import 'dart:convert';
import 'package:http/http.dart' as http;

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
}
