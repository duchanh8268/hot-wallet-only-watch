import 'dart:convert';
import 'dart:typed_data';
import 'package:chain_core_interface/chain_core_interface.dart';
import 'package:sui_core/sui_core.dart';
import '../../core/models/chain_tx_record.dart';
import 'services/sui_rpc_service.dart';

/// Hot Wallet plugin supporting Sui.
class SuiHotPlugin implements IHotChainPlugin {
  static final SuiHotPlugin instance = SuiHotPlugin._();

  @override
  final ChainId chainId = ChainId.sui;

  final SuiRpcService rpcService;

  SuiHotPlugin._({SuiRpcService? rpc}) : rpcService = rpc ?? SuiRpcService();

  factory SuiHotPlugin.withRpc(SuiRpcService rpc) => SuiHotPlugin._(rpc: rpc);

  @override
  String get displayName => 'Sui';

  @override
  List<ChainNetwork> get supportedNetworks => const [
        ChainNetwork(
          id: 'testnet',
          name: 'Sui Testnet',
          isTestnet: true,
          networkCode: 1,
        ),
        ChainNetwork(
          id: 'mainnet',
          name: 'Sui Mainnet',
          isTestnet: false,
          networkCode: 0,
        ),
        ChainNetwork(
          id: 'devnet',
          name: 'Sui Devnet',
          isTestnet: true,
          networkCode: 2,
        ),
      ];

  @override
  ChainNetwork get defaultNetwork => supportedNetworks.first;

  @override
  bool canHandleUr(String urType) {
    final lower = urType.toLowerCase();
    return lower == SuiAccountUr.urType ||
        lower == SuiSignRequestUr.urType ||
        lower == SuiSignResponseUr.urType;
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
    final masterHd = SuiSlip0010Key.fromSeed(seed);
    final childKey = masterHd.deriveSuiAccount(
      accountIndex: accountIndex,
      addressIndex: addressIndex,
    );

    try {
      final address = childKey.suiAddress;
      final accountUr = SuiAccountUr(
        chain: chainId.id,
        network: network.id,
        accountIndex: accountIndex,
        addressIndex: addressIndex,
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
      final mist = await rpcService.getBalance(
        address: address,
        networkId: network.id,
      );
      final sui = mist.toDouble() / 1e9;
      List<ChainTxRecord> recentTxs = const [];
      String? historyError;
      try {
        recentTxs = await rpcService.getRecentTransactions(
          address: address,
          networkId: network.id,
        );
      } catch (e) {
        historyError = e.toString();
      }
      return {
        'address': address,
        'network': network.id,
        'mist': mist.toString(),
        'sui': sui.toStringAsFixed(4),
        'recentTxs': recentTxs,
        'historyError': ?historyError,
      };
    } catch (e) {
      return {
        'address': address,
        'network': network.id,
        'mist': '0',
        'sui': '0.0000',
        'error': e.toString(),
      };
    }
  }

  @override
  Future<String> broadcastTransaction({
    required ChainNetwork network,
    required Uint8List signedTxBytes,
  }) async {
    final decoded = jsonDecode(utf8.decode(signedTxBytes)) as Map<String, dynamic>;
    final txBytesB64 = decoded['txBytes'] as String;
    final sigs = (decoded['signatures'] as List).map((e) => e.toString()).toList();
    return await rpcService.executeTransactionBlock(
      txBytesBase64: txBytesB64,
      signatures: sigs,
      networkId: network.id,
    );
  }
}
