import 'dart:typed_data';
import 'package:cardano_core/cardano_core.dart';
import 'package:chain_core_interface/chain_core_interface.dart';
import 'services/blockfrost_service.dart';

/// Cardano Conway Era Hot Wallet plugin implementing [IHotChainPlugin].
class CardanoHotPlugin implements IHotChainPlugin {
  static const CardanoHotPlugin instance = CardanoHotPlugin._();
  const CardanoHotPlugin._();

  @override
  ChainId get chainId => ChainId.cardano;

  @override
  String get displayName => 'Cardano';

  @override
  List<ChainNetwork> get supportedNetworks => const [
        ChainNetwork(id: 'preprod', name: 'Preprod Testnet', isTestnet: true, networkCode: 0),
        ChainNetwork(id: 'preview', name: 'Preview Testnet', isTestnet: true, networkCode: 0),
        ChainNetwork(id: 'mainnet', name: 'Cardano Mainnet', isTestnet: false, networkCode: 1),
      ];

  @override
  ChainNetwork get defaultNetwork => supportedNetworks.first;

  CardanoNetwork _toCardanoNetwork(ChainNetwork network) {
    return switch (network.id.toLowerCase()) {
      'mainnet' => CardanoNetwork.mainnet,
      'preview' => CardanoNetwork.preview,
      _ => CardanoNetwork.preprod,
    };
  }

  @override
  bool canHandleUr(String urType) {
    final lower = urType.toLowerCase();
    return lower == CardanoAccountUr.urType ||
        lower == CardanoSignRequestUr.urType ||
        lower == CardanoSignResponseUr.urType;
  }

  @override
  Future<PublicAccountDetails> derivePublicAccount({
    required Uint8List entropy,
    String passphrase = '',
    required ChainNetwork network,
    required int accountIndex,
    required int addressIndex,
    String? label,
  }) async {
    final cardanoNet = _toCardanoNetwork(network);
    final master = CardanoMasterKey.fromEntropy(entropy, passphrase: passphrase);
    try {
      final acct = master.exportAccountPublicKey(accountIndex: accountIndex);
      final primaryAddr = acct.deriveBaseAddress(
        role: 0,
        index: addressIndex,
        network: cardanoNet,
      );
      final stakeAddr = acct.deriveRewardAddress(network: cardanoNet);
      final acctXvkBech32 = acct.toBech32();
      final accountUr = CardanoAccountUr(
        network: cardanoNet,
        acctXvk: acct.bytes,
        accountIndex: accountIndex,
        label: label,
      ).toUr();

      return PublicAccountDetails(
        primaryAddress: primaryAddr,
        secondaryAddress: stakeAddr,
        publicIdentifier: acctXvkBech32,
        accountUr: accountUr,
        rawPublicKey: acct.bytes,
      );
    } finally {
      master.dispose();
    }
  }

  @override
  Future<void> configureEndpoint({required ChainNetwork network, String? customUrl, String? apiKey}) async {
    // Cardano endpoint & project ID configuration is managed via BlockfrostService / WebCryptoStorage
  }

  @override
  Future<Map<String, dynamic>> fetchAccountBalance({
    required ChainNetwork network,
    required String address,
  }) async {
    // Standard query delegated to BlockfrostService
    return {
      'address': address,
      'network': network.id,
    };
  }

  @override
  Future<String> broadcastTransaction({
    required ChainNetwork network,
    required Uint8List signedTxBytes,
  }) async {
    throw UnimplementedError('Direct broadcast should use BlockfrostService.submitTransaction');
  }
}
