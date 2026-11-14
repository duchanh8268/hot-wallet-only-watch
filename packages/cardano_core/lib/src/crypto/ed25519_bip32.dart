import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/api.dart' show KeyParameter;
import 'package:pointycastle/digests/sha512.dart';
import 'package:pointycastle/key_derivators/api.dart' show Pbkdf2Parameters;
import 'package:pointycastle/key_derivators/pbkdf2.dart';
import 'package:pointycastle/macs/hmac.dart';

import 'bytes.dart';

/// Extended 96-byte Ed25519-BIP32 Private Key (kL[32] || kR[32] || chainCode[32]).
class ExtendedPrivateKey {
  final Uint8List bytes;

  ExtendedPrivateKey(Uint8List raw)
      : bytes = Uint8List.fromList(raw) {
    if (bytes.length != 96) {
      throw ArgumentError('ExtendedPrivateKey must be 96 bytes, got ${bytes.length}');
    }
  }

  /// Derives the Icarus V2 Master Key from BIP-39 [entropy] and optional [passphrase].
  factory ExtendedPrivateKey.fromIcarusEntropy(
    Uint8List entropy, {
    String passphrase = '',
  }) {
    final passwordBytes = Uint8List.fromList(utf8.encode(passphrase));
    final pbkdf2 = PBKDF2KeyDerivator(HMac(SHA512Digest(), 128));
    pbkdf2.init(Pbkdf2Parameters(entropy, 4096, 96));
    Uint8List? out;
    try {
      out = pbkdf2.process(passwordBytes);
      return ExtendedPrivateKey.fromIcarusSeed(out);
    } finally {
      zeroize(passwordBytes);
      zeroize(out);
    }
  }

  /// Constructs an Icarus V2 Master Key from a pre-derived 96-byte PBKDF2-HMAC-SHA512 seed.
  factory ExtendedPrivateKey.fromIcarusSeed(Uint8List seed96) {
    if (seed96.length != 96) {
      throw ArgumentError('Icarus seed must be 96 bytes, got ${seed96.length}');
    }
    final clamped = Uint8List.fromList(seed96);
    try {
      // Ed25519-BIP32 / CIP-3 scalar clamping on kL
      clamped[0] &= 0xf8;
      clamped[31] = (clamped[31] & 0x1f) | 0x40;
      return ExtendedPrivateKey(clamped);
    } finally {
      zeroize(clamped);
    }
  }

  Uint8List get kL => Uint8List.sublistView(bytes, 0, 32);
  Uint8List get kR => Uint8List.sublistView(bytes, 32, 64);
  Uint8List get chainCode => Uint8List.sublistView(bytes, 64, 96);

  /// Computes the 32-byte Ed25519 public key `A = kL * B`.
  Uint8List get publicKey {
    final scalar = _bytesToBigIntLe(kL);
    return _encodePoint(_scalarMultBase(scalar));
  }

  /// Returns the 64-byte Extended Public Key (pub[32] || chainCode[32]).
  ExtendedPublicKey toExtendedPublicKey() {
    final pub = publicKey;
    final out = Uint8List(64);
    out.setRange(0, 32, pub);
    out.setRange(32, 64, chainCode);
    return ExtendedPublicKey(out);
  }

