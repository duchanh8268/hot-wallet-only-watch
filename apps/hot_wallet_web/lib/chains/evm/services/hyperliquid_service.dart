import 'dart:convert';
import 'package:http/http.dart' as http;

import '../../../core/models/chain_tx_record.dart';

/// Service client for Hyperliquid L1 API (Info & Exchange endpoints).
class HyperliquidService {
  final http.Client _client;
  final Map<String, String> _apiEndpoints = {
    'mainnet': 'https://api.hyperliquid.xyz',
    'testnet': 'https://api.hyperliquid-testnet.xyz',
  };

  HyperliquidService({http.Client? client}) : _client = client ?? http.Client();

  void setCustomApiUrl(String networkId, String url) {
    _apiEndpoints[networkId.toLowerCase()] = url;
  }

  String getApiUrl(String networkId) {
    return _apiEndpoints[networkId.toLowerCase()] ??
        _apiEndpoints['mainnet']!;
  }

  /// Queries user clearinghouse state (account value, margin, positions).
  Future<Map<String, dynamic>> getUserState(String networkId, String userAddress) async {
    final url = Uri.parse('${getApiUrl(networkId)}/info');
    final resp = await _client.post(
      url,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'type': 'clearinghouseState',
        'user': userAddress,
      }),
    );

    if (resp.statusCode != 200) {
      throw StateError('Hyperliquid /info query failed with HTTP ${resp.statusCode}: ${resp.body}');
    }

    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  /// Queries spot balances.
  Future<Map<String, dynamic>> getSpotState(String networkId, String userAddress) async {
    final url = Uri.parse('${getApiUrl(networkId)}/info');
    final resp = await _client.post(
      url,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'type': 'spotClearinghouseState',
        'user': userAddress,
      }),
    );

    if (resp.statusCode != 200) {
      throw StateError('Hyperliquid spot state failed with HTTP ${resp.statusCode}: ${resp.body}');
    }

    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  /// Submits signed EIP-712 action to Hyperliquid `/exchange`.
  Future<Map<String, dynamic>> submitAction({
    required String networkId,
    required Map<String, dynamic> action,
    required int nonce,
    required Map<String, dynamic> signature,
  }) async {
    final url = Uri.parse('${getApiUrl(networkId)}/exchange');
    final body = jsonEncode({
      'action': action,
      'nonce': nonce,
      'signature': signature,
    });

    final resp = await _client.post(
      url,
      headers: {'Content-Type': 'application/json'},
      body: body,
    );

    if (resp.statusCode != 200) {
      throw StateError('Hyperliquid /exchange failed with HTTP ${resp.statusCode}: ${resp.body}');
    }

    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  /// Explorer URL for Hyperliquid L1 transaction hashes.
  static String explorerTxUrl(String networkId, String txHash) {
    final isValidNonZeroHash = RegExp(r'^0x[0-9a-fA-F]{64}$').hasMatch(txHash) &&
        !RegExp(r'^0x0+$').hasMatch(txHash);
    if (!isValidNonZeroHash) return '';
    return networkId.toLowerCase() == 'testnet'
        ? 'https://app.hyperliquid-testnet.xyz/explorer/tx/$txHash'
        : 'https://app.hyperliquid.xyz/explorer/tx/$txHash';
  }

  /// Fetches recent Hyperliquid ledger transfers (`userNonFundingLedgerUpdates`) and fills (`userFills`).
  Future<List<ChainTxRecord>> getRecentActivity(
    String networkId,
    String userAddress, {
    int limit = 15,
  }) async {
    final url = Uri.parse('${getApiUrl(networkId)}/info');
    final results = <ChainTxRecord>[];
    final seen = <String>{};

    // 1. Ledger updates (deposits, withdrawals, internal usdSend transfers)
    final ledgerResp = await _client
        .post(
          url,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'type': 'userNonFundingLedgerUpdates',
            'user': userAddress,
          }),
        )
        .timeout(const Duration(seconds: 5));
    if (ledgerResp.statusCode != 200) {
      throw StateError('Hyperliquid ledger query HTTP ${ledgerResp.statusCode}');
    }

    final ledgerList = jsonDecode(ledgerResp.body) as List<dynamic>? ?? const [];
    final userLower = userAddress.toLowerCase();
    for (final item in ledgerList) {
      if (item is! Map<String, dynamic>) continue;
      final timeMs = (item['time'] as num?)?.toInt() ?? 0;
      final rawHash = item['hash']?.toString() ?? '';
      final delta = item['delta'] as Map<String, dynamic>? ?? const {};
      final deltaType = delta['type']?.toString() ?? 'transfer';
      final usdc = delta['usdc']?.toString();
      final dest = delta['destination']?.toString().toLowerCase() ?? '';
      final sender = delta['user']?.toString().toLowerCase() ?? '';

      String direction = 'tx';
      if (deltaType == 'deposit') {
        direction = 'in';
      } else if (deltaType == 'withdraw' || sender == userLower) {
        direction = 'out';
      } else if (dest == userLower) {
        direction = 'in';
      }

      final hash = rawHash.isNotEmpty ? rawHash : '${deltaType}_$timeMs';
      final dedupKey = '$hash:$timeMs:$deltaType';
      if (!seen.add(dedupKey)) continue;

      final sign = direction == 'in' ? '+' : (direction == 'out' ? '-' : '');
      final summary = usdc != null ? '$deltaType • $sign$usdc USDC' : deltaType;
      results.add(ChainTxRecord(
        txHash: hash,
        timestampMs: timeMs,
        status: 'confirmed',
        direction: direction,
        summary: summary,
        blockOrSlot: 'Hyperliquid L1',
        explorerUrl: explorerTxUrl(networkId, hash),
      ));
    }

    // 2. Recent order fills (best-effort; do not fail if empty/unavailable)
    try {
      final fillsResp = await _client
          .post(
            url,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'type': 'userFills',
              'user': userAddress,
            }),
          )
          .timeout(const Duration(seconds: 4));
      if (fillsResp.statusCode == 200) {
        final fillsList = jsonDecode(fillsResp.body) as List<dynamic>? ?? const [];
        for (final fill in fillsList.take(limit)) {
          if (fill is! Map<String, dynamic>) continue;
          final timeMs = (fill['time'] as num?)?.toInt() ?? 0;
          final rawHash = fill['hash']?.toString() ?? 'fill_$timeMs';
          final coin = fill['coin']?.toString() ?? '';
          final sz = fill['sz']?.toString() ?? '';
          final px = fill['px']?.toString() ?? '';
          final side = fill['side']?.toString() == 'B' ? 'BUY' : 'SELL';
          final dedupKey = '$rawHash:$timeMs:$coin';
          if (!seen.add(dedupKey)) continue;
          results.add(ChainTxRecord(
            txHash: rawHash,
            timestampMs: timeMs,
            status: 'confirmed',
            direction: 'tx',
            summary: '$side $sz $coin @ \$$px'.trim(),
            blockOrSlot: 'Fill',
            explorerUrl: explorerTxUrl(networkId, rawHash),
          ));
        }
      }
    } catch (_) {}

    results.sort((a, b) => b.timestampMs.compareTo(a.timestampMs));
    return results.take(limit).toList();
  }
}
