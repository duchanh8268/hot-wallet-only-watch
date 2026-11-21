import 'dart:typed_data';
import 'package:chain_core_interface/chain_core_interface.dart' show zeroize, zeroizeAll;
import 'package:crypto/crypto.dart' as crypto;
import 'hash160.dart';
import 'secp256k1_btc.dart';

/// BIP-32 Hierarchical Deterministic Key for Bitcoin (supports BIP-84 Native SegWit derivation).
class BtcHdKey {
  static const int hardenedOffset = 0x80000000;

  final Uint8List privateKey; // 32 bytes
  final Uint8List chainCode;  // 32 bytes
  final int depth;
  final int parentFingerprint;
  final int childNumber;

  BtcHdKey({
    required Uint8List privateKey,
    required Uint8List chainCode,
    this.depth = 0,
    this.parentFingerprint = 0,
    this.childNumber = 0,
  })  : privateKey = Uint8List.fromList(privateKey),
        chainCode = Uint8List.fromList(chainCode);

  /// Creates a Master HD Key from a BIP-39 binary seed (typically 64 bytes).
  factory BtcHdKey.fromSeed(Uint8List seed) {
    final hmac = crypto.Hmac(crypto.sha512, 'Bitcoin seed'.codeUnits);
    final i = Uint8List.fromList(hmac.convert(seed).bytes);
    final il = Uint8List.sublistView(i, 0, 32);
    final ir = Uint8List.sublistView(i, 32, 64);
    try {
      return BtcHdKey(
        privateKey: il,
        chainCode: ir,
        depth: 0,
        parentFingerprint: 0,
        childNumber: 0,
      );
    } finally {
      zeroize(i);
    }
  }

  /// 33-byte compressed public key.
  Uint8List get publicKeyCompressed => Secp256k1Btc.getPublicKeyCompressed(privateKey);

  /// 20-byte Hash160 of compressed public key (used as Witness Program for P2WPKH).
  Uint8List get pubKeyHash => hash160(publicKeyCompressed);

  /// 4-byte key fingerprint.
  int get fingerprint {
    final h = pubKeyHash;
    return (h[0] << 24) | (h[1] << 16) | (h[2] << 8) | h[3];
  }

  /// Derives child key at [index]. If [hardened] is true, adds [hardenedOffset].
  BtcHdKey deriveChild(int index, {bool hardened = false}) {
    final effectiveIndex = hardened ? (index | hardenedOffset) : index;
    final isHardened = (effectiveIndex & hardenedOffset) != 0;

    final data = Uint8List(37);
    if (isHardened) {
      data[0] = 0x00;
      data.setRange(1, 33, privateKey);
    } else {
      data.setRange(0, 33, publicKeyCompressed);
    }
    // Index in big-endian
    data[33] = (effectiveIndex >> 24) & 0xff;
    data[34] = (effectiveIndex >> 16) & 0xff;
    data[35] = (effectiveIndex >> 8) & 0xff;
    data[36] = effectiveIndex & 0xff;

    final hmac = crypto.Hmac(crypto.sha512, chainCode);
    final i = Uint8List.fromList(hmac.convert(data).bytes);
    final il = Uint8List.sublistView(i, 0, 32);
    final ir = Uint8List.sublistView(i, 32, 64);
    Uint8List? childPriv;
    try {
      final ilNum = _bytesToBigInt(il);
      if (ilNum >= Secp256k1Btc.n) {
        // Very rare probability (< 2^-128), skip to next index as per BIP-32
        return deriveChild(index + 1, hardened: hardened);
      }

      final kNum = _bytesToBigInt(privateKey);
      final childNum = (ilNum + kNum) % Secp256k1Btc.n;
      if (childNum == BigInt.zero) {
        return deriveChild(index + 1, hardened: hardened);
      }

      childPriv = _bigIntTo32Bytes(childNum);
      return BtcHdKey(
        privateKey: childPriv,
        chainCode: ir,
        depth: depth + 1,
        parentFingerprint: fingerprint,
        childNumber: effectiveIndex,
      );
    } finally {
      zeroizeAll([data, i, childPriv]);
    }
  }

  /// Derives along a path like `m/84'/0'/0'/0/0` or `84'/0'/0'/0/0`.
  BtcHdKey derivePath(String path) {
    var clean = path.trim();
    if (clean.startsWith('m/')) clean = clean.substring(2);
    if (clean.isEmpty) return this;

    final segments = clean.split('/');
    var current = this;
    for (final seg in segments) {
      final isHardened = seg.endsWith("'") || seg.endsWith('h') || seg.endsWith('H');
      final numStr = isHardened ? seg.substring(0, seg.length - 1) : seg;
      final idx = int.parse(numStr);
      final next = current.deriveChild(idx, hardened: isHardened);
      if (current != this) {
        current.dispose();
      }
      current = next;
    }
    return current;
  }

  /// Derives BIP-84 Native SegWit account key `m/84'/coinType'/account'`.
  /// [isTestnet]: if true, coinType is 1', otherwise 0'.
  BtcHdKey deriveBip84Account({
    required int accountIndex,
    bool isTestnet = false,
  }) {
    final coinType = isTestnet ? 1 : 0;
    return derivePath("84'/$coinType'/$accountIndex'");
  }

  /// Derives BIP-84 address key `m/84'/coinType'/account'/change/addressIndex`.
  BtcHdKey deriveBip84Address({
    required int accountIndex,
    int change = 0,
    required int addressIndex,
    bool isTestnet = false,
  }) {
    final coinType = isTestnet ? 1 : 0;
    return derivePath("84'/$coinType'/$accountIndex'/$change/$addressIndex");
  }

  void dispose() {
    zeroize(privateKey);
    zeroize(chainCode);
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
}
