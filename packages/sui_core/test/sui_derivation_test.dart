import 'dart:typed_data';
import 'package:chain_core_interface/chain_core_interface.dart' show Bip39;
import 'package:test/test.dart';
import 'package:sui_core/sui_core.dart';

void main() {
  group('Sui Key Derivation & Address Tests', () {
    const testMnemonic =
        'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';

    test('Derives Sui address format (0x + 64 hex characters)', () {
      final entropy = Bip39.mnemonicToEntropy(testMnemonic);
      final seed = Bip39.entropyToSeed(entropy);
      final master = SuiSlip0010Key.fromSeed(seed);
      final suiKey = master.deriveSuiAccount(accountIndex: 0, addressIndex: 0);

      expect(suiKey.publicKey.length, equals(32));
      expect(suiKey.suiAddress.startsWith('0x'), isTrue);
      expect(suiKey.suiAddress.length, equals(66)); // 0x + 64 hex chars

      // Different account index yields different address
      final suiKey1 = master.deriveSuiAccount(accountIndex: 1, addressIndex: 0);
      expect(suiKey1.suiAddress, isNot(equals(suiKey.suiAddress)));

      master.dispose();
      suiKey.dispose();
      suiKey1.dispose();
    });

    test('Signs message and verifies with SuiEd25519', () {
      final priv = Uint8List(32)..fillRange(0, 32, 0x42);
      final pub = SuiEd25519.derivePublicKey(priv);
      final msg = Uint8List.fromList([1, 2, 3, 4, 5]);

      final sig = SuiEd25519.sign(message: msg, privateKey32: priv);
      expect(sig.length, equals(64));

      final isValid = SuiEd25519.verify(
        message: msg,
        signature: sig,
        publicKey: pub,
      );
      expect(isValid, isTrue);
    });
  });
}
