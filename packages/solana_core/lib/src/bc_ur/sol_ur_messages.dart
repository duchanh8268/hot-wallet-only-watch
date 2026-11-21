import 'dart:typed_data';
import 'package:chain_core_interface/chain_core_interface.dart';
import '../address/base58.dart';
import '../transaction/solana_models.dart';

/// `ur:sol-account` (Cold Wallet -> Hot Wallet export).
class SolAccountUr {
  static const String urType = 'sol-account';

  final int version;
  final String chain;
  final String network;
  final int accountIndex;
  final String address;
  final String? label;

  SolAccountUr({
    this.version = 1,
    required this.chain,
    required this.network,
    required this.accountIndex,
    required this.address,
    this.label,
  });

  Uint8List toCborBytes() {
    final entries = <CborMapEntry>[
      CborMapEntry(CborInt.fromInt(1), CborInt.fromInt(version)),
      CborMapEntry(CborInt.fromInt(2), CborText(chain)),
      CborMapEntry(CborInt.fromInt(3), CborText(network)),
      CborMapEntry(CborInt.fromInt(4), CborInt.fromInt(accountIndex)),
      CborMapEntry(CborInt.fromInt(5), CborText(address)),
    ];
    if (label != null && label!.isNotEmpty) {
      entries.add(CborMapEntry(CborInt.fromInt(6), CborText(label!)));
    }
    return CborMap(entries).encode();
  }

  String toUr({bool uppercase = true}) =>
      UrEncoder.encodeSingle(urType, toCborBytes(), uppercase: uppercase);

  UrEncoder createEncoder({int maxFragmentLen = 90}) => UrEncoder(
        type: urType,
        cborPayload: toCborBytes(),
        maxFragmentLen: maxFragmentLen,
      );

  factory SolAccountUr.fromCborBytes(Uint8List cborBytes) {
    final value = CborValue.decode(cborBytes);
    if (value is! CborMap) throw const FormatException('Expected CBOR Map for SolAccountUr');

    final ver = value.getByIntKey(1);
    final ch = value.getByIntKey(2);
    final net = value.getByIntKey(3);
    final acctIdx = value.getByIntKey(4);
    final addr = value.getByIntKey(5);
    final lbl = value.getByIntKey(6);

    return SolAccountUr(
      version: ver is CborInt ? ver.toInt() : 1,
      chain: ch is CborText ? ch.text : 'solana',
      network: net is CborText ? net.text : 'mainnet',
      accountIndex: acctIdx is CborInt ? acctIdx.toInt() : 0,
      address: addr is CborText ? addr.text : '',
      label: lbl is CborText ? lbl.text : null,
    );
  }

  factory SolAccountUr.fromUr(String urString) {
    final dec = UrDecoder.decodeSingle(urString);
    if (dec.type.toLowerCase() != urType) {
      throw FormatException('UR type ${dec.type} does not match $urType');
    }
    return SolAccountUr.fromCborBytes(dec.cborPayload);
  }
}

/// `ur:sol-sign-request` (Hot Wallet -> Cold Wallet signing request).
class SolSignRequestUr {
  static const String urType = 'sol-sign-request';

  final int version;
  final Uint8List requestId; // 16 bytes
  final String chain;
  final String network;
  final Uint8List messageBytes;
  final int accountIndex;

  SolSignRequestUr({
    this.version = 1,
    required this.requestId,
    required this.chain,
    required this.network,
    required this.messageBytes,
    required this.accountIndex,
  });

  SolanaMessage get message => SolanaMessage.deserialize(messageBytes);

  Uint8List toCborBytes() {
    return CborMap([
      CborMapEntry(CborInt.fromInt(1), CborInt.fromInt(version)),
      CborMapEntry(CborInt.fromInt(2), CborBytes(requestId)),
      CborMapEntry(CborInt.fromInt(3), CborText(chain)),
      CborMapEntry(CborInt.fromInt(4), CborText(network)),
      CborMapEntry(CborInt.fromInt(5), CborBytes(messageBytes)),
      CborMapEntry(CborInt.fromInt(6), CborInt.fromInt(accountIndex)),
    ]).encode();
  }

