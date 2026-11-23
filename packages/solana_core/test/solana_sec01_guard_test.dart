import 'dart:typed_data';
import 'package:chain_core_interface/chain_core_interface.dart';
import 'package:solana_core/solana_core.dart';
import 'package:test/test.dart';

void main() {
  group('Solana SEC-01 Guard & BC-UR Air-Gap Tests', () {
    const mnemonic =
        'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
    final entropy = Bip39.mnemonicToEntropy(mnemonic);

    test('Valid SOL transfer passes SEC-01 audit and signs via auditAndSign', () {
      final seed = Bip39.entropyToSeed(entropy);
      final master = Slip0010Key.fromSeed(seed);
      final key0 = master.deriveSolanaAccount(accountIndex: 0);

      final recipient = Uint8List.fromList(List.filled(32, 0x55));
      final blockhash = Uint8List.fromList(List.filled(32, 0x88));

      final ix = SystemProgram.transfer(
        fromPubkey: key0.publicKey,
        toPubkey: recipient,
        lamports: BigInt.from(2500000000), // 2.5 SOL
      );

      final message = SolanaMessage.compile(
        feePayer: key0.publicKey,
        recentBlockhash: blockhash,
        instructions: [ix],
      );

      final requestId = Uint8List.fromList(List.filled(16, 0x99));
      final signReq = SolSignRequestUr(
        requestId: requestId,
        chain: 'solana',
        network: 'mainnet',
        messageBytes: message.serialize(),
        accountIndex: 0,
      );

      final verdict = SolanaSec01Guard.audit(
        entropy: entropy,
        request: signReq,
        expectedAccountIndex: 0,
      );

      expect(verdict.isApproved, isTrue);
      expect(verdict.recipientAddress, equals(Base58.encode(recipient)));
      expect(verdict.amountDisplay.contains('2.500000000 SOL'), isTrue);
      expect(verdict.isHighRiskContractCall, isFalse);

      final signedResp = SolanaSec01Guard.auditAndSign(
        entropy: entropy,
        request: signReq,
        expectedAccountIndex: 0,
      );

      expect(signedResp.signature.length, equals(64));
      expect(signedResp.publicKey, equals(key0.publicKey));

      final verified = Ed25519Solana.verify(
        publicKey: key0.publicKey,
        message: signReq.messageBytes,
        signature: signedResp.signature,
      );
      expect(verified, isTrue);

      master.dispose();
      key0.dispose();
    });

    test('Blocks fee payer mismatch between Cold Wallet and Sign Request', () {
      final foreignKey = Uint8List.fromList(List.filled(32, 0xee));
      final recipient = Uint8List.fromList(List.filled(32, 0x55));
      final blockhash = Uint8List.fromList(List.filled(32, 0x88));

      final ix = SystemProgram.transfer(
        fromPubkey: foreignKey,
        toPubkey: recipient,
        lamports: BigInt.from(1000000000),
      );

      final message = SolanaMessage.compile(
        feePayer: foreignKey,
        recentBlockhash: blockhash,
        instructions: [ix],
      );

      final signReq = SolSignRequestUr(
        requestId: Uint8List.fromList(List.filled(16, 0x01)),
        chain: 'solana',
        network: 'mainnet',
        messageBytes: message.serialize(),
        accountIndex: 0,
      );

      final verdict = SolanaSec01Guard.audit(
        entropy: entropy,
        request: signReq,
        expectedAccountIndex: 0,
      );

      expect(verdict.isApproved, isFalse);
      expect(verdict.rejectReason?.contains('không khớp với ví đang mở'), isTrue);
    });

    test('Flags unknown program call as high-risk contract call', () {
      final seed = Bip39.entropyToSeed(entropy);
      final master = Slip0010Key.fromSeed(seed);
      final key0 = master.deriveSolanaAccount(accountIndex: 0);

      final customProgram = Uint8List.fromList(List.filled(32, 0xcc));
      final blockhash = Uint8List.fromList(List.filled(32, 0x88));

      final ix = SolanaInstruction(
        programId: customProgram,
        accounts: [AccountMeta(pubkey: key0.publicKey, isSigner: true, isWritable: true)],
        data: Uint8List.fromList([0x01, 0x02, 0x03]),
      );

      final message = SolanaMessage.compile(
        feePayer: key0.publicKey,
        recentBlockhash: blockhash,
        instructions: [ix],
      );

      final signReq = SolSignRequestUr(
        requestId: Uint8List.fromList(List.filled(16, 0x02)),
        chain: 'solana',
        network: 'mainnet',
        messageBytes: message.serialize(),
        accountIndex: 0,
      );

      final verdict = SolanaSec01Guard.audit(
        entropy: entropy,
        request: signReq,
        expectedAccountIndex: 0,
      );

      expect(verdict.isApproved, isTrue);
      expect(verdict.isHighRiskContractCall, isTrue);
      expect(verdict.warnings.any((w) => w.contains('CẢNH BÁO RỦI RO')), isTrue);

      master.dispose();
      key0.dispose();
    });

    test('BC-UR Roundtrip for sol-account, sol-sign-request, and sol-sign-response', () {
      // 1. Account UR
      final acc = SolAccountUr(
        chain: 'solana',
        network: 'mainnet',
        accountIndex: 0,
        address: '5FHneW46xGXgs5mUiveU4sbTyGBzmstUspZC92UhjJM694ty',
        label: 'My Solana Cold Vault',
      );
      final accUr = acc.toUr();
      expect(accUr.toLowerCase().startsWith('ur:sol-account/'), isTrue);

      final decodedAcc = SolAccountUr.fromUr(accUr);
      expect(decodedAcc.address, equals(acc.address));
      expect(decodedAcc.label, equals('My Solana Cold Vault'));

      // 2. Sign Request UR
      final req = SolSignRequestUr(
        requestId: Uint8List.fromList(List.filled(16, 0x77)),
        chain: 'solana',
        network: 'devnet',
        messageBytes: Uint8List.fromList([1, 2, 3, 4, 5]),
        accountIndex: 1,
      );
      final reqUr = req.toUr();
      expect(reqUr.toLowerCase().startsWith('ur:sol-sign-request/'), isTrue);

      final decodedReq = SolSignRequestUr.fromUr(reqUr);
      expect(decodedReq.accountIndex, equals(1));
      expect(decodedReq.messageBytes, equals(req.messageBytes));

      // 3. Sign Response UR
      final resp = SolSignResponseUr(
        requestId: Uint8List.fromList(List.filled(16, 0x77)),
        signature: Uint8List.fromList(List.filled(64, 0x88)),
        publicKey: Uint8List.fromList(List.filled(32, 0x99)),
      );
      final respUr = resp.toUr();
      expect(respUr.toLowerCase().startsWith('ur:sol-sign-response/'), isTrue);

      final decodedResp = SolSignResponseUr.fromUr(respUr);
      expect(decodedResp.signature, equals(resp.signature));
      expect(decodedResp.publicKey, equals(resp.publicKey));
    });

    test('Flags multi-instruction recipient spoofing, Assign opcode, and rejects v0 / trailing bytes / network mismatch', () {
      final seed = Bip39.entropyToSeed(entropy);
      final master = Slip0010Key.fromSeed(seed);
      final key0 = master.deriveSolanaAccount(accountIndex: 0);

      final attacker = Uint8List.fromList(List.filled(32, 0xaa));
      final friend = Uint8List.fromList(List.filled(32, 0xbb));
      final blockhash = Uint8List.fromList(List.filled(32, 0x88));

      // 1. Multi-instruction spoofing: Ix 0 sends 10 SOL to attacker, Ix 1 sends 0 SOL to friend
      final ix0 = SystemProgram.transfer(
        fromPubkey: key0.publicKey,
        toPubkey: attacker,
        lamports: BigInt.from(10000000000),
      );
      final ix1 = SystemProgram.transfer(
        fromPubkey: key0.publicKey,
        toPubkey: friend,
        lamports: BigInt.zero,
      );
      final multiMsg = SolanaMessage.compile(
        feePayer: key0.publicKey,
        recentBlockhash: blockhash,
        instructions: [ix0, ix1],
      );
      final multiVerdict = SolanaSec01Guard.audit(
        entropy: entropy,
        request: SolSignRequestUr(
          requestId: Uint8List(16),
          chain: 'solana',
          network: 'mainnet-beta',
          messageBytes: multiMsg.serialize(),
          accountIndex: 0,
        ),
        expectedAccountIndex: 0,
      );
      expect(multiVerdict.isApproved, isTrue);
      expect(multiVerdict.isHighRiskContractCall, isTrue);
      expect(multiVerdict.recipientAddress, contains(Base58.encode(attacker)));
      expect(multiVerdict.recipientAddress, contains(Base58.encode(friend)));
      expect(multiVerdict.warnings.any((w) => w.contains('ĐA LỆNH')), isTrue);

      // 2. Dangerous SystemProgram Assign (opcode 1) must trigger highRisk
      final assignIx = SolanaInstruction(
        programId: SystemProgram.programId,
        accounts: [AccountMeta(pubkey: key0.publicKey, isSigner: true, isWritable: true)],
        data: Uint8List.fromList([0x01, 0x00, 0x00, 0x00, ...attacker]),
      );
      final assignMsg = SolanaMessage.compile(
        feePayer: key0.publicKey,
        recentBlockhash: blockhash,
        instructions: [assignIx],
      );
      final assignVerdict = SolanaSec01Guard.audit(
        entropy: entropy,
        request: SolSignRequestUr(
          requestId: Uint8List(16),
          chain: 'solana',
          network: 'mainnet-beta',
          messageBytes: assignMsg.serialize(),
          accountIndex: 0,
        ),
        expectedAccountIndex: 0,
      );
      expect(assignVerdict.isApproved, isTrue);
      expect(assignVerdict.isHighRiskContractCall, isTrue);
      expect(assignVerdict.warnings.any((w) => w.contains('Assign')), isTrue);

      // 3. Rejects Versioned v0 prefix and trailing bytes
      final v0Bytes = Uint8List.fromList([0x80, ...multiMsg.serialize()]);
      final v0Verdict = SolanaSec01Guard.audit(
        entropy: entropy,
        request: SolSignRequestUr(
          requestId: Uint8List(16),
          chain: 'solana',
          network: 'mainnet-beta',
          messageBytes: v0Bytes,
          accountIndex: 0,
        ),
        expectedAccountIndex: 0,
      );
      expect(v0Verdict.isApproved, isFalse);

      final trailingBytes = Uint8List.fromList([...multiMsg.serialize(), 0xde, 0xad]);
      final trailingVerdict = SolanaSec01Guard.audit(
        entropy: entropy,
        request: SolSignRequestUr(
          requestId: Uint8List(16),
          chain: 'solana',
          network: 'mainnet-beta',
          messageBytes: trailingBytes,
          accountIndex: 0,
        ),
        expectedAccountIndex: 0,
      );
      expect(trailingVerdict.isApproved, isFalse);

      // 4. Rejects network mismatch and accountIndex mismatch
      final netMismatch = SolanaSec01Guard.audit(
        entropy: entropy,
        request: SolSignRequestUr(
          requestId: Uint8List(16),
          chain: 'solana',
          network: 'mainnet-beta',
          messageBytes: multiMsg.serialize(),
          accountIndex: 0,
        ),
        expectedAccountIndex: 0,
        expectedNetwork: 'devnet',
      );
      expect(netMismatch.isApproved, isFalse);

      final acctMismatch = SolanaSec01Guard.audit(
        entropy: entropy,
        request: SolSignRequestUr(
          requestId: Uint8List(16),
          chain: 'solana',
          network: 'mainnet-beta',
          messageBytes: multiMsg.serialize(),
          accountIndex: 2,
        ),
        expectedAccountIndex: 0,
      );
      expect(acctMismatch.isApproved, isFalse);

      // 5. allowMultiAccount: true resolves accountIndex 2 and signs with derived key 2
      final key2 = master.deriveSolanaAccount(accountIndex: 2);
      final solRecipient = Uint8List.fromList(List.filled(32, 0x33));
      final msg2 = SolanaMessage.compile(
        feePayer: key2.publicKey,
        recentBlockhash: blockhash,
        instructions: [
          SystemProgram.transfer(
            fromPubkey: key2.publicKey,
            toPubkey: solRecipient,
            lamports: BigInt.from(250000000),
          ),
        ],
      );
      final req2 = SolSignRequestUr(
        requestId: Uint8List(16),
        chain: 'solana',
        network: 'mainnet-beta',
        messageBytes: msg2.serialize(),
        accountIndex: 2,
      );
      final multiAcctVerdict = SolanaSec01Guard.audit(
        entropy: entropy,
        request: req2,
        expectedAccountIndex: 0,
        expectedNetwork: 'mainnet-beta',
        allowMultiAccount: true,
      );
      expect(multiAcctVerdict.isApproved, isTrue);
      expect(multiAcctVerdict.extraDetails['Derivation Path'], equals("m/44'/501'/2'/0'"));

      final multiResp = SolanaSec01Guard.auditAndSign(
        entropy: entropy,
        request: req2,
        expectedAccountIndex: 0,
        expectedNetwork: 'mainnet-beta',
        allowMultiAccount: true,
      );
      expect(multiResp.signature.length, equals(64));

      // Still enforces expectedNetwork with allowMultiAccount: true
      final multiNetMismatch = SolanaSec01Guard.audit(
        entropy: entropy,
        request: req2,
        expectedAccountIndex: 0,
        expectedNetwork: 'devnet',
        allowMultiAccount: true,
      );
      expect(multiNetMismatch.isApproved, isFalse);

      master.dispose();
      key0.dispose();
      key2.dispose();
    });
  });
}
