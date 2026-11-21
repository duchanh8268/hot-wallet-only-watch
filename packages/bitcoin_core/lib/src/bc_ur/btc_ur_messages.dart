import 'dart:convert';
import 'dart:typed_data';
import 'package:chain_core_interface/chain_core_interface.dart';
import '../transaction/btc_models.dart';

/// `ur:btc-account` (Cold Wallet -> Hot Wallet export).
class BtcAccountUr {
  static const String urType = 'btc-account';

  final int version;
  final String chain; // 'bitcoin'
  final String network; // 'mainnet' or 'testnet'
  final int accountIndex;
  final String receiveAddress;
  final int masterFingerprint;
  final String? accountXpub;
  final String? label;

  BtcAccountUr({
    this.version = 1,
    required this.chain,
    required this.network,
    required this.accountIndex,
    required this.receiveAddress,
    this.masterFingerprint = 0,
    this.accountXpub,
    this.label,
  });

  Uint8List toCborBytes() {
    final entries = <CborMapEntry>[
      CborMapEntry(CborInt.fromInt(1), CborInt.fromInt(version)),
      CborMapEntry(CborInt.fromInt(2), CborText(chain)),
      CborMapEntry(CborInt.fromInt(3), CborText(network)),
      CborMapEntry(CborInt.fromInt(4), CborInt.fromInt(accountIndex)),
      CborMapEntry(CborInt.fromInt(5), CborText(receiveAddress)),
      CborMapEntry(CborInt.fromInt(6), CborInt.fromInt(masterFingerprint)),
    ];
    if (accountXpub != null && accountXpub!.isNotEmpty) {
      entries.add(CborMapEntry(CborInt.fromInt(7), CborText(accountXpub!)));
    }
    if (label != null && label!.isNotEmpty) {
      entries.add(CborMapEntry(CborInt.fromInt(8), CborText(label!)));
    }
    return CborMap(entries).encode();
  }

  String toUr({bool uppercase = true}) =>
      UrEncoder.encodeSingle(urType, toCborBytes(), uppercase: uppercase);

  factory BtcAccountUr.fromCborBytes(Uint8List bytes) {
    final root = CborValue.decode(bytes);
    if (root is! CborMap) {
      throw const FormatException('btc-account must be a CBOR map');
    }
    final ver = root.getByIntKey(1);
    final ch = root.getByIntKey(2);
    final net = root.getByIntKey(3);
    final acctIdx = root.getByIntKey(4);
    final addr = root.getByIntKey(5);
    final mFp = root.getByIntKey(6);
    final xpub = root.getByIntKey(7);
    final lbl = root.getByIntKey(8);

    if (ver is! CborInt || ch is! CborText || net is! CborText || addr is! CborText) {
      throw const FormatException('Missing required fields in btc-account');
    }

    return BtcAccountUr(
      version: ver.toInt(),
      chain: ch.text,
      network: net.text,
      accountIndex: acctIdx is CborInt ? acctIdx.toInt() : 0,
      receiveAddress: addr.text,
      masterFingerprint: mFp is CborInt ? mFp.toInt() : 0,
      accountXpub: xpub is CborText ? xpub.text : null,
      label: lbl is CborText ? lbl.text : null,
    );
  }

  factory BtcAccountUr.fromUr(String urString) {
    final res = UrDecoder.decodeSingle(urString);
    if (res.type != urType) {
      throw FormatException('Expected ur:$urType, got ur:${res.type}');
    }
    return BtcAccountUr.fromCborBytes(res.cborPayload);
  }
}

/// `ur:btc-sign-request` (Hot Wallet -> Cold Wallet signing request).
class BtcSignRequestUr {
  static const String urType = 'btc-sign-request';

  final int version;
  final Uint8List requestId; // 16 bytes UUID
  final String chain; // 'bitcoin'
  final String network; // 'mainnet' or 'testnet'
  final BtcTransaction transaction;
  final int accountIndex;
  final BigInt feeSat;
  final Map<String, dynamic> metadata;

  BtcSignRequestUr({
    this.version = 1,
    required Uint8List requestId,
    required this.chain,
    required this.network,
    required this.transaction,
    this.accountIndex = 0,
    required this.feeSat,
    this.metadata = const {},
  }) : requestId = Uint8List.fromList(requestId) {
    if (this.requestId.length != 16) {
      throw ArgumentError('requestId must be 16 bytes');
    }
  }

