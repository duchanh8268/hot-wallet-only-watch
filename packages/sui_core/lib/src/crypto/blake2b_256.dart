import 'dart:typed_data';
import 'package:pointycastle/digests/blake2b.dart';

/// Computes a 32-byte Blake2b-256 digest of [data].
Uint8List blake2b256(Uint8List data) {
  final digest = Blake2bDigest(digestSize: 32);
  final out = Uint8List(32);
  digest.update(data, 0, data.length);
  digest.doFinal(out, 0);
  return out;
}
