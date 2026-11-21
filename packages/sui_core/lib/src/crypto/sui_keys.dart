import 'dart:convert';
import 'dart:typed_data';
import 'package:chain_core_interface/chain_core_interface.dart' show hexEncode;
import 'package:pointycastle/api.dart' show KeyParameter;
import 'package:pointycastle/digests/sha512.dart';
import 'package:pointycastle/macs/hmac.dart';
import 'blake2b_256.dart';

/// Pure Dart RFC 8032 Ed25519 cryptographic primitives for Sui.
class SuiEd25519 {
  static final BigInt _p = (BigInt.one << 255) - BigInt.from(19);
  static final BigInt _twoPow256 = BigInt.one << 256;
  static final BigInt _orderL = (BigInt.one << 252) +
      BigInt.parse('27742317777372353535851937790883648493');
  static final BigInt _d = _modP(
    -BigInt.from(121665) * BigInt.from(121666).modInverse(_p),
  );
  static final BigInt _d2 = _modP(BigInt.two * _d);
  static final BigInt _sqrtM1 = BigInt.parse(
    '19681161376707505956807079304988542015446066515923890162744021073123829784752',
  );
  static final BigInt _pMinus5Div8 = (_p - BigInt.from(5)) >> 3;

  static final _EdPoint _basePoint = _initBasePoint();

  const SuiEd25519._();

  /// Derives the 32-byte Ed25519 public key from a 32-byte private key (RFC 8032).
  static Uint8List derivePublicKey(Uint8List privateKey32) {
    if (privateKey32.length != 32) {
      throw ArgumentError('Khóa riêng Ed25519 phải đúng 32 bytes');
    }
    final h = _sha512(privateKey32);
    Uint8List? s;
    try {
      s = _clampScalar(Uint8List.sublistView(h, 0, 32));
      final sInt = _bytesToBigIntLe(s);
      final pt = _scalarMultBase(sInt);
      return _encodePoint(pt);
    } finally {
      zeroize(h);
      zeroize(s);
    }
  }

  /// Signs [message] with a 32-byte Ed25519 [privateKey32] producing a 64-byte signature.
  static Uint8List sign({
    required Uint8List message,
    required Uint8List privateKey32,
  }) {
    if (privateKey32.length != 32) {
      throw ArgumentError('Khóa riêng Ed25519 phải đúng 32 bytes');
    }
    final h = _sha512(privateKey32);
    Uint8List? s;
    Uint8List? rInput;
    Uint8List? rDigest;
    Uint8List? kInput;
    Uint8List? kDigest;
    Uint8List? sBytes;
    try {
      s = _clampScalar(Uint8List.sublistView(h, 0, 32));
      final sInt = _bytesToBigIntLe(s);
      final pubKey = _encodePoint(_scalarMultBase(sInt));

      // r = SHA512(prefix || message) mod L
      final prefix = Uint8List.sublistView(h, 32, 64);
      rInput = Uint8List(prefix.length + message.length);
      rInput.setRange(0, prefix.length, prefix);
      rInput.setRange(prefix.length, rInput.length, message);

      rDigest = _sha512(rInput);
      final r = _bytesToBigIntLe(rDigest) % _orderL;
      final rPoint = _encodePoint(_scalarMultBase(r));

      // k = SHA512(R || A || M) mod L
      kInput = Uint8List(32 + 32 + message.length);
      kInput.setRange(0, 32, rPoint);
      kInput.setRange(32, 64, pubKey);
      kInput.setRange(64, kInput.length, message);

      kDigest = _sha512(kInput);
      final k = _bytesToBigIntLe(kDigest) % _orderL;

      // S = (r + k * s) mod L
      final S = (r + (k * sInt)) % _orderL;
      sBytes = _bigIntToBytesLe(S, 32);

      final sig = Uint8List(64);
      sig.setRange(0, 32, rPoint);
      sig.setRange(32, 64, sBytes);

      if (!verify(publicKey: pubKey, message: message, signature: sig)) {
        throw StateError('Lỗi kiểm tra chữ ký Ed25519 thất bại');
      }
      return sig;
    } finally {
      zeroize(h);
      zeroize(s);
      zeroize(rInput);
      zeroize(rDigest);
      zeroize(kInput);
      zeroize(kDigest);
      zeroize(sBytes);
    }
  }

