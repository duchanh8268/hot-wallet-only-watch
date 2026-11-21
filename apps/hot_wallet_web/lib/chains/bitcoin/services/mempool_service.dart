import 'dart:convert';
import 'package:http/http.dart' as http;

import '../../../core/models/chain_tx_record.dart';

/// UTXO entry fetched from Mempool.space API.
class MempoolUtxo {
  final String txid;
  final int vout;
  final BigInt valueSat;
  final bool confirmed;
  final int? blockHeight;

  const MempoolUtxo({
    required this.txid,
    required this.vout,
    required this.valueSat,
    required this.confirmed,
    this.blockHeight,
  });

  factory MempoolUtxo.fromJson(Map<String, dynamic> json) {
    final status = json['status'] as Map<String, dynamic>? ?? {};
    final txid = json['txid'] as String;
    if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(txid)) {
      throw FormatException('Invalid Bitcoin UTXO txid: $txid');
    }
    final vout = (json['vout'] as num).toInt();
    if (vout < 0) {
      throw FormatException('Negative Bitcoin UTXO vout: $vout');
    }
    final valueSat = BigInt.from(json['value'] as num);
    final maxBtcSats = BigInt.from(21000000) * BigInt.from(100000000);
    if (valueSat <= BigInt.zero || valueSat > maxBtcSats) {
      throw FormatException('Invalid Bitcoin UTXO value: $valueSat satoshis');
    }
    return MempoolUtxo(
      txid: txid,
      vout: vout,
      valueSat: valueSat,
      confirmed: status['confirmed'] as bool? ?? false,
      blockHeight: (status['block_height'] as num?)?.toInt(),
    );
  }
}

/// Recommended fee rates from Mempool.space.
class MempoolFeeRates {
  final int fastestFee;
  final int halfHourFee;
  final int hourFee;
  final int minimumFee;

  const MempoolFeeRates({
    required this.fastestFee,
    required this.halfHourFee,
    required this.hourFee,
    required this.minimumFee,
  });

  factory MempoolFeeRates.fromJson(Map<String, dynamic> json) {
    return MempoolFeeRates(
      fastestFee: ((json['fastestFee'] as num?)?.toInt() ?? 15).clamp(1, 5000),
      halfHourFee: ((json['halfHourFee'] as num?)?.toInt() ?? 10).clamp(1, 5000),
      hourFee: ((json['hourFee'] as num?)?.toInt() ?? 5).clamp(1, 5000),
      minimumFee: ((json['minimumFee'] as num?)?.toInt() ?? 1).clamp(1, 5000),
    );
  }

  static const MempoolFeeRates defaults = MempoolFeeRates(
    fastestFee: 15,
    halfHourFee: 10,
    hourFee: 5,
    minimumFee: 1,
  );
}

/// Service client for Mempool.space REST APIs (Mainnet, Testnet4, Signet).
class MempoolService {
  final http.Client _client;
  final Map<String, String> _customUrls = {};

  static const Map<String, String> defaultBaseUrls = {
    'mainnet': 'https://mempool.space/api',
    'testnet4': 'https://mempool.space/testnet4/api',
    'signet': 'https://mempool.space/signet/api',
  };

  MempoolService({http.Client? client}) : _client = client ?? http.Client();

  String getBaseUrl(String networkId) {
    final netKey = networkId.toLowerCase();
    return _customUrls[netKey] ??
        defaultBaseUrls[netKey] ??
        'https://mempool.space/api';
  }

  void setCustomApiUrl(String networkId, String url) {
    _customUrls[networkId.toLowerCase()] = url;
  }

