import 'package:cardano_core/cardano_core.dart';
import 'package:chain_core_interface/chain_core_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/hot_app_state.dart';
import '../theme/hot_theme.dart';

class MultiChainOverviewScreen extends StatelessWidget {
  final HotAppState appState;
  final VoidCallback onOpenSettings;
  final VoidCallback onOpenAccounts;
  final ValueChanged<ChainId>? onSelectChain;

  const MultiChainOverviewScreen({
    super.key,
    required this.appState,
    required this.onOpenSettings,
    required this.onOpenAccounts,
    this.onSelectChain,
  });

  static Color _chainBrandColor(ChainId chainId) {
    switch (chainId) {
      case ChainId.cardano:
        return const Color(0xFF2A60E4);
      case ChainId.bitcoin:
        return const Color(0xFFF7931A);
      case ChainId.ethereum:
        return const Color(0xFF627EEA);
      case ChainId.hyperliquid:
        return const Color(0xFF00D2B4);
      case ChainId.solana:
        return const Color(0xFF9945FF);
      case ChainId.sui:
        return const Color(0xFF4FA2FF);
    }
  }

  static IconData _chainIcon(ChainId chainId) {
    switch (chainId) {
      case ChainId.cardano:
        return Icons.hub_outlined;
      case ChainId.bitcoin:
        return Icons.currency_bitcoin;
      case ChainId.ethereum:
        return Icons.diamond_outlined;
      case ChainId.hyperliquid:
        return Icons.water_drop_outlined;
      case ChainId.solana:
        return Icons.bolt;
      case ChainId.sui:
        return Icons.waves;
    }
  }

