import 'dart:convert';
import 'dart:typed_data';

import '../crypto/bytes.dart';

/// Represents a unique Cardano Native Asset identifier (`policyId` 28B + `assetName`).
class AssetKey implements Comparable<AssetKey> {
  final String policyIdHex;
  final String assetNameHex;

  AssetKey(this.policyIdHex, this.assetNameHex) {
    if (policyIdHex.length != 56) {
      throw ArgumentError('policyIdHex must be 56 hex chars (28 bytes)');
    }
  }

  factory AssetKey.fromBytes(Uint8List policyId, Uint8List assetName) {
    if (policyId.length != 28) {
      throw ArgumentError('policyId must be 28 bytes');
    }
    return AssetKey(hexEncode(policyId), hexEncode(assetName));
  }

  /// Blockfrost concatenated unit string (`policyIdHex + assetNameHex`).
  String get unit => '$policyIdHex$assetNameHex';

  Uint8List get policyIdBytes => hexDecode(policyIdHex);
  Uint8List get assetNameBytes => hexDecode(assetNameHex);

  /// Best-effort UTF-8/ASCII display name, falling back to hex if non-printable.
  String get displayName {
    if (assetNameHex.isEmpty) return '(unnamed)';
    final bytes = assetNameBytes;
    try {
      final decoded = utf8.decode(bytes, allowMalformed: false);
      final isPrintable = decoded.runes.every((r) => r >= 32 && r <= 126);
      if (isPrintable && decoded.isNotEmpty) return decoded;
    } catch (_) {}
    return '0x$assetNameHex';
  }

  String get shortPolicy =>
      '${policyIdHex.substring(0, 8)}...${policyIdHex.substring(policyIdHex.length - 6)}';

  @override
  int compareTo(AssetKey other) {
    final p = policyIdHex.compareTo(other.policyIdHex);
    return p != 0 ? p : assetNameHex.compareTo(other.assetNameHex);
  }

  @override
  bool operator ==(Object other) =>
      other is AssetKey &&
      other.policyIdHex == policyIdHex &&
      other.assetNameHex == assetNameHex;

  @override
  int get hashCode => Object.hash(policyIdHex, assetNameHex);

  @override
  String toString() => '$policyIdHex.$assetNameHex';
}

/// Immutable container for Cardano Multi-Asset quantities (`Map<AssetKey, BigInt>`).
class MultiAsset {
  final Map<AssetKey, BigInt> assets;

  MultiAsset([Map<AssetKey, BigInt>? initial])
      : assets = Map.unmodifiable({
          if (initial != null)
            for (final e in initial.entries)
              if (e.value > BigInt.zero) e.key: e.value,
        });

  static final MultiAsset empty = MultiAsset();

  bool get isEmpty => assets.isEmpty;
  bool get isNotEmpty => assets.isNotEmpty;

  BigInt operator [](AssetKey key) => assets[key] ?? BigInt.zero;

  /// Groups assets by `policyIdHex` -> `assetNameHex` -> `amount` for CBOR encoding.
  Map<String, Map<String, BigInt>> get groupedByPolicy {
    final out = <String, Map<String, BigInt>>{};
    final sortedKeys = assets.keys.toList()..sort();
    for (final k in sortedKeys) {
      out.putIfAbsent(k.policyIdHex, () => {})[k.assetNameHex] = assets[k]!;
    }
    return out;
  }

  MultiAsset add(MultiAsset other) {
    final next = Map<AssetKey, BigInt>.from(assets);
    for (final e in other.assets.entries) {
      next[e.key] = (next[e.key] ?? BigInt.zero) + e.value;
    }
    return MultiAsset(next);
  }

  MultiAsset subtract(MultiAsset other) {
    final next = Map<AssetKey, BigInt>.from(assets);
    for (final e in other.assets.entries) {
      final current = next[e.key] ?? BigInt.zero;
      final remaining = current - e.value;
      if (remaining < BigInt.zero) {
        throw StateError('Insufficient asset balance for ${e.key}');
      }
      if (remaining == BigInt.zero) {
        next.remove(e.key);
      } else {
        next[e.key] = remaining;
      }
    }
    return MultiAsset(next);
  }

