import 'package:chain_core_interface/chain_core_interface.dart';

/// Watch-Only account profile for Solana.
class SolWatchOnlyProfile {
  final String id;
  final String name;
  final ChainId chainId;
  final String networkId; // 'mainnet-beta', 'devnet', 'testnet'
  final String address;
  final int accountIndex;

  const SolWatchOnlyProfile({
    required this.id,
    required this.name,
    this.chainId = ChainId.solana,
    required this.networkId,
    required this.address,
    this.accountIndex = 0,
  });

  SolWatchOnlyProfile copyWith({
    String? name,
    String? networkId,
    String? address,
    int? accountIndex,
  }) =>
      SolWatchOnlyProfile(
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

  factory SolWatchOnlyProfile.fromJson(Map<String, dynamic> json) =>
      SolWatchOnlyProfile(
        id: json['id'] as String,
        name: json['name'] as String,
        chainId: ChainId.solana,
        networkId: json['networkId'] as String? ?? 'devnet',
        address: json['address'] as String,
        accountIndex: (json['accountIndex'] as num?)?.toInt() ?? 0,
      );
}