  void _copyToClipboard(BuildContext context, String text, String label) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Đã sao chép địa chỉ $label'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Widget _buildAssetCard({
    required BuildContext context,
    required ChainId chainId,
    required String chainName,
    required String networkName,
    required bool isTestnet,
    required String balanceFormatted,
    required String secondaryBalance,
    required String? address,
    required String accountName,
    required VoidCallback onTap,
  }) {
    final brand = _chainBrandColor(chainId);
    final isVi = appState.strings.isVi;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: brand.withValues(alpha: 0.35), width: 1.2),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header: Icon + Name + Network Badge + Forward Arrow
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: brand.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: brand.withValues(alpha: 0.5)),
                    ),
                    child: Icon(_chainIcon(chainId), size: 20, color: brand),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          chainName,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            color: HotTheme.textPrimary,
                          ),
                        ),
                        Text(
                          accountName,
                          style: const TextStyle(
                            fontSize: 11,
                            color: HotTheme.textSecondary,
                            fontWeight: FontWeight.w500,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: isTestnet
                          ? Colors.greenAccent.withValues(alpha: 0.15)
                          : HotTheme.warning.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: isTestnet
                            ? Colors.greenAccent.withValues(alpha: 0.4)
                            : HotTheme.warning.withValues(alpha: 0.4),
                      ),
                    ),
                    child: Text(
                      networkName.toUpperCase(),
                      style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.w800,
                        color: isTestnet ? Colors.greenAccent : HotTheme.warning,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Icon(Icons.arrow_forward_ios, size: 14, color: HotTheme.textSecondary),
                ],
              ),
              const SizedBox(height: 14),

              // Balance Display
              Text(
                balanceFormatted,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w900,
                  color: Colors.white,
                  letterSpacing: 0.3,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                secondaryBalance,
                style: const TextStyle(
                  fontSize: 12,
                  fontFamily: 'monospace',
                  color: HotTheme.textSecondary,
                ),
              ),

              if (address != null && address.isNotEmpty) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.black26,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.white10),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          address,
                          style: const TextStyle(
                            fontSize: 11,
                            fontFamily: 'monospace',
                            color: Colors.white70,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                        tooltip: isVi ? 'Sao chép địa chỉ' : 'Copy address',
                        onPressed: () => _copyToClipboard(context, address, chainName),
                        icon: const Icon(Icons.copy, size: 14, color: HotTheme.primary),
                      ),
                    ],
                  ),
                ),
              ],

              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Text(
                    isVi ? 'Vào chi tiết dashboard →' : 'Open chain dashboard →',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: brand,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  static BigInt _parseBigInt(dynamic val) {
    if (val == null) return BigInt.zero;
    if (val is BigInt) return val;
    if (val is int) return BigInt.from(val);
    if (val is String) {
      return BigInt.tryParse(val) ?? BigInt.zero;
    }
    return BigInt.zero;
  }

  void _handleSelectChain(ChainId chain) {
    if (onSelectChain != null) {
      onSelectChain!(chain);
    } else {
      appState.setActiveChain(chain);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = appState.strings;
    final isVi = s.isVi;

    // Cardano Info
    final cardanoProfile = appState.activeProfile;
    final cardanoLovelace = appState.syncState?.totalLovelace ?? BigInt.zero;
    final cardanoAda = (cardanoLovelace.toDouble() / 1000000).toStringAsFixed(6);
    final cardanoAddr = cardanoProfile != null
        ? CardanoAccountPublicKey.fromBech32(cardanoProfile.acctXvkBech32).deriveBaseAddress(role: 0, index: 0, network: appState.network)
        : '';

    // Bitcoin Info
    final btcProfile = appState.activeBtcProfile;
    final btcSat = _parseBigInt(appState.btcAccountState?['balanceSat']);
    final btcVal = (btcSat.toDouble() / 100000000).toStringAsFixed(8);
    final btcAddr = btcProfile?.receiveAddress ?? '';

    // Ethereum Info
    final ethProfile = appState.allEvmProfiles.where((p) => p.chainId == ChainId.ethereum).firstOrNull;
    final ethWei = _parseBigInt(appState.evmAccountState?['balanceWei']);
    final ethVal = (ethWei.toDouble() / 1e18).toStringAsFixed(6);
    final ethAddr = ethProfile?.address ?? '';

    // Hyperliquid Info
    final hlProfile = appState.allEvmProfiles.where((p) => p.chainId == ChainId.hyperliquid).firstOrNull;
    final hlValue = appState.evmAccountState?['accountValueUsd']?.toString() ??
        appState.evmAccountState?['hlAccountValue']?.toString() ??
        '0.00 USDC';
    final hlAddr = hlProfile?.address ?? '';

    // Solana Info
    final solProfile = appState.activeSolProfile;
    final solLamports = _parseBigInt(appState.solAccountState?['lamports'] ?? appState.solAccountState?['balanceLamports']);
    final solVal = appState.solAccountState?['sol']?.toString() ?? (solLamports.toDouble() / 1000000000).toStringAsFixed(4);
    final solAddr = solProfile?.address ?? '';

    // Sui Info
    final suiProfile = appState.activeSuiProfile;
    final suiMist = _parseBigInt(appState.suiAccountState?['mist'] ?? appState.suiAccountState?['balanceMist']);
    final suiVal = appState.suiAccountState?['sui']?.toString() ?? (suiMist.toDouble() / 1000000000).toStringAsFixed(4);
    final suiAddr = suiProfile?.address ?? '';

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Portfolio Overview Header Banner
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                HotTheme.primarySurface,
                HotTheme.surfaceElevated,
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: HotTheme.primaryBorder),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.account_balance_wallet, color: HotTheme.primary, size: 24),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      isVi ? 'Danh Mục Đa Chuỗi (Portfolio)' : 'Multi-Chain Portfolio',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: onOpenSettings,
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      visualDensity: VisualDensity.compact,
                    ),
                    icon: const Icon(Icons.settings, size: 14),
                    label: Text(isVi ? 'RPC & Node' : 'RPC Nodes', style: const TextStyle(fontSize: 11)),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                isVi
                    ? 'Quản lý tập trung 6 Blockchain qua giao thức Air-Gap BC-UR an toàn tuyệt đối. Bấm vào từng chuỗi để xem chi tiết hoặc thực hiện giao dịch.'
                    : 'Unified multi-chain view across 6 blockchains via Zero-Network BC-UR protocol. Tap any card to open its dedicated dashboard.',
                style: const TextStyle(fontSize: 12, color: HotTheme.textSecondary),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // 1. CARDANO CARD
        _buildAssetCard(
          context: context,
          chainId: ChainId.cardano,
          chainName: 'Cardano (ADA)',
          networkName: appState.network.name,
          isTestnet: appState.network != CardanoNetwork.mainnet,
          balanceFormatted: '$cardanoAda ADA',
          secondaryBalance: '≈ $cardanoLovelace lovelace',
          address: cardanoAddr,
          accountName: cardanoProfile?.name ?? (isVi ? 'Chưa nạp ví Cardano' : 'No Cardano account'),
          onTap: () => _handleSelectChain(ChainId.cardano),
        ),

        // 2. BITCOIN CARD
        _buildAssetCard(
          context: context,
          chainId: ChainId.bitcoin,
          chainName: 'Bitcoin (BTC)',
          networkName: 'Testnet4 / Mainnet',
          isTestnet: true,
          balanceFormatted: '$btcVal BTC',
          secondaryBalance: '≈ $btcSat satoshis',
          address: btcAddr,
          accountName: btcProfile?.name ?? (isVi ? 'Chưa nạp ví Bitcoin' : 'No Bitcoin account'),
          onTap: () => _handleSelectChain(ChainId.bitcoin),
        ),

        // 3. ETHEREUM CARD
        _buildAssetCard(
          context: context,
          chainId: ChainId.ethereum,
          chainName: 'Ethereum (ETH)',
          networkName: 'Sepolia / Mainnet',
          isTestnet: true,
          balanceFormatted: '$ethVal ETH',
          secondaryBalance: '≈ $ethWei Wei',
          address: ethAddr,
          accountName: ethProfile?.name ?? (isVi ? 'Chưa nạp ví Ethereum' : 'No Ethereum account'),
          onTap: () => _handleSelectChain(ChainId.ethereum),
        ),

        // 4. HYPERLIQUID CARD
        _buildAssetCard(
          context: context,
          chainId: ChainId.hyperliquid,
          chainName: 'Hyperliquid (HYPE / L1)',
          networkName: 'Hyperliquid L1',
          isTestnet: false,
          balanceFormatted: hlValue,
          secondaryBalance: 'Perps / Spot Clearinghouse',
          address: hlAddr,
          accountName: hlProfile?.name ?? (isVi ? 'Chưa nạp ví Hyperliquid' : 'No Hyperliquid account'),
          onTap: () => _handleSelectChain(ChainId.hyperliquid),
        ),

        // 5. SOLANA CARD
        _buildAssetCard(
          context: context,
          chainId: ChainId.solana,
          chainName: 'Solana (SOL)',
          networkName: 'Devnet / Mainnet',
          isTestnet: true,
          balanceFormatted: '$solVal SOL',
          secondaryBalance: '≈ $solLamports lamports',
          address: solAddr,
          accountName: solProfile?.name ?? (isVi ? 'Chưa nạp ví Solana' : 'No Solana account'),
          onTap: () => _handleSelectChain(ChainId.solana),
        ),

        // 6. SUI CARD
        _buildAssetCard(
          context: context,
          chainId: ChainId.sui,
          chainName: 'Sui (SUI)',
          networkName: 'Testnet / Mainnet',
          isTestnet: true,
          balanceFormatted: '$suiVal SUI',
          secondaryBalance: '≈ $suiMist MIST',
          address: suiAddr,
          accountName: suiProfile?.name ?? (isVi ? 'Chưa nạp ví Sui' : 'No Sui account'),
          onTap: () => _handleSelectChain(ChainId.sui),
        ),
      ],
    );
  }
}
