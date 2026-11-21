import 'dart:typed_data';
import 'package:chain_core_interface/chain_core_interface.dart' show Bip39;
import 'package:test/test.dart';
import 'package:sui_core/sui_core.dart';

void main() {
  group('Sui SEC-01 Guard & Signing Tests', () {
    const testMnemonic =
        'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
    final entropy = Bip39.mnemonicToEntropy(testMnemonic);
    final seed = Bip39.entropyToSeed(entropy);
    final master = SuiSlip0010Key.fromSeed(seed);
    final suiKey = master.deriveSuiAccount(accountIndex: 0, addressIndex: 0);
    final myAddress = suiKey.suiAddress;

    test('Audits valid Sui transfer and approves', () {
      final txData = SuiTransactionData.createTransfer(
        sender: myAddress,
        recipient: '0x1111111111111111111111111111111111111111111111111111111111111111',
        amountMIST: BigInt.from(1000000000), // 1 SUI
        gasPayment: [
          SuiObjectRef(
            objectId: '0x2222222222222222222222222222222222222222222222222222222222222222',
            version: BigInt.one,
            digest: '0x3333333333333333333333333333333333333333333333333333333333333333',
          ),
        ],
        gasBudget: BigInt.from(5000000), // 0.005 SUI
      );

      final req = SuiSignRequestUr(
        requestId: Uint8List(16),
        chain: 'sui',
        network: 'testnet',
        txBytes: txData.toBcs(),
        accountIndex: 0,
        addressIndex: 0,
      );

      final verdict = SuiSec01Guard.audit(
        entropy: entropy,
        request: req,
        expectedAccountIndex: 0,
        expectedAddressIndex: 0,
      );

      expect(verdict.isApproved, isTrue);
      expect(verdict.amountDisplay, contains('1.0000 SUI'));
      expect(verdict.isHighRiskContractCall, isFalse);
    });

    test('Rejects if sender does not match unlocked account', () {
      final txData = SuiTransactionData.createTransfer(
        sender: '0x9999999999999999999999999999999999999999999999999999999999999999',
        recipient: '0x1111111111111111111111111111111111111111111111111111111111111111',
        amountMIST: BigInt.from(500000000),
        gasPayment: [],
        gasBudget: BigInt.from(5000000),
      );

      final req = SuiSignRequestUr(
        requestId: Uint8List(16),
        chain: 'sui',
        network: 'testnet',
        txBytes: txData.toBcs(),
        accountIndex: 0,
        addressIndex: 0,
      );

      final verdict = SuiSec01Guard.audit(
        entropy: entropy,
        request: req,
        expectedAccountIndex: 0,
      );

      expect(verdict.isApproved, isFalse);
      expect(verdict.rejectReason, contains('không khớp với ví'));
    });

    test('auditAndSign produces valid Sui signature and roundtrips', () {
      final txData = SuiTransactionData.createTransfer(
        sender: myAddress,
        recipient: '0x1111111111111111111111111111111111111111111111111111111111111111',
        amountMIST: BigInt.from(2500000000),
        gasPayment: [
          SuiObjectRef(
            objectId: '0x2222222222222222222222222222222222222222222222222222222222222222',
            version: BigInt.two,
            digest: '0x3333333333333333333333333333333333333333333333333333333333333333',
          ),
        ],
        gasBudget: BigInt.from(10000000),
      );

      final req = SuiSignRequestUr(
        requestId: Uint8List(16),
        chain: 'sui',
        network: 'testnet',
        txBytes: txData.toBcs(),
        accountIndex: 0,
        addressIndex: 0,
      );

      final resp = SuiSec01Guard.auditAndSign(
        entropy: entropy,
        request: req,
        expectedAccountIndex: 0,
      );

      expect(resp.signature.length, equals(64));
      expect(resp.publicKey.length, equals(32));
      expect(resp.serializedSignature.length, equals(97));
      expect(resp.base64Signature.isNotEmpty, isTrue);

      // Verify Ed25519 signature over intent message
      final isValid = SuiEd25519.verify(
        message: txData.toIntentMessage(),
        signature: resp.signature,
        publicKey: resp.publicKey,
      );
      expect(isValid, isTrue);

      // Check UR roundtrip
      final ur = resp.toUr();
      final parsedResp = SuiSignResponseUr.fromUr(ur);
      expect(parsedResp.signature, equals(resp.signature));
      expect(parsedResp.publicKey, equals(resp.publicKey));
    });

    test('Flags GasCoin drain / ObjectArg transfer / multi-recipient spoofing and rejects unknown commands, trailing bytes, or network mismatch', () {
      const attacker = '0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      const friend = '0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
      final gasRef = SuiObjectRef(
        objectId: '0x2222222222222222222222222222222222222222222222222222222222222222',
        version: BigInt.one,
        digest: '0x3333333333333333333333333333333333333333333333333333333333333333',
      );

      // 1. Direct GasCoin drain without SplitCoins + multi-TransferObjects spoofing
      final drainTx = SuiTransactionData(
        v1: SuiTransactionDataV1(
          ptb: SuiProgrammableTransaction(
            inputs: [
              SuiPureCallArg.address(attacker),
              SuiPureCallArg.u64(BigInt.from(1000000)),
              SuiPureCallArg.address(friend),
            ],
            commands: [
              SuiTransferObjectsCommand(
                objects: [const SuiGasCoinArgument()],
                recipient: const SuiInputArgument(0),
              ),
              SuiSplitCoinsCommand(
                coin: const SuiGasCoinArgument(),
                amounts: [const SuiInputArgument(1)],
              ),
              SuiTransferObjectsCommand(
                objects: [const SuiResultArgument(1)],
                recipient: const SuiInputArgument(2),
              ),
            ],
          ),
          sender: myAddress,
          gasData: SuiGasData(
            payment: [gasRef],
            owner: myAddress,
            price: BigInt.from(1000),
            budget: BigInt.from(5000000),
          ),
        ),
      );
      final drainVerdict = SuiSec01Guard.audit(
        entropy: entropy,
        request: SuiSignRequestUr(
          requestId: Uint8List(16),
          chain: 'sui',
          network: 'mainnet',
          txBytes: drainTx.toBcs(),
          accountIndex: 0,
          addressIndex: 0,
        ),
        expectedAccountIndex: 0,
        expectedAddressIndex: 0,
      );
      expect(drainVerdict.isApproved, isTrue);
      expect(drainVerdict.isHighRiskContractCall, isTrue);
      expect(drainVerdict.recipientAddress, contains(attacker));
      expect(drainVerdict.recipientAddress, contains(friend));
      expect(drainVerdict.warnings.any((w) => w.contains('GasCoin')), isTrue);

      // 2. Rejects trailing bytes in txBytes
      final trailingTxBytes = Uint8List.fromList([...drainTx.toBcs(), 0xde, 0xad]);
      final trailingVerdict = SuiSec01Guard.audit(
        entropy: entropy,
        request: SuiSignRequestUr(
          requestId: Uint8List(16),
          chain: 'sui',
          network: 'mainnet',
          txBytes: trailingTxBytes,
          accountIndex: 0,
          addressIndex: 0,
        ),
        expectedAccountIndex: 0,
      );
      expect(trailingVerdict.isApproved, isFalse);

      // 3. Rejects network mismatch and accountIndex mismatch
      final netMismatch = SuiSec01Guard.audit(
        entropy: entropy,
        request: SuiSignRequestUr(
          requestId: Uint8List(16),
          chain: 'sui',
          network: 'mainnet',
          txBytes: drainTx.toBcs(),
          accountIndex: 0,
          addressIndex: 0,
        ),
        expectedAccountIndex: 0,
        expectedNetwork: 'testnet',
      );
      expect(netMismatch.isApproved, isFalse);

      final acctMismatch = SuiSec01Guard.audit(
        entropy: entropy,
        request: SuiSignRequestUr(
          requestId: Uint8List(16),
          chain: 'sui',
          network: 'mainnet',
          txBytes: drainTx.toBcs(),
          accountIndex: 3,
          addressIndex: 0,
        ),
        expectedAccountIndex: 0,
      );
      expect(acctMismatch.isApproved, isFalse);
    });
  });
}
