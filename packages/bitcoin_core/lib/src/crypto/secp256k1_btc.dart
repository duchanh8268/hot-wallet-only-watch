import 'dart:typed_data';
import 'package:pointycastle/export.dart' as pc;

/// Pure Dart secp256k1 ECDSA operations for Bitcoin (compressed keys, low-S, DER encoding).
class Secp256k1Btc {
  static final pc.ECDomainParameters params = pc.ECDomainParameters('secp256k1');
  static final BigInt n = params.n;
  static final BigInt halfN = n >> 1;

  const Secp256k1Btc._();

  /// Derives standard 33-byte compressed public key (0x02/0x03 || X) from 32-byte [privateKey].
  static Uint8List getPublicKeyCompressed(Uint8List privateKey) {
    final d = _bytesToBigInt(privateKey);
    if (d <= BigInt.zero || d >= n) {
      throw ArgumentError('Invalid secp256k1 private key');
    }
    final q = params.G * d;
    if (q == null || q.isInfinity) {
      throw StateError('Derived public key point is at infinity');
    }
    final xBytes = _bigIntTo32Bytes(q.x!.toBigInteger()!);
    final prefix = q.y!.toBigInteger()!.isEven ? 0x02 : 0x03;
    return Uint8List.fromList([prefix, ...xBytes]);
  }

  /// Derives 65-byte uncompressed public key (0x04 || X || Y) from 32-byte [privateKey].
  static Uint8List getPublicKeyUncompressed(Uint8List privateKey) {
    final d = _bytesToBigInt(privateKey);
    if (d <= BigInt.zero || d >= n) {
      throw ArgumentError('Invalid secp256k1 private key');
    }
    final q = params.G * d;
    final xBytes = _bigIntTo32Bytes(q!.x!.toBigInteger()!);
    final yBytes = _bigIntTo32Bytes(q.y!.toBigInteger()!);
    return Uint8List.fromList([0x04, ...xBytes, ...yBytes]);
  }

  /// Signs 32-byte [sighash] with [privateKey], returning canonical low-S [r] and [s].
  static ({Uint8List r, Uint8List s}) sign(Uint8List sighash, Uint8List privateKey) {
    if (sighash.length != 32) {
      throw ArgumentError('Sighash must be 32 bytes, got ${sighash.length}');
    }
    if (privateKey.length != 32) {
      throw ArgumentError('Private key must be 32 bytes');
    }

    final d = _bytesToBigInt(privateKey);
    if (d <= BigInt.zero || d >= n) {
      throw ArgumentError('Invalid secp256k1 private key');
    }
    final signer = pc.ECDSASigner(null, pc.HMac(pc.SHA256Digest(), 64));
    final privKey = pc.ECPrivateKey(d, params);
    signer.init(true, pc.PrivateKeyParameter(privKey));

    final sig = signer.generateSignature(sighash) as pc.ECSignature;
    var r = sig.r;
    var s = sig.s;

    // Enforce BIP-62 low-S
    if (s > halfN) {
      s = n - s;
    }

    return (
      r: _bigIntTo32Bytes(r),
      s: _bigIntTo32Bytes(s),
    );
  }

  /// Encodes [r] and [s] into standard Bitcoin DER format.
  static Uint8List encodeDerSignature(Uint8List rBytes, Uint8List sBytes) {
    final r = _bytesToBigInt(rBytes);
    final s = _bytesToBigInt(sBytes);
    final rDer = _encodeDerInteger(r);
    final sDer = _encodeDerInteger(s);

    final totalLen = rDer.length + sDer.length;
    return Uint8List.fromList([
      0x30, // Sequence tag
      totalLen,
      ...rDer,
      ...sDer,
    ]);
  }

  /// Signs [sighash] and returns DER-encoded signature with [sighashType] byte appended (e.g. 0x01 SIGHASH_ALL).
  static Uint8List signDer(Uint8List sighash, Uint8List privateKey, {int sighashType = 0x01}) {
    final sig = sign(sighash, privateKey);
    final der = encodeDerSignature(sig.r, sig.s);
    return Uint8List.fromList([...der, sighashType]);
  }

  /// Verifies a DER signature (without sighashType byte) against [sighash] and [compressedPubKey].
  static bool verifyDer(Uint8List sighash, Uint8List derSignature, Uint8List compressedPubKey) {
    try {
      final (r, s) = _decodeDerSignature(derSignature);
      return verify(sighash, r, s, compressedPubKey);
    } catch (_) {
      return false;
    }
  }

