import 'dart:typed_data';
import 'package:crypto/crypto.dart' as crypto;
import 'package:pointycastle/digests/ripemd160.dart';

/// Computes Hash160: RIPEMD-160(SHA-256(data)).
/// Result is exactly 20 bytes, used for Bitcoin addresses and witness programs.
Uint8List hash160(Uint8List data) {
  final sha = crypto.sha256.convert(data).bytes;
  final ripemd = RIPEMD160Digest();
  return ripemd.process(Uint8List.fromList(sha));
}