  /// Derives a child [ExtendedPrivateKey] using Ed25519-BIP32 V2 specification.
  /// Use [index] >= 0x80000000 for hardened derivation.
  ExtendedPrivateKey deriveChild(int index) {
    final isHardened = (index & 0x80000000) != 0;
    final idxLe = uint32ToLe(index);

    final Uint8List zInput;
    final Uint8List cInput;
    if (isHardened) {
      zInput = concatBytes([
        [0x00],
        kL,
        kR,
        idxLe,
      ]);
      cInput = concatBytes([
        [0x01],
        kL,
        kR,
        idxLe,
      ]);
    } else {
      final pub = publicKey;
      zInput = concatBytes([
        [0x02],
        pub,
        idxLe,
      ]);
      cInput = concatBytes([
        [0x03],
        pub,
        idxLe,
      ]);
    }

    final zMac = _hmacSha512(chainCode, zInput);
    final cMac = _hmacSha512(chainCode, cInput);
    zeroize(zInput);
    zeroize(cInput);

    final childBytes = Uint8List(96);
    Uint8List? childKL;
    Uint8List? childKR;
    try {
      // V2: child_kL = kL + 8 * zL (where zL = Z[0..28])
      final zL = _bytesToBigIntLe(Uint8List.sublistView(zMac, 0, 28));
      final kLInt = _bytesToBigIntLe(kL);
      final childKLInt = kLInt + (zL * BigInt.from(8));
      if (childKLInt >= _twoPow256) {
        throw StateError('Derived child kL overflowed 256 bits');
      }
      if ((childKLInt % _orderL) == BigInt.zero) {
        throw StateError('Derived child kL is congruent to 0 mod L');
      }
      childKL = _bigIntToBytesLe(childKLInt, 32);

      // child_kR = (kR + zR) mod 2^256
      final zR = _bytesToBigIntLe(Uint8List.sublistView(zMac, 32, 64));
      final kRInt = _bytesToBigIntLe(kR);
      final childKRInt = (kRInt + zR) & _mask256;
      childKR = _bigIntToBytesLe(childKRInt, 32);

      childBytes.setRange(0, 32, childKL);
      childBytes.setRange(32, 64, childKR);
      childBytes.setRange(64, 96, Uint8List.sublistView(cMac, 32, 64));

      return ExtendedPrivateKey(childBytes);
    } finally {
      zeroize(zMac);
      zeroize(cMac);
      zeroize(childKL);
      zeroize(childKR);
      zeroize(childBytes);
    }
  }

  /// Convenience helper for hardened derivation (`index | 0x80000000`).
  ExtendedPrivateKey deriveHardened(int index) {
    if (index < 0 || index >= 0x80000000) {
      throw ArgumentError.value(index, 'index', 'Expected 0 <= index < 2^31');
    }
    return deriveChild(index | 0x80000000);
  }

  /// Signs [message] using extended key `(kL, kR)` producing a 64-byte Ed25519 signature.
  /// Optional [auxRand] mixes additional hedged entropy into nonce generation when provided.
  Uint8List sign(Uint8List message, {Uint8List? auxRand}) {
    final pub = publicKey;
    Uint8List? rInput;
    Uint8List? rDigestBytes;
    Uint8List? hInput;
    Uint8List? hDigestBytes;
    Uint8List? sBytes;
    try {
      rInput = (auxRand != null && auxRand.isNotEmpty)
          ? concatBytes([kR, auxRand, message])
          : concatBytes([kR, message]);
      rDigestBytes = Uint8List.fromList(sha512.convert(rInput).bytes);
      final r = _bytesToBigIntLe(rDigestBytes) % _orderL;
      final rPoint = _encodePoint(_scalarMultBase(r));

      hInput = concatBytes([rPoint, pub, message]);
      hDigestBytes = Uint8List.fromList(sha512.convert(hInput).bytes);
      final h = _bytesToBigIntLe(hDigestBytes) % _orderL;

      final kLInt = _bytesToBigIntLe(kL);
      final s = (r + (h * kLInt)) % _orderL;
      sBytes = _bigIntToBytesLe(s, 32);

      final sig = Uint8List(64);
      sig.setRange(0, 32, rPoint);
      sig.setRange(32, 64, sBytes);

      // Verify-Before-Output countermeasure against fault injection / bit-flip attacks
      if (!Ed25519.verify(pub, message, sig)) {
        zeroize(sig);
        throw StateError('Ed25519 fault check failed: generated signature did not verify');
      }
      return sig;
    } finally {
      zeroize(rInput);
      zeroize(rDigestBytes);
      zeroize(hInput);
      zeroize(hDigestBytes);
      zeroize(sBytes);
    }
  }

  /// Overwrites internal secret key material with zeros.
  void dispose() => zeroize(bytes);
}

/// Extended 64-byte Ed25519-BIP32 Public Key (pub[32] || chainCode[32]).
class ExtendedPublicKey {
  final Uint8List bytes;

  ExtendedPublicKey(Uint8List raw)
      : bytes = Uint8List.fromList(raw) {
    if (bytes.length != 64) {
      throw ArgumentError('ExtendedPublicKey must be 64 bytes, got ${bytes.length}');
    }
  }

