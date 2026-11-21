import 'dart:typed_data';
import 'package:bitcoin_core/bitcoin_core.dart';
import 'package:chain_core_interface/chain_core_interface.dart' show Bip39;
import 'package:test/test.dart';

void main() {
  group('Bitcoin SEC-01 Guard & BC-UR Air-Gap Tests', () {
    const mnemonic =
        'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
    final entropy = Bip39.mnemonicToEntropy(mnemonic);

    test('Valid Bitcoin SegWit transaction passes SEC-01 audit and signs via auditAndSign', () {
      final master = BtcHdKey.fromSeed(Bip39.mnemonicToSeed(mnemonic));
      final key0 = master.deriveBip84Address(accountIndex: 0, change: 0, addressIndex: 0);
      final keyChange = master.deriveBip84Address(accountIndex: 0, change: 1, addressIndex: 0);

      final changeAddr = Bech32Segwit.encodeP2wpkh(hrp: 'bc', program20: keyChange.pubKeyHash);
      const recipientAddr = 'bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4';

      final utxos = [
        BtcUtxo(
          outpoint: const OutPoint(txid: '3333333333333333333333333333333333333333333333333333333333333333', vout: 0),
          valueSat: BigInt.from(200000),
          accountIndex: 0,
          change: 0,
          addressIndex: 0,
        ),
      ];

      final build = BtcTxBuilder.buildP2wpkhTx(
        availableUtxos: utxos,
        recipientAddress: recipientAddr,
        amountSat: BigInt.from(150000),
        changeAddress: changeAddr,
        changeIndex: 0,
        feeRateSatPerVb: 5,
      );

      final reqId = Uint8List.fromList(List.filled(16, 0xaa));
      final signReq = BtcSignRequestUr(
        requestId: reqId,
        chain: 'bitcoin',
        network: 'mainnet',
        transaction: build.transaction,
        accountIndex: 0,
        feeSat: build.feeSat,
      );

      final verdict = BtcSec01Guard.audit(
        entropy: entropy,
        request: signReq,
        expectedAccountIndex: 0,
      );

      expect(verdict.isApproved, isTrue);
      expect(verdict.recipientAddress, equals(recipientAddr));
      expect(verdict.amountDisplay.contains('0.00150000 BTC'), isTrue);

      final response = BtcSec01Guard.auditAndSign(
        entropy: entropy,
        request: signReq,
        expectedAccountIndex: 0,
      );

      expect(response.witnesses.length, equals(1));
      expect(response.witnesses[0].items.length, equals(2)); // sig + pubkey

      master.dispose();
      key0.dispose();
      keyChange.dispose();
    });

    test('SEC-01 Guard hard-locks and rejects tampered change address attack', () {
      final master = BtcHdKey.fromSeed(Bip39.mnemonicToSeed(mnemonic));
      final attackerKey = master.deriveBip84Address(accountIndex: 99, change: 1, addressIndex: 99);
      final attackerChangeScript = Uint8List.fromList([0x00, 0x14, ...attackerKey.pubKeyHash]);

      final tx = BtcTransaction(
        version: 2,
        inputs: [
          BtcTxIn(
            previousOutput: const OutPoint(txid: '4444444444444444444444444444444444444444444444444444444444444444', vout: 0),
            amountSat: BigInt.from(100000),
            accountIndex: 0,
            change: 0,
            addressIndex: 0,
          ),
        ],
        outputs: [
          BtcTxOut.fromAddress(
            valueSat: BigInt.from(50000),
            address: 'bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4',
          ),
          BtcTxOut(
            valueSat: BigInt.from(48000),
            scriptPubKey: attackerChangeScript, // Tampered change!
            isChange: true,
            changeIndex: 0, // Claiming to be change #0
          ),
        ],
      );

      final signReq = BtcSignRequestUr(
        requestId: Uint8List(16),
        chain: 'bitcoin',
        network: 'mainnet',
        transaction: tx,
        accountIndex: 0,
        feeSat: BigInt.from(2000),
      );

      final verdict = BtcSec01Guard.audit(
        entropy: entropy,
        request: signReq,
        expectedAccountIndex: 0,
      );

      expect(verdict.isApproved, isFalse);
      expect(verdict.rejectReason!.contains('Địa chỉ thối (Change Address) bị đánh tráo'), isTrue);

      master.dispose();
      attackerKey.dispose();
    });

    test('BC-UR Roundtrip for btc-account, btc-sign-request, btc-sign-response', () {
      // 1. btc-account
      final acct = BtcAccountUr(
        chain: 'bitcoin',
        network: 'mainnet',
        accountIndex: 0,
        receiveAddress: 'bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu',
        masterFingerprint: 0x12345678,
        label: 'My Bitcoin Cold Vault',
      );
      final acctUr = acct.toUr();
      expect(acctUr.toLowerCase().startsWith('ur:btc-account/'), isTrue);
      final parsedAcct = BtcAccountUr.fromUr(acctUr);
      expect(parsedAcct.receiveAddress, equals(acct.receiveAddress));
      expect(parsedAcct.accountIndex, equals(0));
      expect(parsedAcct.label, equals('My Bitcoin Cold Vault'));

      // 2. btc-sign-response
      final resp = BtcSignResponseUr(
        requestId: Uint8List.fromList(List.filled(16, 0x55)),
        witnesses: [
          BtcWitness([Uint8List.fromList([1, 2, 3]), Uint8List.fromList([4, 5, 6])]),
        ],
      );
      final respUr = resp.toUr();
      expect(respUr.toLowerCase().startsWith('ur:btc-sign-response/'), isTrue);
      final parsedResp = BtcSignResponseUr.fromUr(respUr);
      expect(parsedResp.witnesses.length, equals(1));
      expect(parsedResp.witnesses[0].items[0], equals(Uint8List.fromList([1, 2, 3])));
    });

    test('Rejects 0-satoshi output spoofing, duplicate OutPoint, fee mismatch, and network mismatch', () {
      final master = BtcHdKey.fromSeed(Bip39.mnemonicToSeed(mnemonic));
      final attackerKey = master.deriveBip84Address(accountIndex: 99, change: 0, addressIndex: 0);
      final attackerAddr = Bech32Segwit.encodeP2wpkh(hrp: 'bc', program20: attackerKey.pubKeyHash);
      const validTxid = '6666666666666666666666666666666666666666666666666666666666666666';

      // 1. 0-satoshi output spoofing
      final zeroOutTx = BtcTransaction(
        inputs: [
          BtcTxIn(
            previousOutput: const OutPoint(txid: validTxid, vout: 0),
            amountSat: BigInt.from(100000),
            accountIndex: 0,
            change: 0,
            addressIndex: 0,
          ),
        ],
        outputs: [
          BtcTxOut.fromAddress(
            valueSat: BigInt.zero,
            address: 'bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4',
          ),
          BtcTxOut.fromAddress(
            valueSat: BigInt.from(98000),
            address: attackerAddr,
          ),
        ],
      );
      final zeroVerdict = BtcSec01Guard.audit(
        entropy: entropy,
        request: BtcSignRequestUr(
          requestId: Uint8List(16),
          chain: 'bitcoin',
          network: 'mainnet',
          transaction: zeroOutTx,
          accountIndex: 0,
          feeSat: BigInt.from(2000),
        ),
        expectedAccountIndex: 0,
      );
      expect(zeroVerdict.isApproved, isFalse);

      // 2. Duplicate OutPoint
      final dupInTx = BtcTransaction(
        inputs: [
          BtcTxIn(
            previousOutput: const OutPoint(txid: validTxid, vout: 0),
            amountSat: BigInt.from(100000),
            accountIndex: 0,
            change: 0,
            addressIndex: 0,
          ),
          BtcTxIn(
            previousOutput: const OutPoint(txid: validTxid, vout: 0),
            amountSat: BigInt.from(100000),
            accountIndex: 0,
            change: 0,
            addressIndex: 0,
          ),
        ],
        outputs: [
          BtcTxOut.fromAddress(
            valueSat: BigInt.from(198000),
            address: attackerAddr,
          ),
        ],
      );
      final dupVerdict = BtcSec01Guard.audit(
        entropy: entropy,
        request: BtcSignRequestUr(
          requestId: Uint8List(16),
          chain: 'bitcoin',
          network: 'mainnet',
          transaction: dupInTx,
          accountIndex: 0,
          feeSat: BigInt.from(2000),
        ),
        expectedAccountIndex: 0,
      );
      expect(dupVerdict.isApproved, isFalse);
      expect(dupVerdict.rejectReason, contains('trùng lặp'));

      // 3. Multi-output displays ALL recipients and flags highRisk
      final multiOutTx = BtcTransaction(
        inputs: [
          BtcTxIn(
            previousOutput: const OutPoint(txid: validTxid, vout: 0),
            amountSat: BigInt.from(100000),
            accountIndex: 0,
            change: 0,
            addressIndex: 0,
          ),
        ],
        outputs: [
          BtcTxOut.fromAddress(
            valueSat: BigInt.from(1000),
            address: 'bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4',
          ),
          BtcTxOut.fromAddress(
            valueSat: BigInt.from(97000),
            address: attackerAddr,
          ),
        ],
      );
      final multiVerdict = BtcSec01Guard.audit(
        entropy: entropy,
        request: BtcSignRequestUr(
          requestId: Uint8List(16),
          chain: 'bitcoin',
          network: 'mainnet',
          transaction: multiOutTx,
          accountIndex: 0,
          feeSat: BigInt.from(2000),
        ),
        expectedAccountIndex: 0,
      );
      expect(multiVerdict.isApproved, isTrue);
      expect(multiVerdict.isHighRiskContractCall, isTrue);
      expect(multiVerdict.recipientAddress, contains('bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4'));
      expect(multiVerdict.recipientAddress, contains(attackerAddr));

      // 4. Fee mismatch & Network mismatch
      final feeMismatch = BtcSec01Guard.audit(
        entropy: entropy,
        request: BtcSignRequestUr(
          requestId: Uint8List(16),
          chain: 'bitcoin',
          network: 'mainnet',
          transaction: multiOutTx,
          accountIndex: 0,
          feeSat: BigInt.from(500),
        ),
        expectedAccountIndex: 0,
      );
      expect(feeMismatch.isApproved, isFalse);

      final netMismatch = BtcSec01Guard.audit(
        entropy: entropy,
        request: BtcSignRequestUr(
          requestId: Uint8List(16),
          chain: 'bitcoin',
          network: 'mainnet',
          transaction: multiOutTx,
          accountIndex: 0,
          feeSat: BigInt.from(2000),
        ),
        expectedAccountIndex: 0,
        expectedNetwork: 'testnet4',
      );
      expect(netMismatch.isApproved, isFalse);
      expect(netMismatch.rejectReason, contains('Network Mismatch'));

      master.dispose();
      attackerKey.dispose();
    });
  });
}
