import 'dart:typed_data';
import 'package:chain_core_interface/chain_core_interface.dart';
import '../address/base58.dart';
import '../bc_ur/sol_ur_messages.dart';
import '../crypto/ed25519_solana.dart';
import '../crypto/slip0010.dart';
import '../transaction/solana_models.dart';

/// Offline SEC-01 Security Audit Guard & Signer for Solana transactions.
class SolanaSec01Guard {
  const SolanaSec01Guard._();

  /// Audits an incoming [SolSignRequestUr] against the unlocked [entropy].
  static AuditVerdict audit({
    required Uint8List entropy,
    String passphrase = '',
    required SolSignRequestUr request,
    required int expectedAccountIndex,
    String? expectedNetwork,
  }) {
    if (request.accountIndex != expectedAccountIndex) {
      return AuditVerdict.rejected(
        'AccountIndex trong yêu cầu (${request.accountIndex}) không khớp với ví đang mở ($expectedAccountIndex)',
      );
    }

    if (expectedNetwork != null &&
        request.network.trim().toLowerCase() != expectedNetwork.trim().toLowerCase()) {
      return AuditVerdict.rejected(
        'Xung đột mạng lưới (Network Mismatch): Yêu cầu ký thuộc mạng "${request.network}" '
        'nhưng Ví Lạnh đang đặt ở mạng "$expectedNetwork".',
      );
    }

    final seed = Bip39.entropyToSeed(entropy, passphrase: passphrase);
    final master = Slip0010Key.fromSeed(seed);
    final signerKey = master.deriveSolanaAccount(accountIndex: expectedAccountIndex);

    try {
      final SolanaMessage message;
      try {
        message = request.message;
      } catch (e) {
        return AuditVerdict.rejected('Lỗi giải mã cấu trúc SolanaMessage: $e');
      }

      if (message.accountKeys.isEmpty) {
        return AuditVerdict.rejected('Giao dịch Solana không có danh sách tài khoản (accountKeys empty)');
      }

      // 1. Verify Signer / Fee Payer Ownership
      final expectedPubkey = signerKey.publicKey;
      final feePayerPubkey = message.accountKeys.first;
      var signerMatches = (expectedPubkey.length == feePayerPubkey.length);
      if (signerMatches) {
        for (var i = 0; i < 32; i++) {
          if (expectedPubkey[i] != feePayerPubkey[i]) {
            signerMatches = false;
            break;
          }
        }
      }

      if (!signerMatches) {
        return AuditVerdict.rejected(
          'Tài khoản ký chính trong giao dịch (${Base58.encode(feePayerPubkey)}) '
          'không khớp với ví đang mở (m/44\'/501\'/$expectedAccountIndex\'/0\': ${Base58.encode(expectedPubkey)})',
        );
      }

      // 2. Decode Instructions & Detect High Risk
      final warnings = <String>[];
      var isHighRisk = false;
      if (message.header.numRequiredSignatures > 1) {
        isHighRisk = true;
        warnings.add(
          'LƯU Ý: Giao dịch yêu cầu ${message.header.numRequiredSignatures} chữ ký đồng thời (Co-signers).',
        );
      }

      var totalLamports = BigInt.zero;
      final transfers = <({String to, BigInt lamports})>[];
      final extraDetails = <String, String>{
        'Người trả phí (Fee Payer)': Base58.encode(feePayerPubkey),
        'Recent Blockhash': Base58.encode(message.recentBlockhash),
        'Số lượng lệnh (Instructions)': '${message.instructions.length}',
        'Chữ ký yêu cầu': '${message.header.numRequiredSignatures}',
      };

      final sysProgBytes = SystemProgram.programId;

      for (var i = 0; i < message.instructions.length; i++) {
        final ix = message.instructions[i];
        if (ix.programIdIndex < 0 || ix.programIdIndex >= message.accountKeys.length) {
          return AuditVerdict.rejected('Chỉ số Program #$i vượt quá phạm vi danh sách tài khoản');
        }
        for (final accIdx in ix.accountIndices) {
          if (accIdx < 0 || accIdx >= message.accountKeys.length) {
            return AuditVerdict.rejected('Chỉ số tài khoản ($accIdx) trong lệnh #$i vượt quá phạm vi');
          }
        }
        final progKey = message.accountKeys[ix.programIdIndex];

        // Check if System Program
        var isSystemProgram = (progKey.length == 32);
        if (isSystemProgram) {
          for (var j = 0; j < 32; j++) {
            if (progKey[j] != sysProgBytes[j]) {
              isSystemProgram = false;
              break;
            }
          }
        }

        if (isSystemProgram) {
          // System Program instruction
          if (ix.data.length == 12 &&
              ix.data[0] == 0x02 &&
              ix.data[1] == 0x00 &&
              ix.data[2] == 0x00 &&
              ix.data[3] == 0x00) {
            // Transfer Instruction
            if (ix.accountIndices.length < 2) {
              return AuditVerdict.rejected('Lệnh SystemProgram.Transfer #$i thiếu tài khoản nguồn/đích');
            }
            var lamports = BigInt.zero;
            for (var b = 7; b >= 0; b--) {
              lamports = (lamports << 8) | BigInt.from(ix.data[4 + b]);
            }
            totalLamports += lamports;

            final fromKey = message.accountKeys[ix.accountIndices[0]];
            if (!_bytesEqual(fromKey, expectedPubkey)) {
              isHighRisk = true;
              warnings.add('Lệnh #$i chuyển tiền từ tài khoản khác: ${Base58.encode(fromKey)}');
            }

            final toAddr = Base58.encode(message.accountKeys[ix.accountIndices[1]]);
            transfers.add((to: toAddr, lamports: lamports));
            extraDetails['Transfer #$i'] = '$toAddr (${_formatSol(lamports)} SOL)';
          } else {
            isHighRisk = true;
            final opcode = ix.data.length >= 4
                ? (ix.data[0] | (ix.data[1] << 8) | (ix.data[2] << 16) | (ix.data[3] << 24))
                : (ix.data.isNotEmpty ? ix.data[0] : -1);
            final opName = switch (opcode) {
              0 => 'CreateAccount',
              1 => 'Assign (Thay đổi Program sở hữu tài khoản!)',
              3 => 'CreateAccountWithSeed',
              4 => 'AdvanceNonceAccount',
              5 => 'WithdrawNonceAccount',
              8 => 'Allocate',
              10 => 'AssignWithSeed',
              11 => 'TransferWithSeed',
              _ => 'UnknownSystemOp(#$opcode)',
            };
            warnings.add('CẢNH BÁO RỦI RO: Lệnh System Program #$i: $opName');
            extraDetails['SystemOp #$i'] = opName;
          }
        } else {
          // Unknown / Contract call
          isHighRisk = true;
          final progBase58 = Base58.encode(progKey);
          warnings.add('CẢNH BÁO RỦI RO: Giao dịch tương tác với Program / Hợp đồng thông minh lạ ($progBase58)');
          extraDetails['Program Call #$i'] = progBase58;
        }
      }

      final uniqueRecipients = transfers.map((t) => t.to).toSet();
      if (transfers.length > 1 || uniqueRecipients.length > 1) {
        isHighRisk = true;
        warnings.add(
          'CẢNH BÁO ĐA LỆNH: Giao dịch chứa ${transfers.length} lệnh chuyển SOL tới ${uniqueRecipients.length} địa chỉ nhận!',
        );
      }

      final recipientAddress = transfers.isEmpty
          ? 'N/A'
          : transfers.length == 1
              ? transfers.first.to
              : transfers.map((t) => '${t.to} (${_formatSol(t.lamports)} SOL)').join('\n');

      // Estimated standard Solana signature fee (5,000 lamports = 0.000005 SOL per signature)
      final feeLamports = BigInt.from(message.header.numRequiredSignatures * 5000);

      return AuditVerdict(
        isApproved: true,
        recipientAddress: recipientAddress,
        amountDisplay: '${_formatSol(totalLamports)} SOL (${_formatLamports(totalLamports)} lamports)',
        feeDisplay: '${_formatSol(feeLamports)} SOL (${_formatLamports(feeLamports)} lamports)',
        networkDisplay: '${request.chain.toUpperCase()} (${request.network.toUpperCase()})',
        isHighRiskContractCall: isHighRisk,
        warnings: warnings,
        extraDetails: extraDetails,
      );
    } finally {
      master.dispose();
      signerKey.dispose();
      Ed25519Solana.zeroize(seed);
    }
  }

