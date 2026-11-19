/// Represents a specific network environment (Mainnet, Testnet, Preprod, Devnet, etc.) for a chain.
class ChainNetwork {
  final String id;
  final String name;
  final bool isTestnet;
  final int? networkCode;

  const ChainNetwork({
    required this.id,
    required this.name,
    this.isTestnet = false,
    this.networkCode,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ChainNetwork && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => name;
}
