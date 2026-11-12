import 'dart:typed_data';
import 'package:pointycastle/digests/blake2b.dart';

/// Computes a Blake2b digest of [data] with the specified [digestSize] in bytes (1..64).
Uint8List blake2b(Uint8List data, {required int digestSize}) {
  if (digestSize < 1 || digestSize > 64) {
    throw RangeError.range(digestSize, 1, 64, 'digestSize');
  }
  final digest = Blake2bDigest(digestSize: digestSize);
  final out = Uint8List(digestSize);
  digest.update(data, 0, data.length);
  digest.doFinal(out, 0);
  return out;
}

/// Computes Blake2b-224 (28 bytes), used in Cardano key/script hashes.
Uint8List blake2b224(Uint8List data) => blake2b(data, digestSize: 28);

/// Computes Blake2b-256 (32 bytes), used in Cardano transaction body hashes and headers.
Uint8List blake2b256(Uint8List data) => blake2b(data, digestSize: 32);
