import 'dart:typed_data';

import '../conway/cbor.dart';
import '../conway/models.dart';
import '../crypto/bytes.dart';
import '../crypto/cardano_keys.dart';
import 'ur_codec.dart';

/// `ur:cardano-account` (Cold Wallet -> Hot Wallet).
class CardanoAccountUr {
  static const String urType = 'cardano-account';

  final int version;
  final CardanoNetwork network;
  final Uint8List acctXvk; // 64 bytes: pub[32] || chainCode[32]
  final int accountIndex;
  final String? label;

  CardanoAccountUr({
    this.version = 1,
    required this.network,
    required Uint8List acctXvk,
    this.accountIndex = 0,
    this.label,
  }) : acctXvk = Uint8List.fromList(acctXvk) {
    if (this.acctXvk.length != 64) {
      throw ArgumentError('acct_xvk must be 64 bytes, got ${this.acctXvk.length}');
    }
  }

  Uint8List toCborBytes() {
    final entries = <CborMapEntry>[
      CborMapEntry(CborInt.fromInt(1), CborInt.fromInt(version)),
      CborMapEntry(CborInt.fromInt(2), CborInt.fromInt(network.urCode)),
      CborMapEntry(CborInt.fromInt(3), CborBytes(acctXvk)),
      CborMapEntry(CborInt.fromInt(4), CborInt.fromInt(accountIndex)),
    ];
    if (label != null && label!.isNotEmpty) {
      entries.add(CborMapEntry(CborInt.fromInt(5), CborText(label!)));
    }
    return CborMap(entries).encode();
  }

  String toUr({bool uppercase = true}) =>
      UrEncoder.encodeSingle(urType, toCborBytes(), uppercase: uppercase);

  factory CardanoAccountUr.fromCborBytes(Uint8List bytes) {
    final root = CborValue.decode(bytes);
    if (root is! CborMap) {
      throw const FormatException('cardano-account must be a CBOR map');
    }
    final ver = root.getByIntKey(1);
    final net = root.getByIntKey(2);
    final xvk = root.getByIntKey(3);
    final idx = root.getByIntKey(4);
    final lbl = root.getByIntKey(5);

    if (ver is! CborInt || net is! CborInt || xvk is! CborBytes) {
      throw const FormatException('Missing required fields in cardano-account');
    }

    return CardanoAccountUr(
      version: ver.toInt(),
      network: CardanoNetwork.fromUrCode(net.toInt()),
      acctXvk: xvk.bytes,
      accountIndex: idx is CborInt ? idx.toInt() : 0,
      label: lbl is CborText ? lbl.text : null,
    );
  }

  factory CardanoAccountUr.fromUr(String urString) {
    final res = UrDecoder.decodeSingle(urString);
    if (res.type != urType) {
      throw FormatException('Expected ur:$urType, got ur:${res.type}');
    }
    return CardanoAccountUr.fromCborBytes(res.cborPayload);
  }
}

/// Input context entry passed inside `ur:cardano-sign-request` for SEC-01 audit.
class UrUtxoInputContext {
  final Uint8List txHash;
  final int outputIndex;
  final Uint8List addressBytes;
  final BigInt lovelace;
  final MultiAsset multiAssets;
  final int? derivationRole; // 0 = External, 1 = Internal, 2 = Stake, 3 = DRep (null = auto-discover)
  final int? derivationIndex; // null = auto-discover

  bool get hasDerivationHint =>
      derivationRole != null &&
      derivationRole! >= 0 &&
      derivationIndex != null &&
      derivationIndex! >= 0;

