import 'dart:typed_data';
import 'package:chain_core_interface/chain_core_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hot_wallet_web/chains/sui/sui_hot_plugin.dart';
import 'package:hot_wallet_web/core/services/hot_chain_registry.dart';
import 'package:sui_core/sui_core.dart';

void main() {
  group('SuiHotPlugin Tests', () {
    test('HotChainRegistry contains Sui plugin', () {
      final registry = HotChainRegistry();
      final sui = registry.getPlugin(ChainId.sui);

      expect(sui.chainId, equals(ChainId.sui));
      expect(sui.displayName, equals('Sui'));
      expect(registry.findPluginForUr('sui-account'), isNotNull);
      expect(registry.findPluginForUr('sui-sign-request'), isNotNull);
      expect(registry.findPluginForUr('sui-sign-response'), isNotNull);
    });

    test('Sui plugin handles UR types and validates serialization', () {
      final plugin = SuiHotPlugin.instance;
      expect(plugin.canHandleUr('sui-account'), isTrue);
      expect(plugin.canHandleUr('sui-sign-request'), isTrue);
      expect(plugin.canHandleUr('sui-sign-response'), isTrue);
      expect(plugin.canHandleUr('sol-account'), isFalse);

      final dummySig = Uint8List(64)..fillRange(0, 64, 0x77);
      final dummyPub = Uint8List(32)..fillRange(0, 32, 0x88);
      final resp = SuiSignResponseUr(
        requestId: Uint8List(16),
        signature: dummySig,
        publicKey: dummyPub,
      );

      expect(resp.serializedSignature.length, equals(97));
      expect(resp.base64Signature.isNotEmpty, isTrue);
    });
  });
}
