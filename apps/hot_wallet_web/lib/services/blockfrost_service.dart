import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cardano_core/cardano_core.dart';
import 'package:http/http.dart' as http;

class BlockfrostException implements Exception {
  final int statusCode;
  final String message;

  const BlockfrostException(this.statusCode, this.message);

  @override
  String toString() => 'BlockfrostException($statusCode): $message';
}

class ProtocolParameters {
  final int minFeeA;
  final int minFeeB;
  final int coinsPerUTxOByte;
  final BigInt keyDeposit;
  final BigInt poolDeposit;
  final int maxTxSize;

  const ProtocolParameters({
    required this.minFeeA,
    required this.minFeeB,
    required this.coinsPerUTxOByte,
    required this.keyDeposit,
    required this.poolDeposit,
    required this.maxTxSize,
  });

  static final ProtocolParameters cardanoDefaults = ProtocolParameters(
    minFeeA: 44,
    minFeeB: 155381,
    coinsPerUTxOByte: 4310,
    keyDeposit: BigInt.from(2000000),
    poolDeposit: BigInt.from(500000000),
    maxTxSize: 16384,
  );

  factory ProtocolParameters.fromBlockfrostJson(Map<String, dynamic> json) {
    int parseInt(dynamic v, int fallback) =>
        v == null ? fallback : int.tryParse(v.toString()) ?? fallback;
    BigInt parseBigInt(dynamic v, BigInt fallback) =>
        v == null ? fallback : BigInt.tryParse(v.toString()) ?? fallback;

    return ProtocolParameters(
      minFeeA: parseInt(json['min_fee_a'], 44),
      minFeeB: parseInt(json['min_fee_b'], 155381),
      coinsPerUTxOByte: parseInt(
        json['coins_per_utxo_size'] ?? json['coins_per_utxo_word'],
        4310,
      ),
      keyDeposit: parseBigInt(json['key_deposit'], BigInt.from(2000000)),
      poolDeposit: parseBigInt(json['pool_deposit'], BigInt.from(500000000)),
      maxTxSize: parseInt(json['max_tx_size'], 16384),
    );
  }
}

class BlockfrostUtxo {
  final String txHash;
  final int outputIndex;
  final String address;
  final BigInt lovelace;
  final MultiAsset multiAsset;

  const BlockfrostUtxo({
    required this.txHash,
    required this.outputIndex,
    required this.address,
    required this.lovelace,
    required this.multiAsset,
  });

  factory BlockfrostUtxo.fromJson(Map<String, dynamic> json, String address) {
    var lovelace = BigInt.zero;
    final assets = <AssetKey, BigInt>{};

    final amounts = (json['amount'] as List<dynamic>? ?? const []);
    for (final item in amounts) {
      final map = item as Map<String, dynamic>;
      final unit = map['unit'] as String;
      final qty = BigInt.parse(map['quantity'].toString());
      if (unit == 'lovelace') {
        lovelace += qty;
      } else if (unit.length >= 56) {
        final policyHex = unit.substring(0, 56);
        final nameHex = unit.substring(56);
        assets[AssetKey(policyHex, nameHex)] = qty;
      }
    }

    return BlockfrostUtxo(
      txHash: json['tx_hash'] as String,
      outputIndex: (json['output_index'] as num).toInt(),
      address: address,
      lovelace: lovelace,
      multiAsset: MultiAsset(assets),
    );
  }
}

class StakeAccountInfo {
  final bool registered;
  final BigInt controlledAmount;
  final BigInt withdrawableAmount;
  final String? poolId;
  final String? drepId;

  const StakeAccountInfo({
    required this.registered,
    required this.controlledAmount,
    required this.withdrawableAmount,
    this.poolId,
    this.drepId,
  });

  static final StakeAccountInfo empty = StakeAccountInfo(
    registered: false,
    controlledAmount: BigInt.zero,
    withdrawableAmount: BigInt.zero,
  );
}

class AssetMetadataInfo {
  final String unit;
  final String? fingerprint;
  final String? ticker;
  final String? name;
  final String? description;
  final int decimals;
  final String? onchainStandard;

  const AssetMetadataInfo({
    required this.unit,
    this.fingerprint,
    this.ticker,
    this.name,
    this.description,
    this.decimals = 0,
    this.onchainStandard,
  });
}

class AddressTxSummary {
  final String txHash;
  final int blockHeight;
  final int blockTime;

  const AddressTxSummary({
    required this.txHash,
    required this.blockHeight,
    required this.blockTime,
  });
}

/// Multi-network Blockfrost REST API client.
class BlockfrostService {
  final http.Client client;

  BlockfrostService({http.Client? client}) : client = client ?? http.Client();

