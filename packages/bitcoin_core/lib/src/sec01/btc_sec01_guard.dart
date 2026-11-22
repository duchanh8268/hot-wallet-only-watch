import 'dart:typed_data';
import 'package:chain_core_interface/chain_core_interface.dart';
import '../address/bech32_segwit.dart';
import '../bc_ur/btc_ur_messages.dart';
import '../crypto/btc_hd_key.dart';
import '../crypto/secp256k1_btc.dart';
import '../transaction/btc_models.dart';
import '../transaction/btc_serializer.dart';
import '../transaction/sighash_bip143.dart';

/// Offline SEC-01 Security Audit Guard & Signer for Bitcoin Native SegWit transactions.
class BtcSec01Guard {
  const BtcSec01Guard._();

  static final BigInt _maxMoneySat = BigInt.from(21000000) * BigInt.from(100000000);

  /// Audits an incoming [BtcSignRequestUr] against the unlocked [entropy].
  static AuditVerdict audit({
    required Uint8List entropy,
    String passphrase = '',
    required BtcSignRequestUr request,
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

    final isTestnet = request.network.toLowerCase().contains('test') ||
        request.network.toLowerCase().contains('signet');
    final hrp = isTestnet ? 'tb' : 'bc';

    final seed = Bip39.entropyToSeed(entropy, passphrase: passphrase);
    final master = BtcHdKey.fromSeed(seed);

    try {
      final tx = request.transaction;
      if (tx.inputs.isEmpty) {
        return AuditVerdict.rejected('Giao dịch không có UTXO đầu vào (inputs empty)');
      }
      if (tx.outputs.isEmpty) {
        return AuditVerdict.rejected('Giao dịch không có đầu ra (outputs empty)');
      }

      // 1. Verify Input UTXO (nonWitnessUtxo + OutPoint + PrevOut Value & ScriptPubKey Ownership)
      var totalInputSat = BigInt.zero;
      final seenOutpoints = <String>{};
      for (var i = 0; i < tx.inputs.length; i++) {
        final inp = tx.inputs[i];
        final Uint8List outpointBytes;
        try {
          outpointBytes = inp.previousOutput.toBytes();
        } catch (e) {
          return AuditVerdict.rejected('UTXO đầu vào #$i có OutPoint không hợp lệ: $e');
        }
        final canonicalOutpoint = OutPoint.fromBytes(outpointBytes);
        final outpointKey = '${canonicalOutpoint.txid.toLowerCase()}:${canonicalOutpoint.vout}';
        if (!seenOutpoints.add(outpointKey)) {
          return AuditVerdict.rejected('Phát hiện UTXO đầu vào bị trùng lặp tại Input #$i ($outpointKey)');
        }
        if (inp.scriptSig.isNotEmpty) {
          return AuditVerdict.rejected('Native SegWit Input #$i không được chứa scriptSig khác rỗng');
        }

        // Require and verify full previous transaction (nonWitnessUtxo) to prevent BIP-143 amount spoofing
        final prevRaw = inp.nonWitnessUtxo;
        if (prevRaw == null || prevRaw.isEmpty) {
          return AuditVerdict.rejected(
            'UTXO đầu vào #$i thiếu dữ liệu giao dịch trước (nonWitnessUtxo) để xác thực giá trị BIP-143',
          );
        }
        final ({int version, List<BtcTxOut> outputs, int lockTime, String txid}) prevTx;
        try {
          prevTx = BtcSerializer.parseRawTransaction(prevRaw);
        } catch (e) {
          return AuditVerdict.rejected('UTXO đầu vào #$i có nonWitnessUtxo không hợp lệ: $e');
        }
        if (prevTx.txid.toLowerCase() != canonicalOutpoint.txid.toLowerCase()) {
          return AuditVerdict.rejected(
            'CẢNH BÁO AN NINH: Hash của nonWitnessUtxo (${prevTx.txid}) không khớp với TxID đầu vào #$i (${canonicalOutpoint.txid})',
          );
        }
        if (canonicalOutpoint.vout < 0 || canonicalOutpoint.vout >= prevTx.outputs.length) {
          return AuditVerdict.rejected(
            'UTXO đầu vào #$i có vout=${canonicalOutpoint.vout} vượt quá số đầu ra của nonWitnessUtxo (${prevTx.outputs.length})',
          );
        }

        final verifiedPrevOut = prevTx.outputs[canonicalOutpoint.vout];
        final verifiedSat = verifiedPrevOut.valueSat;
        if (verifiedSat <= BigInt.zero || verifiedSat > _maxMoneySat) {
          return AuditVerdict.rejected('UTXO đầu vào #$i có giá trị satoshi thực tế không hợp lệ ($verifiedSat)');
        }
        if (inp.amountSat != null && inp.amountSat! != verifiedSat) {
          return AuditVerdict.rejected(
            'CẢNH BÁO AN NINH BIP-143: Giá trị khai báo (${inp.amountSat} sats) ở UTXO #$i '
            'không khớp với giao dịch gốc ($verifiedSat sats)!',
          );
        }
        totalInputSat += verifiedSat;

        final acctIdx = inp.accountIndex ?? request.accountIndex;
        if (acctIdx != expectedAccountIndex) {
          return AuditVerdict.rejected(
            'UTXO #$i thuộc accountIndex #$acctIdx khác với ví đang mở (#$expectedAccountIndex)',
          );
        }

        final change = inp.change;
        final addrIdx = inp.addressIndex;
        if (change == null || (change != 0 && change != 1)) {
          return AuditVerdict.rejected('UTXO #$i có giá trị chain (change=$change) không hợp lệ (chỉ nhận 0 hoặc 1)');
        }
        if (addrIdx == null || addrIdx < 0 || addrIdx >= 0x80000000) {
          return AuditVerdict.rejected('UTXO #$i có addressIndex ($addrIdx) không hợp lệ');
        }

        final derived = master.deriveBip84Address(
          accountIndex: acctIdx,
          change: change,
          addressIndex: addrIdx,
          isTestnet: isTestnet,
        );
        try {
          final expectedScript = Uint8List(22);
          expectedScript[0] = 0x00;
          expectedScript[1] = 0x14;
          expectedScript.setRange(2, 22, derived.pubKeyHash);

          if (verifiedPrevOut.scriptPubKey.length != 22 ||
              !constantTimeEquals(verifiedPrevOut.scriptPubKey, expectedScript)) {
            return AuditVerdict.rejected(
              'CẢNH BÁO AN NINH: ScriptPubKey của UTXO #$i không thuộc địa chỉ '
              'm/84\'/${isTestnet ? 1 : 0}\'/$acctIdx\'/$change/$addrIdx của ví này!',
            );
          }
        } finally {
          derived.dispose();
        }
      }

      // 2. Classify Outputs & Strict Change Address Verification
      var totalOutputSat = BigInt.zero;
      final externalRecipients = <({String address, BigInt valueSat})>[];
      var sendAmountSat = BigInt.zero;
      var isHighRisk = false;
      final warnings = <String>[];
      final extraDetails = <String, String>{
        'Inputs Count': '${tx.inputs.length} UTXOs',
        'Outputs Count': '${tx.outputs.length}',
        'Total Inputs': '${_formatSats(totalInputSat)} sats',
      };

      for (var i = 0; i < tx.outputs.length; i++) {
        final out = tx.outputs[i];
        if (out.valueSat <= BigInt.zero || out.valueSat > _maxMoneySat) {
          return AuditVerdict.rejected(
            'Output #$i có giá trị satoshi không hợp lệ (${out.valueSat} sats). Chặn 0-satoshi / số âm.',
          );
        }
        totalOutputSat += out.valueSat;

        if (out.isChange) {
          // Hard-lock change address verification
          final changeIdx = out.changeIndex;
          if (changeIdx == null || changeIdx < 0 || changeIdx >= 0x80000000) {
            return AuditVerdict.rejected('Change Output #$i thiếu hoặc sai changeIndex ($changeIdx)');
          }
          final derivedChangeKey = master.deriveBip84Address(
            accountIndex: expectedAccountIndex,
            change: 1, // Change chain
            addressIndex: changeIdx,
            isTestnet: isTestnet,
          );

          final expectedProgram = derivedChangeKey.pubKeyHash;
          derivedChangeKey.dispose();

          final expectedScript = Uint8List(22);
          expectedScript[0] = 0x00;
          expectedScript[1] = 0x14;
          expectedScript.setRange(2, 22, expectedProgram);

          var matches = out.scriptPubKey.length == 22;
          if (matches) {
            for (var j = 0; j < 22; j++) {
              if (out.scriptPubKey[j] != expectedScript[j]) {
                matches = false;
                break;
              }
            }
          }

          if (!matches) {
            return AuditVerdict.rejected(
              'CẢNH BÁO AN NINH CỰC KỲ NGUY HIỂM: Địa chỉ thối (Change Address) bị đánh tráo! '
              'ScriptPubKey không khớp với địa chỉ nội bộ m/84\'/${isTestnet ? 1 : 0}\'/$expectedAccountIndex\'/1/$changeIdx.',
            );
          }
          extraDetails['Change Output #$i'] = 'Verified internal (index $changeIdx): ${_formatBtc(out.valueSat)} BTC';
        } else {
          // Payment destination
          sendAmountSat += out.valueSat;
          String addrDisplay;
          if (out.scriptPubKey.length == 22 &&
              out.scriptPubKey[0] == 0x00 &&
              out.scriptPubKey[1] == 0x14) {
            addrDisplay = Bech32Segwit.encodeP2wpkh(
              hrp: hrp,
              program20: out.scriptPubKey.sublist(2, 22),
            );
          } else {
            isHighRisk = true;
            addrDisplay = 'Script:${hexEncode(out.scriptPubKey, prefix0x: true)}';
            warnings.add('Đầu ra #$i không phải chuẩn P2WPKH Bech32');
          }
          externalRecipients.add((address: addrDisplay, valueSat: out.valueSat));
          extraDetails['Recipient Output #$i'] = '$addrDisplay (${_formatBtc(out.valueSat)} BTC)';
        }
      }

      if (externalRecipients.isEmpty) {
        warnings.add('Giao dịch tự chuyển nội bộ (không có đầu ra bên ngoài)');
      } else if (externalRecipients.length > 1) {
        isHighRisk = true;
        warnings.add(
          'CẢNH BÁO ĐA ĐẦU RA: Giao dịch gửi đến ${externalRecipients.length} địa chỉ nhận khác nhau. '
          'Vui lòng đối chiếu từng địa chỉ và số tiền bên dưới!',
        );
      }

      final recipientAddress = externalRecipients.isEmpty
          ? 'Self-Transfer (Nội bộ)'
          : externalRecipients.length == 1
              ? externalRecipients.first.address
              : externalRecipients
                  .map((r) => '${r.address} (${_formatBtc(r.valueSat)} BTC)')
                  .join('\n');

      // 3. Fee Sanity & Envelope Consistency Check
      final feeSat = totalInputSat - totalOutputSat;
      if (feeSat < BigInt.zero) {
        return AuditVerdict.rejected('Tổng giá trị đầu ra vượt quá đầu vào (âm phí)');
      }
      if (feeSat != request.feeSat) {
        return AuditVerdict.rejected(
          'Phí giao dịch tính toán ($feeSat sats) không khớp với phí khai báo trong UR (${request.feeSat} sats)',
        );
      }
      if (feeSat == BigInt.zero) {
        warnings.add('Cảnh báo: Phí mạng bằng 0 satoshi, giao dịch có thể bị từ chối');
      }

      // High fee check (> 0.01 BTC = 1,000,000 sats)
      if (feeSat > BigInt.from(1000000)) {
        isHighRisk = true;
        warnings.add('CẢNH BÁO PHÍ CAO: Phí mạng là ${_formatBtc(feeSat)} BTC');
      }

      return AuditVerdict(
        isApproved: true,
        recipientAddress: recipientAddress,
        amountDisplay: '${_formatBtc(sendAmountSat)} BTC (${_formatSats(sendAmountSat)} sats)',
        feeDisplay: '${_formatBtc(feeSat)} BTC (${_formatSats(feeSat)} sats)',
        networkDisplay: '${request.chain.toUpperCase()} (${request.network.toUpperCase()})',
        isHighRiskContractCall: isHighRisk,
        warnings: warnings,
        extraDetails: extraDetails,
      );
    } finally {
      master.dispose();
      zeroize(seed);
    }
  }

  /// Audits and signs all inputs of [request], returning a [BtcSignResponseUr].
  static BtcSignResponseUr auditAndSign({
    required Uint8List entropy,
    String passphrase = '',
    required BtcSignRequestUr request,
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
      throw StateError(verdict.rejectReason ?? 'SEC-01 audit rejected Bitcoin transaction');
    }

    final isTestnet = request.network.toLowerCase().contains('test') ||
        request.network.toLowerCase().contains('signet');
    final seed = Bip39.entropyToSeed(entropy, passphrase: passphrase);
    final master = BtcHdKey.fromSeed(seed);

    try {
      final witnesses = <BtcWitness>[];
      final tx = request.transaction;

      for (var i = 0; i < tx.inputs.length; i++) {
        final inp = tx.inputs[i];
        final verifiedPrevTx = BtcSerializer.parseRawTransaction(inp.nonWitnessUtxo!);
        final verifiedAmountSat = verifiedPrevTx.outputs[inp.previousOutput.vout].valueSat;
        final acctIdx = inp.accountIndex ?? request.accountIndex;
        final change = inp.change ?? 0;
        final addrIdx = inp.addressIndex ?? 0;

        final key = master.deriveBip84Address(
          accountIndex: acctIdx,
          change: change,
          addressIndex: addrIdx,
          isTestnet: isTestnet,
        );
        try {
          final pubKeyCompressed = key.publicKeyCompressed;
          final pubKeyHash = key.pubKeyHash;

          final sighash = Bip143Sighash.computeP2wpkhSighash(
            tx: tx,
            inputIndex: i,
            pubKeyHash20: pubKeyHash,
            amountSat: verifiedAmountSat,
            sighashType: Bip143Sighash.sighashAll,
          );

          final sigDer = Secp256k1Btc.signDer(
            sighash,
            key.privateKey,
            sighashType: Bip143Sighash.sighashAll,
          );

          // SegWit P2WPKH witness stack: [ <signature+sighash_type>, <compressed_pubkey> ]
          witnesses.add(BtcWitness([sigDer, pubKeyCompressed]));
        } finally {
          key.dispose();
        }
      }

      return BtcSignResponseUr(
        requestId: request.requestId,
        witnesses: witnesses,
      );
    } finally {
      master.dispose();
      zeroize(seed);
    }
  }

  static String _formatBtc(BigInt sats) {
    final whole = sats ~/ BigInt.from(10).pow(8);
    final remainder = (sats % BigInt.from(10).pow(8)).toString().padLeft(8, '0');
    return '$whole.$remainder';
  }

  static String _formatSats(BigInt sats) {
    return sats.toString().replaceAllMapped(
          RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
          (m) => '${m[1]},',
        );
  }
}
