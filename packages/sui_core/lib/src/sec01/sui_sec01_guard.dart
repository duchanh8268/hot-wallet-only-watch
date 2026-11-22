import 'dart:typed_data';
import 'package:chain_core_interface/chain_core_interface.dart'
    show AuditVerdict, Bip39, constantTimeEquals;
import '../bcs/bcs.dart';
import '../bc_ur/sui_ur_messages.dart';
import '../crypto/sui_keys.dart';
import '../transaction/sui_models.dart';

/// Offline SEC-01 Security Audit Guard & Signer for Sui transactions.
class SuiSec01Guard {
  const SuiSec01Guard._();

  /// Audits an incoming [SuiSignRequestUr] against the unlocked [entropy].
  static AuditVerdict audit({
    required Uint8List entropy,
    String passphrase = '',
    required SuiSignRequestUr request,
    required int expectedAccountIndex,
    int expectedAddressIndex = 0,
    String? expectedNetwork,
  }) {
    if (request.accountIndex != expectedAccountIndex ||
        request.addressIndex != expectedAddressIndex) {
      return AuditVerdict.rejected(
        'Chỉ số dẫn xuất trong yêu cầu (account=${request.accountIndex}, address=${request.addressIndex}) '
        'không khớp với ví đang mở (account=$expectedAccountIndex, address=$expectedAddressIndex)',
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
    final master = SuiSlip0010Key.fromSeed(seed);
    final signerKey = master.deriveSuiAccount(
      accountIndex: expectedAccountIndex,
      addressIndex: expectedAddressIndex,
    );

    try {
      final SuiTransactionData txData;
      try {
        txData = request.transactionData;
      } catch (e) {
        return AuditVerdict.rejected('Lỗi giải mã BCS SuiTransactionData: $e');
      }

      // Canonical BCS Round-Trip Check: guarantees 1-to-1 equality with signed bytes
      final canonicalBcs = txData.toBcs();
      if (!constantTimeEquals(canonicalBcs, request.txBytes)) {
        return AuditVerdict.rejected(
          'Cảnh báo: Payload BCS giao dịch Sui không chính tắc (Canonical BCS mismatch)',
        );
      }

      final sender = txData.v1.sender.toLowerCase();
      final expectedAddress = signerKey.suiAddress.toLowerCase();

      // 1. Verify Sender Address Ownership
      if (sender != expectedAddress) {
        return AuditVerdict.rejected(
          'Người gửi trong giao dịch ($sender) không khớp với ví '
          '(m/44\'/784\'/$expectedAccountIndex\'/0\'/$expectedAddressIndex\': $expectedAddress)',
        );
      }

      // 2. Verify Gas Owner & Budget
      final gasOwner = txData.v1.gasData.owner.toLowerCase();
      if (gasOwner != expectedAddress) {
        return AuditVerdict.rejected(
          'Người trả phí Gas ($gasOwner) không khớp với người gửi ($expectedAddress)',
        );
      }

      final gasBudget = txData.v1.gasData.budget;
      final maxBudget = BigInt.from(50) * BigInt.from(1000000000); // 50 SUI
      if (gasBudget > maxBudget) {
        return AuditVerdict.rejected(
          'Ngân sách phí Gas vượt quá giới hạn an toàn 50 SUI: ${_formatMist(gasBudget)} SUI',
        );
      }

      // 3. Inspect PTB Commands thoroughly
      final ptb = txData.v1.ptb;
      if (ptb.commands.isEmpty) {
        return AuditVerdict.rejected('Giao dịch Sui PTB không có lệnh thực thi nào');
      }

      final warnings = <String>[];
      var isHighRisk = false;
      var gasCoinTaintedByMerge = false;
      var totalMist = BigInt.zero;
      final splitCmdInfos = <int, _SuiSplitInfo>{};
      final recipients = <String>[];
      final extraDetails = <String, String>{
        'Người gửi (Sender)': txData.v1.sender,
        'Ngân sách Gas (Budget)': '${_formatNumber(gasBudget)} MIST',
        'Giá Gas': '${_formatNumber(txData.v1.gasData.price)} MIST',
        'Số lượng Coin trả phí': '${txData.v1.gasData.payment.length}',
        'Số lượng lệnh (Commands)': '${ptb.commands.length}',
      };

      for (var cmdIdx = 0; cmdIdx < ptb.commands.length; cmdIdx++) {
        final cmd = ptb.commands[cmdIdx];
        if (cmd is SuiSplitCoinsCommand) {
          var isGasCoinSource = cmd.coin is SuiGasCoinArgument && !gasCoinTaintedByMerge;
          if (cmd.coin is SuiResultArgument) {
            final srcInfo = splitCmdInfos[(cmd.coin as SuiResultArgument).index];
            if (srcInfo != null && srcInfo.isTaintedByMerge) {
              isHighRisk = true;
              warnings.add(
                'Lệnh #$cmdIdx: SplitCoins tách từ kết quả đã qua MergeCoins (#${(cmd.coin as SuiResultArgument).index})',
              );
            }
            isGasCoinSource = false;
          } else if (cmd.coin is! SuiGasCoinArgument) {
            isHighRisk = true;
            warnings.add('Lệnh #$cmdIdx: SplitCoins từ một Coin/Object khác ngoài GasCoin');
          } else if (gasCoinTaintedByMerge) {
            isHighRisk = true;
            warnings.add('Lệnh #$cmdIdx: SplitCoins từ GasCoin đã bị gộp thêm Object trước đó');
          }
          final cmdAmounts = <BigInt>[];
          for (final amtArg in cmd.amounts) {
            if (amtArg is! SuiInputArgument ||
                amtArg.index < 0 ||
                amtArg.index >= ptb.inputs.length) {
              return AuditVerdict.rejected(
                'Lệnh SplitCoins #$cmdIdx có tham số số tiền không trỏ tới Input hợp lệ',
              );
            }
            final inArg = ptb.inputs[amtArg.index];
            if (inArg is! SuiPureCallArg) {
              return AuditVerdict.rejected(
                'Lệnh SplitCoins #$cmdIdx yêu cầu tham số Pure u64 hợp lệ',
              );
            }
            final BigInt amt;
            try {
              final reader = BcsReader(inArg.bytes);
              amt = reader.readU64();
              if (reader.remaining != 0) {
                return AuditVerdict.rejected(
                  'Lệnh SplitCoins #$cmdIdx chứa byte dư thừa trong tham số u64',
                );
              }
            } catch (e) {
              return AuditVerdict.rejected(
                'Lệnh SplitCoins #$cmdIdx có tham số u64 không hợp lệ: $e',
              );
            }
            totalMist += amt;
            cmdAmounts.add(amt);
          }
          splitCmdInfos[cmdIdx] = _SuiSplitInfo(
            isFromGasCoin: isGasCoinSource,
            amounts: cmdAmounts,
          );
        } else if (cmd is SuiTransferObjectsCommand) {
          if (cmd.objects.isEmpty) {
            return AuditVerdict.rejected('Lệnh TransferObjects #$cmdIdx không có đối tượng nào');
          }

          if (cmd.recipient is! SuiInputArgument) {
            return AuditVerdict.rejected(
              'Lệnh TransferObjects #$cmdIdx có địa chỉ người nhận không phải Pure Input',
            );
          }
          final recArg = cmd.recipient as SuiInputArgument;
          if (recArg.index < 0 || recArg.index >= ptb.inputs.length) {
            return AuditVerdict.rejected(
              'Lệnh TransferObjects #$cmdIdx trỏ tới Input người nhận ngoài phạm vi (${recArg.index})',
            );
          }
          final recInput = ptb.inputs[recArg.index];
          if (recInput is! SuiPureCallArg) {
            return AuditVerdict.rejected(
              'Lệnh TransferObjects #$cmdIdx có Input người nhận không phải Pure Address',
            );
          }
          final String recAddr;
          try {
            final recReader = BcsReader(recInput.bytes);
            recAddr = recReader.readAddress();
            if (recReader.remaining != 0) {
              return AuditVerdict.rejected(
                'Lệnh TransferObjects #$cmdIdx có độ dài địa chỉ người nhận không hợp lệ',
              );
            }
          } catch (e) {
            return AuditVerdict.rejected(
              'Lệnh TransferObjects #$cmdIdx có địa chỉ người nhận không hợp lệ: $e',
            );
          }
          recipients.add(recAddr);

          // Audit every object being transferred
          for (var objIdx = 0; objIdx < cmd.objects.length; objIdx++) {
            final obj = cmd.objects[objIdx];
            if (obj is SuiGasCoinArgument) {
              isHighRisk = true;
              warnings.add(
                'CẢNH BÁO NGUY HIỂM: Lệnh #$cmdIdx chuyển TOÀN BỘ số dư GasCoin tới $recAddr!',
              );
              extraDetails['Transfer #$cmdIdx.$objIdx'] = 'TOÀN BỘ GasCoin -> $recAddr';
            } else if (obj is SuiInputArgument) {
              if (obj.index < 0 || obj.index >= ptb.inputs.length) {
                return AuditVerdict.rejected(
                  'Lệnh TransferObjects #$cmdIdx tham chiếu Input ngoài phạm vi (${obj.index})',
                );
              }
              final objInput = ptb.inputs[obj.index];
              if (objInput is SuiObjectArg) {
                isHighRisk = true;
                warnings.add(
                  'CẢNH BÁO: Lệnh #$cmdIdx chuyển nguyên Object/Coin/NFT (${objInput.objectRef.objectId}) tới $recAddr!',
                );
                extraDetails['Transfer Object #$cmdIdx.$objIdx'] =
                    '${objInput.objectRef.objectId} -> $recAddr';
              } else {
                isHighRisk = true;
                warnings.add('CẢNH BÁO: Lệnh #$cmdIdx chuyển Input #${obj.index} bất thường');
              }
            } else if (obj is SuiResultArgument) {
              final splitInfo = splitCmdInfos[obj.index];
              if (splitInfo == null || !splitInfo.isFromGasCoin) {
                isHighRisk = true;
                warnings.add(
                  'CẢNH BÁO: Lệnh #$cmdIdx chuyển kết quả từ lệnh #${obj.index} (không phải GasCoin Split)',
                );
                extraDetails['Transfer #$cmdIdx.$objIdx'] = 'Result#${obj.index} -> $recAddr';
              } else {
                final totalSplit = splitInfo.amounts.fold(BigInt.zero, (a, b) => a + b);
                final amtSummary = splitInfo.amounts.length == 1
                    ? '${_formatMist(totalSplit)} SUI'
                    : '${_formatMist(totalSplit)} SUI (${splitInfo.amounts.length} phần: ${splitInfo.amounts.map(_formatMist).join(' + ')})';
                if (splitInfo.isTaintedByMerge) {
                  isHighRisk = true;
                  final mergedList = splitInfo.mergedSources.join(', ');
                  warnings.add(
                    'CẢNH BÁO NGUY HIỂM: Kết quả Result#${obj.index} đã bị MergeCoins gộp thêm [$mergedList] trước khi chuyển tới $recAddr!',
                  );
                  extraDetails['Transfer #$cmdIdx.$objIdx'] =
                      '$amtSummary + MERGED [$mergedList] -> $recAddr';
                } else {
                  extraDetails['Transfer #$cmdIdx.$objIdx'] = '$amtSummary -> $recAddr';
                }
              }
            } else if (obj is SuiNestedResultArgument) {
              final splitInfo = splitCmdInfos[obj.commandIndex];
              if (splitInfo == null ||
                  !splitInfo.isFromGasCoin ||
                  obj.resultIndex < 0 ||
                  obj.resultIndex >= splitInfo.amounts.length) {
                isHighRisk = true;
                warnings.add(
                  'CẢNH BÁO: Lệnh #$cmdIdx chuyển kết quả lồng NestedResult(${obj.commandIndex}, ${obj.resultIndex}) không xác định giá trị',
                );
                extraDetails['Transfer #$cmdIdx.$objIdx'] =
                    'NestedResult(${obj.commandIndex}, ${obj.resultIndex}) -> $recAddr';
              } else {
                final nestedAmt = splitInfo.amounts[obj.resultIndex];
                final amtSummary = '${_formatMist(nestedAmt)} SUI';
                if (splitInfo.isTaintedByMerge) {
                  isHighRisk = true;
                  final mergedList = splitInfo.mergedSources.join(', ');
                  warnings.add(
                    'CẢNH BÁO NGUY HIỂM: Kết quả NestedResult(${obj.commandIndex}, ${obj.resultIndex}) đã bị MergeCoins gộp thêm [$mergedList] trước khi chuyển tới $recAddr!',
                  );
                  extraDetails['Transfer #$cmdIdx.$objIdx'] =
                      '$amtSummary + MERGED [$mergedList] -> $recAddr';
                } else {
                  extraDetails['Transfer #$cmdIdx.$objIdx'] = '$amtSummary -> $recAddr';
                }
              }
            }
          }
        } else if (cmd is SuiMergeCoinsCommand) {
          isHighRisk = true;
          final destDesc = _describeSuiArgument(cmd.destination, ptb.inputs);
          if (destDesc == null) {
            return AuditVerdict.rejected(
              'Lệnh MergeCoins #$cmdIdx tham chiếu đích ngoài phạm vi inputs',
            );
          }
          final srcDescriptions = <String>[];
          for (final src in cmd.sources) {
            final srcDesc = _describeSuiArgument(src, ptb.inputs);
            if (srcDesc == null) {
              return AuditVerdict.rejected(
                'Lệnh MergeCoins #$cmdIdx tham chiếu nguồn ngoài phạm vi inputs',
              );
            }
            srcDescriptions.add(srcDesc);
          }

          if (cmd.destination is SuiResultArgument) {
            final destIdx = (cmd.destination as SuiResultArgument).index;
            final info = splitCmdInfos[destIdx];
            if (info != null) {
              info.isTaintedByMerge = true;
              info.mergedSources.addAll(srcDescriptions);
            }
          } else if (cmd.destination is SuiNestedResultArgument) {
            final destCmd = (cmd.destination as SuiNestedResultArgument).commandIndex;
            final info = splitCmdInfos[destCmd];
            if (info != null) {
              info.isTaintedByMerge = true;
              info.mergedSources.addAll(srcDescriptions);
            }
          } else if (cmd.destination is SuiGasCoinArgument) {
            gasCoinTaintedByMerge = true;
          }

          final joinedSources = srcDescriptions.join(', ');
          extraDetails['MergeCoins #$cmdIdx'] = '$destDesc <- [$joinedSources]';
          warnings.add(
            'CẢNH BÁO: Lệnh MergeCoins (#$cmdIdx) gộp [$joinedSources] vào $destDesc',
          );
        } else {
          isHighRisk = true;
          warnings.add('CẢNH BÁO: Giao dịch chứa lệnh Move Call hoặc Contract interaction phức tạp');
        }
      }

      if (recipients.isEmpty) {
        isHighRisk = true;
        warnings.add('LƯU Ý: Giao dịch không có lệnh TransferObjects rõ ràng');
      } else if (recipients.toSet().length > 1 || recipients.length > 1) {
        isHighRisk = true;
        warnings.add(
          'CẢNH BÁO ĐA LỆNH CHUYỂN: Giao dịch thực hiện ${recipients.length} lệnh chuyển tới ${recipients.toSet().length} địa chỉ!',
        );
      }

      final recipientAddress = recipients.isEmpty
          ? 'N/A'
          : recipients.toSet().join('\n');

      final feeMist = gasBudget;

      return AuditVerdict(
        isApproved: true,
        recipientAddress: recipientAddress,
        amountDisplay: '${_formatMist(totalMist)} SUI (${_formatNumber(totalMist)} MIST)',
        feeDisplay: 'Tối đa ${_formatMist(feeMist)} SUI (${_formatNumber(feeMist)} MIST)',
        networkDisplay: '${request.chain.toUpperCase()} (${request.network.toUpperCase()})',
        isHighRiskContractCall: isHighRisk,
        warnings: warnings,
        extraDetails: extraDetails,
      );
    } finally {
      master.dispose();
      signerKey.dispose();
      SuiEd25519.zeroize(seed);
    }
  }

  static String? _describeSuiArgument(SuiArgument arg, List<SuiCallArg> inputs) {
    if (arg is SuiGasCoinArgument) return 'GasCoin';
    if (arg is SuiResultArgument) return 'Result(${arg.index})';
    if (arg is SuiNestedResultArgument) {
      return 'NestedResult(${arg.commandIndex}, ${arg.resultIndex})';
    }
    if (arg is SuiInputArgument) {
      if (arg.index < 0 || arg.index >= inputs.length) return null;
      final input = inputs[arg.index];
      if (input is SuiObjectArg) {
        return 'Input(${arg.index}: Object ${input.objectRef.objectId})';
      }
      return 'Input(${arg.index})';
    }
    return arg.toString();
  }

  /// Audits and signs the Sui transaction, returning [SuiSignResponseUr].
  static SuiSignResponseUr auditAndSign({
    required Uint8List entropy,
    String passphrase = '',
    required SuiSignRequestUr request,
    required int expectedAccountIndex,
    int expectedAddressIndex = 0,
    String? expectedNetwork,
  }) {
    final verdict = audit(
      entropy: entropy,
      passphrase: passphrase,
      request: request,
      expectedAccountIndex: expectedAccountIndex,
      expectedAddressIndex: expectedAddressIndex,
      expectedNetwork: expectedNetwork,
    );

    if (!verdict.isApproved) {
      throw StateError(verdict.rejectReason ?? 'Giao dịch bị từ chối bởi kiểm toán SEC-01');
    }

    final seed = Bip39.entropyToSeed(entropy, passphrase: passphrase);
    final master = SuiSlip0010Key.fromSeed(seed);
    final signerKey = master.deriveSuiAccount(
      accountIndex: expectedAccountIndex,
      addressIndex: expectedAddressIndex,
    );

    try {
      // Sign canonical [0, 0, 0] || verified request.txBytes
      final intentMessage = Uint8List(3 + request.txBytes.length);
      intentMessage[0] = 0;
      intentMessage[1] = 0;
      intentMessage[2] = 0;
      intentMessage.setRange(3, intentMessage.length, request.txBytes);
      final sig = signerKey.sign(intentMessage);

      return SuiSignResponseUr(
        requestId: request.requestId,
        signature: sig,
        publicKey: signerKey.publicKey,
      );
    } finally {
      master.dispose();
      signerKey.dispose();
      SuiEd25519.zeroize(seed);
    }
  }

  static String _formatMist(BigInt mist) {
    final doubleVal = mist.toDouble() / 1e9;
    return doubleVal.toStringAsFixed(4);
  }

  static String _formatNumber(BigInt n) {
    return n.toString().replaceAllMapped(
      RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
      (Match m) => '${m[1]},',
    );
  }
}

class _SuiSplitInfo {
  final bool isFromGasCoin;
  final List<BigInt> amounts;
  bool isTaintedByMerge = false;
  final List<String> mergedSources = [];

  _SuiSplitInfo({
    required this.isFromGasCoin,
    required this.amounts,
  });
}