  /// Verifies an Ed25519 [signature] against [publicKey] and [message].
  static bool verify({
    required Uint8List publicKey,
    required Uint8List message,
    required Uint8List signature,
  }) {
    if (publicKey.length != 32 || signature.length != 64) {
      return false;
    }
    try {
      final aPoint = _decodePoint(publicKey);
      final a8 = _scalarMultSmall(aPoint, 8);
      if (_constantTimeEquals(_encodePoint(a8), _encodePoint(_EdPoint.identity))) {
        return false;
      }

      final rBytes = Uint8List.sublistView(signature, 0, 32);
      final sBytes = Uint8List.sublistView(signature, 32, 64);
      final rPoint = _decodePoint(rBytes);
      final s = _bytesToBigIntLe(sBytes);
      if (s < BigInt.zero || s >= _orderL) return false;

      final kInput = Uint8List(32 + 32 + message.length);
      kInput.setRange(0, 32, rBytes);
      kInput.setRange(32, 64, publicKey);
      kInput.setRange(64, kInput.length, message);

      final hDigest = _sha512(kInput);
      final h = _bytesToBigIntLe(hDigest) % _orderL;

      final sG = _scalarMultBase(s);
      final rPlusHa = _pointAdd(rPoint, _scalarMult(aPoint, h));

      final lhs = _scalarMultSmall(sG, 8);
      final rhs = _scalarMultSmall(rPlusHa, 8);
      return _constantTimeEquals(_encodePoint(lhs), _encodePoint(rhs));
    } catch (_) {
      return false;
    }
  }

  static Uint8List _sha512(Uint8List data) {
    final digest = SHA512Digest();
    final out = Uint8List(64);
    digest.update(data, 0, data.length);
    digest.doFinal(out, 0);
    return out;
  }

  static Uint8List _clampScalar(Uint8List key32) {
    final clamped = Uint8List.fromList(key32);
    clamped[0] &= 248;
    clamped[31] &= 127;
    clamped[31] |= 64;
    return clamped;
  }

  static bool _constantTimeEquals(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  static void zeroize(Uint8List? bytes) {
    if (bytes == null) return;
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = 0;
    }
  }

  static _EdPoint _initBasePoint() {
    final y = (BigInt.from(4) * BigInt.from(5).modInverse(_p)) % _p;
    final x = _recoverX(y, 0);
    return _EdPoint(x, y, BigInt.one, (x * y) % _p);
  }

  static BigInt _modP(BigInt v) {
    final r = v % _p;
    return r.isNegative ? r + _p : r;
  }

  static BigInt _recoverX(BigInt y, int signBit) {
    final y2 = (y * y) % _p;
    final u = _modP(y2 - BigInt.one);
    final v = _modP((_d * y2) + BigInt.one);
    final v3 = (v * v * v) % _p;
    final v7 = (v3 * v3 * v) % _p;
    var x = (u * v3 * (u * v7).modPow(_pMinus5Div8, _p)) % _p;
    if (_modP(v * x * x) != u) {
      x = (x * _sqrtM1) % _p;
      if (_modP(v * x * x) != u) {
        throw const FormatException('Invalid Ed25519 point: no square root');
      }
    }
    if (x == BigInt.zero && signBit == 1) {
      throw const FormatException('Invalid Ed25519 point: negative zero');
    }
    if ((x.isOdd ? 1 : 0) != signBit) {
      x = _modP(-x);
    }
    return x;
  }

  static _EdPoint _pointAdd(_EdPoint p1, _EdPoint p2) {
    final a = _modP((p1.y - p1.x) * (p2.y - p2.x));
    final b = _modP((p1.y + p1.x) * (p2.y + p2.x));
    final c = _modP(p1.t * _d2 * p2.t);
    final d = _modP(BigInt.two * p1.z * p2.z);
    final e = _modP(b - a);
    final f = _modP(d - c);
    final g = _modP(d + c);
    final h = _modP(b + a);
    return _EdPoint(
      (e * f) % _p,
      (g * h) % _p,
      (f * g) % _p,
      (e * h) % _p,
    );
  }

