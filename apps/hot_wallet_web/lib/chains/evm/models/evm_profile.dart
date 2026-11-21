import 'package:chain_core_interface/chain_core_interface.dart';

/// Watch-Only account profile for EVM chains (Ethereum, Hyperliquid).
class EvmWatchOnlyProfile {
  final String id;
  final String name;
  final ChainId chainId;
  final String networkId;
  final String address;
  final int accountIndex;

  const EvmWatchOnlyProfile({
    required this.id,
    required this.name,
    required this.chainId,
    required this.networkId,
    required this.address,
    this.accountIndex = 0,
  });

  EvmWatchOnlyProfile copyWith({
    String? name,
    String? networkId,
    String? address,
    int? accountIndex,
  }) =>
      EvmWatchOnlyProfile(
        id: id,
        name: name ?? this.name,
        chainId: chainId,
        networkId: networkId ?? this.networkId,
        address: address ?? this.address,
        accountIndex: accountIndex ?? this.accountIndex,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'chainId': chainId.id,
        'networkId': networkId,
        'address': address,
        'accountIndex': accountIndex,
      };

  factory EvmWatchOnlyProfile.fromJson(Map<String, dynamic> json) =>
      EvmWatchOnlyProfile(
        id: json['id'] as String,
        name: json['name'] as String,
        chainId: json['chainId'] == 'hyperliquid'
            ? ChainId.hyperliquid
            : ChainId.ethereum,
        networkId: json['networkId'] as String? ?? 'mainnet',
        address: json['address'] as String,
        accountIndex: (json['accountIndex'] as num?)?.toInt() ?? 0,
      );
}