  String toUr({bool uppercase = true}) =>
      UrEncoder.encodeSingle(urType, toCborBytes(), uppercase: uppercase);

  UrEncoder createEncoder({int maxFragmentLen = 90}) => UrEncoder(
        type: urType,
        cborPayload: toCborBytes(),
        maxFragmentLen: maxFragmentLen,
      );

  factory SolSignRequestUr.fromCborBytes(Uint8List cborBytes) {
    final value = CborValue.decode(cborBytes);
    if (value is! CborMap) throw const FormatException('Expected CBOR Map for SolSignRequestUr');

    final ver = value.getByIntKey(1);
    final reqId = value.getByIntKey(2);
    final ch = value.getByIntKey(3);
    final net = value.getByIntKey(4);
    final msg = value.getByIntKey(5);
    final acctIdx = value.getByIntKey(6);

    return SolSignRequestUr(
      version: ver is CborInt ? ver.toInt() : 1,
      requestId: (reqId as CborBytes).bytes,
      chain: (ch as CborText).text,
      network: (net as CborText).text,
      messageBytes: (msg as CborBytes).bytes,
      accountIndex: (acctIdx as CborInt).toInt(),
    );
  }

  factory SolSignRequestUr.fromUr(String urString) {
    final dec = UrDecoder.decodeSingle(urString);
    if (dec.type.toLowerCase() != urType) {
      throw FormatException('UR type ${dec.type} does not match $urType');
    }
    return SolSignRequestUr.fromCborBytes(dec.cborPayload);
  }
}

/// `ur:sol-sign-response` (Cold Wallet -> Hot Wallet signing response).
class SolSignResponseUr {
  static const String urType = 'sol-sign-response';

  final int version;
  final Uint8List requestId; // 16 bytes
  final Uint8List signature; // 64 bytes
  final Uint8List publicKey; // 32 bytes

  SolSignResponseUr({
    this.version = 1,
    required this.requestId,
    required this.signature,
    required this.publicKey,
  });

  String get address => Base58.encode(publicKey);

  Uint8List toCborBytes() {
    return CborMap([
      CborMapEntry(CborInt.fromInt(1), CborInt.fromInt(version)),
      CborMapEntry(CborInt.fromInt(2), CborBytes(requestId)),
      CborMapEntry(CborInt.fromInt(3), CborBytes(signature)),
      CborMapEntry(CborInt.fromInt(4), CborBytes(publicKey)),
    ]).encode();
  }

  String toUr({bool uppercase = true}) =>
      UrEncoder.encodeSingle(urType, toCborBytes(), uppercase: uppercase);

  UrEncoder createEncoder({int maxFragmentLen = 90}) => UrEncoder(
        type: urType,
        cborPayload: toCborBytes(),
        maxFragmentLen: maxFragmentLen,
      );

  factory SolSignResponseUr.fromCborBytes(Uint8List cborBytes) {
    final value = CborValue.decode(cborBytes);
    if (value is! CborMap) throw const FormatException('Expected CBOR Map for SolSignResponseUr');

    final ver = value.getByIntKey(1);
    final reqId = value.getByIntKey(2);
    final sig = value.getByIntKey(3);
    final pub = value.getByIntKey(4);

    return SolSignResponseUr(
      version: ver is CborInt ? ver.toInt() : 1,
      requestId: (reqId as CborBytes).bytes,
      signature: (sig as CborBytes).bytes,
      publicKey: (pub as CborBytes).bytes,
    );
  }

  factory SolSignResponseUr.fromUr(String urString) {
    final dec = UrDecoder.decodeSingle(urString);
    if (dec.type.toLowerCase() != urType) {
      throw FormatException('UR type ${dec.type} does not match $urType');
    }
    return SolSignResponseUr.fromCborBytes(dec.cborPayload);
  }
}
