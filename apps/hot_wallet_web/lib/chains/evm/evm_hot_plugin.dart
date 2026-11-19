import 'dart:convert';
import 'dart:typed_data';

import 'package:chain_core_interface/chain_core_interface.dart';
import 'package:evm_core/evm_core.dart';
import 'services/evm_rpc_service.dart';
import 'services/hyperliquid_service.dart';

/// Hot Wallet plugin supporting EVM blockchains (Ethereum, Hyperliquid L1).
class EvmHotPlugin implements IHotChainPlugin {
  static final EvmHotPlugin ethereum = EvmHotPlugin._(ChainId.ethereum);
  static final EvmHotPlugin hyperliquid = EvmHotPlugin._(ChainId.hyperliquid);

  @override
  final ChainId chainId;

  final EvmRpcService rpcService;
  final HyperliquidService hlService;

  EvmHotPlugin._(this.chainId, {EvmRpcService? rpc, HyperliquidService? hl})
      : rpcService = rpc ?? EvmRpcService(),
        hlService = hl ?? HyperliquidService();

  @override
  String get displayName => chainId == ChainId.hyperliquid ? 'Hyperliquid' : 'Ethereum';

  @override
  List<ChainNetwork> get supportedNetworks {
    if (chainId == ChainId.hyperliquid) {
      return const [
        ChainNetwork(id: 'mainnet', name: 'Hyperliquid L1 Mainnet', isTestnet: false, networkCode: 999),
        ChainNetwork(id: 'testnet', name: 'Hyperliquid Testnet', isTestnet: true, networkCode: 998),
      ];
    }
    return const [
      ChainNetwork(id: 'mainnet', name: 'Ethereum Mainnet', isTestnet: false, networkCode: 1),
      ChainNetwork(id: 'sepolia', name: 'Sepolia Testnet', isTestnet: true, networkCode: 11155111),
      ChainNetwork(id: 'holesky', name: 'Holesky Testnet', isTestnet: true, networkCode: 17000),
    ];
  }

  @override
  ChainNetwork get defaultNetwork => supportedNetworks.first;

  @override
  bool canHandleUr(String urType) {
    final lower = urType.toLowerCase();
    return lower == EthAccountUr.urType ||
        lower == EthSignRequestUr.urType ||
        lower == EthSignResponseUr.urType;
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
    final masterHd = EvmHdKey.fromSeed(seed);
    final childKey = masterHd.deriveEvmAccount(
      accountIndex: accountIndex,
      addressIndex: addressIndex,
    );
    try {
      final address = Eip55.addressFromPublicKey64(childKey.publicKey64);
      final accountUr = EthAccountUr(
        chain: chainId.id,
        network: network.id,
        address: address,
        accountIndex: accountIndex,
        label: label,
      ).toUr();

      return PublicAccountDetails(
        primaryAddress: address,
        secondaryAddress: null,
        publicIdentifier: address,
        accountUr: accountUr,
        rawPublicKey: childKey.publicKey65,
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
      if (chainId == ChainId.hyperliquid) {
        hlService.setCustomApiUrl(network.id, customUrl);
      } else {
        rpcService.setCustomRpcUrl(network.id, customUrl);
      }
    }
  }

  @override
  Future<Map<String, dynamic>> fetchAccountBalance({
    required ChainNetwork network,
    required String address,
  }) async {
    if (chainId == ChainId.hyperliquid) {
      try {
        final state = await hlService.getUserState(network.id, address);
        final margin = state['marginSummary'] as Map<String, dynamic>? ?? {};
        final accountValue = margin['accountValue']?.toString() ?? '0';
        return {
          'address': address,
          'network': network.id,
          'accountValueUsd': accountValue,
          'raw': state,
        };
      } catch (e) {
        return {
          'address': address,
          'network': network.id,
          'accountValueUsd': '0.00',
          'error': e.toString(),
        };
      }
    } else {
      try {
        final balanceWei = await rpcService.getBalance(network.id, address);
        final nonce = await rpcService.getTransactionCount(network.id, address);
        return {
          'address': address,
          'network': network.id,
          'balanceWei': balanceWei.toString(),
          'nonce': nonce.toString(),
        };
      } catch (e) {
        return {
          'address': address,
          'network': network.id,
          'balanceWei': '0',
          'nonce': '0',
          'error': e.toString(),
        };
      }
    }
  }

  @override
  Future<String> broadcastTransaction({
    required ChainNetwork network,
    required Uint8List signedTxBytes,
  }) async {
    if (chainId == ChainId.hyperliquid) {
      final jsonPayload = jsonDecode(utf8.decode(signedTxBytes)) as Map<String, dynamic>;
      final resp = await hlService.submitAction(
        networkId: network.id,
        action: jsonPayload['action'] as Map<String, dynamic>,
        nonce: jsonPayload['nonce'] as int,
        signature: jsonPayload['signature'] as Map<String, dynamic>,
      );
      return resp['status']?.toString() ?? 'ok';
    } else {
      return await rpcService.sendRawTransaction(network.id, signedTxBytes);
    }
  }

  /// Injects an `EthSignResponseUr` signature into an unsigned `Eip1559Transaction`.
  Uint8List assembleSignedEip1559Tx(
    Eip1559Transaction tx,
    EthSignResponseUr response,
  ) {
    return EvmTxSerializer.serializeEip1559Signed(
      tx,
      EvmSignature(
        r: response.r,
        s: response.s,
        v: response.v,
      ),
    );
  }
}
