import 'dart:typed_data';
import 'package:crypto/crypto.dart';

/// Pure Dart RFC 8032 Ed25519 cryptographic primitives.
class Ed25519Solana {
  const Ed25519Solana._();

  /// Derives the 32-byte Ed25519 public key from a 32-byte seed/private key (RFC 8032).
  static Uint8List derivePublicKey(Uint8List privateKey32) {
    if (privateKey32.length != 32) {
      throw ArgumentError('Khóa riêng Ed25519 phải đúng 32 bytes');
    }
    final h = Uint8List.fromList(sha512.convert(privateKey32).bytes);
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
    final h = Uint8List.fromList(sha512.convert(privateKey32).bytes);
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

      rDigest = Uint8List.fromList(sha512.convert(rInput).bytes);
      final r = _bytesToBigIntLe(rDigest) % _orderL;
      final rPoint = _encodePoint(_scalarMultBase(r));

      // k = SHA512(R || A || M) mod L
      kInput = Uint8List(32 + 32 + message.length);
      kInput.setRange(0, 32, rPoint);
      kInput.setRange(32, 64, pubKey);
      kInput.setRange(64, kInput.length, message);

      kDigest = Uint8List.fromList(sha512.convert(kInput).bytes);
      final k = _bytesToBigIntLe(kDigest) % _orderL;

      // S = (r + k * s) mod L
      final S = (r + (k * sInt)) % _orderL;
      sBytes = _bigIntToBytesLe(S, 32);

      final sig = Uint8List(64);
      sig.setRange(0, 32, rPoint);
      sig.setRange(32, 64, sBytes);

      // Verify before output
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
      // Reject small-order / torsion public keys ([8]A == Identity)
      final a8 = _scalarMultSmall(aPoint, 8);
      if (_constantTimeEquals(_encodePoint(a8), _encodePoint(_EdPoint.identity))) {
        return false;
      }

      final rBytes = Uint8List.sublistView(signature, 0, 32);
      final sBytes = Uint8List.sublistView(signature, 32, 64);
      final rPoint = _decodePoint(rBytes);
      final s = _bytesToBigIntLe(sBytes);
      if (s < BigInt.zero || s >= _orderL) {
        return false;
      }

      final kInput = Uint8List(32 + 32 + message.length);
      kInput.setRange(0, 32, rBytes);
      kInput.setRange(32, 64, publicKey);
      kInput.setRange(64, kInput.length, message);

      final hDigest = sha512.convert(kInput).bytes;
      final h = _bytesToBigIntLe(Uint8List.fromList(hDigest)) % _orderL;

      final sG = _scalarMultBase(s);
      final rPlusHa = _pointAdd(rPoint, _scalarMult(aPoint, h));

      // Verify [8](S*G) == [8](R + h*A)
      final lhs = _scalarMultSmall(sG, 8);
      final rhs = _scalarMultSmall(rPlusHa, 8);
      return _constantTimeEquals(_encodePoint(lhs), _encodePoint(rhs));
    } catch (_) {
      return false;
    }
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
}

// ============================================================================
// Curve25519 / Ed25519 Pure Dart Arithmetic (Extended Twisted Edwards)
// ============================================================================

final BigInt _p = (BigInt.one << 255) - BigInt.from(19);
final BigInt _twoPow256 = BigInt.one << 256;
final BigInt _orderL = (BigInt.one << 252) +
    BigInt.parse('27742317777372353535851937790883648493');
final BigInt _d = _modP(
  -BigInt.from(121665) * BigInt.from(121666).modInverse(_p),
);
final BigInt _d2 = _modP(BigInt.two * _d);
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

_EdPoint _scalarMultBase(BigInt k) {
  return _scalarMult(_basePoint, k);
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
  return pt;
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
