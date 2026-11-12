import 'package:cardano_core/cardano_core.dart';
import 'blockfrost_service.dart';

class WatchOnlyProfile {
  final String id;
  final String name;
  final CardanoNetwork network;
  final String acctXvkBech32;
  final int accountIndex;
  final int createdAtMs;

  const WatchOnlyProfile({
    required this.id,
    required this.name,
    required this.network,
    required this.acctXvkBech32,
    this.accountIndex = 0,
    required this.createdAtMs,
  });

  WatchOnlyProfile copyWith({String? name}) => WatchOnlyProfile(
        id: id,
        name: name ?? this.name,
        network: network,
        acctXvkBech32: acctXvkBech32,
        accountIndex: accountIndex,
        createdAtMs: createdAtMs,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'network': network.id,
        'acctXvkBech32': acctXvkBech32,
        'accountIndex': accountIndex,
        'createdAtMs': createdAtMs,
      };

  factory WatchOnlyProfile.fromJson(Map<String, dynamic> json) {
    return WatchOnlyProfile(
      id: json['id'] as String,
      name: json['name'] as String,
      network: CardanoNetwork.fromId(json['network'] as String),
      acctXvkBech32: json['acctXvkBech32'] as String,
      accountIndex: (json['accountIndex'] as num?)?.toInt() ?? 0,
      createdAtMs: (json['createdAtMs'] as num).toInt(),
    );
  }
}

class DerivedUtxo {
  final BlockfrostUtxo utxo;
  final int derivationRole;
  final int derivationIndex;

  const DerivedUtxo({
    required this.utxo,
    required this.derivationRole,
    required this.derivationIndex,
  });
}

class WalletSyncState {
  final BigInt totalLovelace;
  final MultiAsset totalMultiAsset;
  final List<DerivedUtxo> utxos;
  final String primaryReceiveAddress;
  final String nextUnusedExternalAddress;
  final int nextUnusedExternalIndex;
  final int nextUnusedInternalIndex;
  final String stakeAddress;
  final StakeAccountInfo stakeInfo;
  final String? poolName;
  final Map<String, AssetMetadataInfo> assetMetadata;
  final List<AddressTxSummary> recentTxs;
  final ProtocolParameters protocolParameters;
  final int latestSlot;

  const WalletSyncState({
    required this.totalLovelace,
    required this.totalMultiAsset,
    required this.utxos,
    required this.primaryReceiveAddress,
    required this.nextUnusedExternalAddress,
    this.nextUnusedExternalIndex = 0,
    required this.nextUnusedInternalIndex,
    required this.stakeAddress,
    required this.stakeInfo,
    this.poolName,
    required this.assetMetadata,
    required this.recentTxs,
    required this.protocolParameters,
    required this.latestSlot,
  });
}

/// Discovers HD addresses (`0/i`, `1/i`, `2/0`) via gap-limit and aggregates balances from Blockfrost.
class HdWalletSyncService {
  static const int _batchSize = 6;
  static final Map<String, CardanoAccountPublicKey> _accountKeyCache = {};

  final BlockfrostService blockfrost;

  const HdWalletSyncService(this.blockfrost);

  CardanoAccountPublicKey _getAccountKey(String acctXvkBech32) {
    return _accountKeyCache[acctXvkBech32] ??=
        CardanoAccountPublicKey.fromBech32(acctXvkBech32);
  }

  Future<_ChainScanResult> _scanChain({
    required CardanoAccountPublicKey accountKey,
    required CardanoNetwork network,
    required String projectId,
    required int role,
    required int gapLimit,
  }) async {
    final utxos = <DerivedUtxo>[];
    final txs = <AddressTxSummary>[];
    var consecutiveEmpty = 0;
    var highestUsedIdx = -1;
    var index = 0;

    while (consecutiveEmpty < gapLimit) {
      final indices = [for (var i = 0; i < _batchSize; i++) index + i];
      final addrs = [
        for (final idx in indices)
          accountKey.deriveBaseAddress(role: role, index: idx, network: network),
      ];

      // 1. Check txs concurrently across the batch.
      //    If an address has zero txs, it mathematically has zero UTXOs (saves 50% RTTs).
      final batchTxs = await Future.wait([
        for (final addr in addrs)
          blockfrost.getAddressTransactions(network, projectId, addr, count: 10),
      ]);

      final nonEmptySlots = <int>[
        for (var i = 0; i < indices.length; i++)
          if (batchTxs[i].isNotEmpty) i,
      ];

      final batchUtxos = nonEmptySlots.isEmpty
          ? const <List<BlockfrostUtxo>>[]
          : await Future.wait([
              for (final slot in nonEmptySlots)
                blockfrost.getAddressUtxos(network, projectId, addrs[slot]),
            ]);

      final utxosBySlot = <int, List<BlockfrostUtxo>>{};
      for (var k = 0; k < nonEmptySlots.length; k++) {
        utxosBySlot[nonEmptySlots[k]] = batchUtxos[k];
      }

      for (var i = 0; i < indices.length; i++) {
        final addrTxs = batchTxs[i];
        final addrUtxos = utxosBySlot[i] ?? const <BlockfrostUtxo>[];
        if (addrTxs.isEmpty && addrUtxos.isEmpty) {
          consecutiveEmpty++;
          if (consecutiveEmpty >= gapLimit) break;
        } else {
          consecutiveEmpty = 0;
          highestUsedIdx = indices[i];
          for (final u in addrUtxos) {
            utxos.add(
              DerivedUtxo(
                utxo: u,
                derivationRole: role,
                derivationIndex: indices[i],
              ),
            );
          }
          txs.addAll(addrTxs);
        }
      }

      index += _batchSize;
    }

    return _ChainScanResult(
      utxos: utxos,
      txs: txs,
      nextIndex: highestUsedIdx + 1,
    );
  }