  @override
  bool operator ==(Object other) {
    if (other is! MultiAsset || other.assets.length != assets.length) {
      return false;
    }
    for (final e in assets.entries) {
      if (other.assets[e.key] != e.value) return false;
    }
    return true;
  }

  @override
  int get hashCode =>
      Object.hashAll(assets.entries.map((e) => Object.hash(e.key, e.value)));
}

/// UTXO reference `[txHash, index]`.
class TxInput {
  final Uint8List txHash;
  final int index;

  TxInput({required Uint8List txHash, required this.index})
      : txHash = Uint8List.fromList(txHash) {
    if (this.txHash.length != 32) {
      throw ArgumentError('txHash must be 32 bytes, got ${this.txHash.length}');
    }
    if (index < 0) {
      throw ArgumentError('TxInput index must be >= 0');
    }
  }

  String get id => '${hexEncode(txHash)}#$index';

  @override
  bool operator ==(Object other) =>
      other is TxInput &&
      other.index == index &&
      constantTimeEquals(other.txHash, txHash);

  @override
  int get hashCode => Object.hash(Object.hashAll(txHash), index);
}

/// Cardano Transaction Output.
class TxOutput {
  final Uint8List addressBytes;
  final BigInt lovelace;
  final MultiAsset multiAsset;

  TxOutput({
    required Uint8List addressBytes,
    required this.lovelace,
    MultiAsset? multiAsset,
  })  : addressBytes = Uint8List.fromList(addressBytes),
        multiAsset = multiAsset ?? MultiAsset.empty {
    if (lovelace < BigInt.zero) {
      throw ArgumentError('TxOutput lovelace cannot be negative');
    }
  }
}

/// Shelley/Conway stake credential: `[0, keyHash28]` or `[1, scriptHash28]`.
class StakeCredential {
  final bool isScriptHash;
  final Uint8List hash28;

  StakeCredential({this.isScriptHash = false, required Uint8List hash28})
      : hash28 = Uint8List.fromList(hash28) {
    if (this.hash28.length != 28) {
      throw ArgumentError('StakeCredential hash must be 28 bytes');
    }
  }

  @override
  bool operator ==(Object other) =>
      other is StakeCredential &&
      other.isScriptHash == isScriptHash &&
      constantTimeEquals(other.hash28, hash28);

  @override
  int get hashCode => Object.hash(isScriptHash, Object.hashAll(hash28));
}

/// Conway Era DRep target in vote delegation certificates.
sealed class DRep {
  const DRep();
}

class DRepKeyHash extends DRep {
  final Uint8List hash28;
  DRepKeyHash(Uint8List hash28) : hash28 = Uint8List.fromList(hash28) {
    if (this.hash28.length != 28) {
      throw ArgumentError('DRep key hash must be 28 bytes');
    }
  }
}

class DRepScriptHash extends DRep {
  final Uint8List hash28;
  DRepScriptHash(Uint8List hash28) : hash28 = Uint8List.fromList(hash28) {
    if (this.hash28.length != 28) {
      throw ArgumentError('DRep script hash must be 28 bytes');
    }
  }
}

class DRepAlwaysAbstain extends DRep {
  const DRepAlwaysAbstain();
}

class DRepAlwaysNoConfidence extends DRep {
  const DRepAlwaysNoConfidence();
}

/// Conway Era Certificates.
sealed class CardanoCertificate {
  StakeCredential get stakeCredential;
  const CardanoCertificate();
}

class StakeRegistrationCert extends CardanoCertificate {
  @override
  final StakeCredential stakeCredential;
  final BigInt? coin; // null => legacy tag 0; non-null => Conway tag 7

  const StakeRegistrationCert(this.stakeCredential, {this.coin});
}

class StakeDeregistrationCert extends CardanoCertificate {
  @override
  final StakeCredential stakeCredential;
  final BigInt? coin; // null => legacy tag 1; non-null => Conway tag 8

  const StakeDeregistrationCert(this.stakeCredential, {this.coin});
}

