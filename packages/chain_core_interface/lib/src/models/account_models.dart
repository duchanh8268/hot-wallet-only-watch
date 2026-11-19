import 'dart:typed_data';

/// Account & address derivation index configuration.
class AccountDerivationConfig {
  final String id;
  final String label;
  final int accountIndex;
  final int addressIndex;

  const AccountDerivationConfig({
    required this.id,
    required this.label,
    required this.accountIndex,
    required this.addressIndex,
  });

  String get pathSummary => '$accountIndex/0/$addressIndex';

  static String buildId(int accountIndex, int addressIndex) =>
      '${accountIndex}_$addressIndex';

  static String defaultLabel(int accountIndex, int addressIndex) =>
      'Account $accountIndex/0/$addressIndex';

  AccountDerivationConfig copyWith({String? label}) => AccountDerivationConfig(
        id: id,
        label: label ?? this.label,
        accountIndex: accountIndex,
        addressIndex: addressIndex,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'accountIndex': accountIndex,
        'addressIndex': addressIndex,
      };

  factory AccountDerivationConfig.fromJson(Map<String, dynamic> json) =>
      AccountDerivationConfig(
        id: json['id'] as String? ?? buildId(0, 0),
        label: json['label'] as String? ?? defaultLabel(0, 0),
        accountIndex: (json['accountIndex'] as num?)?.toInt() ?? 0,
        addressIndex: (json['addressIndex'] as num?)?.toInt() ?? 0,
      );
}

/// Generic container for public account details derived by a chain plugin.
class PublicAccountDetails {
  final String primaryAddress;
  final String? secondaryAddress; // e.g. Stake address in Cardano
  final String? publicIdentifier; // e.g. acct_xvk Bech32 or xpub
  final String accountUr;
  final Uint8List? rawPublicKey;

  const PublicAccountDetails({
    required this.primaryAddress,
    this.secondaryAddress,
    this.publicIdentifier,
    required this.accountUr,
    this.rawPublicKey,
  });
}