  Uint8List get publicKey => Uint8List.sublistView(bytes, 0, 32);
  Uint8List get chainCode => Uint8List.sublistView(bytes, 32, 64);

  /// Soft (non-hardened) public child derivation (`0 <= index < 2^31`).
  ExtendedPublicKey deriveChild(int index) {
    if (index < 0 || index >= 0x80000000) {
      throw ArgumentError.value(index, 'index', 'Public derivation requires 0 <= index < 2^31');
    }
    final idxLe = uint32ToLe(index);
    final zInput = concatBytes([
      [0x02],
      publicKey,
      idxLe,
    ]);
    final cInput = concatBytes([
      [0x03],
      publicKey,
      idxLe,
    ]);

    final zMac = _hmacSha512(chainCode, zInput);
    final cMac = _hmacSha512(chainCode, cInput);

    final zL = _bytesToBigIntLe(Uint8List.sublistView(zMac, 0, 28));
    final parentPoint = _decodePoint(publicKey);
    final tweakPoint = _scalarMultBase(zL * BigInt.from(8));
    final childPub = _encodePoint(_pointAdd(parentPoint, tweakPoint));

    final out = Uint8List(64);
    out.setRange(0, 32, childPub);
    out.setRange(32, 64, Uint8List.sublistView(cMac, 32, 64));
    return ExtendedPublicKey(out);
  }
}

/// Ed25519 signature verification (RFC 8032 cofactor-8 equation with small-order public key rejection).
class Ed25519 {
  static bool verify(
    Uint8List publicKey,
    Uint8List message,
    Uint8List signature,
  ) {
    if (publicKey.length != 32 || signature.length != 64) {
      return false;
    }
    try {
      final aPoint = _decodePoint(publicKey);
      // Reject small-order / torsion public keys ([8]A == Identity)
      final a8 = _scalarMultSmall(aPoint, 8);
      if (constantTimeEquals(_encodePoint(a8), _encodePoint(_EdPoint.identity))) {
        return false;
      }

      final rBytes = Uint8List.sublistView(signature, 0, 32);
      final sBytes = Uint8List.sublistView(signature, 32, 64);
      final rPoint = _decodePoint(rBytes);
      final s = _bytesToBigIntLe(sBytes);
      if (s < BigInt.zero || s >= _orderL) {
        return false;
      }

      final hDigest = sha512.convert(concatBytes([rBytes, publicKey, message])).bytes;
      final h = _bytesToBigIntLe(Uint8List.fromList(hDigest)) % _orderL;

      final sG = _scalarMultBase(s);
      final rPlusHa = _pointAdd(rPoint, _scalarMult(aPoint, h));

      // Verify [8](S*G) == [8](R + h*A)
      final lhs = _scalarMultSmall(sG, 8);
      final rhs = _scalarMultSmall(rPlusHa, 8);
      return constantTimeEquals(_encodePoint(lhs), _encodePoint(rhs));
    } catch (_) {
      return false;
    }
  }
}

// ============================================================================
// Curve25519 / Ed25519 Pure Dart Arithmetic (Extended Twisted Edwards)
// ============================================================================

final BigInt _p = (BigInt.one << 255) - BigInt.from(19);
final BigInt _twoPow256 = BigInt.one << 256;
final BigInt _mask256 = (BigInt.one << 256) - BigInt.one;
final BigInt _orderL = (BigInt.one << 252) +
    BigInt.parse('27742317777372353535851937790883648493');

final BigInt _d =
    (BigInt.from(-121665) * BigInt.from(121666).modInverse(_p)) % _p;
final BigInt _d2 = (_d * BigInt.two) % _p;
final BigInt _sqrtM1 = BigInt.parse(
  '19681161376707505956807079304988542015446066515923890162744021073123829784752',
);
final BigInt _pMinus5Div8 = (_p - BigInt.from(5)) >> 3;

final _EdPoint _basePoint = _initBasePoint();

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

_EdPoint _initBasePoint() {
  final y = (BigInt.from(4) * BigInt.from(5).modInverse(_p)) % _p;
  final x = _recoverX(y, 0);
  return _EdPoint(x, y, BigInt.one, (x * y) % _p);
}