  Future<WalletSyncState> syncProfile({
    required WatchOnlyProfile profile,
    required String projectId,
    int gapLimit = 20,
  }) async {
    final accountKey = _getAccountKey(profile.acctXvkBech32);
    final network = profile.network;
    final stakeAddress = accountKey.deriveRewardAddress(network: network);

    final pparamsFuture = blockfrost.getProtocolParameters(network, projectId);
    final latestSlotFuture = blockfrost.getLatestSlot(network, projectId);
    final stakeFuture = blockfrost.getStakeAccount(network, projectId, stakeAddress);
    final extScanFuture = _scanChain(
      accountKey: accountKey,
      network: network,
      projectId: projectId,
      role: 0,
      gapLimit: gapLimit,
    );
    final intScanFuture = _scanChain(
      accountKey: accountKey,
      network: network,
      projectId: projectId,
      role: 1,
      gapLimit: gapLimit,
    );

    final pparams = await pparamsFuture;
    final latestSlot = await latestSlotFuture;
    final stakeInfo = await stakeFuture;
    final extScan = await extScanFuture;
    final intScan = await intScanFuture;

    final utxos = <DerivedUtxo>[...extScan.utxos, ...intScan.utxos];
    final txByHash = <String, AddressTxSummary>{
      for (final tx in extScan.txs) tx.txHash: tx,
      for (final tx in intScan.txs) tx.txHash: tx,
    };

    var totalLovelace = BigInt.zero;
    var totalMultiAsset = MultiAsset.empty;
    for (final item in utxos) {
      totalLovelace += item.utxo.lovelace;
      totalMultiAsset = totalMultiAsset.add(item.utxo.multiAsset);
    }

    final poolFuture = (stakeInfo.poolId != null && stakeInfo.poolId!.isNotEmpty)
        ? blockfrost.getPoolTickerName(network, projectId, stakeInfo.poolId!)
        : Future<String?>.value(null);

    final poolName = await poolFuture;
    final assetKeys = totalMultiAsset.assets.keys.toList();
    final assetMeta = <String, AssetMetadataInfo>{};
    const metaBatchSize = 5;
    for (var i = 0; i < assetKeys.length; i += metaBatchSize) {
      final end = (i + metaBatchSize < assetKeys.length)
          ? i + metaBatchSize
          : assetKeys.length;
      final batch = assetKeys.sublist(i, end);
      final results = await Future.wait([
        for (final assetKey in batch)
          blockfrost
              .getAssetMetadata(network, projectId, assetKey.unit)
              .then<AssetMetadataInfo?>((v) => v)
              .catchError((_) => null),
      ]);
      for (var j = 0; j < batch.length; j++) {
        final meta = results[j];
        if (meta != null) {
          assetMeta[batch[j].unit] = meta;
        }
      }
    }

    final recentTxs = txByHash.values.toList()
      ..sort((a, b) => b.blockTime.compareTo(a.blockTime));

    return WalletSyncState(
      totalLovelace: totalLovelace,
      totalMultiAsset: totalMultiAsset,
      utxos: utxos,
      primaryReceiveAddress: accountKey.deriveBaseAddress(
        role: 0,
        index: 0,
        network: network,
      ),
      nextUnusedExternalAddress: accountKey.deriveBaseAddress(
        role: 0,
        index: extScan.nextIndex,
        network: network,
      ),
      nextUnusedExternalIndex: extScan.nextIndex,
      nextUnusedInternalIndex: intScan.nextIndex,
      stakeAddress: stakeAddress,
      stakeInfo: stakeInfo,
      poolName: poolName,
      assetMetadata: assetMeta,
      recentTxs: recentTxs.take(20).toList(),
      protocolParameters: pparams,
      latestSlot: latestSlot,
    );
  }
}

class _ChainScanResult {
  final List<DerivedUtxo> utxos;
  final List<AddressTxSummary> txs;
  final int nextIndex;

  const _ChainScanResult({
    required this.utxos,
    required this.txs,
    required this.nextIndex,
  });
}