  Future<dynamic> _getJson(
    CardanoNetwork network,
    String projectId,
    String path, {
    bool allow404 = false,
  }) async {
    if (projectId.trim().isEmpty) {
      throw const BlockfrostException(401, 'Missing Blockfrost Project ID');
    }
    final uri = Uri.parse('${network.blockfrostBaseUrl}$path');
    http.Response resp = await client
        .get(uri, headers: {'project_id': projectId.trim()})
        .timeout(const Duration(seconds: 15));

    if (resp.statusCode == 429) {
      await Future<void>.delayed(const Duration(milliseconds: 600));
      resp = await client
          .get(uri, headers: {'project_id': projectId.trim()})
          .timeout(const Duration(seconds: 15));
    }

    if (allow404 && resp.statusCode == 404) {
      return null;
    }
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw BlockfrostException(resp.statusCode, resp.body);
    }
    return jsonDecode(resp.body);
  }

  /// Tests connectivity and validity of [projectId] on [network].
  Future<int> getLatestSlot(CardanoNetwork network, String projectId) async {
    final json = await _getJson(network, projectId, '/blocks/latest')
        as Map<String, dynamic>;
    return (json['slot'] as num?)?.toInt() ?? 0;
  }

  Future<ProtocolParameters> getProtocolParameters(
    CardanoNetwork network,
    String projectId,
  ) async {
    final json = await _getJson(network, projectId, '/epochs/latest/parameters')
        as Map<String, dynamic>;
    return ProtocolParameters.fromBlockfrostJson(json);
  }

  Future<List<BlockfrostUtxo>> getAddressUtxos(
    CardanoNetwork network,
    String projectId,
    String address,
  ) async {
    const pageSize = 100;
    const maxPages = 50;
    final all = <BlockfrostUtxo>[];

    for (var page = 1; page <= maxPages; page++) {
      final data = await _getJson(
        network,
        projectId,
        '/addresses/$address/utxos?count=$pageSize&page=$page',
        allow404: true,
      );
      if (data == null) break;
      final list = data as List<dynamic>;
      if (list.isEmpty) break;
      for (final item in list) {
        all.add(BlockfrostUtxo.fromJson(item as Map<String, dynamic>, address));
      }
      if (list.length < pageSize) break;
    }

    return all;
  }

  Future<List<AddressTxSummary>> getAddressTransactions(
    CardanoNetwork network,
    String projectId,
    String address, {
    int count = 20,
  }) async {
    final data = await _getJson(
      network,
      projectId,
      '/addresses/$address/transactions?order=desc&count=$count',
      allow404: true,
    );
    if (data == null) return const [];
    final list = data as List<dynamic>;
    return [
      for (final item in list)
        AddressTxSummary(
          txHash: (item as Map<String, dynamic>)['tx_hash'] as String,
          blockHeight: (item['block_height'] as num?)?.toInt() ?? 0,
          blockTime: (item['block_time'] as num?)?.toInt() ?? 0,
        ),
    ];
  }

  Future<StakeAccountInfo> getStakeAccount(
    CardanoNetwork network,
    String projectId,
    String stakeAddress,
  ) async {
    final data = await _getJson(
      network,
      projectId,
      '/accounts/$stakeAddress',
      allow404: true,
    );
    if (data == null) return StakeAccountInfo.empty;
    final map = data as Map<String, dynamic>;
    return StakeAccountInfo(
      registered: map['active'] == true,
      controlledAmount: BigInt.tryParse('${map['controlled_amount']}') ?? BigInt.zero,
      withdrawableAmount:
          BigInt.tryParse('${map['withdrawable_amount']}') ?? BigInt.zero,
      poolId: map['pool_id'] as String?,
      drepId: map['drep_id'] as String?,
    );
  }

  Future<AssetMetadataInfo?> getAssetMetadata(
    CardanoNetwork network,
    String projectId,
    String unit,
  ) async {
    final data = await _getJson(
      network,
      projectId,
      '/assets/$unit',
      allow404: true,
    );
    if (data == null) return null;
    final map = data as Map<String, dynamic>;
    final meta = map['metadata'] as Map<String, dynamic>?;
    final onchain = map['onchain_metadata'] as Map<String, dynamic>?;
    final rawDesc = meta?['description'] ?? onchain?['description'];
    final descText = rawDesc is List ? rawDesc.join() : rawDesc?.toString();
    final rawDecimals = meta?['decimals'] ?? onchain?['decimals'];
    final parsedDecimals = rawDecimals is num
        ? rawDecimals.toInt()
        : (rawDecimals is String ? int.tryParse(rawDecimals.trim()) ?? 0 : 0);
    return AssetMetadataInfo(
      unit: unit,
      fingerprint: map['fingerprint'] as String?,
      ticker: (meta?['ticker'] ?? onchain?['ticker'])?.toString(),
      name: (meta?['name'] ?? onchain?['name'])?.toString(),
      description: descText,
      decimals: parsedDecimals.clamp(0, 18),
      onchainStandard: map['onchain_metadata_standard']?.toString(),
    );
  }

  Future<String?> getPoolTickerName(
    CardanoNetwork network,
    String projectId,
    String poolId,
  ) async {
    final data = await _getJson(
      network,
      projectId,
      '/pools/$poolId/metadata',
      allow404: true,
    );
    if (data == null) return null;
    final map = data as Map<String, dynamic>;
    final ticker = map['ticker'] as String?;
    final name = map['name'] as String?;
    if (ticker != null && name != null) return '[$ticker] $name';
    return ticker ?? name;
  }

  /// Broadcasts signed transaction CBOR bytes (`application/cbor`), returns `txHash`.
  Future<String> submitTransaction(
    CardanoNetwork network,
    String projectId,
    Uint8List signedTxCbor,
  ) async {
    if (projectId.trim().isEmpty) {
      throw const BlockfrostException(401, 'Missing Blockfrost Project ID');
    }
    final uri = Uri.parse('${network.blockfrostBaseUrl}/tx/submit');
    final resp = await client
        .post(
          uri,
          headers: {
            'project_id': projectId.trim(),
            'Content-Type': 'application/cbor',
          },
          body: signedTxCbor,
        )
        .timeout(const Duration(seconds: 20));
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw BlockfrostException(resp.statusCode, resp.body);
    }
    final decoded = jsonDecode(resp.body);
    return decoded.toString();
  }

  Future<bool> isTransactionConfirmed(
    CardanoNetwork network,
    String projectId,
    String txHash,
  ) async {
    final data = await _getJson(
      network,
      projectId,
      '/txs/$txHash',
      allow404: true,
    );
    return data != null;
  }
}
