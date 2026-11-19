/// Supported blockchain networks across Cold and Hot wallets.
enum ChainId {
  cardano(
    id: 'cardano',
    displayName: 'Cardano',
    ticker: 'ADA',
    derivationPrefix: "m/1852'/1815'",
  ),
  bitcoin(
    id: 'bitcoin',
    displayName: 'Bitcoin',
    ticker: 'BTC',
    derivationPrefix: "m/84'/0'",
  ),
  ethereum(
    id: 'ethereum',
    displayName: 'Ethereum',
    ticker: 'ETH',
    derivationPrefix: "m/44'/60'",
  ),
  hyperliquid(
    id: 'hyperliquid',
    displayName: 'Hyperliquid',
    ticker: 'HYPE',
    derivationPrefix: "m/44'/60'",
  ),
  solana(
    id: 'solana',
    displayName: 'Solana',
    ticker: 'SOL',
    derivationPrefix: "m/44'/501'",
  ),
  sui(
    id: 'sui',
    displayName: 'Sui',
    ticker: 'SUI',
    derivationPrefix: "m/44'/784'",
  );

  final String id;
  final String displayName;
  final String ticker;
  final String derivationPrefix;

  const ChainId({
    required this.id,
    required this.displayName,
    required this.ticker,
    required this.derivationPrefix,
  });

  static ChainId fromId(String id) {
    return ChainId.values.firstWhere(
      (c) => c.id.toLowerCase() == id.toLowerCase(),
      orElse: () => throw ArgumentError('Unsupported chain id: $id'),
    );
  }
}
