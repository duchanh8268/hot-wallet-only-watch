import 'dart:typed_data';
import 'package:chain_core_interface/chain_core_interface.dart';
import 'package:solana_core/solana_core.dart';
import '../../core/models/chain_tx_record.dart';
import 'services/solana_rpc_service.dart';

/// Hot Wallet plugin supporting Solana.
class SolanaHotPlugin implements IHotChainPlugin {
  static final SolanaHotPlugin instance = SolanaHotPlugin._();

  @override
  final ChainId chainId = ChainId.solana;

  final SolanaRpcService rpcService;

  SolanaHotPlugin._({SolanaRpcService? rpc})
      : rpcService = rpc ?? SolanaRpcService();

  @override
  String get displayName => 'Solana';

  @override
  List<ChainNetwork> get supportedNetworks => const [
        ChainNetwork(
          id: 'devnet',
          name: 'Solana Devnet',
          isTestnet: true,
          networkCode: 1,
        ),
        ChainNetwork(
          id: 'mainnet-beta',
          name: 'Solana Mainnet',
          isTestnet: false,
          networkCode: 0,
        ),
        ChainNetwork(
          id: 'testnet',
          name: 'Solana Testnet',
          isTestnet: true,
          networkCode: 2,
        ),
      ];

  @override
  ChainNetwork get defaultNetwork => supportedNetworks.first;

  @override
  bool canHandleUr(String urType) {
    final lower = urType.toLowerCase();
    return lower == SolAccountUr.urType ||
        lower == SolSignRequestUr.urType ||
        lower == SolSignResponseUr.urType;
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
    final seed = Bip39.entropyToSeed(entropy, passphrase: passphrase);
    final masterHd = Slip0010Key.fromSeed(seed);
    final childKey = masterHd.deriveSolanaAccount(accountIndex: accountIndex);

    try {
      final address = childKey.solanaAddress;
      final accountUr = SolAccountUr(
        chain: chainId.id,
        network: network.id,
        accountIndex: accountIndex,
        address: address,
        label: label,
      ).toUr();

      return PublicAccountDetails(
        primaryAddress: address,
        secondaryAddress: null,
        publicIdentifier: address,
        accountUr: accountUr,
        rawPublicKey: childKey.publicKey,
      );
    } finally {
      masterHd.dispose();
      childKey.dispose();
      zeroize(seed);
    }
  }

  @override
  Future<void> configureEndpoint({
    required ChainNetwork network,
    String? customUrl,
    String? apiKey,
  }) async {
    if (customUrl != null && customUrl.isNotEmpty) {
      rpcService.setCustomRpcUrl(network.id, customUrl);
    }
  }

  @override
  Future<Map<String, dynamic>> fetchAccountBalance({
    required ChainNetwork network,
    required String address,
  }) async {
    try {
      final lamports = await rpcService.getBalance(
        address: address,
        networkId: network.id,
      );
      final sol = lamports.toDouble() / 1e9;
      List<ChainTxRecord> recentTxs = const [];
      String? historyError;
      try {
        recentTxs = await rpcService.getRecentSignatures(
          address: address,
          networkId: network.id,
        );
      } catch (e) {
        historyError = e.toString();
      }
      return {
        'address': address,
        'network': network.id,
        'lamports': lamports.toString(),
        'sol': sol.toStringAsFixed(4),
        'recentTxs': recentTxs,
        'historyError': ?historyError,
      };
    } catch (e) {
      return {
        'address': address,
        'network': network.id,
        'lamports': '0',
        'sol': '0.0000',
        'error': e.toString(),
      };
    }
  }

  @override
  Future<String> broadcastTransaction({
    required ChainNetwork network,
    required Uint8List signedTxBytes,
  }) async {
    return await rpcService.sendTransaction(
      transactionBytes: signedTxBytes,
      networkId: network.id,
    );
  }

  /// Assembles a signed Solana transaction from original message and signature.
  SolanaTransaction assembleSignedTx({
    required SolanaMessage message,
    required SolSignResponseUr response,
  }) {
    return SolanaTransaction(
      signatures: [response.signature],
      message: message,
    );
  }
}
