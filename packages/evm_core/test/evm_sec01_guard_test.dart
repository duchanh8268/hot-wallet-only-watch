import 'dart:convert';
import 'dart:typed_data';
import 'package:chain_core_interface/chain_core_interface.dart';
import 'package:evm_core/evm_core.dart';
import 'package:test/test.dart';

void main() {
  group('EVM SEC-01 Security Guard Tests', () {
    const mnemonic = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
    final entropy = Bip39.mnemonicToEntropy(mnemonic);

    test('Passes valid EIP-1559 ETH transfer inspection', () {
      final tx = Eip1559Transaction(
        chainId: 1,
        nonce: BigInt.zero,
        maxPriorityFeePerGas: BigInt.from(2000000000),
        maxFeePerGas: BigInt.from(20000000000),
        gasLimit: BigInt.from(21000),
        to: '0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed',
        value: BigInt.from(1000000000000000000), // 1 ETH
      );

      final req = EthSignRequestUr(
        requestId: hexDecode('0123456789abcdef0123456789abcdef'),
        chain: 'ethereum',
        network: 'mainnet',
        payloadType: EthPayloadType.eip1559,
        rawPayload: tx.unsignedSigningBytes,
        accountIndex: 0,
        addressIndex: 0,
        metadata: {
          'chainId': 1,
          'to': '0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed',
          'valueWei': '1000000000000000000',
          'gasLimit': '21000',
          'maxFeePerGas': '20000000000',
        },
      );

      final verdict = EvmSec01Guard.audit(
        entropy: entropy,
        request: req,
        expectedAccountIndex: 0,
        expectedAddressIndex: 0,
        expectedNetwork: 'mainnet',
      );

      expect(verdict.isApproved, isTrue);
      expect(verdict.recipientAddress, equals('0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed'));
      expect(verdict.amountDisplay, contains('1.000000 ETH'));
      expect(verdict.isHighRiskContractCall, isFalse);
    });

    test('Rejects forged metadata that disagrees with actual RLP signing bytes', () {
      final maliciousTx = Eip1559Transaction(
        chainId: 1,
        nonce: BigInt.zero,
        maxPriorityFeePerGas: BigInt.from(2000000000),
        maxFeePerGas: BigInt.from(20000000000),
        gasLimit: BigInt.from(21000),
        to: '0x3535353535353535353535353535353535353535', // Attacker address
        value: BigInt.from(5000000000000000000), // 5 ETH
      );

      final req = EthSignRequestUr(
        requestId: hexDecode('0123456789abcdef0123456789abcdef'),
        chain: 'ethereum',
        network: 'mainnet',
        payloadType: EthPayloadType.eip1559,
        rawPayload: maliciousTx.unsignedSigningBytes,
        accountIndex: 0,
        addressIndex: 0,
        metadata: {
          'chainId': 1,
          'to': '0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed', // Spoofed benign address
          'valueWei': '1000000000000000', // Spoofed 0.001 ETH
          'gasLimit': '21000',
          'maxFeePerGas': '20000000000',
        },
      );

      final verdict = EvmSec01Guard.audit(
        entropy: entropy,
        request: req,
        expectedAccountIndex: 0,
        expectedAddressIndex: 0,
      );

      expect(verdict.isApproved, isFalse);
      expect(verdict.rejectReason, contains('không khớp với RLP'));
    });

    test('Parses ERC-20 calldata inside RLP tx and displays token recipient and amount', () {
      // 0xa9059cbb + 12 zeros + 20-byte recipient + 32-byte amount (100 * 10^18)
      final recipient = '5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed'.toLowerCase();
      final calldata = hexDecode(
        'a9059cbb'
        '000000000000000000000000$recipient'
        '0000000000000000000000000000000000000000000000056bc75e2d63100000', // 100 * 1e18
      );

      final tx = Eip1559Transaction(
        chainId: 1,
        nonce: BigInt.one,
        maxPriorityFeePerGas: BigInt.from(2000000000),
        maxFeePerGas: BigInt.from(20000000000),
        gasLimit: BigInt.from(65000),
        to: '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48',
        value: BigInt.zero,
        data: calldata,
      );

      final req = EthSignRequestUr(
        requestId: hexDecode('0123456789abcdef0123456789abcdef'),
        chain: 'ethereum',
        network: 'mainnet',
        payloadType: EthPayloadType.eip1559,
        rawPayload: tx.unsignedSigningBytes,
        accountIndex: 0,
        addressIndex: 0,
        metadata: {
          'chainId': 1,
          'to': '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48',
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
      expect(verdict.extraDetails['Token Contract'], equals('0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48'));
      expect(verdict.isHighRiskContractCall, isFalse);
    });

    test('Flags ERC-20 unlimited approve as high-risk contract call with spender', () {
      final spender = '3535353535353535353535353535353535353535';
      final calldata = hexDecode(
        '095ea7b3'
        '000000000000000000000000$spender'
        'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff',
      );
      final tx = Eip1559Transaction(
        chainId: 1,
        nonce: BigInt.zero,
        maxPriorityFeePerGas: BigInt.from(1000000000),
        maxFeePerGas: BigInt.from(20000000000),
        gasLimit: BigInt.from(60000),
        to: '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48',
        value: BigInt.zero,
        data: calldata,
      );

      final req = EthSignRequestUr(
        requestId: hexDecode('0123456789abcdef0123456789abcdef'),
        chain: 'ethereum',
        network: 'mainnet',
        payloadType: EthPayloadType.eip1559,
        rawPayload: tx.unsignedSigningBytes,
      );

      final verdict = EvmSec01Guard.audit(
        entropy: entropy,
        request: req,
        expectedAccountIndex: 0,
        expectedAddressIndex: 0,
      );

      expect(verdict.isApproved, isTrue);
      expect(verdict.isHighRiskContractCall, isTrue);
      expect(verdict.recipientAddress, equals('0x3535353535353535353535353535353535353535'));
      expect(verdict.warnings.any((w) => w.contains('VÔ HẠN')), isTrue);
    });

    test('Rejects accountIndex/addressIndex mismatch and network mismatch', () {
      final tx = Eip1559Transaction(
        chainId: 1,
        nonce: BigInt.zero,
        maxPriorityFeePerGas: BigInt.from(1000000000),
        maxFeePerGas: BigInt.from(20000000000),
        gasLimit: BigInt.from(21000),
        to: '0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed',
        value: BigInt.from(1000),
      );
      final req = EthSignRequestUr(
        requestId: hexDecode('0123456789abcdef0123456789abcdef'),
        chain: 'ethereum',
        network: 'mainnet',
        payloadType: EthPayloadType.eip1559,
        rawPayload: tx.unsignedSigningBytes,
        accountIndex: 2,
        addressIndex: 0,
      );

      final acctMismatch = EvmSec01Guard.audit(
        entropy: entropy,
        request: req,
        expectedAccountIndex: 0,
        expectedAddressIndex: 0,
      );
      expect(acctMismatch.isApproved, isFalse);
      expect(acctMismatch.rejectReason, contains('không khớp với ví đang mở'));

      final netMismatch = EvmSec01Guard.audit(
        entropy: entropy,
        request: EthSignRequestUr(
          requestId: req.requestId,
          chain: 'ethereum',
          network: 'mainnet',
          payloadType: EthPayloadType.eip1559,
          rawPayload: tx.unsignedSigningBytes,
        ),
        expectedAccountIndex: 0,
        expectedAddressIndex: 0,
        expectedNetwork: 'sepolia',
      );
      expect(netMismatch.isApproved, isFalse);
      expect(netMismatch.rejectReason, contains('Network Mismatch'));
    });

    test('Passes Hyperliquid EIP-712 UsdSend audit and rejects spoofed domain', () {
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
        expectedNetwork: 'testnet',
      );

      expect(verdict.isApproved, isTrue);
      expect(verdict.recipientAddress, equals('0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed'));
      expect(verdict.amountDisplay, contains('250.0 USDC (Hyperliquid L1)'));
      expect(verdict.isHighRiskContractCall, isFalse);

      // Spoofed custom EIP-712 claiming UsdSend in primaryType with wrong domain must be high-risk
      final spoofedPayload = utf8.encode(jsonEncode({
        'types': {
          'EIP712Domain': [
            {'name': 'name', 'type': 'string'},
            {'name': 'chainId', 'type': 'uint256'},
          ],
          'FakeUsdSend': [
            {'name': 'destination', 'type': 'string'},
          ],
        },
        'primaryType': 'FakeUsdSend',
        'domain': {'name': 'MaliciousDapp', 'chainId': 1},
        'message': {'destination': '0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed'},
      }));
      final spoofedVerdict = EvmSec01Guard.audit(
        entropy: entropy,
        request: EthSignRequestUr(
          requestId: req.requestId,
          chain: 'ethereum',
          network: 'mainnet',
          payloadType: EthPayloadType.eip712,
          rawPayload: Uint8List.fromList(spoofedPayload),
        ),
        expectedAccountIndex: 0,
        expectedAddressIndex: 0,
      );
      expect(spoofedVerdict.isApproved, isTrue);
      expect(spoofedVerdict.isHighRiskContractCall, isTrue);
    });

    test('Fails closed on empty or non-RLP rawPayload', () {
      final req = EthSignRequestUr(
        requestId: hexDecode('0123456789abcdef0123456789abcdef'),
        chain: 'ethereum',
        network: 'mainnet',
        payloadType: EthPayloadType.eip1559,
        rawPayload: Uint8List(0),
        metadata: {
          'chainId': 1,
          'to': '0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed',
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
      expect(verdict.rejectReason, contains('RLP'));
    });
  });
}
