import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'bytes_utils.dart';
import 'secp256k1.dart';

/// BIP-32 Hierarchical Deterministic (HD) key derivation for secp256k1 (BIP-44 EVM).
class EvmHdKey {
  final Uint8List privateKey; // 32 bytes
  final Uint8List chainCode;  // 32 bytes
  final int depth;
  final int childIndex;

  EvmHdKey({
    required Uint8List privateKey,
    required Uint8List chainCode,
    this.depth = 0,
    this.childIndex = 0,
  })  : privateKey = Uint8List.fromList(privateKey),
        chainCode = Uint8List.fromList(chainCode) {
    if (this.privateKey.length != 32) {
      throw ArgumentError('privateKey must be 32 bytes');
    }
    if (this.chainCode.length != 32) {
      throw ArgumentError('chainCode must be 32 bytes');
    }
  }

  /// Derives master node from 64-byte (512-bit) BIP-39 [seed].
  factory EvmHdKey.fromSeed(Uint8List seed) {
    if (seed.length < 16 || seed.length > 64) {
      throw ArgumentError('Seed must be between 16 and 64 bytes');
    }
    final hmac = Hmac(sha512, utf8.encode('Bitcoin seed'));
    final i = Uint8List.fromList(hmac.convert(seed).bytes);
    try {
      final il = Uint8List.sublistView(i, 0, 32);
      final ir = Uint8List.sublistView(i, 32, 64);

      return EvmHdKey(
        privateKey: il,
        chainCode: ir,
        depth: 0,
        childIndex: 0,
      );
    } finally {
      zeroize(i);
    }
  }

  /// Derives a child private key at [index]. Hardened index when [index] >= 0x80000000.
  EvmHdKey deriveChild(int index) {
    final isHardened = (index & 0x80000000) != 0;
    final indexBytes = Uint8List(4)
      ..buffer.asByteData().setUint32(0, index, Endian.big);

    final Uint8List data;
    if (isHardened) {
      data = concatBytes([
        Uint8List.fromList([0x00]),
        privateKey,
        indexBytes,
      ]);
    } else {
      final compPub = Secp256k1.getPublicKeyCompressed(privateKey);
      data = concatBytes([
        compPub,
        indexBytes,
      ]);
    }

    final hmac = Hmac(sha512, chainCode);
    final i = Uint8List.fromList(hmac.convert(data).bytes);
    Uint8List? childPriv;
    try {
      final il = Uint8List.sublistView(i, 0, 32);
      final ir = Uint8List.sublistView(i, 32, 64);

      final ilNum = _bytesToBigInt(il);
      final pNum = _bytesToBigInt(privateKey);
      final childPrivNum = (ilNum + pNum) % Secp256k1.n;

      if (ilNum >= Secp256k1.n || childPrivNum == BigInt.zero) {
        // Very rare invalid key, try next index per BIP-32
        return deriveChild(index + 1);
      }

      childPriv = _bigIntTo32Bytes(childPrivNum);
      return EvmHdKey(
        privateKey: childPriv,
        chainCode: ir,
        depth: depth + 1,
        childIndex: index,
      );
    } finally {
      zeroizeAll([data, i, childPriv]);
    }
  }

  /// Derives along a path like "m/44'/60'/0'/0/0".
  EvmHdKey derivePath(String path) {
    final clean = path.trim();
    final parts = clean.split('/');
    var current = this;

    for (final rawPart in parts) {
      if (rawPart == 'm' || rawPart.isEmpty) continue;
      var part = rawPart;
      var hardened = false;
      if (part.endsWith("'") || part.endsWith("h") || part.endsWith("H")) {
        hardened = true;
        part = part.substring(0, part.length - 1);
      }
      final idx = int.parse(part);
      final finalIdx = hardened ? (idx | 0x80000000) : idx;
      final next = current.deriveChild(finalIdx);
      if (current != this) {
        current.dispose();
      }
      current = next;
    }

    return current;
  }

  /// Derives standard BIP-44 EVM key for [accountIndex] and [addressIndex] (m/44'/60'/account'/0/addressIndex).
  EvmHdKey deriveEvmAccount({required int accountIndex, required int addressIndex}) {
    return derivePath("m/44'/60'/$accountIndex'/0/$addressIndex");
  }

  /// Gets 64-byte uncompressed public key.
  Uint8List get publicKey64 => Secp256k1.getPublicKey64(privateKey);

  /// Gets 65-byte uncompressed public key with 0x04 prefix.
  Uint8List get publicKey65 => Secp256k1.getPublicKey65(privateKey);

  void dispose() {
    zeroize(privateKey);
    zeroize(chainCode);
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
}
