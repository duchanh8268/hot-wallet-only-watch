import 'dart:typed_data';
import 'package:bitcoin_core/bitcoin_core.dart';
import 'package:chain_core_interface/chain_core_interface.dart' show Bip39, hexEncode;
import 'package:test/test.dart';

void main() {
  group('Bitcoin SEC-01 Guard & BC-UR Air-Gap Tests', () {
    const mnemonic =
        'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
    final entropy = Bip39.mnemonicToEntropy(mnemonic);

    ({BtcUtxo utxo, OutPoint outpoint, Uint8List rawTx}) makeFundingUtxo({
      required Uint8List pubKeyHash20,
      required BigInt valueSat,
      int accountIndex = 0,
      int change = 0,
      int addressIndex = 0,
      int vout = 0,
      int seedByte = 0x11,
      bool segwitFunding = true,
    }) {
      final dummyPrevTx = BtcTransaction(
        version: 2,
        inputs: [
          BtcTxIn(
            previousOutput: OutPoint(txid: hexEncode(Uint8List.fromList(List.filled(32, seedByte))), vout: 0),
            witness: segwitFunding
                ? BtcWitness([Uint8List.fromList(List.filled(71, 0x30)), Uint8List.fromList(List.filled(33, 0x02))])
                : const BtcWitness(),
          ),
        ],
        outputs: [
          for (var i = 0; i < vout; i++)
            BtcTxOut.p2wpkh(valueSat: BigInt.from(1000), program20: Uint8List(20)),
          BtcTxOut.p2wpkh(valueSat: valueSat, program20: pubKeyHash20),
        ],
      );
      final rawTx = BtcSerializer.serialize(dummyPrevTx);
      final txid = BtcSerializer.computeTxId(dummyPrevTx);
      final outpoint = OutPoint(txid: txid, vout: vout);
      return (
        utxo: BtcUtxo(
          outpoint: outpoint,
          valueSat: valueSat,
          accountIndex: accountIndex,
          change: change,
          addressIndex: addressIndex,
          nonWitnessUtxo: rawTx,
        ),
        outpoint: outpoint,
        rawTx: rawTx,
      );
    }

    test('Valid Bitcoin SegWit transaction passes SEC-01 audit and signs via auditAndSign', () {
      final master = BtcHdKey.fromSeed(Bip39.mnemonicToSeed(mnemonic));
      final key0 = master.deriveBip84Address(accountIndex: 0, change: 0, addressIndex: 0);
      final keyChange = master.deriveBip84Address(accountIndex: 0, change: 1, addressIndex: 0);

      final changeAddr = Bech32Segwit.encodeP2wpkh(hrp: 'bc', program20: keyChange.pubKeyHash);
      const recipientAddr = 'bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4';

      final funded = makeFundingUtxo(
        pubKeyHash20: key0.pubKeyHash,
        valueSat: BigInt.from(200000),
      );
      final utxos = [funded.utxo];

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
      final key0 = master.deriveBip84Address(accountIndex: 0, change: 0, addressIndex: 0);
      final funded = makeFundingUtxo(pubKeyHash20: key0.pubKeyHash, valueSat: BigInt.from(100000), seedByte: 0x44);
      final attackerKey = master.deriveBip84Address(accountIndex: 99, change: 1, addressIndex: 99);
      final attackerChangeScript = Uint8List.fromList([0x00, 0x14, ...attackerKey.pubKeyHash]);

      final tx = BtcTransaction(
        version: 2,
        inputs: [
          BtcTxIn(
            previousOutput: funded.outpoint,
            amountSat: BigInt.from(100000),
            accountIndex: 0,
            change: 0,
            addressIndex: 0,
            nonWitnessUtxo: funded.rawTx,
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
      final key0 = master.deriveBip84Address(accountIndex: 0, change: 0, addressIndex: 0);
      final funded = makeFundingUtxo(pubKeyHash20: key0.pubKeyHash, valueSat: BigInt.from(100000), seedByte: 0x66);
      final attackerKey = master.deriveBip84Address(accountIndex: 99, change: 0, addressIndex: 0);
      final attackerAddr = Bech32Segwit.encodeP2wpkh(hrp: 'bc', program20: attackerKey.pubKeyHash);

      // 1. 0-satoshi output spoofing
      final zeroOutTx = BtcTransaction(
        inputs: [
          BtcTxIn(
            previousOutput: funded.outpoint,
            amountSat: BigInt.from(100000),
            accountIndex: 0,
            change: 0,
            addressIndex: 0,
            nonWitnessUtxo: funded.rawTx,
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
            previousOutput: funded.outpoint,
            amountSat: BigInt.from(100000),
            accountIndex: 0,
            change: 0,
            addressIndex: 0,
            nonWitnessUtxo: funded.rawTx,
          ),
          BtcTxIn(
            previousOutput: funded.outpoint,
            amountSat: BigInt.from(100000),
            accountIndex: 0,
            change: 0,
            addressIndex: 0,
            nonWitnessUtxo: funded.rawTx,
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
            previousOutput: funded.outpoint,
            amountSat: BigInt.from(100000),
            accountIndex: 0,
            change: 0,
            addressIndex: 0,
            nonWitnessUtxo: funded.rawTx,
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
      key0.dispose();
      attackerKey.dispose();
    });

    test('Blocks missing nonWitnessUtxo, mismatched txid, BIP-143 fee spoof, and wrong scriptPubKey', () {
      final master = BtcHdKey.fromSeed(Bip39.mnemonicToSeed(mnemonic));
      final key0 = master.deriveBip84Address(accountIndex: 0, change: 0, addressIndex: 0);
      final key1 = master.deriveBip84Address(accountIndex: 0, change: 0, addressIndex: 1);
      final otherKey = master.deriveBip84Address(accountIndex: 99, change: 0, addressIndex: 0);

      final funded0 = makeFundingUtxo(pubKeyHash20: key0.pubKeyHash, valueSat: BigInt.from(1000000), seedByte: 0x71, addressIndex: 0);
      final funded1 = makeFundingUtxo(pubKeyHash20: key1.pubKeyHash, valueSat: BigInt.from(5000000), seedByte: 0x72, addressIndex: 1);
      const destAddr = 'bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4';

      // A. Missing nonWitnessUtxo
      final missingPrev = BtcTransaction(
        inputs: [
          BtcTxIn(
            previousOutput: funded0.outpoint,
            amountSat: BigInt.from(1000000),
            accountIndex: 0,
            change: 0,
            addressIndex: 0,
          ),
        ],
        outputs: [BtcTxOut.fromAddress(valueSat: BigInt.from(998000), address: destAddr)],
      );
      final vMissing = BtcSec01Guard.audit(
        entropy: entropy,
        request: BtcSignRequestUr(
          requestId: Uint8List(16),
          chain: 'bitcoin',
          network: 'mainnet',
          transaction: missingPrev,
          accountIndex: 0,
          feeSat: BigInt.from(2000),
        ),
        expectedAccountIndex: 0,
      );
      expect(vMissing.isApproved, isFalse);
      expect(vMissing.rejectReason, contains('nonWitnessUtxo'));

      // B. Split-request BIP-143 fee spoof: inp1 declares amountSat=10000 when actual funded1 is 5000000
      final spoofedAmt = BtcTransaction(
        inputs: [
          BtcTxIn(
            previousOutput: funded0.outpoint,
            amountSat: BigInt.from(1000000),
            accountIndex: 0,
            change: 0,
            addressIndex: 0,
            nonWitnessUtxo: funded0.rawTx,
          ),
          BtcTxIn(
            previousOutput: funded1.outpoint,
            amountSat: BigInt.from(10000), // Spoofed down!
            accountIndex: 0,
            change: 0,
            addressIndex: 1,
            nonWitnessUtxo: funded1.rawTx,
          ),
        ],
        outputs: [BtcTxOut.fromAddress(valueSat: BigInt.from(1008000), address: destAddr)],
      );
      final vSpoof = BtcSec01Guard.audit(
        entropy: entropy,
        request: BtcSignRequestUr(
          requestId: Uint8List(16),
          chain: 'bitcoin',
          network: 'mainnet',
          transaction: spoofedAmt,
          accountIndex: 0,
          feeSat: BigInt.from(2000),
        ),
        expectedAccountIndex: 0,
      );
      expect(vSpoof.isApproved, isFalse);
      expect(vSpoof.rejectReason, contains('BIP-143'));

      // C. nonWitnessUtxo whose hash does not match previousOutput.txid
      final wrongHash = BtcTransaction(
        inputs: [
          BtcTxIn(
            previousOutput: funded0.outpoint,
            amountSat: BigInt.from(5000000),
            accountIndex: 0,
            change: 0,
            addressIndex: 0,
            nonWitnessUtxo: funded1.rawTx,
          ),
        ],
        outputs: [BtcTxOut.fromAddress(valueSat: BigInt.from(4998000), address: destAddr)],
      );
      final vWrongHash = BtcSec01Guard.audit(
        entropy: entropy,
        request: BtcSignRequestUr(
          requestId: Uint8List(16),
          chain: 'bitcoin',
          network: 'mainnet',
          transaction: wrongHash,
          accountIndex: 0,
          feeSat: BigInt.from(2000),
        ),
        expectedAccountIndex: 0,
      );
      expect(vWrongHash.isApproved, isFalse);
      expect(vWrongHash.rejectReason, contains('nonWitnessUtxo'));

      // D. scriptPubKey of funded output belongs to another key (not derived key0)
      final foreignFunded = makeFundingUtxo(pubKeyHash20: otherKey.pubKeyHash, valueSat: BigInt.from(100000), seedByte: 0x73);
      final wrongScript = BtcTransaction(
        inputs: [
          BtcTxIn(
            previousOutput: foreignFunded.outpoint,
            amountSat: BigInt.from(100000),
            accountIndex: 0,
            change: 0,
            addressIndex: 0,
            nonWitnessUtxo: foreignFunded.rawTx,
          ),
        ],
        outputs: [BtcTxOut.fromAddress(valueSat: BigInt.from(98000), address: destAddr)],
      );
      final vWrongScript = BtcSec01Guard.audit(
        entropy: entropy,
        request: BtcSignRequestUr(
          requestId: Uint8List(16),
          chain: 'bitcoin',
          network: 'mainnet',
          transaction: wrongScript,
          accountIndex: 0,
          feeSat: BigInt.from(2000),
        ),
        expectedAccountIndex: 0,
      );
      expect(vWrongScript.isApproved, isFalse);
      expect(vWrongScript.rejectReason, contains('ScriptPubKey'));

      master.dispose();
      key0.dispose();
      key1.dispose();
      otherKey.dispose();
    });
  });
}
