/// Supported Hyperliquid L1 action types.
enum HyperliquidActionType {
  usdSend,
  spotSend,
  approveAgent,
  cancelOrder,
  order;
}

/// Hyperliquid L1 USD transfer action.
class HlUsdSendAction {
  final bool isMainnet;
  final String destination;
  final String amount; // USD decimal string, e.g. "100.5"
  final int time;      // Unix timestamp milliseconds

  const HlUsdSendAction({
    required this.isMainnet,
    required this.destination,
    required this.amount,
    required this.time,
  });

  Map<String, dynamic> toMessageMap() => {
        'hyperliquidChain': isMainnet ? 'Mainnet' : 'Testnet',
        'destination': destination,
        'amount': amount,
        'time': time,
      };
}

/// Hyperliquid L1 Spot token transfer action.
class HlSpotSendAction {
  final bool isMainnet;
  final String destination;
  final String token;  // e.g. "PURR:0xc4bf3f803ea120301513470b6073f0d4"
  final String amount;
  final int time;

  const HlSpotSendAction({
    required this.isMainnet,
    required this.destination,
    required this.token,
    required this.amount,
    required this.time,
  });

  Map<String, dynamic> toMessageMap() => {
        'hyperliquidChain': isMainnet ? 'Mainnet' : 'Testnet',
        'destination': destination,
        'token': token,
        'amount': amount,
        'time': time,
      };
}

/// Hyperliquid API Agent session key approval action.
class HlApproveAgentAction {
  final bool isMainnet;
  final String agentAddress;
  final String? agentName;
  final int nonce;

  const HlApproveAgentAction({
    required this.isMainnet,
    required this.agentAddress,
    this.agentName,
    required this.nonce,
  });

  Map<String, dynamic> toMessageMap() => {
        'hyperliquidChain': isMainnet ? 'Mainnet' : 'Testnet',
        'agentAddress': agentAddress,
        'agentName': agentName ?? '',
        'nonce': nonce,
      };
}
