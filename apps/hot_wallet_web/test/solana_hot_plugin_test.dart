import 'dart:typed_data';
import 'package:chain_core_interface/chain_core_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hot_wallet_web/chains/solana/services/solana_rpc_service.dart';
import 'package:hot_wallet_web/chains/solana/solana_hot_plugin.dart';
import 'package:hot_wallet_web/core/services/hot_chain_registry.dart';
import 'package:solana_core/solana_core.dart';

void main() {
  group('SolanaHotPlugin Tests', () {
    test('HotChainRegistry contains Solana plugin', () {
      final registry = HotChainRegistry();
      final sol = registry.getPlugin(ChainId.solana);

      expect(sol.chainId, equals(ChainId.solana));
      expect(sol.displayName, equals('Solana'));
      expect(registry.findPluginForUr('sol-account'), isNotNull);
      expect(registry.findPluginForUr('sol-sign-request'), isNotNull);
      expect(registry.findPluginForUr('sol-sign-response'), isNotNull);
    });

    test('Assembles valid signed Solana transaction from Cold Wallet response', () {
      final plugin = SolanaHotPlugin.instance;

      final fromPubkey = Uint8List(32)..fillRange(0, 32, 1);
      final toPubkey = Uint8List(32)..fillRange(0, 32, 2);
      final transferIx = SystemProgram.transfer(
        fromPubkey: fromPubkey,
        toPubkey: toPubkey,
        lamports: BigInt.from(1000000),
      );

      final msg = SolanaMessage.compile(
        instructions: [transferIx],
        feePayer: fromPubkey,
        recentBlockhash: Uint8List(32)..fillRange(0, 32, 9),
      );

      final dummySig = Uint8List(64)..fillRange(0, 64, 0x55);
      final resp = SolSignResponseUr(
        requestId: Uint8List(16),
        signature: dummySig,
        publicKey: fromPubkey,
      );

      final tx = plugin.assembleSignedTx(
        message: msg,
        response: resp,
      );

      expect(tx.signatures.length, equals(1));
      expect(tx.signatures.first, equals(dummySig));

      final serialized = tx.serialize();
      expect(serialized.isNotEmpty, isTrue);
    });

    test('SolanaRpcService uses PublicNode mainnet-beta default and supports resetToDefaultRpcUrl', () {
      final rpc = SolanaRpcService();
      expect(rpc.getRpcUrl('mainnet-beta'), equals('https://solana-rpc.publicnode.com'));
      expect(rpc.getRpcUrl('mainnet'), equals('https://solana-rpc.publicnode.com'));
      rpc.setCustomRpcUrl('mainnet-beta', 'https://custom-sol.example');
      expect(rpc.getRpcUrl('mainnet-beta'), equals('https://custom-sol.example'));
      rpc.resetToDefaultRpcUrl('mainnet-beta');
      expect(rpc.getRpcUrl('mainnet-beta'), equals('https://solana-rpc.publicnode.com'));
    });
  });
}
