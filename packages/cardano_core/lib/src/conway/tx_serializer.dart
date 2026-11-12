import 'dart:typed_data';

import '../crypto/blake2b.dart';
import '../crypto/bytes.dart';
import '../crypto/ed25519_bip32.dart';
import 'cbor.dart';
import 'models.dart';

/// Encodes, decodes, hashes, and assembles Cardano Conway Era transactions.
class ConwayTxSerializer {
  /// Encodes a [TxOutput] in Conway/Babbage format `{0: address, 1: value}`.
  static CborValue encodeTxOutput(TxOutput out) {
    final CborValue valueCbor;
    if (out.multiAsset.isEmpty) {
      valueCbor = CborInt(out.lovelace);
    } else {
      final policyEntries = <CborMapEntry>[];
      final grouped = out.multiAsset.groupedByPolicy;
      for (final policyEntry in grouped.entries) {
        final assetEntries = <CborMapEntry>[];
        for (final assetEntry in policyEntry.value.entries) {
          assetEntries.add(
            CborMapEntry(
              CborBytes(hexDecode(assetEntry.key)),
              CborInt(assetEntry.value),
            ),
          );
        }
        policyEntries.add(
          CborMapEntry(
            CborBytes(hexDecode(policyEntry.key)),
            CborMap(assetEntries),
          ),
        );
      }
      valueCbor = CborArray([
        CborInt(out.lovelace),
        CborMap(policyEntries),
      ]);
    }

    return CborMap([
      CborMapEntry(CborInt.fromInt(0), CborBytes(out.addressBytes)),
      CborMapEntry(CborInt.fromInt(1), valueCbor),
    ]);
  }

  /// Decodes either Shelley `[address, value]` or Babbage/Conway `{0: address, 1: value}` output.
  static TxOutput decodeTxOutput(CborValue val) {
    final Uint8List addressBytes;
    final CborValue valueCbor;

    if (val is CborArray && val.items.length >= 2) {
      final addr = val.items[0];
      if (addr is! CborBytes) {
        throw const FormatException('Invalid Shelley TxOutput address');
      }
      addressBytes = addr.bytes;
      valueCbor = val.items[1];
    } else if (val is CborMap) {
      final addr = val.getByIntKey(0);
      final v = val.getByIntKey(1);
      if (addr is! CborBytes || v == null) {
        throw const FormatException('Invalid Babbage/Conway TxOutput map');
      }
      addressBytes = addr.bytes;
      valueCbor = v;
    } else {
      throw const FormatException('Unsupported TxOutput CBOR structure');
    }

    if (valueCbor is CborInt) {
      return TxOutput(addressBytes: addressBytes, lovelace: valueCbor.value);
    } else if (valueCbor is CborArray && valueCbor.items.length == 2) {
      final coin = valueCbor.items[0];
      final maMap = valueCbor.items[1];
      if (coin is! CborInt || maMap is! CborMap) {
        throw const FormatException('Invalid MultiAsset value in TxOutput');
      }
      final parsedAssets = <AssetKey, BigInt>{};
      for (final pEntry in maMap.entries) {
        final pKey = pEntry.key;
        final aMap = pEntry.value;
        if (pKey is! CborBytes || aMap is! CborMap) {
          throw const FormatException('Invalid policy entry in TxOutput');
        }
        for (final aEntry in aMap.entries) {
          final aKey = aEntry.key;
          final qty = aEntry.value;
          if (aKey is! CborBytes || qty is! CborInt) {
            throw const FormatException('Invalid asset entry in TxOutput');
          }
          parsedAssets[AssetKey.fromBytes(pKey.bytes, aKey.bytes)] = qty.value;
        }
      }
      return TxOutput(
        addressBytes: addressBytes,
        lovelace: coin.value,
        multiAsset: MultiAsset(parsedAssets),
      );
    }

    throw const FormatException('Invalid TxOutput value CBOR');
  }

