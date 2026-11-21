import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:sui_core/sui_core.dart';

import '../../../core/models/chain_tx_record.dart';

/// Service for querying Sui JSON-RPC endpoints and executing transaction blocks.
class SuiRpcService {
  final http.Client _client;
  final Map<String, String> _customUrls = {};

  SuiRpcService({http.Client? client}) : _client = client ?? http.Client();

  void setCustomRpcUrl(String networkId, String url) {
    _customUrls[networkId.toLowerCase()] = url;
  }

  String getRpcUrl(String networkId) {
    final key = networkId.toLowerCase();
    if (_customUrls.containsKey(key) && _customUrls[key]!.isNotEmpty) {
      return _customUrls[key]!;
    }
    switch (key) {
      case 'mainnet':
        return 'https://fullnode.mainnet.sui.io:443';
      case 'devnet':
        return 'https://fullnode.devnet.sui.io:443';
      case 'testnet':
      default:
        return 'https://fullnode.testnet.sui.io:443';
    }
  }

  /// Fetches total SUI balance for [address] in MIST (1 SUI = 1,000,000,000 MIST).
  Future<BigInt> getBalance({
    required String address,
    required String networkId,
  }) async {
    final url = getRpcUrl(networkId);
    final body = jsonEncode({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'suix_getBalance',
      'params': [address],
    });

    final response = await _client
        .post(
          Uri.parse(url),
          headers: {'Content-Type': 'application/json'},
          body: body,
        )
        .timeout(const Duration(seconds: 6));

    if (response.statusCode != 200) {
      throw Exception('Sui RPC HTTP ${response.statusCode}: ${response.body}');
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (data['error'] != null) {
      throw Exception(data['error']['message'] ?? 'Sui RPC error');
    }
    final result = data['result'] as Map<String, dynamic>?;
    if (result == null || result['totalBalance'] == null) {
      throw Exception('Missing totalBalance from Sui RPC');
    }
    final balance = BigInt.parse(result['totalBalance'].toString());
    if (balance.isNegative) {
      throw const FormatException('Negative Sui balance returned by RPC');
    }
    return balance;
  }

  /// Fetches gas coin objects for paying transaction gas.
  Future<List<SuiObjectRef>> getCoins({
    required String address,
    required String networkId,
  }) async {
    final url = getRpcUrl(networkId);
    final body = jsonEncode({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'suix_getCoins',
      'params': [address, null, null, 5],
    });

    final response = await _client
        .post(
          Uri.parse(url),
          headers: {'Content-Type': 'application/json'},
          body: body,
        )
        .timeout(const Duration(seconds: 6));

    if (response.statusCode != 200) {
      throw Exception('Sui RPC HTTP ${response.statusCode}: ${response.body}');
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (data['error'] != null) {
      throw Exception(data['error']['message'] ?? 'Sui RPC error');
    }
    final result = data['result'] as Map<String, dynamic>?;
    if (result == null || result['data'] is! List) {
      throw Exception('Missing coins list from Sui RPC');
    }
    final list = result['data'] as List;
    return list.map((item) {
      final version = BigInt.parse(item['version'].toString());
      if (version.isNegative) {
        throw const FormatException('Negative Sui coin version returned by RPC');
      }
      return SuiObjectRef(
        objectId: item['coinObjectId'] as String,
        version: version,
        digest: item['digest'] as String,
      );
    }).toList();
  }

  /// Executes a signed transaction block on Sui network.
  Future<String> executeTransactionBlock({
    required String txBytesBase64,
    required List<String> signatures,
    required String networkId,
  }) async {
    if (txBytesBase64.isEmpty || signatures.isEmpty) {
      throw ArgumentError('Sui transaction bytes and signatures cannot be empty');
    }
    final url = getRpcUrl(networkId);
    final body = jsonEncode({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'sui_executeTransactionBlock',
      'params': [
        txBytesBase64,
        signatures,
        {'showEffects': true},
      ],
    });

    final response = await _client
        .post(
          Uri.parse(url),
          headers: {'Content-Type': 'application/json'},
          body: body,
        )
        .timeout(const Duration(seconds: 8));

    if (response.statusCode != 200) {
      throw Exception('Sui broadcast HTTP ${response.statusCode}: ${response.body}');
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (data['error'] != null) {
      throw Exception(data['error']['message'] ?? 'Sui RPC Error');
    }
    final digest = data['result']?['digest'] as String?;
    if (digest == null || digest.isEmpty) {
      throw Exception('Sui RPC did not return a transaction digest');
    }
    return digest;
  }

  /// SuiScan explorer transaction URL for [networkId].
  static String explorerTxUrl(String networkId, String digest) {
    final key = networkId.toLowerCase();
    final net = (key == 'mainnet' || key == 'devnet' || key == 'testnet') ? key : 'testnet';
    return 'https://suiscan.xyz/$net/tx/$digest';
  }

  /// Fetches recent transaction blocks involving [address] (`FromAddress` & `ToAddress`).
  Future<List<ChainTxRecord>> getRecentTransactions({
    required String address,
    required String networkId,
    int limit = 15,
  }) async {
    Future<List<dynamic>> queryByFilter(Map<String, dynamic> filter) async {
      final url = getRpcUrl(networkId);
      final body = jsonEncode({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'suix_queryTransactionBlocks',
        'params': [
          {
            'filter': filter,
            'options': {'showEffects': true},
          },
          null,
          limit,
          true,
        ],
      });
      final response = await _client
          .post(
            Uri.parse(url),
            headers: {'Content-Type': 'application/json'},
            body: body,
          )
          .timeout(const Duration(seconds: 6));
      if (response.statusCode != 200) {
        throw Exception('Sui suix_queryTransactionBlocks HTTP ${response.statusCode}');
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (data['error'] != null) {
        throw Exception(data['error']['message'] ?? 'Sui RPC error');
      }
      final result = data['result'] as Map<String, dynamic>?;
      return result?['data'] as List<dynamic>? ?? const [];
    }

    final itemsByDigest = <String, ChainTxRecord>{};
    Object? firstError;

    for (final entry in [
      {'filter': {'FromAddress': address}, 'direction': 'out'},
      {'filter': {'ToAddress': address}, 'direction': 'in'},
    ]) {
      try {
        final rawList = await queryByFilter(entry['filter'] as Map<String, dynamic>);
        final dir = entry['direction'] as String;
        for (final raw in rawList) {
          if (raw is! Map<String, dynamic>) continue;
          final digest = raw['digest']?.toString() ?? '';
          if (digest.isEmpty) continue;
          final tsMs = int.tryParse(raw['timestampMs']?.toString() ?? '0') ?? 0;
          final checkpoint = raw['checkpoint']?.toString();
          final effects = raw['effects'] as Map<String, dynamic>? ?? const {};
          final execStatus =
              (effects['status'] as Map<String, dynamic>?)?['status']?.toString() ?? 'success';
          final existing = itemsByDigest[digest];
          final finalDir = existing != null && existing.direction != dir ? 'self' : dir;
          itemsByDigest[digest] = ChainTxRecord(
            txHash: digest,
            timestampMs: tsMs,
            status: execStatus == 'failure' ? 'failed' : 'confirmed',
            direction: finalDir,
            blockOrSlot: checkpoint != null ? 'Checkpoint #$checkpoint' : '',
            explorerUrl: explorerTxUrl(networkId, digest),
          );
        }
      } catch (e) {
        firstError ??= e;
      }
    }

    if (itemsByDigest.isEmpty && firstError != null) {
      throw firstError;
    }

    final sorted = itemsByDigest.values.toList()
      ..sort((a, b) => b.timestampMs.compareTo(a.timestampMs));
    return sorted.take(limit).toList();
  }
}
