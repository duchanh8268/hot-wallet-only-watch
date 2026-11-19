import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:chain_core_interface/chain_core_interface.dart';
import 'package:evm_core/evm_core.dart';

/// Lightweight JSON-RPC client for EVM blockchains.
class EvmRpcService {
  final http.Client _client;
  final Map<String, String> _rpcEndpoints = {
    'mainnet': 'https://cloudflare-eth.com',
    'sepolia': 'https://ethereum-sepolia-rpc.publicnode.com',
    'holesky': 'https://ethereum-holesky-rpc.publicnode.com',
  };

  EvmRpcService({http.Client? client}) : _client = client ?? http.Client();

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

    final resp = await _client.post(
      url,
      headers: {'Content-Type': 'application/json'},
      body: body,
    );

    if (resp.statusCode != 200) {
      throw StateError('RPC request failed with HTTP ${resp.statusCode}: ${resp.body}');
    }

    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    if (data.containsKey('error')) {
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
}