  /// Verifies [r] and [s] against [sighash] and [compressedPubKey].
  /// Enforces BIP-62 low-S (`0 < s <= halfN`) and curve range checks.
  static bool verify(Uint8List sighash, Uint8List rBytes, Uint8List sBytes, Uint8List compressedPubKey) {
    try {
      if (sighash.length != 32 || rBytes.length != 32 || sBytes.length != 32) {
        return false;
      }
      final r = _bytesToBigInt(rBytes);
      final s = _bytesToBigInt(sBytes);
      if (r <= BigInt.zero || r >= n || s <= BigInt.zero || s > halfN) {
        return false;
      }
      final point = params.curve.decodePoint(compressedPubKey);
      if (point == null || point.isInfinity) return false;

      final pubKey = pc.ECPublicKey(point, params);
      final verifier = pc.ECDSASigner(null, pc.HMac(pc.SHA256Digest(), 64));
      verifier.init(false, pc.PublicKeyParameter(pubKey));

      return verifier.verifySignature(sighash, pc.ECSignature(r, s));
    } catch (_) {
      return false;
    }
  }

  static Uint8List _encodeDerInteger(BigInt value) {
    var bytes = _bigIntToBytes(value);
    if (bytes.isEmpty) bytes = Uint8List.fromList([0]);
    // If high bit is set, prefix with 0x00 to indicate positive integer in two's complement
    if ((bytes[0] & 0x80) != 0) {
      bytes = Uint8List.fromList([0x00, ...bytes]);
    }
    return Uint8List.fromList([0x02, bytes.length, ...bytes]);
  }

  static (Uint8List, Uint8List) _decodeDerSignature(Uint8List der) {
    if (der.length < 8 || der[0] != 0x30) {
      throw const FormatException('Invalid DER signature tag');
    }
    final seqLen = der[1];
    if (seqLen + 2 != der.length) {
      throw const FormatException('Invalid DER sequence length or trailing bytes');
    }
    var offset = 2;
    if (offset + 2 > der.length || der[offset] != 0x02) {
      throw const FormatException('Invalid DER integer tag for R');
    }
    final rLen = der[offset + 1];
    offset += 2;
    if (rLen == 0 || rLen > 33 || offset + rLen > der.length) {
      throw const FormatException('Invalid DER R length');
    }
    var r = der.sublist(offset, offset + rLen);
    if ((r[0] & 0x80) != 0 || (rLen > 1 && r[0] == 0x00 && (r[1] & 0x80) == 0)) {
      throw const FormatException('Non-canonical DER R integer encoding');
    }
    offset += rLen;

    if (offset + 2 > der.length || der[offset] != 0x02) {
      throw const FormatException('Invalid DER integer tag for S');
    }
    final sLen = der[offset + 1];
    offset += 2;
    if (sLen == 0 || sLen > 33 || offset + sLen != der.length) {
      throw const FormatException('Invalid DER S length or trailing bytes');
    }
    var s = der.sublist(offset, offset + sLen);
    if ((s[0] & 0x80) != 0 || (sLen > 1 && s[0] == 0x00 && (s[1] & 0x80) == 0)) {
      throw const FormatException('Non-canonical DER S integer encoding');
    }

    if (r.isNotEmpty && r[0] == 0x00) r = r.sublist(1);
    if (s.isNotEmpty && s[0] == 0x00) s = s.sublist(1);

    return (_bigIntTo32Bytes(_bytesToBigInt(r)), _bigIntTo32Bytes(_bytesToBigInt(s)));
  }

  static BigInt _bytesToBigInt(Uint8List bytes) {
    var result = BigInt.zero;
    for (final b in bytes) {
      result = (result << 8) | BigInt.from(b);
    }
    return result;
  }

  static Uint8List _bigIntTo32Bytes(BigInt value) {
    final hex = value.toRadixString(16).padLeft(64, '0');
    final bytes = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return bytes;
  }

  static Uint8List _bigIntToBytes(BigInt value) {
    var hex = value.toRadixString(16);
    if (hex.length.isOdd) hex = '0$hex';
    final len = hex.length ~/ 2;
    final bytes = Uint8List(len);
    for (var i = 0; i < len; i++) {
      bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return bytes;
  }
}
