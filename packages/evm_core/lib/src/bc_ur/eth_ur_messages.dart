import 'dart:convert';
import 'dart:typed_data';
import 'package:chain_core_interface/chain_core_interface.dart';

/// `ur:eth-account` (Cold Wallet -> Hot Wallet).
class EthAccountUr {
  static const String urType = 'eth-account';

  final int version;
  final String chain; // 'ethereum' or 'hyperliquid'
  final String network; // 'mainnet', 'sepolia', 'testnet'
  final String address;
  final int accountIndex;
  final int addressIndex;
  final String? label;

  EthAccountUr({
    this.version = 1,
    required this.chain,
    required this.network,
    required this.address,
    this.accountIndex = 0,
    this.addressIndex = 0,
    this.label,
  });

  Uint8List toCborBytes() {
    final entries = <CborMapEntry>[
      CborMapEntry(CborInt.fromInt(1), CborInt.fromInt(version)),
      CborMapEntry(CborInt.fromInt(2), CborText(chain)),
      CborMapEntry(CborInt.fromInt(3), CborText(network)),
      CborMapEntry(CborInt.fromInt(4), CborText(address)),
      CborMapEntry(CborInt.fromInt(5), CborInt.fromInt(accountIndex)),
    ];
    if (label != null && label!.isNotEmpty) {
      entries.add(CborMapEntry(CborInt.fromInt(6), CborText(label!)));
    }
    if (addressIndex != 0) {
      entries.add(CborMapEntry(CborInt.fromInt(7), CborInt.fromInt(addressIndex)));
    }
    return CborMap(entries).encode();
  }

  String toUr({bool uppercase = true}) =>
      UrEncoder.encodeSingle(urType, toCborBytes(), uppercase: uppercase);

  factory EthAccountUr.fromCborBytes(Uint8List bytes) {
    final root = CborValue.decode(bytes);
    if (root is! CborMap) {
      throw const FormatException('eth-account must be a CBOR map');
    }
    final ver = root.getByIntKey(1);
    final ch = root.getByIntKey(2);
    final net = root.getByIntKey(3);
    final addr = root.getByIntKey(4);
    final idx = root.getByIntKey(5);
    final lbl = root.getByIntKey(6);
    final addrIdx = root.getByIntKey(7);

    if (ver is! CborInt || ch is! CborText || net is! CborText || addr is! CborText) {
      throw const FormatException('Missing required fields in eth-account');
    }

    return EthAccountUr(
      version: ver.toInt(),
      chain: ch.text,
      network: net.text,
      address: addr.text,
      accountIndex: idx is CborInt ? idx.toInt() : 0,
      addressIndex: addrIdx is CborInt ? addrIdx.toInt() : 0,
      label: lbl is CborText ? lbl.text : null,
    );
  }

  factory EthAccountUr.fromUr(String urString) {
    final res = UrDecoder.decodeSingle(urString);
    if (res.type != urType) {
      throw FormatException('Expected ur:$urType, got ur:${res.type}');
    }
    return EthAccountUr.fromCborBytes(res.cborPayload);
  }
}

/// Payload type for `ur:eth-sign-request`.
enum EthPayloadType {
  eip1559(1),
  legacy(2),
  eip712(3);

  final int code;
  const EthPayloadType(this.code);

  static EthPayloadType fromCode(int code) {
    return EthPayloadType.values.firstWhere(
      (t) => t.code == code,
      orElse: () => throw ArgumentError('Unknown EthPayloadType code: $code'),
    );
  }
}

/// `ur:eth-sign-request` (Hot Wallet -> Cold Wallet).
class EthSignRequestUr {
  static const String urType = 'eth-sign-request';

  final int version;
  final Uint8List requestId; // 16 bytes UUID
  final String chain; // 'ethereum' or 'hyperliquid'
  final String network; // 'mainnet', 'sepolia', 'testnet'
  final EthPayloadType payloadType;
  final Uint8List rawPayload;
  final int accountIndex;
  final int addressIndex;
  final Map<String, dynamic> metadata;

  EthSignRequestUr({
    this.version = 1,
    required Uint8List requestId,
    required this.chain,
    required this.network,
    required this.payloadType,
    required Uint8List rawPayload,
    this.accountIndex = 0,
    this.addressIndex = 0,
    this.metadata = const {},
  })  : requestId = Uint8List.fromList(requestId),
        rawPayload = Uint8List.fromList(rawPayload) {
    if (this.requestId.length != 16) {
      throw ArgumentError('requestId must be 16 bytes');
    }
  }

