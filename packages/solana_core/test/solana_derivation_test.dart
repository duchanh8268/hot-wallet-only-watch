import 'dart:convert';
import 'dart:typed_data';
import 'package:chain_core_interface/chain_core_interface.dart';
import 'package:solana_core/solana_core.dart';
import 'package:test/test.dart';

void main() {
  group('Solana SLIP-0010 Derivation Tests', () {
    const mnemonic =
        'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
    final entropy = Bip39.mnemonicToEntropy(mnemonic);

    test('Derives Solana key at m/44\'/501\'/0\'/0\' and verifies Ed25519 signatures', () {
      final seed = Bip39.entropyToSeed(entropy);
      final master = Slip0010Key.fromSeed(seed);
      final solKey = master.deriveSolanaAccount(accountIndex: 0);

      expect(solKey.privateKey.length, equals(32));
      expect(solKey.chainCode.length, equals(32));
      expect(solKey.publicKey.length, equals(32));

      final address = solKey.solanaAddress;
      expect(address.isNotEmpty, isTrue);

      // Sign message
      final msg = Uint8List.fromList(utf8.encode('Hello Solana Air-Gap!'));
      final sig = solKey.sign(msg);
      expect(sig.length, equals(64));

      // Verify
      final isValid = Ed25519Solana.verify(
        publicKey: solKey.publicKey,
        message: msg,
        signature: sig,
      );
      expect(isValid, isTrue);

      // Mutated message fails verification
      final badMsg = Uint8List.fromList(utf8.encode('Tampered Solana Message'));
      expect(
        Ed25519Solana.verify(publicKey: solKey.publicKey, message: badMsg, signature: sig),
        isFalse,
      );

      master.dispose();
      solKey.dispose();
    });

    test('Different account indices produce distinct Solana addresses', () {
      final seed = Bip39.entropyToSeed(entropy);
      final master = Slip0010Key.fromSeed(seed);

      final key0 = master.deriveSolanaAccount(accountIndex: 0);
      final key1 = master.deriveSolanaAccount(accountIndex: 1);

      expect(key0.solanaAddress, isNot(equals(key1.solanaAddress)));
      expect(key0.publicKey, isNot(equals(key1.publicKey)));

      master.dispose();
      key0.dispose();
      key1.dispose();
    });
  });
}