  /// Encodes a [ConwayTxBody] into deterministic CBOR bytes.
  static Uint8List encodeTxBody(ConwayTxBody body) {
    final entries = <CborMapEntry>[
      CborMapEntry(
        CborInt.fromInt(0),
        CborTag(
          258,
          CborArray([
            for (final i in body.inputs)
              CborArray([CborBytes(i.txHash), CborInt.fromInt(i.index)]),
          ]),
        ),
      ),
      CborMapEntry(
        CborInt.fromInt(1),
        CborArray([
          for (final o in body.outputs) encodeTxOutput(o),
        ]),
      ),
      CborMapEntry(CborInt.fromInt(2), CborInt(body.fee)),
    ];

    if (body.ttl != null) {
      entries.add(CborMapEntry(CborInt.fromInt(3), CborInt.fromInt(body.ttl!)));
    }

    if (body.certificates.isNotEmpty) {
      entries.add(
        CborMapEntry(
          CborInt.fromInt(4),
          CborTag(
            258,
            CborArray([
              for (final c in body.certificates) _encodeCertificate(c),
            ]),
          ),
        ),
      );
    }

    if (body.withdrawals.isNotEmpty) {
      entries.add(
        CborMapEntry(
          CborInt.fromInt(5),
          CborMap([
            for (final w in body.withdrawals)
              CborMapEntry(
                CborBytes(w.rewardAddressBytes),
                CborInt(w.coin),
              ),
          ]),
        ),
      );
    }

    if (body.networkId != null) {
      entries.add(
        CborMapEntry(
          CborInt.fromInt(8),
          CborInt.fromInt(body.networkId!),
        ),
      );
    }

    return CborMap(entries).encode();
  }

  /// Decodes raw [txBodyCbor] bytes into a [ConwayTxBody].
  static ConwayTxBody decodeTxBody(Uint8List txBodyCbor) {
    final root = CborValue.decode(txBodyCbor);
    if (root is! CborMap) {
      throw const FormatException('TxBody CBOR must be a map');
    }

    // 0: inputs
    final rawInputs = _unwrapSet(root.getByIntKey(0));
    if (rawInputs == null) {
      throw const FormatException('TxBody missing inputs (key 0)');
    }
    final inputs = <TxInput>[];
    for (final item in rawInputs.items) {
      if (item is! CborArray || item.items.length != 2) {
        throw const FormatException('Invalid TxInput CBOR');
      }
      final hash = item.items[0];
      final idx = item.items[1];
      if (hash is! CborBytes || idx is! CborInt) {
        throw const FormatException('Invalid TxInput fields');
      }
      inputs.add(TxInput(txHash: hash.bytes, index: idx.toInt()));
    }

    // 1: outputs
    final rawOutputs = root.getByIntKey(1);
    if (rawOutputs is! CborArray) {
      throw const FormatException('TxBody missing outputs (key 1)');
    }
    final outputs = [
      for (final item in rawOutputs.items) decodeTxOutput(item),
    ];

    // 2: fee
    final rawFee = root.getByIntKey(2);
    if (rawFee is! CborInt) {
      throw const FormatException('TxBody missing fee (key 2)');
    }

    // 3: ttl (optional)
    final rawTtl = root.getByIntKey(3);
    final ttl = rawTtl is CborInt ? rawTtl.toInt() : null;

    // 4: certificates (optional)
    final certs = <CardanoCertificate>[];
    final rawCerts = root.getByIntKey(4);
    if (rawCerts != null) {
      final certArr = _unwrapSet(rawCerts);
      if (certArr == null) {
        throw const FormatException('Invalid certificates CBOR (key 4)');
      }
      for (final c in certArr.items) {
        certs.add(_decodeCertificate(c));
      }
    }

    // 5: withdrawals (optional)
    final withdrawals = <Withdrawal>[];
    final rawWdrl = root.getByIntKey(5);
    if (rawWdrl != null) {
      if (rawWdrl is! CborMap) {
        throw const FormatException('Invalid withdrawals CBOR (key 5)');
      }
      for (final e in rawWdrl.entries) {
        final k = e.key;
        final v = e.value;
        if (k is! CborBytes || v is! CborInt) {
          throw const FormatException('Invalid withdrawal entry');
        }
        withdrawals.add(Withdrawal(rewardAddressBytes: k.bytes, coin: v.value));
      }
    }

    // 8: network_id (optional)
    final rawNet = root.getByIntKey(8);
    final networkId = rawNet is CborInt ? rawNet.toInt() : null;

    return ConwayTxBody(
      inputs: inputs,
      outputs: outputs,
      fee: rawFee.value,
      ttl: ttl,
      certificates: certs,
      withdrawals: withdrawals,
      networkId: networkId,
    );
  }