  Uint8List toCborBytes() {
    final entries = <CborMapEntry>[
      CborMapEntry(CborInt.fromInt(1), CborInt.fromInt(version)),
      CborMapEntry(CborInt.fromInt(2), CborBytes(requestId)),
      CborMapEntry(CborInt.fromInt(3), CborText(chain)),
      CborMapEntry(CborInt.fromInt(4), CborText(network)),
      CborMapEntry(CborInt.fromInt(5), CborInt.fromInt(payloadType.code)),
      CborMapEntry(CborInt.fromInt(6), CborBytes(rawPayload)),
      CborMapEntry(CborInt.fromInt(7), CborInt.fromInt(accountIndex)),
      CborMapEntry(CborInt.fromInt(8), CborInt.fromInt(addressIndex)),
    ];
    if (metadata.isNotEmpty) {
      entries.add(CborMapEntry(CborInt.fromInt(9), CborText(jsonEncode(metadata))));
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

  factory EthSignRequestUr.fromCborBytes(Uint8List bytes) {
    final root = CborValue.decode(bytes);
    if (root is! CborMap) {
      throw const FormatException('eth-sign-request must be a CBOR map');
    }
    final ver = root.getByIntKey(1);
    final reqId = root.getByIntKey(2);
    final ch = root.getByIntKey(3);
    final net = root.getByIntKey(4);
    final pType = root.getByIntKey(5);
    final raw = root.getByIntKey(6);
    final acctIdx = root.getByIntKey(7);
    final addrIdx = root.getByIntKey(8);
    final meta = root.getByIntKey(9);

    if (ver is! CborInt ||
        reqId is! CborBytes ||
        ch is! CborText ||
        net is! CborText ||
        pType is! CborInt ||
        raw is! CborBytes) {
      throw const FormatException('Missing required fields in eth-sign-request');
    }

    Map<String, dynamic> parsedMeta = {};
    if (meta is CborText) {
      try {
        parsedMeta = jsonDecode(meta.text) as Map<String, dynamic>;
      } catch (_) {}
    }

    return EthSignRequestUr(
      version: ver.toInt(),
      requestId: reqId.bytes,
      chain: ch.text,
      network: net.text,
      payloadType: EthPayloadType.fromCode(pType.toInt()),
      rawPayload: raw.bytes,
      accountIndex: acctIdx is CborInt ? acctIdx.toInt() : 0,
      addressIndex: addrIdx is CborInt ? addrIdx.toInt() : 0,
      metadata: parsedMeta,
    );
  }

  factory EthSignRequestUr.fromUr(String urString) {
    final decoder = UrDecoder();
    if (!decoder.receivePart(urString) || !decoder.isComplete) {
      throw const FormatException('Incomplete or invalid BC-UR string');
    }
    final res = decoder.result!;
    if (res.type != urType) {
      throw FormatException('Expected ur:$urType, got ur:${res.type}');
    }
    return EthSignRequestUr.fromCborBytes(res.cborPayload);
  }
}

/// `ur:eth-sign-response` (Cold Wallet -> Hot Wallet).
class EthSignResponseUr {
  static const String urType = 'eth-sign-response';

  final int version;
  final Uint8List requestId; // 16 bytes UUID
  final Uint8List r;         // 32 bytes
  final Uint8List s;         // 32 bytes
  final int v;               // yParity (0/1) or recovery ID

  EthSignResponseUr({
    this.version = 1,
    required Uint8List requestId,
    required Uint8List r,
    required Uint8List s,
    required this.v,
  })  : requestId = Uint8List.fromList(requestId),
        r = Uint8List.fromList(r),
        s = Uint8List.fromList(s) {
    if (this.requestId.length != 16) {
      throw ArgumentError('requestId must be 16 bytes');
    }
    if (this.r.length != 32) {
      throw ArgumentError('r must be 32 bytes, got ${this.r.length}');
    }
    if (this.s.length != 32) {
      throw ArgumentError('s must be 32 bytes, got ${this.s.length}');
    }
  }

  Uint8List toCborBytes() {
    return CborMap([
      CborMapEntry(CborInt.fromInt(1), CborInt.fromInt(version)),
      CborMapEntry(CborInt.fromInt(2), CborBytes(requestId)),
      CborMapEntry(CborInt.fromInt(3), CborBytes(r)),
      CborMapEntry(CborInt.fromInt(4), CborBytes(s)),
      CborMapEntry(CborInt.fromInt(5), CborInt.fromInt(v)),
    ]).encode();
  }

  String toUr({bool uppercase = true}) =>
      UrEncoder.encodeSingle(urType, toCborBytes(), uppercase: uppercase);

  UrEncoder createEncoder({int maxFragmentLen = 200}) => UrEncoder(
        type: urType,
        cborPayload: toCborBytes(),
        maxFragmentLen: maxFragmentLen,
      );

  factory EthSignResponseUr.fromCborBytes(Uint8List bytes) {
    final root = CborValue.decode(bytes);
    if (root is! CborMap) {
      throw const FormatException('eth-sign-response must be a CBOR map');
    }
    final ver = root.getByIntKey(1);
    final reqId = root.getByIntKey(2);
    final rBytes = root.getByIntKey(3);
    final sBytes = root.getByIntKey(4);
    final vVal = root.getByIntKey(5);

    if (ver is! CborInt ||
        reqId is! CborBytes ||
        rBytes is! CborBytes ||
        sBytes is! CborBytes ||
        vVal is! CborInt) {
      throw const FormatException('Missing required fields in eth-sign-response');
    }

    return EthSignResponseUr(
      version: ver.toInt(),
      requestId: reqId.bytes,
      r: rBytes.bytes,
      s: sBytes.bytes,
      v: vVal.toInt(),
    );
  }

  factory EthSignResponseUr.fromUr(String urString) {
    final decoder = UrDecoder();
    if (!decoder.receivePart(urString) || !decoder.isComplete) {
      throw const FormatException('Incomplete or invalid BC-UR string');
    }
    final res = decoder.result!;
    if (res.type != urType) {
      throw FormatException('Expected ur:$urType, got ur:${res.type}');
    }
    return EthSignResponseUr.fromCborBytes(res.cborPayload);
  }
}
