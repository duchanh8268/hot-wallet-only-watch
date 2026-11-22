import 'dart:convert';
import 'dart:typed_data';
import 'package:chain_core_interface/chain_core_interface.dart';
import '../address/eip55.dart';
import '../bc_ur/eth_ur_messages.dart';
import '../crypto/evm_hd_key.dart';
import '../eip712/eip712_hasher.dart';
import '../eip712/eip712_types.dart';
import '../transaction/evm_tx_serializer.dart';

/// Offline SEC-01 Security Audit Guard for Ethereum & Hyperliquid transactions.
class EvmSec01Guard {
  const EvmSec01Guard._();

  static const Map<String, int> _ethereumNetworkChainIds = {
    'mainnet': 1,
    'sepolia': 11155111,
    'holesky': 17000,
  };

  /// Audits an incoming [EthSignRequestUr] against the unlocked [entropy] and derivation indices.
  static AuditVerdict audit({
    required Uint8List entropy,
    String passphrase = '',
    required EthSignRequestUr request,
    required int expectedAccountIndex,
    required int expectedAddressIndex,
    String? expectedNetwork,
    String? expectedChain,
  }) {
    if (request.accountIndex != expectedAccountIndex ||
        request.addressIndex != expectedAddressIndex) {
      return AuditVerdict.rejected(
        'Chỉ số dẫn xuất trong yêu cầu (account=${request.accountIndex}, address=${request.addressIndex}) '
        'không khớp với ví đang mở (account=$expectedAccountIndex, address=$expectedAddressIndex)',
      );
    }

    final normalizedChain = request.chain.trim().toLowerCase();
    final normalizedNetwork = request.network.trim().toLowerCase();

    if (normalizedChain != 'ethereum' && normalizedChain != 'hyperliquid') {
      return AuditVerdict.rejected(
        'Chuỗi EVM không được hỗ trợ hoặc không hợp lệ: "${request.chain}"',
      );
    }

    if (expectedChain != null && normalizedChain != expectedChain.trim().toLowerCase()) {
      return AuditVerdict.rejected(
        'Xung đột chuỗi (Chain Mismatch): Yêu cầu ký thuộc "$normalizedChain" '
        'nhưng Ví Lạnh đang chọn "${expectedChain.trim().toLowerCase()}".',
      );
    }

    if (expectedNetwork != null && normalizedNetwork != expectedNetwork.trim().toLowerCase()) {
      return AuditVerdict.rejected(
        'Xung đột mạng lưới (Network Mismatch): Yêu cầu ký thuộc mạng "${request.network}" '
        'nhưng Ví Lạnh đang đặt ở mạng "$expectedNetwork".',
      );
    }

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
        return _auditEip1559(request, myAddress, normalizedChain, normalizedNetwork);
      } else if (request.payloadType == EthPayloadType.legacy) {
        return _auditLegacy(request, myAddress, normalizedChain, normalizedNetwork);
      } else if (request.payloadType == EthPayloadType.eip712) {
        return _auditEip712(request, myAddress, normalizedChain, normalizedNetwork);
      } else {
        return AuditVerdict.rejected('Unsupported payload type: ${request.payloadType}');
      }
    } finally {
      masterHd.dispose();
      childKey.dispose();
      zeroize(seed);
    }
  }

  static AuditVerdict _auditEip1559(
    EthSignRequestUr request,
    String myAddress,
    String normalizedChain,
    String normalizedNetwork,
  ) {
    try {
      final tx = EvmTxSerializer.deserializeEip1559Unsigned(request.rawPayload);
      return _auditDecodedTransaction(
        request: request,
        myAddress: myAddress,
        normalizedChain: normalizedChain,
        normalizedNetwork: normalizedNetwork,
        chainId: tx.chainId,
        nonce: tx.nonce,
        maxFeePerGas: tx.maxFeePerGas,
        maxPriorityFeePerGas: tx.maxPriorityFeePerGas,
        gasLimit: tx.gasLimit,
        to: tx.to,
        valueWei: tx.value,
        data: tx.data,
        isLegacyPreEip155: false,
      );
    } catch (e) {
      return AuditVerdict.rejected('Lỗi giải mã giao dịch EIP-1559 RLP: $e');
    }
  }

  static AuditVerdict _auditLegacy(
    EthSignRequestUr request,
    String myAddress,
    String normalizedChain,
    String normalizedNetwork,
  ) {
    try {
      final tx = EvmTxSerializer.deserializeLegacyUnsigned(request.rawPayload);
      return _auditDecodedTransaction(
        request: request,
        myAddress: myAddress,
        normalizedChain: normalizedChain,
        normalizedNetwork: normalizedNetwork,
        chainId: tx.chainId,
        nonce: tx.nonce,
        maxFeePerGas: tx.gasPrice,
        maxPriorityFeePerGas: null,
        gasLimit: tx.gasLimit,
        to: tx.to,
        valueWei: tx.value,
        data: tx.data,
        isLegacyPreEip155: tx.chainId == 0,
      );
    } catch (e) {
      return AuditVerdict.rejected('Lỗi giải mã giao dịch Legacy RLP: $e');
    }
  }

  static AuditVerdict _auditDecodedTransaction({
    required EthSignRequestUr request,
    required String myAddress,
    required String normalizedChain,
    required String normalizedNetwork,
    required int chainId,
    required BigInt nonce,
    required BigInt maxFeePerGas,
    required BigInt? maxPriorityFeePerGas,
    required BigInt gasLimit,
    required String to,
    required BigInt valueWei,
    required Uint8List data,
    required bool isLegacyPreEip155,
  }) {
    final expectedChainId = _ethereumNetworkChainIds[normalizedNetwork];
    if (normalizedChain == 'ethereum') {
      if (expectedChainId == null) {
        return AuditVerdict.rejected('Mạng Ethereum không được hỗ trợ: "${request.network}"');
      }
      if (chainId != expectedChainId && !isLegacyPreEip155) {
        return AuditVerdict.rejected(
          'Chain ID trong RLP ($chainId) không khớp với mạng $normalizedNetwork (Chain ID $expectedChainId)',
        );
      }
    }

    // Cross-check untrusted metadata against decoded RLP bytes if metadata fields are present
    final meta = request.metadata;
    if (meta['chainId'] != null &&
        meta['chainId'].toString() != chainId.toString()) {
      return AuditVerdict.rejected(
        'Dữ liệu metadata (chainId=${meta['chainId']}) không khớp với RLP ($chainId)',
      );
    }
    if (meta['to'] != null &&
        meta['to'].toString().trim().toLowerCase() != to.toLowerCase()) {
      return AuditVerdict.rejected(
        'Dữ liệu metadata (to=${meta['to']}) không khớp với RLP ($to)',
      );
    }
    if (meta['valueWei'] != null &&
        meta['valueWei'].toString() != valueWei.toString()) {
      return AuditVerdict.rejected(
        'Dữ liệu metadata (valueWei=${meta['valueWei']}) không khớp với RLP ($valueWei)',
      );
    }
    if (meta['gasLimit'] != null &&
        meta['gasLimit'].toString() != gasLimit.toString()) {
      return AuditVerdict.rejected(
        'Dữ liệu metadata (gasLimit=${meta['gasLimit']}) không khớp với RLP ($gasLimit)',
      );
    }
    final metaMaxFee = meta['maxFeePerGas'] ?? meta['maxFeePerGasWei'];
    if (metaMaxFee != null && metaMaxFee.toString() != maxFeePerGas.toString()) {
      return AuditVerdict.rejected(
        'Dữ liệu metadata (maxFeePerGas=$metaMaxFee) không khớp với RLP ($maxFeePerGas)',
      );
    }

    final warnings = <String>[];
    if (isLegacyPreEip155) {
      warnings.add('CẢNH BÁO: Giao dịch Legacy không có bảo vệ Replay EIP-155 (chainId=0)');
    }

    final maxCostWei = maxFeePerGas * gasLimit;
    var recipient = to;
    var amountDisplay = '${_formatWei(valueWei)} ETH';
    var isContract = false;
    final extraDetails = <String, String>{
      'From': myAddress,
      'Nonce': nonce.toString(),
      'Gas Limit': gasLimit.toString(),
      'Max Fee / Gas': '${_formatGwei(maxFeePerGas)} Gwei',
    };
    if (maxPriorityFeePerGas != null) {
      extraDetails['Priority Fee / Gas'] = '${_formatGwei(maxPriorityFeePerGas)} Gwei';
    }

    if (to.isEmpty) {
      recipient = 'Contract Deployment (Tạo hợp đồng mới)';
      isContract = true;
      warnings.add('CẢNH BÁO RỦI RO: Giao dịch triển khai Smart Contract mới');
    } else if (!Eip55.isValidAddress(to)) {
      return AuditVerdict.rejected('Địa chỉ người nhận không hợp lệ: $to');
    }

    // Inspect decoded calldata from RLP payload (only decode ERC-20 ABI when interacting with an existing contract)
    if (data.isNotEmpty) {
      if (to.isNotEmpty) {
        extraDetails['Contract / Target'] = to;
      }
      if (to.isNotEmpty && data.length >= 4) {
        final selector = hexEncode(data.sublist(0, 4), prefix0x: true);
        if (selector == '0xa9059cbb' &&
            data.length == 68 &&
            _hasZeroAddressPadding(data.sublist(4, 16))) {
          // ERC-20 transfer(address to, uint256 amount)
          final parsedTo = Eip55.formatChecksumAddress(data.sublist(16, 36));
          final rawTokenAmount = _bytesToBigInt(data.sublist(36, 68));
          recipient = parsedTo;
          extraDetails['Token Contract'] = to;
          extraDetails['Raw Token Units'] = rawTokenAmount.toString();

          final rawSymbol = meta['tokenSymbol'];
          final rawDecimals = meta['tokenDecimals'];
          final tokenSymbol = rawSymbol is String ? rawSymbol : null;
          final tokenDecimals = rawDecimals is int ? rawDecimals : null;
          if (tokenSymbol != null && tokenDecimals != null && tokenDecimals >= 0 && tokenDecimals <= 36) {
            final tokenDisplay = '${_formatTokenUnits(rawTokenAmount, tokenDecimals)} $tokenSymbol (chưa xác thực on-chain)';
            amountDisplay = valueWei > BigInt.zero
                ? '$tokenDisplay + ${_formatWei(valueWei)} ETH'
                : tokenDisplay;
          } else {
            amountDisplay = valueWei > BigInt.zero
                ? '$rawTokenAmount raw token units + ${_formatWei(valueWei)} ETH'
                : '$rawTokenAmount raw token units (ERC-20)';
          }
          if (valueWei > BigInt.zero) {
            extraDetails['Native ETH Attached'] = '${_formatWei(valueWei)} ETH';
            warnings.add('LƯU Ý: Giao dịch gọi chuyển ERC-20 đồng thời gửi kèm ${_formatWei(valueWei)} ETH!');
          }
        } else if (selector == '0x095ea7b3' &&
            data.length == 68 &&
            _hasZeroAddressPadding(data.sublist(4, 16))) {
          // ERC-20 approve(address spender, uint256 amount)
          final spender = Eip55.formatChecksumAddress(data.sublist(16, 36));
          final allowance = _bytesToBigInt(data.sublist(36, 68));
          isContract = true;
          recipient = spender;
          extraDetails['Token Contract'] = to;
          extraDetails['Spender'] = spender;
          final isUnlimited = allowance >= (BigInt.one << 255);
          extraDetails['Allowance'] = isUnlimited ? 'UNLIMITED (MAX_UINT256)' : allowance.toString();
          final baseApproveDisplay = isUnlimited
              ? 'Cấp quyền VÔ HẠN Token (Approve)'
              : 'Cấp quyền $allowance raw units (Approve)';
          if (valueWei > BigInt.zero) {
            final ethDisplay = '${_formatWei(valueWei)} ETH';
            amountDisplay = '$baseApproveDisplay + $ethDisplay';
            extraDetails['Native ETH Attached'] = ethDisplay;
            warnings.add(
              'CẢNH BÁO NGHIÊM TRỌNG: Giao dịch ERC-20 Approve đính kèm $ethDisplay gửi tới hợp đồng $to!',
            );
          } else {
            amountDisplay = baseApproveDisplay;
          }
          warnings.add(
            isUnlimited
                ? 'CẢNH BÁO NGUY HIỂM: Cấp quyền chi tiêu Token VÔ HẠN cho $spender!'
                : 'CẢNH BÁO: Giao dịch cấp quyền chi tiêu Token (ERC-20 Approve) cho $spender',
          );
        } else {
          isContract = true;
          extraDetails['Calldata'] = '${data.length} bytes (Selector: $selector)';
          warnings.add('CẢNH BÁO NGUY CƠ: Tương tác hợp đồng thông minh (Selector: $selector, ${data.length} bytes)');
        }
      } else {
        isContract = true;
        extraDetails['Calldata'] = '${data.length} bytes';
        warnings.add('CẢNH BÁO NGUY CƠ: Giao dịch chứa dữ liệu calldata tùy chỉnh (${data.length} bytes)');
      }
    }

    final maxCostEth = _formatWei(maxCostWei);

    return AuditVerdict(
      isApproved: true,
      recipientAddress: recipient,
      amountDisplay: amountDisplay,
      feeDisplay: '$maxCostEth ETH (Max Gas)',
      networkDisplay: '${normalizedChain.toUpperCase()} (Chain ID: $chainId)',
      isHighRiskContractCall: isContract,
      warnings: warnings,
      extraDetails: extraDetails,
    );
  }

  static AuditVerdict _auditEip712(
    EthSignRequestUr request,
    String myAddress,
    String normalizedChain,
    String normalizedNetwork,
  ) {
    try {
      final jsonStr = utf8.decode(request.rawPayload);
      final rawJson = jsonDecode(jsonStr);
      if (rawJson is! Map<String, dynamic>) {
        return AuditVerdict.rejected('EIP-712 payload JSON must be an object');
      }
      final typedData = Eip712TypedData.fromJson(rawJson);
      // Validate hashability of typed data before approval
      Eip712Hasher.hashTypedData(typedData);

      final primaryType = typedData.primaryType;
      final primaryProps = typedData.types[primaryType];
      if (primaryProps == null) {
        return AuditVerdict.rejected('EIP-712 types thiếu định nghĩa cho $primaryType');
      }

      // Compute exact hashed domain field names matching Eip712Hasher.hashDomain
      final domainMap = typedData.domain.toMap();
      final domainTypes = typedData.types['EIP712Domain'];
      final hashedDomainNames = domainTypes != null
          ? domainTypes.map((p) => p.name).toSet()
          : domainMap.keys.toSet();

      final rawDomainObj = rawJson['domain'];
      if (rawDomainObj is Map<String, dynamic>) {
        for (final key in rawDomainObj.keys) {
          if (rawDomainObj[key] != null && !hashedDomainNames.contains(key)) {
            return AuditVerdict.rejected(
              'EIP-712 Domain chứa trường ẩn "$key" không nằm trong EIP712Domain types!',
            );
          }
        }
      }
      for (final key in domainMap.keys) {
        if (!hashedDomainNames.contains(key)) {
          return AuditVerdict.rejected(
            'EIP-712 Domain chứa trường "$key" không được băm trong EIP712Domain types!',
          );
        }
      }

      // Reject any unhashed extra keys in message (and nested structs) omitted from types
      final unhashedPath = _findUnhashedStructField(
        primaryType,
        typedData.message,
        typedData.types,
        primaryType,
      );
      if (unhashedPath != null) {
        return AuditVerdict.rejected(
          'EIP-712 Message chứa trường ẩn không được ký trong types: $unhashedPath',
        );
      }

      final message = typedData.message;
      final domain = typedData.domain;
      final hashedMsgNames = primaryProps.map((p) => p.name).toSet();

      final warnings = <String>[];
      var isHighRisk = false;
      var recipient = 'N/A';
      var amountDisplay = 'N/A';

      final hasAllHlDomainTypes = domainTypes != null &&
          hashedDomainNames.containsAll(const {'name', 'version', 'chainId', 'verifyingContract'}) &&
          !hashedDomainNames.contains('salt');

      final isValidHlDomain = hasAllHlDomainTypes &&
          domain.salt == null &&
          domain.name == 'Exchange' &&
          domain.version == '1' &&
          domain.chainId == 1337 &&
          (domain.verifyingContract?.toLowerCase() ==
              '0x0000000000000000000000000000000000000000');

      if (normalizedChain == 'hyperliquid' &&
          normalizedNetwork != 'mainnet' &&
          normalizedNetwork != 'testnet') {
        return AuditVerdict.rejected('Mạng Hyperliquid không hợp lệ: "${request.network}"');
      }

      final expectedHlChain = normalizedNetwork == 'mainnet' ? 'Mainnet' : 'Testnet';
      final msgHlChain = message['hyperliquidChain']?.toString();

      if (isValidHlDomain && primaryType == 'HyperliquidTransaction:UsdSend') {
        if (!hashedMsgNames.containsAll(const {'hyperliquidChain', 'destination', 'amount'}) ||
            msgHlChain != expectedHlChain) {
          return AuditVerdict.rejected(
            'Hyperliquid chain ($msgHlChain) không khớp với mạng yêu cầu ($normalizedNetwork)',
          );
        }
        recipient = message['destination'] as String? ?? '';
        if (!Eip55.isValidAddress(recipient)) {
          return AuditVerdict.rejected('Địa chỉ nhận Hyperliquid UsdSend không hợp lệ: $recipient');
        }
        final amount = message['amount'] as String? ?? '0';
        amountDisplay = '\$$amount USDC (Hyperliquid L1)';
      } else if (isValidHlDomain && primaryType == 'HyperliquidTransaction:SpotSend') {
        if (!hashedMsgNames.containsAll(const {'hyperliquidChain', 'destination', 'token', 'amount'}) ||
            msgHlChain != expectedHlChain) {
          return AuditVerdict.rejected(
            'Hyperliquid chain ($msgHlChain) không khớp với mạng yêu cầu ($normalizedNetwork)',
          );
        }
        recipient = message['destination'] as String? ?? '';
        if (!Eip55.isValidAddress(recipient)) {
          return AuditVerdict.rejected('Địa chỉ nhận Hyperliquid SpotSend không hợp lệ: $recipient');
        }
        final token = message['token'] as String? ?? '';
        final amount = message['amount'] as String? ?? '0';
        amountDisplay = '$amount $token (Hyperliquid Spot)';
      } else if (isValidHlDomain && primaryType == 'HyperliquidTransaction:ApproveAgent') {
        if (!hashedMsgNames.containsAll(const {'hyperliquidChain', 'agentAddress'}) ||
            msgHlChain != expectedHlChain) {
          return AuditVerdict.rejected(
            'Hyperliquid chain ($msgHlChain) không khớp với mạng yêu cầu ($normalizedNetwork)',
          );
        }
        recipient = message['agentAddress'] as String? ?? '';
        if (!Eip55.isValidAddress(recipient)) {
          return AuditVerdict.rejected('Địa chỉ Agent không hợp lệ: $recipient');
        }
        final name = message['agentName'] as String? ?? 'Agent';
        amountDisplay = 'Ủy quyền API Key cho: $name';
        isHighRisk = true;
        warnings.add('LƯU Ý: Bạn đang cấp quyền ký lệnh giao dịch tự động cho API Agent Key');
      } else {
        isHighRisk = true;
        warnings.add('CẢNH BÁO RỦI RO: Ký cấu trúc dữ liệu EIP-712 tùy chỉnh ($primaryType)');
        if (hashedMsgNames.contains('spender') && message['spender'] != null) {
          recipient = message['spender'].toString();
        } else if (hashedMsgNames.contains('to') && message['to'] != null) {
          recipient = message['to'].toString();
        } else if (hashedMsgNames.contains('destination') && message['destination'] != null) {
          recipient = message['destination'].toString();
        }
      }

      final extraDetails = <String, String>{
        'From': myAddress,
        'Domain Name': hashedDomainNames.contains('name') ? (domain.name ?? 'N/A') : '(Không băm)',
        'Domain Chain ID':
            hashedDomainNames.contains('chainId') ? '${domain.chainId ?? 'N/A'}' : '(Không băm)',
        'Verifying Contract': hashedDomainNames.contains('verifyingContract')
            ? (domain.verifyingContract ?? 'N/A')
            : '(Không băm)',
        'Primary Type': primaryType,
      };
      for (final prop in primaryProps) {
        extraDetails['Msg.${prop.name}'] = '${message[prop.name]}';
      }

      return AuditVerdict(
        isApproved: true,
        recipientAddress: recipient,
        amountDisplay: amountDisplay,
        feeDisplay: '0 Phí L1 (Off-chain Sign)',
        networkDisplay: '${normalizedChain.toUpperCase()} (${normalizedNetwork.toUpperCase()})',
        isHighRiskContractCall: isHighRisk,
        warnings: warnings,
        extraDetails: extraDetails,
      );
    } catch (e) {
      return AuditVerdict.rejected('Lỗi giải mã cấu trúc EIP-712: $e');
    }
  }

  static String? _findUnhashedStructField(
    String typeName,
    Map<String, dynamic> data,
    Map<String, List<Eip712TypeProperty>> types,
    String path, [
    int depth = 0,
  ]) {
    if (depth > Eip712Hasher.maxDepth) return '$path (depth exceeded)';
    final props = types[typeName];
    if (props == null) return '$path (missing type $typeName)';
    final propMap = {for (final p in props) p.name: p.type};
    for (final key in data.keys) {
      final propType = propMap[key];
      if (propType == null) {
        return '$path.$key';
      }
      final val = data[key];
      if (types.containsKey(propType) && val is Map<String, dynamic>) {
        final sub = _findUnhashedStructField(propType, val, types, '$path.$key', depth + 1);
        if (sub != null) return sub;
      } else if (propType.endsWith(']') && val is List) {
        final baseType = propType.substring(0, propType.lastIndexOf('['));
        if (types.containsKey(baseType)) {
          for (var i = 0; i < val.length; i++) {
            final item = val[i];
            if (item is Map<String, dynamic>) {
              final sub = _findUnhashedStructField(baseType, item, types, '$path.$key[$i]', depth + 1);
              if (sub != null) return sub;
            }
          }
        }
      }
    }
    return null;
  }

  static bool _hasZeroAddressPadding(List<int> pad12) {
    for (final b in pad12) {
      if (b != 0) return false;
    }
    return true;
  }

  static String _formatWei(BigInt wei) => _formatTokenUnits(wei, 18, fixedDecimals: 6);

  static String _formatGwei(BigInt wei) => _formatTokenUnits(wei, 9, fixedDecimals: 2);

  static String _formatTokenUnits(BigInt raw, int decimals, {int fixedDecimals = 4}) {
    if (decimals == 0) return raw.toString();
    final divisor = BigInt.from(10).pow(decimals);
    final whole = raw ~/ divisor;
    final rem = raw % divisor;
    final remStr = rem.toString().padLeft(decimals, '0');
    final shown = fixedDecimals <= decimals
        ? remStr.substring(0, fixedDecimals)
        : remStr.padRight(fixedDecimals, '0');
    return '$whole.$shown';
  }

  static BigInt _bytesToBigInt(List<int> bytes) {
    var result = BigInt.zero;
    for (final b in bytes) {
      result = (result << 8) | BigInt.from(b);
    }
    return result;
  }
}