  /// Computes Blake2b-256 hash of [txBodyCbor] (the exact digest signed by Ed25519).
  static Uint8List computeTxBodyHash(Uint8List txBodyCbor) =>
      blake2b256(txBodyCbor);

  /// Assembles `[tx_body_raw, witness_set, true, null]` preserving exact [txBodyCbor] bytes.
  static Uint8List assembleSignedTransaction({
    required Uint8List txBodyCbor,
    required List<VKeyWitness> witnesses,
    bool verifySignatures = true,
  }) {
    if (witnesses.isEmpty) {
      throw ArgumentError('At least one VKeyWitness is required');
    }

    final txBodyHash = computeTxBodyHash(txBodyCbor);
    // Deduplicate witnesses by vkey
    final deduped = <String, VKeyWitness>{};
    for (final w in witnesses) {
      if (verifySignatures &&
          !Ed25519.verify(w.vkey, txBodyHash, w.signature)) {
        throw StateError('Invalid VKeyWitness signature for ${hexEncode(w.vkey)}');
      }
      deduped[hexEncode(w.vkey)] = w;
    }

    final witnessSet = CborMap([
      CborMapEntry(
        CborInt.fromInt(0),
        CborTag(
          258,
          CborArray([
            for (final w in deduped.values)
              CborArray([CborBytes(w.vkey), CborBytes(w.signature)]),
          ]),
        ),
      ),
    ]);

    final out = BytesBuilder(copy: false);
    out.addByte(0x84); // 4-element CBOR array
    out.add(txBodyCbor);
    witnessSet.writeTo(out);
    out.addByte(0xf5); // is_valid = true
    out.addByte(0xf6); // auxiliary_data = null
    return out.toBytes();
  }

  static CborArray? _unwrapSet(CborValue? v) {
    if (v is CborArray) return v;
    if (v is CborTag && v.tag == 258 && v.value is CborArray) {
      return v.value as CborArray;
    }
    return null;
  }

  static CborArray _encodeCredential(StakeCredential cred) {
    return CborArray([
      CborInt.fromInt(cred.isScriptHash ? 1 : 0),
      CborBytes(cred.hash28),
    ]);
  }

  static StakeCredential _decodeCredential(CborValue val) {
    if (val is! CborArray || val.items.length != 2) {
      throw const FormatException('Invalid StakeCredential CBOR');
    }
    final type = val.items[0];
    final hash = val.items[1];
    if (type is! CborInt || hash is! CborBytes) {
      throw const FormatException('Invalid StakeCredential fields');
    }
    return StakeCredential(
      isScriptHash: type.toInt() == 1,
      hash28: hash.bytes,
    );
  }

  static CborArray _encodeDRep(DRep drep) {
    return switch (drep) {
      DRepKeyHash(:final hash28) =>
        CborArray([CborInt.fromInt(0), CborBytes(hash28)]),
      DRepScriptHash(:final hash28) =>
        CborArray([CborInt.fromInt(1), CborBytes(hash28)]),
      DRepAlwaysAbstain() => CborArray([CborInt.fromInt(2)]),
      DRepAlwaysNoConfidence() => CborArray([CborInt.fromInt(3)]),
    };
  }

  static DRep _decodeDRep(CborValue val) {
    if (val is! CborArray || val.items.isEmpty) {
      throw const FormatException('Invalid DRep CBOR');
    }
    final tag = val.items[0];
    if (tag is! CborInt) {
      throw const FormatException('Invalid DRep tag');
    }
    switch (tag.toInt()) {
      case 0:
        final h = val.items[1];
        if (h is! CborBytes) throw const FormatException('Invalid DRep key hash');
        return DRepKeyHash(h.bytes);
      case 1:
        final h = val.items[1];
        if (h is! CborBytes) throw const FormatException('Invalid DRep script hash');
        return DRepScriptHash(h.bytes);
      case 2:
        return const DRepAlwaysAbstain();
      case 3:
        return const DRepAlwaysNoConfidence();
      default:
        throw FormatException('Unknown DRep tag: ${tag.toInt()}');
    }
  }