  /// Fetches confirmed and unconfirmed UTXOs for a given Bitcoin address.
  Future<List<MempoolUtxo>> getUtxos(String networkId, String address) async {
    final base = getBaseUrl(networkId);
    final uri = Uri.parse('$base/address/$address/utxo');
    final resp = await _client.get(uri).timeout(const Duration(seconds: 4));
    if (resp.statusCode != 200) {
      throw Exception('Mempool API error (${resp.statusCode}): ${resp.body}');
    }
    final list = jsonDecode(resp.body) as List<dynamic>;
    return list.map((e) => MempoolUtxo.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// Fetches address balance and stats.
  Future<Map<String, dynamic>> getAddressStats(String networkId, String address) async {
    final base = getBaseUrl(networkId);
    final uri = Uri.parse('$base/address/$address');
    final resp = await _client.get(uri).timeout(const Duration(seconds: 4));
    if (resp.statusCode != 200) {
      throw Exception('Mempool API error (${resp.statusCode}): ${resp.body}');
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  /// Fetches recommended fee rates in sat/vB.
  Future<MempoolFeeRates> getRecommendedFees(String networkId) async {
    final base = getBaseUrl(networkId);
    final uri = Uri.parse('$base/v1/fees/recommended');
    try {
      final resp = await _client.get(uri).timeout(const Duration(seconds: 4));
      if (resp.statusCode == 200) {
        return MempoolFeeRates.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
      }
    } catch (_) {}
    return MempoolFeeRates.defaults;
  }

  /// Broadcasts a signed raw hex transaction to the Bitcoin network.
  Future<String> broadcastRawTx(String networkId, String rawTxHex) async {
    final base = getBaseUrl(networkId);
    final uri = Uri.parse('$base/tx');
    final resp = await _client
        .post(
          uri,
          headers: {'Content-Type': 'text/plain'},
          body: rawTxHex,
        )
        .timeout(const Duration(seconds: 6));
    if (resp.statusCode != 200) {
      throw Exception('Lỗi phát sóng Bitcoin tx (${resp.statusCode}): ${resp.body}');
    }
    return resp.body.trim();
  }

  /// Explorer URL for a Bitcoin transaction on Mempool.space.
  static String explorerTxUrl(String networkId, String txid) {
    switch (networkId.toLowerCase()) {
      case 'testnet4':
        return 'https://mempool.space/testnet4/tx/$txid';
      case 'signet':
        return 'https://mempool.space/signet/tx/$txid';
      case 'mainnet':
      default:
        return 'https://mempool.space/tx/$txid';
    }
  }

  /// Fetches recent transactions (up to 15) for [address] via Mempool.space `/address/<addr>/txs`.
  Future<List<ChainTxRecord>> getRecentTxs(
    String networkId,
    String address, {
    int limit = 15,
  }) async {
    final base = getBaseUrl(networkId);
    final uri = Uri.parse('$base/address/$address/txs');
    final resp = await _client.get(uri).timeout(const Duration(seconds: 5));
    if (resp.statusCode != 200) {
      throw Exception('Mempool /txs HTTP ${resp.statusCode}');
    }
    final list = jsonDecode(resp.body) as List<dynamic>;
    final targetAddr = address.toLowerCase();
    final out = <ChainTxRecord>[];
    for (final raw in list.take(limit)) {
      if (raw is! Map<String, dynamic>) continue;
      final txid = raw['txid'] as String? ?? '';
      if (txid.isEmpty) continue;
      final statusMap = raw['status'] as Map<String, dynamic>? ?? const {};
      final confirmed = statusMap['confirmed'] as bool? ?? false;
      final blockHeight = (statusMap['block_height'] as num?)?.toInt();
      final blockTimeSec = (statusMap['block_time'] as num?)?.toInt() ?? 0;

      var receivedSat = BigInt.zero;
      for (final vout in (raw['vout'] as List<dynamic>? ?? const [])) {
        if (vout is Map<String, dynamic> &&
            vout['scriptpubkey_address']?.toString().toLowerCase() == targetAddr) {
          final val = vout['value'] as num?;
          if (val != null) receivedSat += BigInt.from(val.toInt());
        }
      }
      var spentSat = BigInt.zero;
      for (final vin in (raw['vin'] as List<dynamic>? ?? const [])) {
        if (vin is Map<String, dynamic>) {
          final prevout = vin['prevout'] as Map<String, dynamic>?;
          if (prevout != null &&
              prevout['scriptpubkey_address']?.toString().toLowerCase() == targetAddr) {
            final val = prevout['value'] as num?;
            if (val != null) spentSat += BigInt.from(val.toInt());
          }
        }
      }

      final netSat = receivedSat - spentSat;
      final direction = spentSat > BigInt.zero && receivedSat >= spentSat
          ? (netSat == BigInt.zero ? 'self' : 'out')
          : (netSat > BigInt.zero ? 'in' : (netSat < BigInt.zero ? 'out' : 'tx'));
      final absSat = netSat.isNegative ? -netSat : netSat;
      final whole = absSat ~/ BigInt.from(100000000);
      final frac = (absSat % BigInt.from(100000000)).toString().padLeft(8, '0');
      final sign = netSat > BigInt.zero ? '+' : (netSat < BigInt.zero ? '-' : '');
      final summary = netSat == BigInt.zero ? '' : '$sign$whole.$frac BTC';

      out.add(ChainTxRecord(
        txHash: txid,
        timestampMs: blockTimeSec > 0 ? blockTimeSec * 1000 : 0,
        status: confirmed ? 'confirmed' : 'pending',
        direction: direction,
        summary: summary,
        blockOrSlot: confirmed && blockHeight != null ? 'Block #$blockHeight' : 'Mempool',
        explorerUrl: explorerTxUrl(networkId, txid),
      ));
    }
    return out;
  }
}