class StakeDelegationCert extends CardanoCertificate {
  @override
  final StakeCredential stakeCredential;
  final Uint8List poolKeyHash;

  StakeDelegationCert(this.stakeCredential, Uint8List poolKeyHash)
      : poolKeyHash = Uint8List.fromList(poolKeyHash) {
    if (this.poolKeyHash.length != 28) {
      throw ArgumentError('Pool key hash must be 28 bytes');
    }
  }
}

class VoteDelegationCert extends CardanoCertificate {
  @override
  final StakeCredential stakeCredential;
  final DRep drep;

  const VoteDelegationCert(this.stakeCredential, this.drep);
}

class StakeVoteDelegationCert extends CardanoCertificate {
  @override
  final StakeCredential stakeCredential;
  final Uint8List poolKeyHash;
  final DRep drep;

  StakeVoteDelegationCert(this.stakeCredential, Uint8List poolKeyHash, this.drep)
      : poolKeyHash = Uint8List.fromList(poolKeyHash) {
    if (this.poolKeyHash.length != 28) {
      throw ArgumentError('Pool key hash must be 28 bytes');
    }
  }
}

class StakeRegDelegCert extends CardanoCertificate {
  @override
  final StakeCredential stakeCredential;
  final Uint8List poolKeyHash;
  final BigInt coin;

  StakeRegDelegCert(this.stakeCredential, Uint8List poolKeyHash, this.coin)
      : poolKeyHash = Uint8List.fromList(poolKeyHash) {
    if (this.poolKeyHash.length != 28) {
      throw ArgumentError('Pool key hash must be 28 bytes');
    }
  }
}

class VoteRegDelegCert extends CardanoCertificate {
  @override
  final StakeCredential stakeCredential;
  final DRep drep;
  final BigInt coin;

  const VoteRegDelegCert(this.stakeCredential, this.drep, this.coin);
}

class StakeVoteRegDelegCert extends CardanoCertificate {
  @override
  final StakeCredential stakeCredential;
  final Uint8List poolKeyHash;
  final DRep drep;
  final BigInt coin;

  StakeVoteRegDelegCert(
    this.stakeCredential,
    Uint8List poolKeyHash,
    this.drep,
    this.coin,
  ) : poolKeyHash = Uint8List.fromList(poolKeyHash) {
    if (this.poolKeyHash.length != 28) {
      throw ArgumentError('Pool key hash must be 28 bytes');
    }
  }
}

/// Reward withdrawal entry.
class Withdrawal {
  final Uint8List rewardAddressBytes;
  final BigInt coin;

  Withdrawal({required Uint8List rewardAddressBytes, required this.coin})
      : rewardAddressBytes = Uint8List.fromList(rewardAddressBytes) {
    if (this.rewardAddressBytes.length != 29) {
      throw ArgumentError('Reward address must be 29 bytes');
    }
    if (coin < BigInt.zero) {
      throw ArgumentError('Withdrawal amount cannot be negative');
    }
  }
}

/// Cardano Conway Era Transaction Body.
class ConwayTxBody {
  final List<TxInput> inputs;
  final List<TxOutput> outputs;
  final BigInt fee;
  final int? ttl;
  final List<CardanoCertificate> certificates;
  final List<Withdrawal> withdrawals;
  final int? networkId;

  ConwayTxBody({
    required this.inputs,
    required this.outputs,
    required this.fee,
    this.ttl,
    this.certificates = const [],
    this.withdrawals = const [],
    this.networkId,
  });
}

/// Ed25519 VKey Witness `[vkey(32B), signature(64B)]`.
class VKeyWitness {
  final Uint8List vkey;
  final Uint8List signature;

  VKeyWitness({required Uint8List vkey, required Uint8List signature})
      : vkey = Uint8List.fromList(vkey),
        signature = Uint8List.fromList(signature) {
    if (this.vkey.length != 32) {
      throw ArgumentError('VKey must be 32 bytes');
    }
    if (this.signature.length != 64) {
      throw ArgumentError('Signature must be 64 bytes');
    }
  }
}