  static CborArray _encodeCertificate(CardanoCertificate cert) {
    return switch (cert) {
      StakeRegistrationCert(:final stakeCredential, :final coin) => coin == null
          ? CborArray([CborInt.fromInt(0), _encodeCredential(stakeCredential)])
          : CborArray([
              CborInt.fromInt(7),
              _encodeCredential(stakeCredential),
              CborInt(coin),
            ]),
      StakeDeregistrationCert(:final stakeCredential, :final coin) => coin == null
          ? CborArray([CborInt.fromInt(1), _encodeCredential(stakeCredential)])
          : CborArray([
              CborInt.fromInt(8),
              _encodeCredential(stakeCredential),
              CborInt(coin),
            ]),
      StakeDelegationCert(:final stakeCredential, :final poolKeyHash) =>
        CborArray([
          CborInt.fromInt(2),
          _encodeCredential(stakeCredential),
          CborBytes(poolKeyHash),
        ]),
      VoteDelegationCert(:final stakeCredential, :final drep) => CborArray([
          CborInt.fromInt(9),
          _encodeCredential(stakeCredential),
          _encodeDRep(drep),
        ]),
      StakeVoteDelegationCert(
        :final stakeCredential,
        :final poolKeyHash,
        :final drep
      ) =>
        CborArray([
          CborInt.fromInt(10),
          _encodeCredential(stakeCredential),
          CborBytes(poolKeyHash),
          _encodeDRep(drep),
        ]),
      StakeRegDelegCert(:final stakeCredential, :final poolKeyHash, :final coin) =>
        CborArray([
          CborInt.fromInt(11),
          _encodeCredential(stakeCredential),
          CborBytes(poolKeyHash),
          CborInt(coin),
        ]),
      VoteRegDelegCert(:final stakeCredential, :final drep, :final coin) =>
        CborArray([
          CborInt.fromInt(12),
          _encodeCredential(stakeCredential),
          _encodeDRep(drep),
          CborInt(coin),
        ]),
      StakeVoteRegDelegCert(
        :final stakeCredential,
        :final poolKeyHash,
        :final drep,
        :final coin
      ) =>
        CborArray([
          CborInt.fromInt(13),
          _encodeCredential(stakeCredential),
          CborBytes(poolKeyHash),
          _encodeDRep(drep),
          CborInt(coin),
        ]),
    };
  }

  static CardanoCertificate _decodeCertificate(CborValue val) {
    if (val is! CborArray || val.items.length < 2) {
      throw const FormatException('Invalid certificate CBOR');
    }
    final tagVal = val.items[0];
    if (tagVal is! CborInt) {
      throw const FormatException('Invalid certificate tag');
    }
    final cred = _decodeCredential(val.items[1]);
    switch (tagVal.toInt()) {
      case 0:
        return StakeRegistrationCert(cred);
      case 1:
        return StakeDeregistrationCert(cred);
      case 2:
        final pool = val.items[2];
        if (pool is! CborBytes) throw const FormatException('Invalid pool hash');
        return StakeDelegationCert(cred, pool.bytes);
      case 7:
        final coin = val.items[2];
        if (coin is! CborInt) throw const FormatException('Invalid reg coin');
        return StakeRegistrationCert(cred, coin: coin.value);
      case 8:
        final coin = val.items[2];
        if (coin is! CborInt) throw const FormatException('Invalid unreg coin');
        return StakeDeregistrationCert(cred, coin: coin.value);
      case 9:
        return VoteDelegationCert(cred, _decodeDRep(val.items[2]));
      case 10:
        final pool = val.items[2];
        if (pool is! CborBytes) throw const FormatException('Invalid pool hash');
        return StakeVoteDelegationCert(cred, pool.bytes, _decodeDRep(val.items[3]));
      case 11:
        final pool = val.items[2];
        final coin = val.items[3];
        if (pool is! CborBytes || coin is! CborInt) {
          throw const FormatException('Invalid stake_reg_deleg cert');
        }
        return StakeRegDelegCert(cred, pool.bytes, coin.value);
      case 12:
        final coin = val.items[3];
        if (coin is! CborInt) throw const FormatException('Invalid vote_reg_deleg coin');
        return VoteRegDelegCert(cred, _decodeDRep(val.items[2]), coin.value);
      case 13:
        final pool = val.items[2];
        final coin = val.items[4];
        if (pool is! CborBytes || coin is! CborInt) {
          throw const FormatException('Invalid stake_vote_reg_deleg cert');
        }
        return StakeVoteRegDelegCert(
          cred,
          pool.bytes,
          _decodeDRep(val.items[3]),
          coin.value,
        );
      default:
        throw FormatException('Unsupported certificate tag: ${tagVal.toInt()}');
    }
  }
}
