import 'package:chain_core_interface/chain_core_interface.dart';

/// Watch-Only account profile for Bitcoin Native SegWit (BIP-84).
class BtcWatchOnlyProfile {
  final String id;
  final String name;
  final ChainId chainId;
  final String networkId; // 'mainnet', 'testnet4', 'signet'
  final String receiveAddress;
  final int accountIndex;
  final int masterFingerprint;
  final String? accountXpub;

  const BtcWatchOnlyProfile({
    required this.id,
    required this.name,
    this.chainId = ChainId.bitcoin,
    required this.networkId,
    required this.receiveAddress,
    this.accountIndex = 0,
    this.masterFingerprint = 0,
    this.accountXpub,
  });

  bool get hasAccountXpub =>
      accountXpub != null && accountXpub!.trim().isNotEmpty;

  BtcWatchOnlyProfile copyWith({
    String? name,
    String? networkId,
    String? receiveAddress,
    int? accountIndex,
    int? masterFingerprint,
    String? accountXpub,
  }) =>
      BtcWatchOnlyProfile(
        id: id,
        name: name ?? this.name,
        chainId: chainId,
        networkId: networkId ?? this.networkId,
        receiveAddress: receiveAddress ?? this.receiveAddress,
        accountIndex: accountIndex ?? this.accountIndex,
        masterFingerprint: masterFingerprint ?? this.masterFingerprint,
        accountXpub: accountXpub ?? this.accountXpub,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'chainId': chainId.id,
        'networkId': networkId,
        'receiveAddress': receiveAddress,
        'accountIndex': accountIndex,
        'masterFingerprint': masterFingerprint,
        if (accountXpub != null) 'accountXpub': accountXpub,
      };

  factory BtcWatchOnlyProfile.fromJson(Map<String, dynamic> json) =>
      BtcWatchOnlyProfile(
        id: json['id'] as String,
        name: json['name'] as String,
        chainId: ChainId.bitcoin,
        networkId: json['networkId'] as String? ?? 'mainnet',
        receiveAddress: json['receiveAddress'] as String,
        accountIndex: (json['accountIndex'] as num?)?.toInt() ?? 0,
        masterFingerprint: (json['masterFingerprint'] as num?)?.toInt() ?? 0,
        accountXpub: json['accountXpub'] as String?,
      );
}