  static _EdPoint _pointDouble(_EdPoint p1) {
    final a = (p1.x * p1.x) % _p;
    final b = (p1.y * p1.y) % _p;
    final c = (BigInt.two * p1.z * p1.z) % _p;
    final h = _modP(a + b);
    final sum = (p1.x + p1.y) % _p;
    final e = _modP(h - (sum * sum) % _p);
    final g = _modP(a - b);
    final f = _modP(c + g);
    return _EdPoint(
      (e * f) % _p,
      (g * h) % _p,
      (f * g) % _p,
      (e * h) % _p,
    );
  }

  static _EdPoint _scalarMult(_EdPoint p, BigInt k) {
    var result = _EdPoint.identity;
    var addend = p;
    var scalar = k;
    final bitCount = scalar >= _twoPow256 ? scalar.bitLength : 256;
    for (var i = 0; i < bitCount; i++) {
      if (scalar.isOdd) {
        result = _pointAdd(result, addend);
      }
      addend = _pointDouble(addend);
      scalar >>= 1;
    }
    return result;
  }

  static _EdPoint _scalarMultSmall(_EdPoint p, int k) {
    var result = _EdPoint.identity;
    var addend = p;
    var scalar = k;
    while (scalar > 0) {
      if ((scalar & 1) == 1) {
        result = _pointAdd(result, addend);
      }
      addend = _pointDouble(addend);
      scalar >>= 1;
    }
    return result;
  }

  static _EdPoint _scalarMultBase(BigInt k) {
    return _scalarMult(_basePoint, k);
  }

  static Uint8List _encodePoint(_EdPoint p) {
    final zInv = p.z.modInverse(_p);
    final x = (p.x * zInv) % _p;
    final y = (p.y * zInv) % _p;
    final out = _bigIntToBytesLe(y, 32);
    if (x.isOdd) {
      out[31] |= 0x80;
    }
    return out;
  }

  static _EdPoint _decodePoint(Uint8List bytes) {
    if (bytes.length != 32) {
      throw const FormatException('Encoded Ed25519 point must be 32 bytes');
    }
    final copy = Uint8List.fromList(bytes);
    final signBit = (copy[31] >> 7) & 1;
    copy[31] &= 0x7f;
    final y = _bytesToBigIntLe(copy);
    if (y >= _p) throw const FormatException('Invalid Ed25519 point: y >= p');
    final x = _recoverX(y, signBit);
    return _EdPoint(x, y, BigInt.one, (x * y) % _p);
  }

  static BigInt _bytesToBigIntLe(Uint8List bytes) {
    var result = BigInt.zero;
    for (var i = bytes.length - 1; i >= 0; i--) {
      result = (result << 8) | BigInt.from(bytes[i]);
    }
    return result;
  }

  static Uint8List _bigIntToBytesLe(BigInt value, int length) {
    final out = Uint8List(length);
    var v = value;
    for (var i = 0; i < length; i++) {
      out[i] = (v & BigInt.from(0xff)).toInt();
      v >>= 8;
    }
    return out;
  }
}

class _EdPoint {
  final BigInt x;
  final BigInt y;
  final BigInt z;
  final BigInt t;

  const _EdPoint(this.x, this.y, this.z, this.t);

  static final _EdPoint identity = _EdPoint(
    BigInt.zero,
    BigInt.one,
    BigInt.one,
    BigInt.zero,
  );
}

/// Represents a SLIP-0010 derived Ed25519 key node for Sui.
class SuiSlip0010Key {
  final Uint8List privateKey; // 32 bytes
  final Uint8List chainCode; // 32 bytes
  Uint8List? _publicKey;

  SuiSlip0010Key({
    required Uint8List privateKey,
    required Uint8List chainCode,
  })  : privateKey = Uint8List.fromList(privateKey),
        chainCode = Uint8List.fromList(chainCode);

