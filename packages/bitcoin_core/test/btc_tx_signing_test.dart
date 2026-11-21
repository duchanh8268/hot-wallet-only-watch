import 'package:bitcoin_core/bitcoin_core.dart';
import 'package:chain_core_interface/chain_core_interface.dart' show Bip39;
import 'package:test/test.dart';

void main() {
  group('Bitcoin SegWit Transaction Building & Signing Tests', () {
    const mnemonic =
        'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';

    late BtcHdKey master;

    setUp(() {
      final seed = Bip39.mnemonicToSeed(mnemonic);
      master = BtcHdKey.fromSeed(seed);
    });

    tearDown(() {
      master.dispose();
    });

    test('BtcTxBuilder creates valid P2WPKH tx with change and verifies BIP-143 signature', () {
      final key0 = master.deriveBip84Address(accountIndex: 0, change: 0, addressIndex: 0);
      final keyChange = master.deriveBip84Address(accountIndex: 0, change: 1, addressIndex: 0);

      final changeAddr = Bech32Segwit.encodeP2wpkh(hrp: 'bc', program20: keyChange.pubKeyHash);
      const recipientAddr = 'bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4';

      final utxos = [
        BtcUtxo(
          outpoint: const OutPoint(
            txid: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
            vout: 0,
          ),
          valueSat: BigInt.from(100000), // 100,000 sats
          accountIndex: 0,
          change: 0,
          addressIndex: 0,
          pubKeyHash: key0.pubKeyHash,
        ),
      ];

      final build = BtcTxBuilder.buildP2wpkhTx(
        availableUtxos: utxos,
        recipientAddress: recipientAddr,
        amountSat: BigInt.from(40000), // Send 40,000 sats
        changeAddress: changeAddr,
        changeIndex: 0,
        feeRateSatPerVb: 5,
      );

      final tx = build.transaction;
      expect(tx.inputs.length, equals(1));
      expect(tx.outputs.length, equals(2)); // Recipient + Change
      expect(build.sendAmountSat, equals(BigInt.from(40000)));
      expect(build.feeSat, greaterThan(BigInt.zero));
      expect(build.changeSat! + build.sendAmountSat + build.feeSat, equals(BigInt.from(100000)));

      // Sign input with BIP-143 sighash
      final sighash = Bip143Sighash.computeP2wpkhSighash(
        tx: tx,
        inputIndex: 0,
        pubKeyHash20: key0.pubKeyHash,
        amountSat: BigInt.from(100000),
      );

      final sigDer = Secp256k1Btc.signDer(sighash, key0.privateKey);
      expect(sigDer.last, equals(0x01)); // SIGHASH_ALL

      final derWithoutSighash = sigDer.sublist(0, sigDer.length - 1);
      final verified = Secp256k1Btc.verifyDer(sighash, derWithoutSighash, key0.publicKeyCompressed);
      expect(verified, isTrue);

      // Attach witness and serialize
      tx.inputs[0].witness = BtcWitness([sigDer, key0.publicKeyCompressed]);
      final rawTx = BtcSerializer.serialize(tx);
      expect(rawTx[4], equals(0x00)); // SegWit marker
      expect(rawTx[5], equals(0x01)); // SegWit flag
      expect(rawTx.length, greaterThan(150));

      key0.dispose();
      keyChange.dispose();
    });

    test('BtcTxBuilder Send Max sweeps all UTXOs with zero change output', () {
      final key0 = master.deriveBip84Address(accountIndex: 0, change: 0, addressIndex: 0);
      final keyChange = master.deriveBip84Address(accountIndex: 0, change: 1, addressIndex: 0);

      final changeAddr = Bech32Segwit.encodeP2wpkh(hrp: 'bc', program20: keyChange.pubKeyHash);
      const recipientAddr = 'bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4';

      final utxos = [
        BtcUtxo(
          outpoint: const OutPoint(txid: '1111111111111111111111111111111111111111111111111111111111111111', vout: 0),
          valueSat: BigInt.from(50000),
          accountIndex: 0,
          change: 0,
          addressIndex: 0,
        ),
        BtcUtxo(
          outpoint: const OutPoint(txid: '2222222222222222222222222222222222222222222222222222222222222222', vout: 1),
          valueSat: BigInt.from(30000),
          accountIndex: 0,
          change: 0,
          addressIndex: 1,
        ),
      ];

      final build = BtcTxBuilder.buildP2wpkhTx(
        availableUtxos: utxos,
        recipientAddress: recipientAddr,
        amountSat: BigInt.zero,
        changeAddress: changeAddr,
        changeIndex: 0,
        feeRateSatPerVb: 10,
        sendMax: true,
      );

      expect(build.transaction.inputs.length, equals(2));
      expect(build.transaction.outputs.length, equals(1)); // Only recipient, no change
      expect(build.changeSat, isNull);
      expect(build.totalInputSat, equals(BigInt.from(80000)));
      expect(build.sendAmountSat + build.feeSat, equals(BigInt.from(80000)));

      key0.dispose();
      keyChange.dispose();
    });
  });
}
