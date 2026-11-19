import '../eip712/eip712_types.dart';
import 'hl_action_models.dart';

/// Formats Hyperliquid L1 actions into standard EIP-712 Typed Data payloads.
class HyperliquidTxBuilder {
  const HyperliquidTxBuilder._();

  static const String exchangeVerifyingContract = '0x0000000000000000000000000000000000000000';

  static Eip712Domain getExchangeDomain({required bool isMainnet}) => Eip712Domain(
        name: 'Exchange',
        version: '1',
        chainId: 1337,
        verifyingContract: exchangeVerifyingContract,
      );

  /// Builds EIP-712 typed data for [HlUsdSendAction].
  static Eip712TypedData buildUsdSendTypedData(HlUsdSendAction action) {
    return Eip712TypedData(
      types: {
        'EIP712Domain': const [
          Eip712TypeProperty(name: 'name', type: 'string'),
          Eip712TypeProperty(name: 'version', type: 'string'),
          Eip712TypeProperty(name: 'chainId', type: 'uint256'),
          Eip712TypeProperty(name: 'verifyingContract', type: 'address'),
        ],
        'HyperliquidTransaction:UsdSend': const [
          Eip712TypeProperty(name: 'hyperliquidChain', type: 'string'),
          Eip712TypeProperty(name: 'destination', type: 'string'),
          Eip712TypeProperty(name: 'amount', type: 'string'),
          Eip712TypeProperty(name: 'time', type: 'uint64'),
        ],
      },
      primaryType: 'HyperliquidTransaction:UsdSend',
      domain: getExchangeDomain(isMainnet: action.isMainnet),
      message: action.toMessageMap(),
    );
  }

  /// Builds EIP-712 typed data for [HlSpotSendAction].
  static Eip712TypedData buildSpotSendTypedData(HlSpotSendAction action) {
    return Eip712TypedData(
      types: {
        'EIP712Domain': const [
          Eip712TypeProperty(name: 'name', type: 'string'),
          Eip712TypeProperty(name: 'version', type: 'string'),
          Eip712TypeProperty(name: 'chainId', type: 'uint256'),
          Eip712TypeProperty(name: 'verifyingContract', type: 'address'),
        ],
        'HyperliquidTransaction:SpotSend': const [
          Eip712TypeProperty(name: 'hyperliquidChain', type: 'string'),
          Eip712TypeProperty(name: 'destination', type: 'string'),
          Eip712TypeProperty(name: 'token', type: 'string'),
          Eip712TypeProperty(name: 'amount', type: 'string'),
          Eip712TypeProperty(name: 'time', type: 'uint64'),
        ],
      },
      primaryType: 'HyperliquidTransaction:SpotSend',
      domain: getExchangeDomain(isMainnet: action.isMainnet),
      message: action.toMessageMap(),
    );
  }

  /// Builds EIP-712 typed data for [HlApproveAgentAction].
  static Eip712TypedData buildApproveAgentTypedData(HlApproveAgentAction action) {
    return Eip712TypedData(
      types: {
        'EIP712Domain': const [
          Eip712TypeProperty(name: 'name', type: 'string'),
          Eip712TypeProperty(name: 'version', type: 'string'),
          Eip712TypeProperty(name: 'chainId', type: 'uint256'),
          Eip712TypeProperty(name: 'verifyingContract', type: 'address'),
        ],
        'HyperliquidTransaction:ApproveAgent': const [
          Eip712TypeProperty(name: 'hyperliquidChain', type: 'string'),
          Eip712TypeProperty(name: 'agentAddress', type: 'address'),
          Eip712TypeProperty(name: 'agentName', type: 'string'),
          Eip712TypeProperty(name: 'nonce', type: 'uint64'),
        ],
      },
      primaryType: 'HyperliquidTransaction:ApproveAgent',
      domain: getExchangeDomain(isMainnet: action.isMainnet),
      message: action.toMessageMap(),
    );
  }
}
