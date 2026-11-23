import 'dart:typed_data';

import 'package:chain_core_interface/chain_core_interface.dart' show hexEncode;
import 'package:crypto/crypto.dart' as crypto;

import '../address/bech32_segwit.dart';
import 'hash160.dart';
import 'hash256.dart';
import 'secp256k1_btc.dart';

/// BIP-32 / BIP-84 Account Extended Public Key (`zpub`/`vpub`/`xpub`/`tpub`)
/// supporting watch-only non-hardened derivation along external (`change=0`)
/// and internal (`change=1`) branches.
class BtcAccountPublicKey {
  static const String _base58Alphabet =
      '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';

  static const int versionXpub = 0x0488B21E;
  static const int versionTpub = 0x043587CF;
  static const int versionZpub = 0x04B24746;
  static const int versionVpub = 0x045F1CF6;

  final Uint8List publicKeyCompressed; // 33 bytes
  final Uint8List chainCode; // 32 bytes
  final int depth;
  final int parentFingerprint;
  final int childNumber;
  final bool isTestnet;

  final Map<int, BtcAccountPublicKey> _changeCache = {};
  final Map<String, BtcAccountPublicKey> _childCache = {};
  final Map<String, Uint8List> _pubKeyHashCache = {};

  BtcAccountPublicKey({
    required Uint8List publicKeyCompressed,
    required Uint8List chainCode,
    this.depth = 3,
    this.parentFingerprint = 0,
    this.childNumber = 0x80000000,
    this.isTestnet = false,
  })  : publicKeyCompressed = Uint8List.fromList(publicKeyCompressed),
        chainCode = Uint8List.fromList(chainCode) {
    if (this.publicKeyCompressed.length != 33) {
      throw ArgumentError(
        'Compressed public key must be 33 bytes, got ${this.publicKeyCompressed.length}',
      );
    }
    if (this.chainCode.length != 32) {
      throw ArgumentError(
        'Chain code must be 32 bytes, got ${this.chainCode.length}',
      );
    }
    final pt = Secp256k1Btc.params.curve.decodePoint(this.publicKeyCompressed);
    if (pt == null || pt.isInfinity) {
      throw ArgumentError('Invalid secp256k1 compressed public key');
    }
  }

  /// 20-byte Hash160 of [publicKeyCompressed].
  Uint8List get pubKeyHash => hash160(publicKeyCompressed);

  /// 4-byte BIP-32 key fingerprint.
  int get fingerprint {
    final h = pubKeyHash;
    return (h[0] << 24) | (h[1] << 16) | (h[2] << 8) | h[3];
  }

  /// Serializes this account extended public key as BIP-84 `zpub`/`vpub`
  /// (when [slip132] is true) or BIP-32 `xpub`/`tpub`.
  String toExtendedKey({bool slip132 = true}) {
    final version = slip132
        ? (isTestnet ? versionVpub : versionZpub)
        : (isTestnet ? versionTpub : versionXpub);

    final payload = Uint8List(78);
    _writeUint32Be(payload, 0, version);
    payload[4] = depth & 0xff;
    _writeUint32Be(payload, 5, parentFingerprint);
    _writeUint32Be(payload, 9, childNumber);
    payload.setRange(13, 45, chainCode);
    payload.setRange(45, 78, publicKeyCompressed);

    final checksum = hash256(payload);
    final raw = Uint8List(82);
    raw.setRange(0, 78, payload);
    raw.setRange(78, 82, checksum.sublist(0, 4));
    return _base58Encode(raw);
  }

  /// Decodes a Base58Check `zpub`, `vpub`, `xpub`, or `tpub` string.
  factory BtcAccountPublicKey.fromExtendedKey(String extKey) {
    final raw = _base58Decode(extKey.trim());
    if (raw.length != 82) {
      throw FormatException('Invalid extended public key length: ${raw.length}');
    }
    final payload = raw.sublist(0, 78);
    final checksum = raw.sublist(78, 82);
    final expectedChecksum = hash256(payload).sublist(0, 4);
    for (var i = 0; i < 4; i++) {
      if (checksum[i] != expectedChecksum[i]) {
        throw const FormatException('Invalid extended public key checksum');
      }
    }

    final version = _readUint32Be(payload, 0);
    final bool isTestnet;
    switch (version) {
      case versionXpub:
      case versionZpub:
        isTestnet = false;
      case versionTpub:
      case versionVpub:
        isTestnet = true;
      default:
        throw FormatException(
          'Unsupported extended public key version: 0x${version.toRadixString(16)}',
        );
    }

    final depth = payload[4];
    final parentFp = _readUint32Be(payload, 5);
    final childNum = _readUint32Be(payload, 9);
    final chainCode = Uint8List.sublistView(payload, 13, 45);
    final pubKey = Uint8List.sublistView(payload, 45, 78);

    return BtcAccountPublicKey(
      publicKeyCompressed: pubKey,
      chainCode: chainCode,
      depth: depth,
      parentFingerprint: parentFp,
      childNumber: childNum,
      isTestnet: isTestnet,
    );
  }

