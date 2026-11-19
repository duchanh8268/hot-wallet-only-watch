import 'dart:typed_data';
import 'package:pointycastle/export.dart' as pc;
import 'bytes_utils.dart';

/// Pure Dart secp256k1 ECDSA signing, verification, and public key derivation.
class Secp256k1 {
  static final pc.ECDomainParameters params = pc.ECDomainParameters('secp256k1');
  static final BigInt n = params.n;
  static final BigInt p = BigInt.parse('fffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2f', radix: 16);
  static final BigInt halfN = n >> 1;

  const Secp256k1._();

  /// Derives uncompressed 64-byte public key (X || Y without 0x04 prefix) from 32-byte [privateKey].
  static Uint8List getPublicKey64(Uint8List privateKey) {
    final d = _bytesToBigInt(privateKey);
    if (d <= BigInt.zero || d >= n) {
      throw ArgumentError('Invalid secp256k1 private key');
    }
    final q = params.G * d;
    if (q == null || q.isInfinity) {
      throw StateError('Derived public key point is at infinity');
    }
    final xBytes = _bigIntTo32Bytes(q.x!.toBigInteger()!);
    final yBytes = _bigIntTo32Bytes(q.y!.toBigInteger()!);
    return concatBytes([xBytes, yBytes]);
  }

  /// Derives standard 65-byte uncompressed public key (0x04 || X || Y) from 32-byte [privateKey].
  static Uint8List getPublicKey65(Uint8List privateKey) {
    final pub64 = getPublicKey64(privateKey);
    return concatBytes([Uint8List.fromList([0x04]), pub64]);
  }

  /// Derives 33-byte compressed public key (0x02/0x03 || X) from 32-byte [privateKey].
  static Uint8List getPublicKeyCompressed(Uint8List privateKey) {
    final d = _bytesToBigInt(privateKey);
    final q = params.G * d;
    final xBytes = _bigIntTo32Bytes(q!.x!.toBigInteger()!);
    final prefix = q.y!.toBigInteger()!.isEven ? 0x02 : 0x03;
    return concatBytes([Uint8List.fromList([prefix]), xBytes]);
  }

  /// Signs 32-byte [messageHash] with [privateKey], returning [r, s, recoveryId (0 or 1)].
  /// Enforces canonical low-S (EIP-2).
  static ({Uint8List r, Uint8List s, int recoveryId}) sign(
    Uint8List messageHash,
    Uint8List privateKey,
  ) {
    if (messageHash.length != 32) {
      throw ArgumentError('messageHash must be 32 bytes, got ${messageHash.length}');
    }
    final d = _bytesToBigInt(privateKey);
    if (d <= BigInt.zero || d >= n) {
      throw ArgumentError('Invalid secp256k1 private key');
    }

    final signer = pc.ECDSASigner(null, pc.HMac(pc.SHA256Digest(), 64));
    signer.init(true, pc.PrivateKeyParameter(pc.ECPrivateKey(d, params)));

    final sig = signer.generateSignature(messageHash) as pc.ECSignature;
    var rVal = sig.r;
    var sVal = sig.s;

    // Enforce low-S (EIP-2)
    if (sVal > halfN) {
      sVal = n - sVal;
    }

    final pubKey64 = getPublicKey64(privateKey);

    // Determine recoveryId (0 or 1)
    var recId = -1;
    for (var i = 0; i < 2; i++) {
      final recovered = recoverPublicKey64(messageHash, rVal, sVal, i);
      if (recovered != null && _bytesEqual(recovered, pubKey64)) {
        recId = i;
        break;
      }
    }

    if (recId == -1) {
      throw StateError('Could not calculate secp256k1 recovery ID');
    }

    return (
      r: _bigIntTo32Bytes(rVal),
      s: _bigIntTo32Bytes(sVal),
      recoveryId: recId,
    );
  }

  /// Verifies secp256k1 signature against 64-byte uncompressed public key.
  static bool verify(
    Uint8List messageHash,
    Uint8List r,
    Uint8List s,
    Uint8List publicKey64,
  ) {
    try {
      final rVal = _bytesToBigInt(r);
      final sVal = _bytesToBigInt(s);
      final xVal = _bytesToBigInt(publicKey64.sublist(0, 32));
      final yVal = _bytesToBigInt(publicKey64.sublist(32, 64));

      final q = params.curve.createPoint(xVal, yVal);
      final pubKey = pc.ECPublicKey(q, params);

      final verifier = pc.ECDSASigner();
      verifier.init(false, pc.PublicKeyParameter(pubKey));
      return verifier.verifySignature(messageHash, pc.ECSignature(rVal, sVal));
    } catch (_) {
      return false;
    }
  }

  /// Recovers 64-byte uncompressed public key from (messageHash, r, s, recoveryId).
  static Uint8List? recoverPublicKey64(
    Uint8List messageHash,
    BigInt r,
    BigInt s,
    int recoveryId,
  ) {
    if (r <= BigInt.zero || r >= n || s <= BigInt.zero || s >= n) {
      return null;
    }

    // 1. Compute coordinate x = r + (recId / 2) * n
    final x = r + BigInt.from(recoveryId ~/ 2) * n;
    if (x >= p) {
      return null;
    }

    // 2. Decompress point R on curve y^2 = x^3 + 7
    final isYEven = (recoveryId & 1) == 0;
    pc.ECPoint? R;
    try {
      final compPrefix = isYEven ? 0x02 : 0x03;
      final compBytes = concatBytes([
        Uint8List.fromList([compPrefix]),
        _bigIntTo32Bytes(x),
      ]);
      R = params.curve.decodePoint(compBytes);
    } catch (_) {
      return null;
    }

    if (R == null || R.isInfinity) {
      return null;
    }

    // Check n * R == infinity
    final nR = R * n;
    if (nR == null || !nR.isInfinity) {
      return null;
    }

    // 3. Compute Q = r^-1 * (s * R - e * G)
    final e = _bytesToBigInt(messageHash);
    final rInv = r.modInverse(n);
    final sR = R * s;
    final eG = params.G * e;
    if (sR == null || eG == null) return null;
    final diff = sR - eG;
    if (diff == null) return null;
    final Q = diff * rInv;

    if (Q == null || Q.isInfinity) {
      return null;
    }

    final xBytes = _bigIntTo32Bytes(Q.x!.toBigInteger()!);
    final yBytes = _bigIntTo32Bytes(Q.y!.toBigInteger()!);
    return concatBytes([xBytes, yBytes]);
  }

  static BigInt _bytesToBigInt(List<int> bytes) {
    var result = BigInt.zero;
    for (final b in bytes) {
      result = (result << 8) | BigInt.from(b);
    }
    return result;
  }

  static Uint8List _bigIntTo32Bytes(BigInt number) {
    final out = Uint8List(32);
    var v = number;
    for (var i = 31; i >= 0; i--) {
      out[i] = (v & BigInt.from(0xff)).toInt();
      v = v >> 8;
    }
    return out;
  }

  static bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
