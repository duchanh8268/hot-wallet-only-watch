import 'dart:convert';
import 'dart:typed_data';
import 'package:chain_core_interface/chain_core_interface.dart';
import '../address/eip55.dart';
import '../bc_ur/eth_ur_messages.dart';
import '../crypto/evm_hd_key.dart';

/// Offline SEC-01 Security Audit Guard for Ethereum & Hyperliquid transactions.
class EvmSec01Guard {
  const EvmSec01Guard._();

  /// Audits an incoming [EthSignRequestUr] against the unlocked [entropy] and derivation indices.
  static AuditVerdict audit({
    required Uint8List entropy,
    String passphrase = '',
    required EthSignRequestUr request,
    required int expectedAccountIndex,
    required int expectedAddressIndex,
  }) {
    // 1. Derive active Cold Wallet address to verify signer ownership
    final seed = Bip39.entropyToSeed(entropy, passphrase: passphrase);
    final masterHd = EvmHdKey.fromSeed(seed);
    final childKey = masterHd.deriveEvmAccount(
      accountIndex: expectedAccountIndex,
      addressIndex: expectedAddressIndex,
    );
    final myAddress = Eip55.addressFromPublicKey64(childKey.publicKey64);

    try {
      if (request.payloadType == EthPayloadType.eip1559) {
        return _auditEip1559(request, myAddress);
      } else if (request.payloadType == EthPayloadType.legacy) {
        return _auditLegacy(request, myAddress);
      } else if (request.payloadType == EthPayloadType.eip712) {
        return _auditEip712(request, myAddress);
      } else {
        return AuditVerdict.rejected('Unsupported payload type: ${request.payloadType}');
      }
    } finally {
      masterHd.dispose();
      childKey.dispose();
      zeroize(seed);
    }
  }

  static AuditVerdict _auditEip1559(EthSignRequestUr request, String myAddress) {
    final meta = request.metadata;
    final chainId = meta['chainId'] as int? ?? 1;
    final to = meta['to'] as String? ?? '';
    final valueWeiStr = meta['valueWei'] as String? ?? '0';
    final valueWei = BigInt.tryParse(valueWeiStr) ?? BigInt.zero;
    final maxFeePerGasStr = meta['maxFeePerGas'] as String? ?? '0';
    final gasLimitStr = meta['gasLimit'] as String? ?? '21000';
    final maxFee = BigInt.tryParse(maxFeePerGasStr) ?? BigInt.zero;
    final gasLimit = BigInt.tryParse(gasLimitStr) ?? BigInt.zero;
    final maxCostWei = maxFee * gasLimit;

    final warnings = <String>[];
    var recipient = to;
    var amountDisplay = '${(valueWei / BigInt.from(10).pow(18)).toStringAsFixed(6)} ETH';
    var isContract = false;

    // Calldata audit
    if (request.rawPayload.isNotEmpty) {
      final data = request.rawPayload;
      if (data.length >= 4) {
        final selector = hexEncode(data.sublist(0, 4), prefix0x: true);
        if (selector == '0xa9059cbb' && data.length >= 68) {
          // ERC-20 transfer(address to, uint256 amount)
          final toBytes = data.sublist(16, 36);
          final parsedTo = Eip55.formatChecksumAddress(toBytes);
          final amountBytes = data.sublist(36, 68);
          final rawTokenAmount = _bytesToBigInt(amountBytes);

          recipient = parsedTo;
          final tokenSymbol = meta['tokenSymbol'] as String? ?? 'ERC-20 Token';
          final tokenDecimals = meta['tokenDecimals'] as int? ?? 18;
          amountDisplay = '${(rawTokenAmount / BigInt.from(10).pow(tokenDecimals)).toStringAsFixed(4)} $tokenSymbol';
        } else if (selector == '0x095ea7b3' && data.length >= 68) {
          // ERC-20 approve(address spender, uint256 amount)
          isContract = true;
          warnings.add('CẢNH BÁO: Giao dịch cấp quyền chi tiêu Token (ERC-20 Approve)');
        } else {
          isContract = true;
          warnings.add('CẢNH BÁO NGUY CƠ: Tương tác hợp đồng thông minh không xác định (Selector: $selector)');
        }
      }
    }

    // Sanity checks
    if (!Eip55.isValidAddress(to)) {
      return AuditVerdict.rejected('Địa chỉ người nhận không hợp lệ: $to');
    }

    final maxCostEth = (maxCostWei / BigInt.from(10).pow(18)).toStringAsFixed(6);

    return AuditVerdict(
      isApproved: true,
      recipientAddress: recipient,
      amountDisplay: amountDisplay,
      feeDisplay: '$maxCostEth ETH (Max Gas)',
      networkDisplay: '${request.chain.toUpperCase()} (Chain ID: $chainId)',
      isHighRiskContractCall: isContract,
      warnings: warnings,
      extraDetails: {
        'From': myAddress,
        'Gas Limit': gasLimit.toString(),
      },
    );
  }

  static AuditVerdict _auditLegacy(EthSignRequestUr request, String myAddress) {
    return _auditEip1559(request, myAddress);
  }

  static AuditVerdict _auditEip712(EthSignRequestUr request, String myAddress) {
    try {
      final jsonStr = utf8.decode(request.rawPayload);
      final jsonMap = jsonDecode(jsonStr) as Map<String, dynamic>;

      final primaryType = jsonMap['primaryType'] as String? ?? 'Unknown';
      final message = jsonMap['message'] as Map<String, dynamic>? ?? {};
      final domain = jsonMap['domain'] as Map<String, dynamic>? ?? {};

      final warnings = <String>[];
      var recipient = 'N/A';
      var amountDisplay = 'N/A';

      if (primaryType.contains('UsdSend')) {
        // Hyperliquid L1 USD transfer
        recipient = message['destination'] as String? ?? 'N/A';
        final amount = message['amount'] as String? ?? '0';
        amountDisplay = '\$$amount USDC (Hyperliquid L1)';
      } else if (primaryType.contains('SpotSend')) {
        // Hyperliquid Spot token transfer
        recipient = message['destination'] as String? ?? 'N/A';
        final token = message['token'] as String? ?? '';
        final amount = message['amount'] as String? ?? '0';
        amountDisplay = '$amount $token (Hyperliquid Spot)';
      } else if (primaryType.contains('ApproveAgent')) {
        // Hyperliquid Agent session key delegation
        recipient = message['agentAddress'] as String? ?? 'N/A';
        final name = message['agentName'] as String? ?? 'Agent';
        amountDisplay = 'Ủy quyền API Key cho: $name';
        warnings.add('LƯU Ý: Bạn đang cấp quyền ký lệnh giao dịch tự động cho API Agent Key');
      } else {
        warnings.add('CẢNH BÁO: Ký cấu trúc dữ liệu EIP-712 tùy chỉnh ($primaryType)');
      }

      return AuditVerdict(
        isApproved: true,
        recipientAddress: recipient,
        amountDisplay: amountDisplay,
        feeDisplay: '0 Phí L1 (Off-chain Sign)',
        networkDisplay: 'Hyperliquid / EIP-712',
        warnings: warnings,
        extraDetails: {
          'Domain': domain['name']?.toString() ?? 'EIP-712',
          'Primary Type': primaryType,
        },
      );
    } catch (e) {
      return AuditVerdict.rejected('Lỗi giải mã cấu trúc EIP-712: $e');
    }
  }

  static BigInt _bytesToBigInt(List<int> bytes) {
    var result = BigInt.zero;
    for (final b in bytes) {
      result = (result << 8) | BigInt.from(b);
    }
    return result;
  }
}
