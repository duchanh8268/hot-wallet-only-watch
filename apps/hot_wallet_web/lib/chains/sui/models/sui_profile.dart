import 'package:chain_core_interface/chain_core_interface.dart';

/// Watch-Only account profile for Sui.
class SuiWatchOnlyProfile {
  final String id;
  final String name;
  final ChainId chainId;
  final String networkId; // 'mainnet', 'testnet', 'devnet'
  final String address;
  final int accountIndex;
  final int addressIndex;

  const SuiWatchOnlyProfile({
    required this.id,
    required this.name,
    this.chainId = ChainId.sui,
    required this.networkId,
    required this.address,
    this.accountIndex = 0,
    this.addressIndex = 0,
  });

  SuiWatchOnlyProfile copyWith({
    String? name,
    String? networkId,
    String? address,
    int? accountIndex,
    int? addressIndex,
  }) =>
      SuiWatchOnlyProfile(
        id: id,
        name: name ?? this.name,
        chainId: chainId,
        networkId: networkId ?? this.networkId,
        address: address ?? this.address,
        accountIndex: accountIndex ?? this.accountIndex,
        addressIndex: addressIndex ?? this.addressIndex,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'chainId': chainId.id,
        'networkId': networkId,
        'address': address,
        'accountIndex': accountIndex,
        'addressIndex': addressIndex,
      };

  factory SuiWatchOnlyProfile.fromJson(Map<String, dynamic> json) =>
      SuiWatchOnlyProfile(
        id: json['id'] as String,
        name: json['name'] as String,
        chainId: ChainId.sui,
        networkId: json['networkId'] as String? ?? 'testnet',
        address: json['address'] as String,
        accountIndex: (json['accountIndex'] as num?)?.toInt() ?? 0,
        addressIndex: (json['addressIndex'] as num?)?.toInt() ?? 0,
      );
}