  /// Derives a non-hardened child public key (`0 <= index < 2^31`).
  BtcAccountPublicKey deriveChild(int index) {
    if (index < 0 || index >= 0x80000000) {
      throw ArgumentError.value(
        index,
        'index',
        'Public key derivation only supports non-hardened indices [0, 2^31 - 1]',
      );
    }

    final data = Uint8List(37);
    data.setRange(0, 33, publicKeyCompressed);
    _writeUint32Be(data, 33, index);

    final hmac = crypto.Hmac(crypto.sha512, chainCode);
    final i = Uint8List.fromList(hmac.convert(data).bytes);
    final il = Uint8List.sublistView(i, 0, 32);
    final ir = Uint8List.sublistView(i, 32, 64);

    final ilNum = _bytesToBigInt(il);
    if (ilNum >= Secp256k1Btc.n) {
      return deriveChild(index + 1);
    }

    final parentPoint = Secp256k1Btc.params.curve.decodePoint(publicKeyCompressed);
    final tweakPoint = Secp256k1Btc.params.G * ilNum;
    if (parentPoint == null || tweakPoint == null) {
      throw StateError('Invalid secp256k1 point during CKDpub');
    }
    final childPoint = tweakPoint + parentPoint;
    if (childPoint == null || childPoint.isInfinity) {
      return deriveChild(index + 1);
    }

    final xBytes = _bigIntTo32Bytes(childPoint.x!.toBigInteger()!);
    final prefix = childPoint.y!.toBigInteger()!.isEven ? 0x02 : 0x03;
    final childPub = Uint8List.fromList([prefix, ...xBytes]);

    return BtcAccountPublicKey(
      publicKeyCompressed: childPub,
      chainCode: ir,
      depth: depth + 1,
      parentFingerprint: fingerprint,
      childNumber: index,
      isTestnet: isTestnet,
    );
  }

  BtcAccountPublicKey deriveChange(int change) {
    if (change != 0 && change != 1) {
      throw ArgumentError.value(change, 'change', 'Expected 0 or 1');
    }
    return _changeCache[change] ??= deriveChild(change);
  }

  BtcAccountPublicKey deriveAddressKey(int change, int addressIndex) {
    final key = '$change/$addressIndex';
    return _childCache[key] ??= deriveChange(change).deriveChild(addressIndex);
  }

  Uint8List derivePubKeyHash(int change, int addressIndex) {
    final key = '$change/$addressIndex';
    return _pubKeyHashCache[key] ??=
        deriveAddressKey(change, addressIndex).pubKeyHash;
  }

  String derivePubKeyHashHex(int change, int addressIndex) =>
      hexEncode(derivePubKeyHash(change, addressIndex));

  String deriveP2wpkhAddress({
    required int change,
    required int addressIndex,
    bool? testnetOverride,
  }) {
    final hrp = (testnetOverride ?? isTestnet) ? 'tb' : 'bc';
    return Bech32Segwit.encodeP2wpkh(
      hrp: hrp,
      program20: derivePubKeyHash(change, addressIndex),
    );
  }

  Uint8List deriveScriptPubKey({
    required int change,
    required int addressIndex,
  }) {
    final pkh = derivePubKeyHash(change, addressIndex);
    final script = Uint8List(22);
    script[0] = 0x00;
    script[1] = 0x14;
    script.setRange(2, 22, pkh);
    return script;
  }

  static void _writeUint32Be(Uint8List buf, int offset, int value) {
    buf[offset] = (value >> 24) & 0xff;
    buf[offset + 1] = (value >> 16) & 0xff;
    buf[offset + 2] = (value >> 8) & 0xff;
    buf[offset + 3] = value & 0xff;
  }

  static int _readUint32Be(Uint8List buf, int offset) {
    return ((buf[offset] & 0xff) << 24) |
        ((buf[offset + 1] & 0xff) << 16) |
        ((buf[offset + 2] & 0xff) << 8) |
        (buf[offset + 3] & 0xff);
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

  static String _base58Encode(Uint8List bytes) {
    var intVal = BigInt.zero;
    for (final b in bytes) {
      intVal = (intVal << 8) | BigInt.from(b);
    }
    final chars = <String>[];
    final fiftyEight = BigInt.from(58);
    while (intVal > BigInt.zero) {
      final rem = (intVal % fiftyEight).toInt();
      chars.add(_base58Alphabet[rem]);
      intVal = intVal ~/ fiftyEight;
    }
    for (final b in bytes) {
      if (b == 0) {
        chars.add(_base58Alphabet[0]);
      } else {
        break;
      }
    }
    return chars.reversed.join();
  }

  static Uint8List _base58Decode(String input) {
    if (input.isEmpty) {
      throw const FormatException('Empty Base58 string');
    }
    var intVal = BigInt.zero;
    final fiftyEight = BigInt.from(58);
    for (var i = 0; i < input.length; i++) {
      final charIdx = _base58Alphabet.indexOf(input[i]);
      if (charIdx < 0) {
        throw FormatException('Invalid Base58 character: ${input[i]}');
      }
      intVal = intVal * fiftyEight + BigInt.from(charIdx);
    }
    final bytes = <int>[];
    while (intVal > BigInt.zero) {
      bytes.add((intVal & BigInt.from(0xff)).toInt());
      intVal = intVal >> 8;
    }
    var leadingZeros = 0;
    for (var i = 0; i < input.length && input[i] == _base58Alphabet[0]; i++) {
      leadingZeros++;
    }
    final out = Uint8List(leadingZeros + bytes.length);
    for (var i = 0; i < bytes.length; i++) {
      out[leadingZeros + i] = bytes[bytes.length - 1 - i];
    }
    return out;
  }
}
