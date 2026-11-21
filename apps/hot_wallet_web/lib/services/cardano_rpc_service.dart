import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cardano_core/cardano_core.dart';
import 'package:http/http.dart' as http;

class CardanoRpcException implements Exception {
  final int statusCode;
  final String message;

  const CardanoRpcException(this.statusCode, this.message);

  @override
  String toString() => 'CardanoRpcException($statusCode): $message';
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

  /// Parses Koios `/cli_protocol_params` or `/epoch_params` JSON with safe bounds clamping.
  factory ProtocolParameters.fromKoiosJson(Map<String, dynamic> json) {
    int parseInt(dynamic v, int fallback) =>
        v == null ? fallback : int.tryParse(v.toString()) ?? fallback;
    BigInt parseBigInt(dynamic v, BigInt fallback) =>
        v == null ? fallback : BigInt.tryParse(v.toString()) ?? fallback;
    BigInt clampBigInt(BigInt val, BigInt minVal, BigInt maxVal) {
      if (val < minVal) return minVal;
      if (val > maxVal) return maxVal;
      return val;
    }

    return ProtocolParameters(
      minFeeA: parseInt(json['txFeePerByte'] ?? json['min_fee_a'], 44).clamp(1, 5000),
      minFeeB: parseInt(json['txFeeFixed'] ?? json['min_fee_b'], 155381).clamp(0, 5000000),
      coinsPerUTxOByte: parseInt(
        json['utxoCostPerByte'] ?? json['coins_per_utxo_size'] ?? json['coins_per_utxo_word'],
        4310,
      ).clamp(1000, 100000),
      keyDeposit: clampBigInt(
        parseBigInt(json['stakeAddressDeposit'] ?? json['key_deposit'], BigInt.from(2000000)),
        BigInt.zero,
        BigInt.from(20000000),
      ),
      poolDeposit: clampBigInt(
        parseBigInt(json['stakePoolDeposit'] ?? json['pool_deposit'], BigInt.from(500000000)),
        BigInt.zero,
        BigInt.from(2000000000),
      ),
      maxTxSize: parseInt(json['maxTxSize'] ?? json['max_tx_size'], 16384).clamp(4096, 65536),
    );
  }
}

class CardanoUtxo {
  final String txHash;
  final int outputIndex;
  final String address;
  final BigInt lovelace;
  final MultiAsset multiAsset;

  const CardanoUtxo({
    required this.txHash,
    required this.outputIndex,
    required this.address,
    required this.lovelace,
    required this.multiAsset,
  });