  /// Audits and signs the Solana transaction, returning [SolSignResponseUr].
  static SolSignResponseUr auditAndSign({
    required Uint8List entropy,
    String passphrase = '',
    required SolSignRequestUr request,
    required int expectedAccountIndex,
    String? expectedNetwork,
  }) {
    final verdict = audit(
      entropy: entropy,
      passphrase: passphrase,
      request: request,
      expectedAccountIndex: expectedAccountIndex,
      expectedNetwork: expectedNetwork,
    );

    if (!verdict.isApproved) {
      throw StateError(verdict.rejectReason ?? 'Giao dịch bị từ chối bởi kiểm toán SEC-01');
    }

    final seed = Bip39.entropyToSeed(entropy, passphrase: passphrase);
    final master = Slip0010Key.fromSeed(seed);
    final signerKey = master.deriveSolanaAccount(accountIndex: expectedAccountIndex);

    try {
      final sig = signerKey.sign(request.messageBytes);
      return SolSignResponseUr(
        requestId: request.requestId,
        signature: sig,
        publicKey: signerKey.publicKey,
      );
    } finally {
      master.dispose();
      signerKey.dispose();
      Ed25519Solana.zeroize(seed);
    }
  }

  static String _formatSol(BigInt lamports) {
    final doubleVal = lamports.toDouble() / 1e9;
    return doubleVal.toStringAsFixed(9);
  }

  static String _formatLamports(BigInt lamports) {
    return lamports.toString().replaceAllMapped(
      RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
      (Match m) => '${m[1]},',
    );
  }

  static bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}
