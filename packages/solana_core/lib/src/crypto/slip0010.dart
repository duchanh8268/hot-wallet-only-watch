import 'dart:convert';
import 'dart:typed_data';
import 'package:pointycastle/api.dart' show KeyParameter;
import 'package:pointycastle/digests/sha512.dart';
import 'package:pointycastle/macs/hmac.dart';

import '../address/base58.dart';
import 'ed25519_solana.dart';

/// Represents a SLIP-0010 derived Ed25519 key node.
class Slip0010Key {
  final Uint8List privateKey; // 32 bytes
  final Uint8List chainCode; // 32 bytes
  Uint8List? _publicKey;

  Slip0010Key({
    required Uint8List privateKey,
    required Uint8List chainCode,
  })  : privateKey = Uint8List.fromList(privateKey),
        chainCode = Uint8List.fromList(chainCode) {
    if (this.privateKey.length != 32) {
      throw ArgumentError('privateKey must be 32 bytes');
    }
    if (this.chainCode.length != 32) {
      throw ArgumentError('chainCode must be 32 bytes');
    }
  }

  /// Derives master node from BIP-39 [seed] (typically 64 bytes).
  factory Slip0010Key.fromSeed(Uint8List seed) {
    final keyBytes = Uint8List.fromList(utf8.encode('ed25519 seed'));
    final i = _hmacSha512(keyBytes, seed);
    try {
      return Slip0010Key(
        privateKey: Uint8List.sublistView(i, 0, 32),
        chainCode: Uint8List.sublistView(i, 32, 64),
      );
    } finally {
      Ed25519Solana.zeroize(keyBytes);
      Ed25519Solana.zeroize(i);
    }
  }

  /// Derives child node for hardened [index].
  /// In SLIP-0010 Ed25519, all child derivations MUST be hardened (index >= 0x80000000).
  Slip0010Key deriveHardened(int index) {
    final hardenedIndex = (index >= 0x80000000) ? index : (index | 0x80000000);

    // data = 0x00 || parent_private_key (32) || index_big_endian (4)
    final data = Uint8List(37);
    data[0] = 0x00;
    data.setRange(1, 33, privateKey);
    data[33] = (hardenedIndex >> 24) & 0xff;
    data[34] = (hardenedIndex >> 16) & 0xff;
    data[35] = (hardenedIndex >> 8) & 0xff;
    data[36] = hardenedIndex & 0xff;

    final i = _hmacSha512(chainCode, data);
    try {
      return Slip0010Key(
        privateKey: Uint8List.sublistView(i, 0, 32),
        chainCode: Uint8List.sublistView(i, 32, 64),
      );
    } finally {
      Ed25519Solana.zeroize(data);
      Ed25519Solana.zeroize(i);
    }
  }

  /// Derives a path of hardened indices: e.g. [44, 501, 0, 0] for `m/44'/501'/0'/0'`.
  Slip0010Key derivePath(List<int> path) {
    var curr = this;
    for (final idx in path) {
      final next = curr.deriveHardened(idx);
      if (curr != this) {
        curr.dispose();
      }
      curr = next;
    }
    return curr;
  }

  /// Derives Solana standard account path: `m/44'/501'/accountIndex'/0'`.
  Slip0010Key deriveSolanaAccount({int accountIndex = 0}) {
    return derivePath([44, 501, accountIndex, 0]);
  }

  /// Derives Sui standard account path: `m/44'/784'/accountIndex'/0'/0'`.
  Slip0010Key deriveSuiAccount({int accountIndex = 0, int addressIndex = 0}) {
    return derivePath([44, 784, accountIndex, 0, addressIndex]);
  }

  /// The 32-byte Ed25519 public key.
  Uint8List get publicKey {
    return Uint8List.fromList(_publicKey ??= Ed25519Solana.derivePublicKey(privateKey));
  }

  /// The Base58-encoded Solana address.
  String get solanaAddress => Base58.encode(publicKey);

  /// Signs [message] using this key.
  Uint8List sign(Uint8List message) {
    return Ed25519Solana.sign(
      message: message,
      privateKey32: privateKey,
    );
  }

  /// Zeroizes sensitive private key bytes in memory.
  void dispose() {
    Ed25519Solana.zeroize(privateKey);
    Ed25519Solana.zeroize(chainCode);
    if (_publicKey != null) {
      Ed25519Solana.zeroize(_publicKey);
    }
  }

  static Uint8List _hmacSha512(Uint8List key, Uint8List data) {
    final hmac = HMac(SHA512Digest(), 128)..init(KeyParameter(key));
    final out = Uint8List(64);
    hmac.update(data, 0, data.length);
    hmac.doFinal(out, 0);
    return out;
  }
}
