import 'package:chain_core_interface/chain_core_interface.dart';
import 'package:evm_core/evm_core.dart';
import 'package:test/test.dart';

void main() {
  group('EVM BIP-39 & BIP-44 Derivation Tests', () {
    test('Standard 12-word mnemonic derives correct m/44/60/0/0/0 Ethereum address', () {
      const mnemonic = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
      final seed = Bip39.mnemonicToSeed(mnemonic);
      expect(seed.length, equals(64));

      final master = EvmHdKey.fromSeed(seed);
      final account0 = master.deriveEvmAccount(accountIndex: 0, addressIndex: 0);

      final address = Eip55.addressFromPublicKey64(account0.publicKey64);
      expect(address, equals('0x9858EfFD232B4033E47d90003D41EC34EcaEda94'));

      // Test account 0, address 1
      final account1 = master.deriveEvmAccount(accountIndex: 0, addressIndex: 1);
      final address1 = Eip55.addressFromPublicKey64(account1.publicKey64);
      expect(Eip55.isValidAddress(address1), isTrue);
      expect(address1, isNot(equals(address)));

      master.dispose();
      account0.dispose();
      account1.dispose();
    });

    test('secp256k1 sign and verify roundtrip', () {
      const mnemonic = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
      final seed = Bip39.mnemonicToSeed(mnemonic);
      final master = EvmHdKey.fromSeed(seed);
      final account = master.deriveEvmAccount(accountIndex: 0, addressIndex: 0);

      final messageHash = keccak256(hexDecode('1234567890abcdef'));
      final sig = Secp256k1.sign(messageHash, account.privateKey);

      expect(sig.r.length, equals(32));
      expect(sig.s.length, equals(32));
      expect(sig.recoveryId, anyOf(0, 1));

      final isValid = Secp256k1.verify(messageHash, sig.r, sig.s, account.publicKey64);
      expect(isValid, isTrue);

      final recovered = Secp256k1.recoverPublicKey64(
        messageHash,
        BigInt.parse(hexEncode(sig.r), radix: 16),
        BigInt.parse(hexEncode(sig.s), radix: 16),
        sig.recoveryId,
      );
      expect(recovered, equals(account.publicKey64));

      master.dispose();
      account.dispose();
    });
  });
}
