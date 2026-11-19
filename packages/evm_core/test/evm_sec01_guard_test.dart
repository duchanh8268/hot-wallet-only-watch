import 'dart:convert';
import 'dart:typed_data';
import 'package:chain_core_interface/chain_core_interface.dart';
import 'package:evm_core/evm_core.dart';
import 'package:test/test.dart';

void main() {
  group('EVM SEC-01 Security Guard Tests', () {
    const mnemonic = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
    final entropy = Bip39.mnemonicToEntropy(mnemonic);

    test('Passes valid ETH transfer inspection', () {
      final req = EthSignRequestUr(
        requestId: hexDecode('0123456789abcdef0123456789abcdef'),
        chain: 'ethereum',
        network: 'mainnet',
        payloadType: EthPayloadType.eip1559,
        rawPayload: Uint8List(0),
        accountIndex: 0,
        addressIndex: 0,
        metadata: {
          'chainId': 1,
          'to': '0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed',
          'valueWei': '1000000000000000000', // 1 ETH
          'gasLimit': '21000',
          'maxFeePerGas': '20000000000',     // 20 gwei
        },
      );

      final verdict = EvmSec01Guard.audit(
        entropy: entropy,
        request: req,
        expectedAccountIndex: 0,
        expectedAddressIndex: 0,
      );

      expect(verdict.isApproved, isTrue);
      expect(verdict.recipientAddress, equals('0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed'));
      expect(verdict.amountDisplay, contains('1.000000 ETH'));
      expect(verdict.isHighRiskContractCall, isFalse);
    });

    test('Parses ERC-20 calldata and displays token recipient and amount', () {
      // 0xa9059cbb + 12 zeros + 20-byte recipient + 32-byte amount (100 * 10^18)
      final recipient = '5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed'.toLowerCase();
      final calldata = hexDecode(
        'a9059cbb'
        '000000000000000000000000$recipient'
        '0000000000000000000000000000000000000000000000056bc75e2d63100000', // 100 * 1e18
      );

      final req = EthSignRequestUr(
        requestId: hexDecode('0123456789abcdef0123456789abcdef'),
        chain: 'ethereum',
        network: 'mainnet',
        payloadType: EthPayloadType.eip1559,
        rawPayload: calldata,
        accountIndex: 0,
        addressIndex: 0,
        metadata: {
          'chainId': 1,
          'to': '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48', // USDC contract address
          'valueWei': '0',
          'gasLimit': '65000',
          'maxFeePerGas': '20000000000',
          'tokenSymbol': 'USDT',
          'tokenDecimals': 18,
        },
      );

      final verdict = EvmSec01Guard.audit(
        entropy: entropy,
        request: req,
        expectedAccountIndex: 0,
        expectedAddressIndex: 0,
      );

      expect(verdict.isApproved, isTrue);
      expect(verdict.recipientAddress, equals('0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed'));
      expect(verdict.amountDisplay, contains('100.0000 USDT'));
      expect(verdict.isHighRiskContractCall, isFalse);
    });

    test('Passes Hyperliquid EIP-712 UsdSend audit', () {
      const action = HlUsdSendAction(
        isMainnet: false,
        destination: '0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed',
        amount: '250.0',
        time: 1700000000000,
      );
      final typedData = HyperliquidTxBuilder.buildUsdSendTypedData(action);

      final jsonPayload = utf8.encode(jsonEncode({
        'types': typedData.types.map((k, v) => MapEntry(k, v.map((p) => p.toJson()).toList())),
        'primaryType': typedData.primaryType,
        'domain': typedData.domain.toMap(),
        'message': typedData.message,
      }));

      final req = EthSignRequestUr(
        requestId: hexDecode('0123456789abcdef0123456789abcdef'),
        chain: 'hyperliquid',
        network: 'testnet',
        payloadType: EthPayloadType.eip712,
        rawPayload: Uint8List.fromList(jsonPayload),
      );

      final verdict = EvmSec01Guard.audit(
        entropy: entropy,
        request: req,
        expectedAccountIndex: 0,
        expectedAddressIndex: 0,
      );

      expect(verdict.isApproved, isTrue);
      expect(verdict.recipientAddress, equals('0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed'));
      expect(verdict.amountDisplay, contains('250.0 USDC (Hyperliquid L1)'));
    });

    test('Fails closed on invalid recipient address', () {
      final req = EthSignRequestUr(
        requestId: hexDecode('0123456789abcdef0123456789abcdef'),
        chain: 'ethereum',
        network: 'mainnet',
        payloadType: EthPayloadType.eip1559,
        rawPayload: Uint8List(0),
        metadata: {
          'chainId': 1,
          'to': '0xInvalidAddress123',
          'valueWei': '1000000',
        },
      );

      final verdict = EvmSec01Guard.audit(
        entropy: entropy,
        request: req,
        expectedAccountIndex: 0,
        expectedAddressIndex: 0,
      );

      expect(verdict.isApproved, isFalse);
      expect(verdict.rejectReason, contains('không hợp lệ'));
    });
  });
}
