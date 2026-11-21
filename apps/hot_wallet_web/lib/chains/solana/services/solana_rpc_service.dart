import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:solana_core/solana_core.dart';

import '../../../core/models/chain_tx_record.dart';

/// Service for querying Solana JSON-RPC endpoints and broadcasting transactions.
class SolanaRpcService {
  static const String defaultMainnetRpcUrl = 'https://solana-rpc.publicnode.com';
  static const String defaultTestnetRpcUrl = 'https://api.testnet.solana.com';
  static const String defaultDevnetRpcUrl = 'https://api.devnet.solana.com';

  final http.Client _client;
  final Map<String, String> _customUrls = {};

  SolanaRpcService({http.Client? client}) : _client = client ?? http.Client();

  void resetToDefaultRpcUrl(String networkId) {
    _customUrls.remove(networkId.toLowerCase());
  }

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
      case 'mainnet-beta':
        return defaultMainnetRpcUrl;
      case 'testnet':
        return defaultTestnetRpcUrl;
      case 'devnet':
      default:
        return defaultDevnetRpcUrl;
    }
  }

  /// Fetches balance for [address] in Lamports (1 SOL = 1,000,000,000 Lamports).
  Future<BigInt> getBalance({
    required String address,
    required String networkId,
  }) async {
    final url = getRpcUrl(networkId);
    final body = jsonEncode({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'getBalance',
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
      throw Exception('Solana RPC HTTP ${response.statusCode}: ${response.body}');
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (data['error'] != null) {
      throw Exception(data['error']['message'] ?? 'Solana RPC error');
    }
    final result = data['result'] as Map<String, dynamic>?;
    if (result == null || result['value'] == null) {
      throw Exception('Missing getBalance result from Solana RPC');
    }
    final balance = BigInt.from(result['value'] as num);
    if (balance.isNegative) {
      throw const FormatException('Negative Solana balance returned by RPC');
    }
    return balance;
  }

  /// Fetches the latest blockhash from the cluster.
  Future<Uint8List> getLatestBlockhash({
    required String networkId,
  }) async {
    final url = getRpcUrl(networkId);
    final body = jsonEncode({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'getLatestBlockhash',
      'params': [
        {'commitment': 'finalized'}
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
      throw Exception('Solana RPC HTTP ${response.statusCode}: ${response.body}');
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (data['error'] != null) {
      throw Exception(data['error']['message'] ?? 'Solana RPC error');
    }
    final result = data['result'] as Map<String, dynamic>?;
    final hashStr = result?['value']?['blockhash'] as String?;
    if (hashStr == null || hashStr.isEmpty) {
      throw Exception('Missing blockhash from Solana RPC');
    }
    final hashBytes = Base58.decode(hashStr);
    if (hashBytes.length != 32) {
      throw FormatException('Invalid Solana blockhash byte length: ${hashBytes.length}');
    }
    return hashBytes;
  }

  /// Broadcasts a fully signed Solana transaction (Base64).
  Future<String> sendTransaction({
    required Uint8List transactionBytes,
    required String networkId,
  }) async {
    if (transactionBytes.isEmpty) {
      throw ArgumentError('Signed Solana transaction bytes cannot be empty');
    }
    final b64 = base64Encode(transactionBytes);
    final url = getRpcUrl(networkId);
    final body = jsonEncode({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'sendTransaction',
      'params': [
        b64,
        {'encoding': 'base64'}
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
      throw Exception('Solana broadcast HTTP ${response.statusCode}: ${response.body}');
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (data['error'] != null) {
      throw Exception(data['error']['message'] ?? 'Solana broadcast RPC error');
    }
    final sig = data['result'] as String?;
    if (sig == null || sig.isEmpty) {
      throw Exception('Solana RPC did not return a transaction signature');
    }
    return sig;
  }

  /// Solana Explorer transaction URL for [networkId].
  static String explorerTxUrl(String networkId, String signature) {
    final key = networkId.toLowerCase();
    if (key == 'mainnet' || key == 'mainnet-beta') {
      return 'https://explorer.solana.com/tx/$signature';
    }
    if (key == 'testnet') {
      return 'https://explorer.solana.com/tx/$signature?cluster=testnet';
    }
    return 'https://explorer.solana.com/tx/$signature?cluster=devnet';
  }

  /// Fetches recent transaction signatures for [address] via `getSignaturesForAddress`.
  Future<List<ChainTxRecord>> getRecentSignatures({
    required String address,
    required String networkId,
    int limit = 15,
  }) async {
    final url = getRpcUrl(networkId);
    final body = jsonEncode({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'getSignaturesForAddress',
      'params': [
        address,
        {'limit': limit},
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
      throw Exception('Solana getSignaturesForAddress HTTP ${response.statusCode}');
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (data['error'] != null) {
      throw Exception(data['error']['message'] ?? 'Solana RPC error');
    }
    final list = data['result'] as List<dynamic>? ?? const [];
    final out = <ChainTxRecord>[];
    for (final raw in list) {
      if (raw is! Map<String, dynamic>) continue;
      final sig = raw['signature']?.toString() ?? '';
      if (sig.isEmpty) continue;
      final slot = raw['slot'];
      final blockTimeSec = (raw['blockTime'] as num?)?.toInt() ?? 0;
      final hasErr = raw['err'] != null;
      out.add(ChainTxRecord(
        txHash: sig,
        timestampMs: blockTimeSec > 0 ? blockTimeSec * 1000 : 0,
        status: hasErr ? 'failed' : 'confirmed',
        direction: 'tx',
        summary: raw['memo']?.toString() ?? '',
        blockOrSlot: slot != null ? 'Slot #$slot' : '',
        explorerUrl: explorerTxUrl(networkId, sig),
      ));
    }
    return out;
  }
}