  UrUtxoInputContext({
    required Uint8List txHash,
    required this.outputIndex,
    required Uint8List addressBytes,
    required this.lovelace,
    MultiAsset? multiAssets,
    int? derivationRole,
    int? derivationIndex,
  })  : txHash = Uint8List.fromList(txHash),
        addressBytes = Uint8List.fromList(addressBytes),
        multiAssets = multiAssets ?? MultiAsset.empty,
        derivationRole = (derivationRole != null && derivationRole >= 0) ? derivationRole : null,
        derivationIndex = (derivationIndex != null && derivationIndex >= 0) ? derivationIndex : null {
    if (this.txHash.length != 32) {
      throw ArgumentError('txHash must be 32 bytes');
    }
    if (outputIndex < 0) {
      throw ArgumentError('outputIndex cannot be negative: $outputIndex');
    }
    if (lovelace < BigInt.zero) {
      throw ArgumentError('UTXO input lovelace cannot be negative: $lovelace');
    }
  }

  CborMap toCbor() {
    final entries = <CborMapEntry>[
      CborMapEntry(CborInt.fromInt(1), CborBytes(txHash)),
      CborMapEntry(CborInt.fromInt(2), CborInt.fromInt(outputIndex)),
      CborMapEntry(CborInt.fromInt(3), CborBytes(addressBytes)),
      CborMapEntry(CborInt.fromInt(4), CborInt(lovelace)),
    ];

    if (multiAssets.isNotEmpty) {
      final policyEntries = <CborMapEntry>[];
      for (final pEntry in multiAssets.groupedByPolicy.entries) {
        final assetEntries = <CborMapEntry>[
          for (final aEntry in pEntry.value.entries)
            CborMapEntry(
              CborBytes(hexDecode(aEntry.key)),
              CborInt(aEntry.value),
            ),
        ];
        policyEntries.add(
          CborMapEntry(
            CborBytes(hexDecode(pEntry.key)),
            CborMap(assetEntries),
          ),
        );
      }
      entries.add(CborMapEntry(CborInt.fromInt(5), CborMap(policyEntries)));
    }

    if (derivationRole != null) {
      entries.add(CborMapEntry(CborInt.fromInt(6), CborInt.fromInt(derivationRole!)));
    }
    if (derivationIndex != null) {
      entries.add(CborMapEntry(CborInt.fromInt(7), CborInt.fromInt(derivationIndex!)));
    }

    return CborMap(entries);
  }

  factory UrUtxoInputContext.fromCbor(CborValue val) {
    if (val is! CborMap) {
      throw const FormatException('UTXO context entry must be a CBOR map');
    }
    final hash = val.getByIntKey(1);
    final idx = val.getByIntKey(2);
    final addr = val.getByIntKey(3);
    final coin = val.getByIntKey(4);
    final ma = val.getByIntKey(5);
    final role = val.getByIntKey(6);
    final dIdx = val.getByIntKey(7);

    if (hash is! CborBytes ||
        idx is! CborInt ||
        addr is! CborBytes ||
        coin is! CborInt) {
      throw const FormatException('Missing required UTXO context fields');
    }

    var multiAsset = MultiAsset.empty;
    if (ma != null) {
      if (ma is! CborMap) {
        throw const FormatException('Invalid multi_assets in UTXO context');
      }
      final parsed = <AssetKey, BigInt>{};
      for (final pEntry in ma.entries) {
        final pKey = pEntry.key;
        final aMap = pEntry.value;
        if (pKey is! CborBytes || aMap is! CborMap) {
          throw const FormatException('Invalid policy entry in UTXO context');
        }
        for (final aEntry in aMap.entries) {
          final aKey = aEntry.key;
          final qty = aEntry.value;
          if (aKey is! CborBytes || qty is! CborInt) {
            throw const FormatException('Invalid asset entry in UTXO context');
          }
          parsed[AssetKey.fromBytes(pKey.bytes, aKey.bytes)] = qty.value;
        }
      }
      multiAsset = MultiAsset(parsed);
    }

    final parsedRole = (role is CborInt && role.toInt() >= 0) ? role.toInt() : null;
    final parsedIdx = (dIdx is CborInt && dIdx.toInt() >= 0) ? dIdx.toInt() : null;

    return UrUtxoInputContext(
      txHash: hash.bytes,
      outputIndex: idx.toInt(),
      addressBytes: addr.bytes,
      lovelace: coin.value,
      multiAssets: multiAsset,
      derivationRole: parsedRole,
      derivationIndex: parsedIdx,
    );
  }
}