  Uint8List toCborBytes() {
    final txJson = jsonEncode(transaction.toJson());
    final entries = <CborMapEntry>[
      CborMapEntry(CborInt.fromInt(1), CborInt.fromInt(version)),
      CborMapEntry(CborInt.fromInt(2), CborBytes(requestId)),
      CborMapEntry(CborInt.fromInt(3), CborText(chain)),
      CborMapEntry(CborInt.fromInt(4), CborText(network)),
      CborMapEntry(CborInt.fromInt(5), CborText(txJson)),
      CborMapEntry(CborInt.fromInt(6), CborInt.fromInt(accountIndex)),
      CborMapEntry(CborInt.fromInt(7), CborText(feeSat.toString())),
    ];
    if (metadata.isNotEmpty) {
      entries.add(CborMapEntry(CborInt.fromInt(8), CborText(jsonEncode(metadata))));
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

  factory BtcSignRequestUr.fromCborBytes(Uint8List bytes) {
    final root = CborValue.decode(bytes);
    if (root is! CborMap) {
      throw const FormatException('btc-sign-request must be a CBOR map');
    }
    final ver = root.getByIntKey(1);
    final reqId = root.getByIntKey(2);
    final ch = root.getByIntKey(3);
    final net = root.getByIntKey(4);
    final txStr = root.getByIntKey(5);
    final acctIdx = root.getByIntKey(6);
    final fee = root.getByIntKey(7);
    final meta = root.getByIntKey(8);

    if (ver is! CborInt ||
        reqId is! CborBytes ||
        ch is! CborText ||
        net is! CborText ||
        txStr is! CborText) {
      throw const FormatException('Missing required fields in btc-sign-request');
    }

    final txJson = jsonDecode(txStr.text) as Map<String, dynamic>;
    final tx = BtcTransaction.fromJson(txJson);

    Map<String, dynamic> parsedMeta = {};
    if (meta is CborText) {
      try {
        parsedMeta = jsonDecode(meta.text) as Map<String, dynamic>;
      } catch (_) {}
    }

    return BtcSignRequestUr(
      version: ver.toInt(),
      requestId: reqId.bytes,
      chain: ch.text,
      network: net.text,
      transaction: tx,
      accountIndex: acctIdx is CborInt ? acctIdx.toInt() : 0,
      feeSat: fee is CborText ? BigInt.parse(fee.text) : BigInt.zero,
      metadata: parsedMeta,
    );
  }

  factory BtcSignRequestUr.fromUr(String urString) {
    final res = UrDecoder.decodeSingle(urString);
    if (res.type != urType) {
      throw FormatException('Expected ur:$urType, got ur:${res.type}');
    }
    return BtcSignRequestUr.fromCborBytes(res.cborPayload);
  }
}

/// `ur:btc-sign-response` (Cold Wallet -> Hot Wallet signed response).
class BtcSignResponseUr {
  static const String urType = 'btc-sign-response';

  final int version;
  final Uint8List requestId; // 16 bytes UUID
  final List<BtcWitness> witnesses;

  BtcSignResponseUr({
    this.version = 1,
    required Uint8List requestId,
    required this.witnesses,
  }) : requestId = Uint8List.fromList(requestId) {
    if (this.requestId.length != 16) {
      throw ArgumentError('requestId must be 16 bytes');
    }
  }

  Uint8List toCborBytes() {
    final witnessListCbor = witnesses.map((w) {
      return CborArray(w.items.map((i) => CborBytes(i)).toList());
    }).toList();

    final entries = <CborMapEntry>[
      CborMapEntry(CborInt.fromInt(1), CborInt.fromInt(version)),
      CborMapEntry(CborInt.fromInt(2), CborBytes(requestId)),
      CborMapEntry(CborInt.fromInt(3), CborArray(witnessListCbor)),
    ];
    return CborMap(entries).encode();
  }

  String toUr({bool uppercase = true}) =>
      UrEncoder.encodeSingle(urType, toCborBytes(), uppercase: uppercase);

  factory BtcSignResponseUr.fromCborBytes(Uint8List bytes) {
    final root = CborValue.decode(bytes);
    if (root is! CborMap) {
      throw const FormatException('btc-sign-response must be a CBOR map');
    }
    final ver = root.getByIntKey(1);
    final reqId = root.getByIntKey(2);
    final witList = root.getByIntKey(3);

    if (ver is! CborInt || reqId is! CborBytes || witList is! CborArray) {
      throw const FormatException('Missing required fields in btc-sign-response');
    }

    final witnesses = <BtcWitness>[];
    for (final item in witList.items) {
      if (item is CborArray) {
        final stack = <Uint8List>[];
        for (final elem in item.items) {
          if (elem is CborBytes) stack.add(elem.bytes);
        }
        witnesses.add(BtcWitness(stack));
      }
    }

    return BtcSignResponseUr(
      version: ver.toInt(),
      requestId: reqId.bytes,
      witnesses: witnesses,
    );
  }

  factory BtcSignResponseUr.fromUr(String urString) {
    final res = UrDecoder.decodeSingle(urString);
    if (res.type != urType) {
      throw FormatException('Expected ur:$urType, got ur:${res.type}');
    }
    return BtcSignResponseUr.fromCborBytes(res.cborPayload);
  }
}
