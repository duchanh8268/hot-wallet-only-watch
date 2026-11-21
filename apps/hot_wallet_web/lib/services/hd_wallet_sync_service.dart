import 'package:cardano_core/cardano_core.dart';
import 'cardano_rpc_service.dart';

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
      createdAtMs: (json['createdAtMs'] as num?)?.toInt() ?? 0,
    );
  }
}

class DerivedUtxo {
  final CardanoUtxo utxo;
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

/// Discovers HD addresses (`0/i`, `1/i`, `2/0`) via gap-limit and aggregates balances from Cardano Koios RPC.
class HdWalletSyncService {
  static const int _batchSize = 6;
  static final Map<String, CardanoAccountPublicKey> _accountKeyCache = {};

  final CardanoRpcService cardanoRpc;

  const HdWalletSyncService(this.cardanoRpc);

  CardanoAccountPublicKey _getAccountKey(String acctXvkBech32) {
    return _accountKeyCache[acctXvkBech32] ??=
        CardanoAccountPublicKey.fromBech32(acctXvkBech32);
  }

  Future<_ChainScanResult> _scanChain({
    required CardanoAccountPublicKey accountKey,
    required CardanoNetwork network,
    required int role,
    required int gapLimit,
  }) async {
    final utxos = <DerivedUtxo>[];
    final txs = <AddressTxSummary>[];
    var consecutiveEmpty = 0;
    var highestUsedIdx = -1;
    var index = 0;

    while (consecutiveEmpty < gapLimit) {
      final remaining = gapLimit - consecutiveEmpty;
      final count = remaining < _batchSize ? remaining : _batchSize;
      final indices = [for (var i = 0; i < count; i++) index + i];
      final addrs = [
        for (final idx in indices)
          accountKey.deriveBaseAddress(role: role, index: idx, network: network),
      ];

      // 1. Batch-probe whether any address in this window has transactions at all.
      final windowAnyTxs = await cardanoRpc.getAddressesTransactions(
        network,
        addrs,
        count: 1,
      );
      if (windowAnyTxs.isEmpty) {
        consecutiveEmpty += count;
        index += count;
        continue;
      }

      // 2. Check individual txs concurrently within the active window.
      final batchTxs = await Future.wait([
        for (final addr in addrs)
          cardanoRpc.getAddressTransactions(network, addr, count: 10),
      ]);

      final nonEmptyAddrs = <String>[
        for (var i = 0; i < addrs.length; i++)
          if (batchTxs[i].isNotEmpty) addrs[i],
      ];

      final utxosByAddr = nonEmptyAddrs.isEmpty
          ? const <String, List<CardanoUtxo>>{}
          : await cardanoRpc.getAddressesUtxosBatch(network, nonEmptyAddrs);

      for (var i = 0; i < indices.length; i++) {
        final addrTxs = batchTxs[i];
        final addrUtxos = utxosByAddr[addrs[i]] ?? const <CardanoUtxo>[];
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

      index += count;
    }

    return _ChainScanResult(
      utxos: utxos,
      txs: txs,
      nextIndex: highestUsedIdx + 1,
    );
  }

  Future<WalletSyncState> syncProfile({
    required WatchOnlyProfile profile,
    int gapLimit = 20,
  }) async {
    final accountKey = _getAccountKey(profile.acctXvkBech32);
    final network = profile.network;
    final stakeAddress = accountKey.deriveRewardAddress(network: network);

    final results = await Future.wait([
      cardanoRpc.getProtocolParameters(network),
      cardanoRpc.getLatestSlot(network),
      cardanoRpc.getStakeAccount(network, stakeAddress),
      _scanChain(
        accountKey: accountKey,
        network: network,
        role: 0,
        gapLimit: gapLimit,
      ),
      _scanChain(
        accountKey: accountKey,
        network: network,
        role: 1,
        gapLimit: gapLimit,
      ),
    ]);

    final pparams = results[0] as ProtocolParameters;
    final latestSlot = results[1] as int;
    final stakeInfo = results[2] as StakeAccountInfo;
    final extScan = results[3] as _ChainScanResult;
    final intScan = results[4] as _ChainScanResult;

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
        ? cardanoRpc.getPoolTickerName(network, stakeInfo.poolId!)
        : Future<String?>.value(null);

    final poolName = await poolFuture;
    final assetKeys = totalMultiAsset.assets.keys.toList();
    final assetMeta = <String, AssetMetadataInfo>{};
    const metaBatchSize = 10;
    for (var i = 0; i < assetKeys.length; i += metaBatchSize) {
      final end = (i + metaBatchSize < assetKeys.length)
          ? i + metaBatchSize
          : assetKeys.length;
      final batch = assetKeys.sublist(i, end);
      final batchResult = await cardanoRpc
          .getAssetsMetadataBatch(network, batch)
          .catchError((_) => const <String, AssetMetadataInfo>{});
      assetMeta.addAll(batchResult);
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
