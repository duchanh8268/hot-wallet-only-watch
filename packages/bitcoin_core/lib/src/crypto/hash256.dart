import 'dart:typed_data';
import 'package:crypto/crypto.dart' as crypto;

/// Computes SHA256(SHA256(data)) commonly used in Bitcoin.
Uint8List hash256(Uint8List data) {
  final first = crypto.sha256.convert(data).bytes;
  final second = crypto.sha256.convert(first).bytes;
  return Uint8List.fromList(second);
}

/// Computes single SHA-256.
Uint8List sha256Hash(Uint8List data) {
  return Uint8List.fromList(crypto.sha256.convert(data).bytes);
}