/// Change output reference passed inside `ur:cardano-sign-request`.
class UrChangeOutputRef {
  final int txOutputIndex;
  final int? internalIndex; // null = auto-discover along role=1

  const UrChangeOutputRef({
    required this.txOutputIndex,
    this.internalIndex,
  });

  CborMap toCbor() {
    final entries = <CborMapEntry>[
      CborMapEntry(CborInt.fromInt(1), CborInt.fromInt(txOutputIndex)),
    ];
    if (internalIndex != null && internalIndex! >= 0) {
      entries.add(CborMapEntry(CborInt.fromInt(2), CborInt.fromInt(internalIndex!)));
    }
    return CborMap(entries);
  }

  factory UrChangeOutputRef.fromCbor(CborValue val) {
    if (val is! CborMap) {
      throw const FormatException('ChangeOutputRef must be a CBOR map');
    }
    final outIdx = val.getByIntKey(1);
    final intIdx = val.getByIntKey(2);
    if (outIdx is! CborInt) {
      throw const FormatException('Missing ChangeOutputRef txOutputIndex');
    }
    return UrChangeOutputRef(
      txOutputIndex: outIdx.toInt(),
      internalIndex: (intIdx is CborInt && intIdx.toInt() >= 0) ? intIdx.toInt() : null,
    );
  }
}

/// `ur:cardano-sign-request` (Hot Wallet -> Cold Wallet).
class CardanoSignRequestUr {
  static const String urType = 'cardano-sign-request';

  final int version;
  final Uint8List requestId; // 16 bytes UUID
  final CardanoNetwork network;
  final Uint8List txBodyCbor;
  final List<UrUtxoInputContext> utxoInputs;
  final List<UrChangeOutputRef> changeOutputs;
  final bool requireStakeWitness;
  final int? accountIndex; // Optional CIP-1852 account index hint (key 8)

  CardanoSignRequestUr({
    this.version = 1,
    required Uint8List requestId,
    required this.network,
    required Uint8List txBodyCbor,
    required this.utxoInputs,
    required this.changeOutputs,
    required this.requireStakeWitness,
    this.accountIndex,
  })  : requestId = Uint8List.fromList(requestId),
        txBodyCbor = Uint8List.fromList(txBodyCbor) {
    if (this.requestId.length != 16) {
      throw ArgumentError('requestId must be 16 bytes');
    }
  }

  Uint8List toCborBytes() {
    final entries = <CborMapEntry>[
      CborMapEntry(CborInt.fromInt(1), CborInt.fromInt(version)),
      CborMapEntry(CborInt.fromInt(2), CborBytes(requestId)),
      CborMapEntry(CborInt.fromInt(3), CborInt.fromInt(network.urCode)),
      CborMapEntry(CborInt.fromInt(4), CborBytes(txBodyCbor)),
      CborMapEntry(
        CborInt.fromInt(5),
        CborArray([for (final u in utxoInputs) u.toCbor()]),
      ),
      CborMapEntry(
        CborInt.fromInt(6),
        CborArray([for (final c in changeOutputs) c.toCbor()]),
      ),
      CborMapEntry(CborInt.fromInt(7), CborBool(requireStakeWitness)),
    ];
    if (accountIndex != null && accountIndex! >= 0) {
      entries.add(CborMapEntry(CborInt.fromInt(8), CborInt.fromInt(accountIndex!)));
    }
    return CborMap(entries).encode();
  }

  UrEncoder createEncoder({int maxFragmentLen = 90}) => UrEncoder(
        type: urType,
        cborPayload: toCborBytes(),
        maxFragmentLen: maxFragmentLen,
      );

