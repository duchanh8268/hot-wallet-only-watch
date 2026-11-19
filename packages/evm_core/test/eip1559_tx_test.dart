import 'dart:typed_data';
import 'package:chain_core_interface/chain_core_interface.dart';
import 'package:evm_core/evm_core.dart';
import 'package:test/test.dart';

void main() {
  group('EIP-1559 Transaction Tests', () {
    test('Constructs, hashes, and signs EIP-1559 transaction', () {
      const mnemonic = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
      final seed = Bip39.mnemonicToSeed(mnemonic);
      final master = EvmHdKey.fromSeed(seed);
      final account = master.deriveEvmAccount(accountIndex: 0, addressIndex: 0);

      final tx = Eip1559Transaction(
        chainId: 1, // Ethereum Mainnet
        nonce: BigInt.zero,
        maxPriorityFeePerGas: BigInt.from(1000000000), // 1 gwei
        maxFeePerGas: BigInt.from(20000000000),        // 20 gwei
        gasLimit: BigInt.from(21000),
        to: '0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed',
        value: BigInt.from(1000000000000000000),       // 1 ETH
        data: Uint8List(0),
      );

      final hash = tx.signingHash;
      expect(hash.length, equals(32));

      final sigRes = Secp256k1.sign(hash, account.privateKey);
      final sig = EvmSignature(r: sigRes.r, s: sigRes.s, v: sigRes.recoveryId);

      final signedRaw = EvmTxSerializer.serializeEip1559Signed(tx, sig);
      expect(signedRaw.isNotEmpty, isTrue);
      expect(signedRaw[0], equals(0x02)); // EIP-1559 envelope prefix

      // Verify signature against public key
      final ok = Secp256k1.verify(hash, sig.r, sig.s, account.publicKey64);
      expect(ok, isTrue);

      master.dispose();
      account.dispose();
    });

    test('Constructs and signs Legacy transaction with EIP-155 replay protection', () {
      const mnemonic = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
      final seed = Bip39.mnemonicToSeed(mnemonic);
      final master = EvmHdKey.fromSeed(seed);
      final account = master.deriveEvmAccount(accountIndex: 0, addressIndex: 0);

      final tx = LegacyTransaction(
        chainId: 1,
        nonce: BigInt.from(9),
        gasPrice: BigInt.from(20000000000),
        gasLimit: BigInt.from(21000),
        to: '0x3535353535353535353535353535353535353535',
        value: BigInt.from(1000000000000000000),
      );

      final hash = tx.signingHash;
      expect(hash.length, equals(32));

      final sigRes = Secp256k1.sign(hash, account.privateKey);
      final sig = EvmSignature(r: sigRes.r, s: sigRes.s, v: sigRes.recoveryId);

      final signedRaw = EvmTxSerializer.serializeLegacySigned(tx, sig);
      expect(signedRaw.isNotEmpty, isTrue);

      master.dispose();
      account.dispose();
    });
  });
}
