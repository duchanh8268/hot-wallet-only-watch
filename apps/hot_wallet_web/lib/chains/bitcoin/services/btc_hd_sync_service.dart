import 'package:bitcoin_core/bitcoin_core.dart';

import '../../../core/models/chain_tx_record.dart';
import '../models/btc_profile.dart';
import 'mempool_service.dart';

/// A Bitcoin UTXO annotated with its exact BIP-84 derivation path `(change, addressIndex)`.
class BtcDerivedUtxo {
  final MempoolUtxo utxo;
  final int accountIndex;
  final int change; // 0 = External receive, 1 = Internal change
  final int addressIndex;
  final String address;

  const BtcDerivedUtxo({
    required this.utxo,
    required this.accountIndex,
    required this.change,
    required this.addressIndex,
    required this.address,
  });

  String path(bool isTestnet) =>
      "m/84'/${isTestnet ? 1 : 0}'/$accountIndex'/$change/$addressIndex";
}

/// Aggregated BIP-84 HD sync state across external (`0/*`) and internal (`1/*`) branches.
class BtcWalletSyncState {
  final BigInt totalSat;
  final List<BtcDerivedUtxo> utxos;
  final String primaryReceiveAddress;
  final String nextUnusedExternalAddress;
  final int nextUnusedExternalIndex;
  final String nextUnusedChangeAddress;
  final int nextUnusedChangeIndex;
  final List<ChainTxRecord> recentTxs;
  final String? historyError;
  final bool isHdSynced;

  const BtcWalletSyncState({
    required this.totalSat,
    required this.utxos,
    required this.primaryReceiveAddress,
    required this.nextUnusedExternalAddress,
    required this.nextUnusedExternalIndex,
    required this.nextUnusedChangeAddress,
    required this.nextUnusedChangeIndex,
    required this.recentTxs,
    this.historyError,
    required this.isHdSynced,
  });
}

/// Discovers Bitcoin BIP-84 addresses (`change=0` and `change=1`) via gap-limit
/// using the watch-only [BtcAccountPublicKey] (`zpub`/`vpub`/`xpub`/`tpub`).
class BtcHdWalletSyncService {
  static const int _batchSize = 5;

  final MempoolService mempoolService;

  const BtcHdWalletSyncService(this.mempoolService);

  Future<BtcWalletSyncState> syncProfile({
    required BtcWatchOnlyProfile profile,
    required String networkId,
    int gapLimit = 20,
  }) async {
    final extKey = profile.accountXpub?.trim();
    if (extKey == null || extKey.isEmpty) {
      final utxos = await mempoolService.getUtxos(networkId, profile.receiveAddress);
      var totalSat = BigInt.zero;
      final derived = <BtcDerivedUtxo>[];
      for (final u in utxos) {
        totalSat += u.valueSat;
        derived.add(
          BtcDerivedUtxo(
            utxo: u,
            accountIndex: profile.accountIndex,
            change: 0,
            addressIndex: 0,
            address: profile.receiveAddress,
          ),
        );
      }
      List<ChainTxRecord> recentTxs = const [];
      String? historyError;
      try {
        recentTxs = await mempoolService.getRecentTxs(networkId, profile.receiveAddress);
      } catch (e) {
        historyError = e.toString();
      }
      return BtcWalletSyncState(
        totalSat: totalSat,
        utxos: derived,
        primaryReceiveAddress: profile.receiveAddress,
        nextUnusedExternalAddress: profile.receiveAddress,
        nextUnusedExternalIndex: 0,
        nextUnusedChangeAddress: '',
        nextUnusedChangeIndex: 0,
        recentTxs: recentTxs,
        historyError: historyError,
        isHdSynced: false,
      );
    }

    final acctPub = BtcAccountPublicKey.fromExtendedKey(extKey);
    final isTestnet = networkId.toLowerCase() != 'mainnet';

    final results = await Future.wait([
      _scanChain(
        acctPub: acctPub,
        networkId: networkId,
        isTestnet: isTestnet,
        accountIndex: profile.accountIndex,
        change: 0,
        gapLimit: gapLimit,
      ),
      _scanChain(
        acctPub: acctPub,
        networkId: networkId,
        isTestnet: isTestnet,
        accountIndex: profile.accountIndex,
        change: 1,
        gapLimit: gapLimit,
      ),
    ]);

    final extScan = results[0];
    final intScan = results[1];

    final allUtxos = <BtcDerivedUtxo>[...extScan.utxos, ...intScan.utxos];
    var totalSat = BigInt.zero;
    for (final u in allUtxos) {
      totalSat += u.utxo.valueSat;
    }

    final txByHash = <String, ChainTxRecord>{};
    for (final tx in [...extScan.txs, ...intScan.txs]) {
      txByHash[tx.txHash] = tx;
    }
    final recentTxs = txByHash.values.toList()
      ..sort((a, b) => b.timestampMs.compareTo(a.timestampMs));

    final primaryReceive = acctPub.deriveP2wpkhAddress(
      change: 0,
      addressIndex: 0,
      testnetOverride: isTestnet,
    );
    final nextExtAddr = acctPub.deriveP2wpkhAddress(
      change: 0,
      addressIndex: extScan.nextIndex,
      testnetOverride: isTestnet,
    );
    final nextChgAddr = acctPub.deriveP2wpkhAddress(
      change: 1,
      addressIndex: intScan.nextIndex,
      testnetOverride: isTestnet,
    );

    return BtcWalletSyncState(
      totalSat: totalSat,
      utxos: allUtxos,
      primaryReceiveAddress: primaryReceive,
      nextUnusedExternalAddress: nextExtAddr,
      nextUnusedExternalIndex: extScan.nextIndex,
      nextUnusedChangeAddress: nextChgAddr,
      nextUnusedChangeIndex: intScan.nextIndex,
      recentTxs: recentTxs.take(20).toList(),
      historyError: extScan.historyError ?? intScan.historyError,
      isHdSynced: true,
    );
  }

