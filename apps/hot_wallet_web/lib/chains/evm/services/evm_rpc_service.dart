import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:chain_core_interface/chain_core_interface.dart';
import 'package:evm_core/evm_core.dart';

import '../../../core/models/chain_tx_record.dart';

/// Lightweight JSON-RPC client for EVM blockchains.
class EvmRpcService {
  static const String defaultMainnetRpcUrl = 'https://ethereum-rpc.publicnode.com';
  static const String defaultSepoliaRpcUrl = 'https://ethereum-sepolia-rpc.publicnode.com';
  static const String defaultHoleskyRpcUrl = 'https://ethereum-holesky-rpc.publicnode.com';

  final http.Client _client;
  final Map<String, String> _rpcEndpoints = {
    'mainnet': defaultMainnetRpcUrl,
    'sepolia': defaultSepoliaRpcUrl,
    'holesky': defaultHoleskyRpcUrl,
  };

  EvmRpcService({http.Client? client}) : _client = client ?? http.Client();

  void resetToDefaultRpcUrl(String networkId) {
    final key = networkId.toLowerCase();
    switch (key) {
      case 'sepolia':
        _rpcEndpoints['sepolia'] = defaultSepoliaRpcUrl;
        break;
      case 'holesky':
        _rpcEndpoints['holesky'] = defaultHoleskyRpcUrl;
        break;
      case 'mainnet':
      default:
        _rpcEndpoints[key] = defaultMainnetRpcUrl;
        break;
    }
  }

  void setCustomRpcUrl(String networkId, String url) {
    _rpcEndpoints[networkId.toLowerCase()] = url;
  }

  String getRpcUrl(String networkId) {
    return _rpcEndpoints[networkId.toLowerCase()] ??
        _rpcEndpoints['mainnet']!;
  }

  Future<dynamic> callRpc(
    String networkId,
    String method,
    List<dynamic> params,
  ) async {
    final url = Uri.parse(getRpcUrl(networkId));
    final body = jsonEncode({
      'jsonrpc': '2.0',
      'id': DateTime.now().millisecondsSinceEpoch,
      'method': method,
      'params': params,
    });

    final resp = await _client
        .post(
          url,
          headers: {'Content-Type': 'application/json'},
          body: body,
        )
        .timeout(const Duration(seconds: 8));

    if (resp.statusCode != 200) {
      throw StateError('RPC request failed with HTTP ${resp.statusCode}: ${resp.body}');
    }

    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    if (data['error'] != null) {
      final err = data['error'];
      throw StateError('RPC error: ${err is Map ? err['message'] : err}');
    }

    return data['result'];
  }

  /// Fetches native ETH balance in Wei.
  Future<BigInt> getBalance(String networkId, String address) async {
    final result = await callRpc(networkId, 'eth_getBalance', [address, 'latest']);
    return BigInt.parse(result as String);
  }

  /// Fetches transaction count (nonce).
  Future<BigInt> getTransactionCount(String networkId, String address) async {
    final result = await callRpc(networkId, 'eth_getTransactionCount', [address, 'pending']);
    return BigInt.parse(result as String);
  }

  /// Fetches current gas price in Wei.
  Future<BigInt> getGasPrice(String networkId) async {
    final result = await callRpc(networkId, 'eth_gasPrice', []);
    return BigInt.parse(result as String);
  }

  /// Broadcasts signed raw transaction.
  Future<String> sendRawTransaction(String networkId, Uint8List rawTxBytes) async {
    final hexTx = hexEncode(rawTxBytes, prefix0x: true);
    final result = await callRpc(networkId, 'eth_sendRawTransaction', [hexTx]);
    return result as String;
  }

  /// Etherscan explorer transaction URL for [networkId].
  static String explorerTxUrl(String networkId, String txHash) {
    switch (networkId.toLowerCase()) {
      case 'sepolia':
        return 'https://sepolia.etherscan.io/tx/$txHash';
      case 'holesky':
        return 'https://holesky.etherscan.io/tx/$txHash';
      case 'mainnet':
      default:
        return 'https://etherscan.io/tx/$txHash';
    }
  }

  /// Blockscout v2 public REST base URL (CORS-enabled, no API key required).
  static String blockscoutApiBase(String networkId) {
    switch (networkId.toLowerCase()) {
      case 'sepolia':
        return 'https://eth-sepolia.blockscout.com/api/v2';
      case 'holesky':
        return 'https://eth-holesky.blockscout.com/api/v2';
      case 'mainnet':
      default:
        return 'https://eth.blockscout.com/api/v2';
    }
  }

  /// Fetches recent Ethereum transactions for [address] using Blockscout v2 REST API.
  Future<List<ChainTxRecord>> getRecentTxs(
    String networkId,
    String address, {
    int limit = 15,
  }) async {
    final uri = Uri.parse('${blockscoutApiBase(networkId)}/addresses/$address/transactions');
    final resp = await _client.get(uri).timeout(const Duration(seconds: 5));
    if (resp.statusCode != 200) {
      throw StateError('Blockscout HTTP ${resp.statusCode}');
    }
    final decoded = jsonDecode(resp.body) as Map<String, dynamic>;
    final items = decoded['items'] as List<dynamic>? ?? const [];
    final targetAddr = address.toLowerCase();
    final weiPerEth = BigInt.from(10).pow(18);

    final out = <ChainTxRecord>[];
    for (final raw in items.take(limit)) {
      if (raw is! Map<String, dynamic>) continue;
      final hash = raw['hash']?.toString() ?? '';
      if (hash.isEmpty) continue;

      final blockNum = raw['block_number'];
      final tsStr = raw['timestamp']?.toString();
      final tsMs = tsStr != null ? (DateTime.tryParse(tsStr)?.millisecondsSinceEpoch ?? 0) : 0;
      final rawStatus = raw['status']?.toString().toLowerCase() ?? 'ok';
      final status = rawStatus == 'error' ? 'failed' : (blockNum == null ? 'pending' : 'confirmed');

      final fromHash = (raw['from'] is Map ? raw['from']['hash'] : raw['from'])?.toString().toLowerCase() ?? '';
      final toHash = (raw['to'] is Map ? raw['to']['hash'] : raw['to'])?.toString().toLowerCase() ?? '';
      final direction = (fromHash == targetAddr && toHash == targetAddr)
          ? 'self'
          : (fromHash == targetAddr ? 'out' : (toHash == targetAddr ? 'in' : 'tx'));

      final valWei = BigInt.tryParse(raw['value']?.toString() ?? '0') ?? BigInt.zero;
      final ethWhole = valWei ~/ weiPerEth;
      final ethFrac = (valWei % weiPerEth).toString().padLeft(18, '0').substring(0, 6);
      final sign = valWei == BigInt.zero
          ? ''
          : (direction == 'in' ? '+' : (direction == 'out' ? '-' : ''));
      final method = raw['method']?.toString();
      final amountText = '$sign$ethWhole.$ethFrac ETH';
      final summary = (method != null && method.isNotEmpty) ? '$amountText ($method)' : amountText;

      out.add(ChainTxRecord(
        txHash: hash,
        timestampMs: tsMs,
        status: status,
        direction: direction,
        summary: summary,
        blockOrSlot: blockNum != null ? 'Block #$blockNum' : 'Pending',
        explorerUrl: explorerTxUrl(networkId, hash),
      ));
    }
    return out;
  }
}