  factory CardanoSignRequestUr.fromCborBytes(Uint8List bytes) {
    final root = CborValue.decode(bytes);
    if (root is! CborMap) {
      throw const FormatException('cardano-sign-request must be a CBOR map');
    }
    final ver = root.getByIntKey(1);
    final reqId = root.getByIntKey(2);
    final net = root.getByIntKey(3);
    final txBody = root.getByIntKey(4);
    final inputs = root.getByIntKey(5);
    final changes = root.getByIntKey(6);
    final reqStake = root.getByIntKey(7);
    final acctIdx = root.getByIntKey(8);

    if (ver is! CborInt ||
        reqId is! CborBytes ||
        net is! CborInt ||
        txBody is! CborBytes ||
        inputs is! CborArray ||
        changes is! CborArray ||
        reqStake is! CborBool) {
      throw const FormatException('Missing or invalid fields in cardano-sign-request');
    }

    return CardanoSignRequestUr(
      version: ver.toInt(),
      requestId: reqId.bytes,
      network: CardanoNetwork.fromUrCode(net.toInt()),
      txBodyCbor: txBody.bytes,
      utxoInputs: [
        for (final i in inputs.items) UrUtxoInputContext.fromCbor(i),
      ],
      changeOutputs: [
        for (final c in changes.items) UrChangeOutputRef.fromCbor(c),
      ],
      requireStakeWitness: reqStake.value,
      accountIndex: (acctIdx is CborInt && acctIdx.toInt() >= 0) ? acctIdx.toInt() : null,
    );
  }
}

/// `ur:cardano-sign-response` (Cold Wallet -> Hot Wallet).
class CardanoSignResponseUr {
  static const String urType = 'cardano-sign-response';

  final int version;
  final Uint8List requestId; // 16 bytes matching request
  final List<VKeyWitness> vkeyWitnesses;

  CardanoSignResponseUr({
    this.version = 1,
    required Uint8List requestId,
    required this.vkeyWitnesses,
  }) : requestId = Uint8List.fromList(requestId) {
    if (this.requestId.length != 16) {
      throw ArgumentError('requestId must be 16 bytes');
    }
  }

  Uint8List toCborBytes() {
    return CborMap([
      CborMapEntry(CborInt.fromInt(1), CborInt.fromInt(version)),
      CborMapEntry(CborInt.fromInt(2), CborBytes(requestId)),
      CborMapEntry(
        CborInt.fromInt(3),
        CborArray([
          for (final w in vkeyWitnesses)
            CborArray([CborBytes(w.vkey), CborBytes(w.signature)]),
        ]),
      ),
    ]).encode();
  }

  UrEncoder createEncoder({int maxFragmentLen = 90}) => UrEncoder(
        type: urType,
        cborPayload: toCborBytes(),
        maxFragmentLen: maxFragmentLen,
      );

  factory CardanoSignResponseUr.fromCborBytes(Uint8List bytes) {
    final root = CborValue.decode(bytes);
    if (root is! CborMap) {
      throw const FormatException('cardano-sign-response must be a CBOR map');
    }
    final ver = root.getByIntKey(1);
    final reqId = root.getByIntKey(2);
    final wits = root.getByIntKey(3);

    if (ver is! CborInt || reqId is! CborBytes || wits is! CborArray) {
      throw const FormatException('Missing fields in cardano-sign-response');
    }

    final parsedWits = <VKeyWitness>[];
    for (final item in wits.items) {
      if (item is! CborArray || item.items.length != 2) {
        throw const FormatException('Invalid VKeyWitness entry in sign-response');
      }
      final vk = item.items[0];
      final sig = item.items[1];
      if (vk is! CborBytes || sig is! CborBytes) {
        throw const FormatException('Invalid VKeyWitness bytes');
      }
      parsedWits.add(VKeyWitness(vkey: vk.bytes, signature: sig.bytes));
    }

    return CardanoSignResponseUr(
      version: ver.toInt(),
      requestId: reqId.bytes,
      vkeyWitnesses: parsedWits,
    );
  }
}
