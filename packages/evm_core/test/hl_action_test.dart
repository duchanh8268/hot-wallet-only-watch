import 'package:evm_core/evm_core.dart';
import 'package:test/test.dart';

void main() {
  group('Hyperliquid L1 Action Tests', () {
    test('HlUsdSendAction builds and hashes EIP-712 typed data', () {
      const action = HlUsdSendAction(
        isMainnet: false,
        destination: '0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed',
        amount: '150.75',
        time: 1700000000000,
      );

      final typedData = HyperliquidTxBuilder.buildUsdSendTypedData(action);
      expect(typedData.primaryType, equals('HyperliquidTransaction:UsdSend'));
      expect(typedData.domain.name, equals('Exchange'));
      expect(typedData.domain.chainId, equals(1337));

      final hash = Eip712Hasher.hashTypedData(typedData);
      expect(hash.length, equals(32));
    });

    test('HlSpotSendAction builds and hashes EIP-712 typed data', () {
      const action = HlSpotSendAction(
        isMainnet: true,
        destination: '0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed',
        token: 'PURR:0xc4bf3f803ea120301513470b6073f0d4',
        amount: '1000',
        time: 1700000000000,
      );

      final typedData = HyperliquidTxBuilder.buildSpotSendTypedData(action);
      expect(typedData.primaryType, equals('HyperliquidTransaction:SpotSend'));

      final hash = Eip712Hasher.hashTypedData(typedData);
      expect(hash.length, equals(32));
    });

    test('HlApproveAgentAction builds and hashes EIP-712 typed data', () {
      const action = HlApproveAgentAction(
        isMainnet: false,
        agentAddress: '0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed',
        agentName: 'TradingBot-1',
        nonce: 1,
      );

      final typedData = HyperliquidTxBuilder.buildApproveAgentTypedData(action);
      expect(typedData.primaryType, equals('HyperliquidTransaction:ApproveAgent'));

      final hash = Eip712Hasher.hashTypedData(typedData);
      expect(hash.length, equals(32));
    });
  });
}