  Future<_BtcChainScanResult> _scanChain({
    required BtcAccountPublicKey acctPub,
    required String networkId,
    required bool isTestnet,
    required int accountIndex,
    required int change,
    required int gapLimit,
  }) async {
    final utxos = <BtcDerivedUtxo>[];
    final txs = <ChainTxRecord>[];
    String? historyError;
    var consecutiveEmpty = 0;
    var highestUsedIdx = -1;
    var index = 0;

    while (consecutiveEmpty < gapLimit) {
      final remaining = gapLimit - consecutiveEmpty;
      final count = remaining < _batchSize ? remaining : _batchSize;
      final indices = [for (var i = 0; i < count; i++) index + i];
      final addrs = [
        for (final idx in indices)
          acctPub.deriveP2wpkhAddress(
            change: change,
            addressIndex: idx,
            testnetOverride: isTestnet,
          ),
      ];

      final probes = await Future.wait([
        for (final addr in addrs) _probeAddressActivity(networkId, addr),
      ]);

      for (var i = 0; i < indices.length; i++) {
        final probe = probes[i];
        final addr = addrs[i];
        final addrIdx = indices[i];

        if (!probe.used) {
          consecutiveEmpty++;
          if (consecutiveEmpty >= gapLimit) break;
          continue;
        }

        consecutiveEmpty = 0;
        highestUsedIdx = addrIdx;

        final addrUtxos = probe.preloadedUtxos ??
            await mempoolService.getUtxos(networkId, addr);
        for (final u in addrUtxos) {
          utxos.add(
            BtcDerivedUtxo(
              utxo: u,
              accountIndex: accountIndex,
              change: change,
              addressIndex: addrIdx,
              address: addr,
            ),
          );
        }

        try {
          final addrTxs = await mempoolService.getRecentTxs(networkId, addr);
          txs.addAll(addrTxs);
        } catch (e) {
          historyError ??= e.toString();
        }
      }

      index += count;
    }

    return _BtcChainScanResult(
      utxos: utxos,
      txs: txs,
      nextIndex: highestUsedIdx + 1,
      historyError: historyError,
    );
  }

  Future<({bool used, List<MempoolUtxo>? preloadedUtxos})> _probeAddressActivity(
    String networkId,
    String address,
  ) async {
    try {
      final stats = await mempoolService.getAddressStats(networkId, address);
      final chainStats = stats['chain_stats'] as Map<String, dynamic>? ?? const {};
      final mempoolStats = stats['mempool_stats'] as Map<String, dynamic>? ?? const {};
      final chainTxCount = (chainStats['tx_count'] as num?)?.toInt() ?? 0;
      final mempoolTxCount = (mempoolStats['tx_count'] as num?)?.toInt() ?? 0;
      return (used: (chainTxCount + mempoolTxCount) > 0, preloadedUtxos: null);
    } catch (_) {
      // Fallback for custom/mock endpoints without /address/<addr> stats endpoint
      final utxos = await mempoolService.getUtxos(networkId, address);
      return (used: utxos.isNotEmpty, preloadedUtxos: utxos);
    }
  }
}

class _BtcChainScanResult {
  final List<BtcDerivedUtxo> utxos;
  final List<ChainTxRecord> txs;
  final int nextIndex;
  final String? historyError;

  const _BtcChainScanResult({
    required this.utxos,
    required this.txs,
    required this.nextIndex,
    this.historyError,
  });
}
