import 'dart:convert';
import 'dart:typed_data';
import 'package:chain_core_interface/chain_core_interface.dart';
import '../transaction/sui_models.dart';

/// `ur:sui-account` (Cold Wallet -> Hot Wallet export).
class SuiAccountUr {
  static const String urType = 'sui-account';

  final int version;
  final String chain;
  final String network;
  final int accountIndex;
  final int addressIndex;
  final String address;
  final String? label;

  SuiAccountUr({
    this.version = 1,
    required this.chain,
    required this.network,
    required this.accountIndex,
    this.addressIndex = 0,
    required this.address,
    this.label,
  });

  Uint8List toCborBytes() {
    final entries = <CborMapEntry>[
      CborMapEntry(CborInt.fromInt(1), CborInt.fromInt(version)),
      CborMapEntry(CborInt.fromInt(2), CborText(chain)),
      CborMapEntry(CborInt.fromInt(3), CborText(network)),
      CborMapEntry(CborInt.fromInt(4), CborInt.fromInt(accountIndex)),
      CborMapEntry(CborInt.fromInt(5), CborInt.fromInt(addressIndex)),
      CborMapEntry(CborInt.fromInt(6), CborText(address)),
    ];
    if (label != null && label!.isNotEmpty) {
      entries.add(CborMapEntry(CborInt.fromInt(7), CborText(label!)));
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

  factory SuiAccountUr.fromCborBytes(Uint8List cborBytes) {
    final value = CborValue.decode(cborBytes);
    if (value is! CborMap) {
      throw const FormatException('Expected CBOR Map for SuiAccountUr');
    }

    final ver = value.getByIntKey(1);
    final ch = value.getByIntKey(2);
    final net = value.getByIntKey(3);
    final acctIdx = value.getByIntKey(4);
    final addrIdx = value.getByIntKey(5);
    final addr = value.getByIntKey(6);
    final lbl = value.getByIntKey(7);

    return SuiAccountUr(
      version: ver is CborInt ? ver.toInt() : 1,
      chain: ch is CborText ? ch.text : 'sui',
      network: net is CborText ? net.text : 'mainnet',
      accountIndex: acctIdx is CborInt ? acctIdx.toInt() : 0,
      addressIndex: addrIdx is CborInt ? addrIdx.toInt() : 0,
      address: addr is CborText ? addr.text : '',
      label: lbl is CborText ? lbl.text : null,
    );
  }

  factory SuiAccountUr.fromUr(String urString) {
    final dec = UrDecoder.decodeSingle(urString);
    if (dec.type.toLowerCase() != urType) {
      throw FormatException('UR type ${dec.type} does not match $urType');
    }
    return SuiAccountUr.fromCborBytes(dec.cborPayload);
  }
}

/// `ur:sui-sign-request` (Hot Wallet -> Cold Wallet signing request).
class SuiSignRequestUr {
  static const String urType = 'sui-sign-request';

  final int version;
  final Uint8List requestId; // 16 bytes
  final String chain;
  final String network;
  final Uint8List txBytes; // BCS TransactionData
  final int accountIndex;
  final int addressIndex;

  SuiSignRequestUr({
    this.version = 1,
    required this.requestId,
    required this.chain,
    required this.network,
    required this.txBytes,
    required this.accountIndex,
    this.addressIndex = 0,
  });

  SuiTransactionData get transactionData =>
      SuiTransactionData.fromBcs(txBytes);

  Uint8List toCborBytes() {
    return CborMap([
      CborMapEntry(CborInt.fromInt(1), CborInt.fromInt(version)),
      CborMapEntry(CborInt.fromInt(2), CborBytes(requestId)),
      CborMapEntry(CborInt.fromInt(3), CborText(chain)),
      CborMapEntry(CborInt.fromInt(4), CborText(network)),
      CborMapEntry(CborInt.fromInt(5), CborBytes(txBytes)),
      CborMapEntry(CborInt.fromInt(6), CborInt.fromInt(accountIndex)),
      CborMapEntry(CborInt.fromInt(7), CborInt.fromInt(addressIndex)),
    ]).encode();
  }

  String toUr({bool uppercase = true}) =>
      UrEncoder.encodeSingle(urType, toCborBytes(), uppercase: uppercase);

  UrEncoder createEncoder({int maxFragmentLen = 90}) => UrEncoder(
        type: urType,
        cborPayload: toCborBytes(),
        maxFragmentLen: maxFragmentLen,
      );

  factory SuiSignRequestUr.fromCborBytes(Uint8List cborBytes) {
    final value = CborValue.decode(cborBytes);
    if (value is! CborMap) {
      throw const FormatException('Expected CBOR Map for SuiSignRequestUr');
    }

    final ver = value.getByIntKey(1);
    final reqId = value.getByIntKey(2);
    final ch = value.getByIntKey(3);
    final net = value.getByIntKey(4);
    final tx = value.getByIntKey(5);
    final acctIdx = value.getByIntKey(6);
    final addrIdx = value.getByIntKey(7);

    return SuiSignRequestUr(
      version: ver is CborInt ? ver.toInt() : 1,
      requestId: (reqId as CborBytes).bytes,
      chain: (ch as CborText).text,
      network: (net as CborText).text,
      txBytes: (tx as CborBytes).bytes,
      accountIndex: (acctIdx as CborInt).toInt(),
      addressIndex: addrIdx is CborInt ? addrIdx.toInt() : 0,
    );
  }

  factory SuiSignRequestUr.fromUr(String urString) {
    final dec = UrDecoder.decodeSingle(urString);
    if (dec.type.toLowerCase() != urType) {
      throw FormatException('UR type ${dec.type} does not match $urType');
    }
    return SuiSignRequestUr.fromCborBytes(dec.cborPayload);
  }
}

/// `ur:sui-sign-response` (Cold Wallet -> Hot Wallet signing response).
class SuiSignResponseUr {
  static const String urType = 'sui-sign-response';

  final int version;
  final Uint8List requestId; // 16 bytes
  final Uint8List signature; // 64 bytes
  final Uint8List publicKey; // 32 bytes

  SuiSignResponseUr({
    this.version = 1,
    required this.requestId,
    required this.signature,
    required this.publicKey,
  });

  /// 97-byte serialized signature for Sui RPC:
  /// `0x00` (Ed25519) || 64-byte signature || 32-byte public key.
  Uint8List get serializedSignature {
    final res = Uint8List(97);
    res[0] = 0x00;
    res.setRange(1, 65, signature);
    res.setRange(65, 97, publicKey);
    return res;
  }

  /// Base64 encoded serialized signature for JSON-RPC `sui_executeTransactionBlock`.
  String get base64Signature => base64Encode(serializedSignature);

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

  factory SuiSignResponseUr.fromCborBytes(Uint8List cborBytes) {
    final value = CborValue.decode(cborBytes);
    if (value is! CborMap) {
      throw const FormatException('Expected CBOR Map for SuiSignResponseUr');
    }

    final ver = value.getByIntKey(1);
    final reqId = value.getByIntKey(2);
    final sig = value.getByIntKey(3);
    final pub = value.getByIntKey(4);

    return SuiSignResponseUr(
      version: ver is CborInt ? ver.toInt() : 1,
      requestId: (reqId as CborBytes).bytes,
      signature: (sig as CborBytes).bytes,
      publicKey: (pub as CborBytes).bytes,
    );
  }

  factory SuiSignResponseUr.fromUr(String urString) {
    final dec = UrDecoder.decodeSingle(urString);
    if (dec.type.toLowerCase() != urType) {
      throw FormatException('UR type ${dec.type} does not match $urType');
    }
    return SuiSignResponseUr.fromCborBytes(dec.cborPayload);
  }
}