BigInt _modP(BigInt v) {
  final r = v % _p;
  return r.isNegative ? r + _p : r;
}

BigInt _recoverX(BigInt y, int signBit) {
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

_EdPoint _pointAdd(_EdPoint p1, _EdPoint p2) {
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

_EdPoint _pointDouble(_EdPoint p1) {
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

_EdPoint _scalarMult(_EdPoint p, BigInt k) {
  var result = _EdPoint.identity;
  var addend = p;
  var scalar = k;
  final bitCount = scalar >= _twoPow256 ? scalar.bitLength : 256;
  for (var i = 0; i < bitCount; i++) {
    final selected = scalar.isOdd ? addend : _EdPoint.identity;
    result = _pointAdd(result, selected);
    addend = _pointDouble(addend);
    scalar >>= 1;
  }
  return result;
}

_EdPoint _scalarMultSmall(_EdPoint p, int k) {
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

List<List<_EdPoint>>? _baseNibbleTable;

List<List<_EdPoint>> _getBaseNibbleTable() {
  final existing = _baseNibbleTable;
  if (existing != null) return existing;

  final table = <List<_EdPoint>>[];
  var windowBase = _basePoint;
  for (var w = 0; w < 64; w++) {
    final row = List<_EdPoint>.filled(16, _EdPoint.identity);
    var acc = _EdPoint.identity;
    for (var d = 1; d < 16; d++) {
      acc = _pointAdd(acc, windowBase);
      row[d] = acc;
    }
    table.add(row);
    // Advance windowBase by 16x (4 doublings) for next nibble window
    if (w < 63) {
      windowBase = _pointDouble(_pointDouble(_pointDouble(_pointDouble(windowBase))));
    }
  }
  _baseNibbleTable = table;
  return table;
}

_EdPoint _scalarMultBase(BigInt k) {
  if (k < BigInt.zero || k >= _twoPow256) {
    return _scalarMult(_basePoint, k);
  }
  final table = _getBaseNibbleTable();
  var result = _EdPoint.identity;
  var scalar = k;
  final mask4 = BigInt.from(0x0f);
  for (var w = 0; w < 64; w++) {
    final nib = (scalar & mask4).toInt();
    result = _pointAdd(result, table[w][nib]);
    scalar >>= 4;
  }
  return result;
}

Uint8List _encodePoint(_EdPoint p) {
  final zInv = p.z.modInverse(_p);
  final x = (p.x * zInv) % _p;
  final y = (p.y * zInv) % _p;
  final out = _bigIntToBytesLe(y, 32);
  if (x.isOdd) {
    out[31] |= 0x80;
  }
  return out;
}

_EdPoint _decodePoint(Uint8List bytes) {
  if (bytes.length != 32) {
    throw const FormatException('Encoded Ed25519 point must be 32 bytes');
  }
  final copy = Uint8List.fromList(bytes);
  final signBit = (copy[31] >> 7) & 1;
  copy[31] &= 0x7f;
  final y = _bytesToBigIntLe(copy);
  if (y >= _p) {
    throw const FormatException('Invalid Ed25519 point: y >= p');
  }
  final x = _recoverX(y, signBit);
  final pt = _EdPoint(x, y, BigInt.one, (x * y) % _p);
  if (!constantTimeEquals(_encodePoint(pt), bytes)) {
    throw const FormatException('Invalid Ed25519 point: non-canonical encoding');
  }
  return pt;
}

Uint8List _hmacSha512(Uint8List key, Uint8List data) {
  final mac = HMac(SHA512Digest(), 128)..init(KeyParameter(key));
  final out = Uint8List(64);
  mac.update(data, 0, data.length);
  mac.doFinal(out, 0);
  return out;
}

BigInt _bytesToBigIntLe(Uint8List bytes) {
  var result = BigInt.zero;
  for (var i = bytes.length - 1; i >= 0; i--) {
    result = (result << 8) | BigInt.from(bytes[i]);
  }
  return result;
}

Uint8List _bigIntToBytesLe(BigInt value, int length) {
  final out = Uint8List(length);
  var v = value;
  for (var i = 0; i < length; i++) {
    out[i] = (v & BigInt.from(0xff)).toInt();
    v >>= 8;
  }
  return out;
}
