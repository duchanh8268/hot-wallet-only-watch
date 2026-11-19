import 'dart:typed_data';
import 'package:pointycastle/export.dart' as pc;

/// Pure Dart Keccak-256 (Ethereum SHA3 variant).
class Keccak256 {
  const Keccak256._();

  /// Computes 32-byte Keccak-256 hash of [data].
  static Uint8List hash(List<int> data) {
    final digest = pc.KeccakDigest(256);
    final input = data is Uint8List ? data : Uint8List.fromList(data);
    return digest.process(input);
  }
}

/// Helper function to compute Keccak-256.
Uint8List keccak256(List<int> data) => Keccak256.hash(data);