  /// Derives master node from BIP-39 [seed].
  factory SuiSlip0010Key.fromSeed(Uint8List seed) {
    final keyBytes = Uint8List.fromList(utf8.encode('ed25519 seed'));
    final i = Uint8List(64);
    try {
      final hmac = HMac(SHA512Digest(), 128)..init(KeyParameter(keyBytes));
      hmac.update(seed, 0, seed.length);
      hmac.doFinal(i, 0);

      return SuiSlip0010Key(
        privateKey: Uint8List.sublistView(i, 0, 32),
        chainCode: Uint8List.sublistView(i, 32, 64),
      );
    } finally {
      SuiEd25519.zeroize(keyBytes);
      SuiEd25519.zeroize(i);
    }
  }

  /// Derives child node for hardened [index].
  SuiSlip0010Key deriveHardened(int index) {
    final hardenedIndex = (index >= 0x80000000) ? index : (index | 0x80000000);

    final data = Uint8List(37);
    final i = Uint8List(64);
    try {
      data[0] = 0x00;
      data.setRange(1, 33, privateKey);
      data[33] = (hardenedIndex >> 24) & 0xff;
      data[34] = (hardenedIndex >> 16) & 0xff;
      data[35] = (hardenedIndex >> 8) & 0xff;
      data[36] = hardenedIndex & 0xff;

      final hmac = HMac(SHA512Digest(), 128)..init(KeyParameter(chainCode));
      hmac.update(data, 0, data.length);
      hmac.doFinal(i, 0);

      return SuiSlip0010Key(
        privateKey: Uint8List.sublistView(i, 0, 32),
        chainCode: Uint8List.sublistView(i, 32, 64),
      );
    } finally {
      SuiEd25519.zeroize(data);
      SuiEd25519.zeroize(i);
    }
  }

  /// Derives Sui standard account path: `m/44'/784'/accountIndex'/0'/addressIndex'`.
  SuiSlip0010Key deriveSuiAccount({int accountIndex = 0, int addressIndex = 0}) {
    final k44 = deriveHardened(44);
    final k784 = k44.deriveHardened(784);
    k44.dispose();
    final kAcc = k784.deriveHardened(accountIndex);
    k784.dispose();
    final k0 = kAcc.deriveHardened(0);
    kAcc.dispose();
    final kAddr = k0.deriveHardened(addressIndex);
    k0.dispose();
    return kAddr;
  }

  /// 32-byte Ed25519 public key.
  Uint8List get publicKey {
    return Uint8List.fromList(_publicKey ??= SuiEd25519.derivePublicKey(privateKey));
  }

  /// Sui Address: `0x` + Blake2b-256(`0x00` || 32-byte Ed25519 public key).
  String get suiAddress {
    final input = Uint8List(33);
    input[0] = 0x00; // Scheme flag: Ed25519 = 0x00
    input.setRange(1, 33, publicKey);
    final digest = blake2b256(input);
    return hexEncode(digest, prefix0x: true);
  }

  /// Signs [message] using this key.
  Uint8List sign(Uint8List message) {
    return SuiEd25519.sign(
      message: message,
      privateKey32: privateKey,
    );
  }

  /// Signs an Intent Message and returns the serialized 97-byte Sui Signature (base64).
  ///
  /// Serialized format: `0x00` (Ed25519 flag) || 64-byte signature || 32-byte public key
  String signIntentMessage(Uint8List intentMessage) {
    final sig64 = sign(intentMessage);
    final serializedSig = Uint8List(97);
    serializedSig[0] = 0x00; // Ed25519 flag
    serializedSig.setRange(1, 65, sig64);
    serializedSig.setRange(65, 97, publicKey);
    return base64Encode(serializedSig);
  }

  void dispose() {
    SuiEd25519.zeroize(privateKey);
    SuiEd25519.zeroize(chainCode);
    if (_publicKey != null) {
      SuiEd25519.zeroize(_publicKey);
    }
  }
}