  factory CardanoUtxo.fromKoiosJson(
    Map<String, dynamic> json, {
    String? fallbackAddress,
  }) {
    final lovelace = BigInt.parse(json['value'].toString());
    final assets = <AssetKey, BigInt>{};

    final assetList = json['asset_list'] as List<dynamic>? ?? const [];
    for (final raw in assetList) {
      if (raw is! Map<String, dynamic>) continue;
      final policyHex = (raw['policy_id'] ?? '').toString().toLowerCase();
      final nameHex = (raw['asset_name'] ?? '').toString().toLowerCase();
      if (policyHex.length != 56) continue;
      final qty = BigInt.parse(raw['quantity'].toString());
      final key = AssetKey(policyHex, nameHex);
      assets[key] = (assets[key] ?? BigInt.zero) + qty;
    }

    return CardanoUtxo(
      txHash: json['tx_hash'] as String,
      outputIndex: ((json['tx_index'] ?? json['output_index']) as num).toInt(),
      address: (json['address'] as String?) ?? fallbackAddress ?? '',
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

/// Keyless multi-network Cardano Koios REST RPC client.
class CardanoRpcService {
  static const String defaultPreprodRpcUrl =
      'https://cardano-koios-rpc.duchanh8268.workers.dev/preprod';
  static const String defaultPreviewRpcUrl =
      'https://cardano-koios-rpc.duchanh8268.workers.dev/preview';
  static const String defaultMainnetRpcUrl =
      'https://cardano-koios-rpc.duchanh8268.workers.dev/mainnet';

  final http.Client client;
  final Map<String, String> _customUrls = {};

  CardanoRpcService({http.Client? client}) : client = client ?? http.Client();

  void resetToDefaultRpcUrl(String networkId) {
    _customUrls.remove(networkId.toLowerCase());
  }

  void setCustomRpcUrl(String networkId, String url) {
    final clean = url.trim().replaceFirst(RegExp(r'/+$'), '');
    if (clean.isNotEmpty) {
      _customUrls[networkId.toLowerCase()] = clean;
    }
  }

  String getRpcUrl(String networkId) {
    final key = networkId.toLowerCase();
    final custom = _customUrls[key];
    if (custom != null && custom.isNotEmpty) {
      return custom;
    }
    switch (key) {
      case 'mainnet':
        return defaultMainnetRpcUrl;
      case 'preview':
        return defaultPreviewRpcUrl;
      case 'preprod':
      default:
        return defaultPreprodRpcUrl;
    }
  }

  Future<dynamic> _getJson(CardanoNetwork network, String path) async {
    final uri = Uri.parse('${getRpcUrl(network.id)}$path');
    http.Response resp = await client
        .get(uri, headers: const {'Accept': 'application/json'})
        .timeout(const Duration(seconds: 15));

    if (resp.statusCode == 429) {
      await Future<void>.delayed(const Duration(milliseconds: 600));
      resp = await client
          .get(uri, headers: const {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 15));
    }

    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw CardanoRpcException(resp.statusCode, resp.body);
    }
    return jsonDecode(resp.body);
  }

  Future<dynamic> _postJson(
    CardanoNetwork network,
    String path,
    Object payload,
  ) async {
    final uri = Uri.parse('${getRpcUrl(network.id)}$path');
    final encoded = jsonEncode(payload);
    http.Response resp = await client
        .post(
          uri,
          headers: const {
            'Content-Type': 'application/json',
            'Accept': 'application/json',
          },
          body: encoded,
        )
        .timeout(const Duration(seconds: 15));

    if (resp.statusCode == 429) {
      await Future<void>.delayed(const Duration(milliseconds: 600));
      resp = await client
          .post(
            uri,
            headers: const {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: encoded,
          )
          .timeout(const Duration(seconds: 15));
    }

    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw CardanoRpcException(resp.statusCode, resp.body);
    }
    return jsonDecode(resp.body);
  }

  /// Queries latest chain tip slot on [network].
  Future<int> getLatestSlot(CardanoNetwork network) async {
    final data = await _getJson(network, '/tip');
    if (data is! List || data.isEmpty) {
      throw const CardanoRpcException(502, 'Empty /tip response from Cardano Koios RPC');
    }
    final first = data.first as Map<String, dynamic>;
    return (first['abs_slot'] as num?)?.toInt() ?? 0;
  }

  Future<ProtocolParameters> getProtocolParameters(CardanoNetwork network) async {
    final data = await _getJson(network, '/cli_protocol_params');
    if (data is Map<String, dynamic>) {
      return ProtocolParameters.fromKoiosJson(data);
    }
    if (data is List && data.isNotEmpty && data.first is Map<String, dynamic>) {
      return ProtocolParameters.fromKoiosJson(data.first as Map<String, dynamic>);
    }
    throw const CardanoRpcException(502, 'Invalid /cli_protocol_params response');
  }

  Future<List<CardanoUtxo>> getAddressUtxos(
    CardanoNetwork network,
    String address,
  ) async {
    final grouped = await getAddressesUtxosBatch(network, [address]);
    return grouped[address] ?? const [];
  }

  Future<Map<String, List<CardanoUtxo>>> getAddressesUtxosBatch(
    CardanoNetwork network,
    List<String> addresses,
  ) async {
    if (addresses.isEmpty) return const {};
    const pageSize = 1000;
    const maxPages = 50;
    final out = <String, List<CardanoUtxo>>{};

    for (var page = 0; page < maxPages; page++) {
      final offset = page * pageSize;
      final data = await _postJson(
        network,
        '/address_utxos?limit=$pageSize&offset=$offset',
        {
          '_addresses': addresses,
          '_extended': true,
        },
      );
      if (data is! List || data.isEmpty) break;

      for (final raw in data) {
        if (raw is! Map<String, dynamic>) continue;
        if (raw['is_spent'] == true) continue;
        final utxo = CardanoUtxo.fromKoiosJson(
          raw,
          fallbackAddress: addresses.length == 1 ? addresses.first : null,
        );
        out.putIfAbsent(utxo.address, () => []).add(utxo);
      }

      if (data.length < pageSize) break;
    }

    return out;
  }

  Future<List<AddressTxSummary>> getAddressTransactions(
    CardanoNetwork network,
    String address, {
    int count = 20,
  }) {
    return getAddressesTransactions(network, [address], count: count);
  }

  Future<List<AddressTxSummary>> getAddressesTransactions(
    CardanoNetwork network,
    List<String> addresses, {
    int count = 20,
  }) async {
    if (addresses.isEmpty) return const [];
    final data = await _postJson(
      network,
      '/address_txs?order=block_height.desc,tx_hash.desc&limit=$count',
      {'_addresses': addresses},
    );
    if (data is! List) return const [];
    return [
      for (final item in data)
        if (item is Map<String, dynamic>)
          AddressTxSummary(
            txHash: item['tx_hash'] as String,
            blockHeight: (item['block_height'] as num?)?.toInt() ?? 0,
            blockTime: (item['block_time'] as num?)?.toInt() ?? 0,
          ),
    ];
  }

  Future<StakeAccountInfo> getStakeAccount(
    CardanoNetwork network,
    String stakeAddress,
  ) async {
    final data = await _postJson(
      network,
      '/account_info',
      {
        '_stake_addresses': [stakeAddress],
      },
    );
    if (data is! List || data.isEmpty) return StakeAccountInfo.empty;
    final map = data.first as Map<String, dynamic>;
    return StakeAccountInfo(
      registered: map['status'] == 'registered',
      controlledAmount:
          BigInt.tryParse('${map['total_balance'] ?? map['utxo'] ?? 0}') ?? BigInt.zero,
      withdrawableAmount:
          BigInt.tryParse('${map['rewards_available'] ?? 0}') ?? BigInt.zero,
      poolId: map['delegated_pool'] as String?,
      drepId: map['delegated_drep'] as String?,
    );
  }

  AssetMetadataInfo _parseKoiosAssetInfo(Map<String, dynamic> map, String unit) {
    final reg = map['token_registry_metadata'] as Map<String, dynamic>?;
    final cip68 = map['cip68_metadata'] as Map<String, dynamic>?;
    final cip68Inner = (cip68?['222'] ?? cip68?['333'] ?? cip68) as Map<String, dynamic>?;

    final mintMeta = map['minting_tx_metadata'] as Map<String, dynamic>?;
    Map<String, dynamic>? cip25;
    final policyHex = (map['policy_id'] ?? '').toString();
    final asciiName = map['asset_name_ascii']?.toString();
    final assetHex = (map['asset_name'] ?? '').toString();
    final raw721 = mintMeta?['721'];
    if (raw721 is Map<String, dynamic>) {
      final policyMap = raw721[policyHex];
      if (policyMap is Map<String, dynamic>) {
        final candidate = (asciiName != null ? policyMap[asciiName] : null) ?? policyMap[assetHex];
        if (candidate is Map<String, dynamic>) {
          cip25 = candidate;
        }
      }
    }

    final rawDesc = reg?['description'] ?? cip68Inner?['description'] ?? cip25?['description'];
    final descText = rawDesc is List ? rawDesc.join() : rawDesc?.toString();
    final rawDecimals = reg?['decimals'] ?? cip68Inner?['decimals'] ?? cip25?['decimals'];
    final parsedDecimals = rawDecimals is num
        ? rawDecimals.toInt()
        : (rawDecimals is String ? int.tryParse(rawDecimals.trim()) ?? 0 : 0);

    final name = (reg?['name'] ??
            cip68Inner?['name'] ??
            cip25?['name'] ??
            (asciiName != null && asciiName.isNotEmpty ? asciiName : null))
        ?.toString();
    final ticker = (reg?['ticker'] ?? cip68Inner?['ticker'] ?? cip25?['ticker'])?.toString();
    final standard = cip68 != null ? 'CIP68' : (cip25 != null ? 'CIP25v1' : null);

    return AssetMetadataInfo(
      unit: unit,
      fingerprint: map['fingerprint'] as String?,
      ticker: ticker,
      name: name,
      description: descText,
      decimals: parsedDecimals.clamp(0, 18),
      onchainStandard: standard,
    );
  }

  Future<Map<String, AssetMetadataInfo>> getAssetsMetadataBatch(
    CardanoNetwork network,
    List<AssetKey> assetKeys,
  ) async {
    if (assetKeys.isEmpty) return const {};
    final data = await _postJson(
      network,
      '/asset_info',
      {
        '_asset_list': [
          for (final k in assetKeys) [k.policyIdHex, k.assetNameHex],
        ],
      },
    );
    if (data is! List) return const {};

    final out = <String, AssetMetadataInfo>{};
    for (final raw in data) {
      if (raw is! Map<String, dynamic>) continue;
      final policyHex = (raw['policy_id'] ?? '').toString().toLowerCase();
      final nameHex = (raw['asset_name'] ?? '').toString().toLowerCase();
      if (policyHex.length != 56) continue;
      final unit = '$policyHex$nameHex';
      out[unit] = _parseKoiosAssetInfo(raw, unit);
    }
    return out;
  }

  Future<AssetMetadataInfo?> getAssetMetadata(
    CardanoNetwork network,
    String unit,
  ) async {
    if (unit.length < 56) return null;
    final policyHex = unit.substring(0, 56);
    final nameHex = unit.substring(56);
    final res = await getAssetsMetadataBatch(
      network,
      [AssetKey(policyHex, nameHex)],
    );
    return res[unit.toLowerCase()] ?? res[unit];
  }

  Future<String?> getPoolTickerName(
    CardanoNetwork network,
    String poolId,
  ) async {
    final data = await _postJson(
      network,
      '/pool_metadata',
      {
        '_pool_bech32_ids': [poolId],
      },
    );
    if (data is! List || data.isEmpty) return null;
    final map = data.first as Map<String, dynamic>;
    final meta = map['meta_json'] as Map<String, dynamic>?;
    final ticker = meta?['ticker'] as String?;
    final name = meta?['name'] as String?;
    if (ticker != null && ticker.isNotEmpty && name != null && name.isNotEmpty) {
      return '[$ticker] $name';
    }
    return (ticker != null && ticker.isNotEmpty) ? ticker : name;
  }

  /// Broadcasts signed transaction CBOR bytes (`application/cbor`), returns `txHash`.
  Future<String> submitTransaction(
    CardanoNetwork network,
    Uint8List signedTxCbor,
  ) async {
    final uri = Uri.parse('${getRpcUrl(network.id)}/submittx');
    final resp = await client
        .post(
          uri,
          headers: const {
            'Content-Type': 'application/cbor',
            'Accept': 'application/json',
          },
          body: signedTxCbor,
        )
        .timeout(const Duration(seconds: 20));
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw CardanoRpcException(resp.statusCode, resp.body);
    }
    final trimmed = resp.body.trim();
    if (trimmed.startsWith('"') && trimmed.endsWith('"')) {
      return jsonDecode(trimmed).toString();
    }
    return trimmed;
  }

  Future<bool> isTransactionConfirmed(
    CardanoNetwork network,
    String txHash,
  ) async {
    final data = await _postJson(
      network,
      '/tx_status',
      {
        '_tx_hashes': [txHash],
      },
    );
    if (data is! List || data.isEmpty) return false;
    final first = data.first as Map<String, dynamic>;
    final confirmations = first['num_confirmations'];
    return confirmations is num && confirmations >= 1;
  }
}
