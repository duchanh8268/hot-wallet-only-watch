import 'package:cardano_core/cardano_core.dart';
import 'package:chain_core_interface/chain_core_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'chains/bitcoin/screens/btc_dashboard_screen.dart';
import 'chains/evm/screens/evm_dashboard_screen.dart';
import 'chains/solana/screens/sol_dashboard_screen.dart';
import 'chains/sui/screens/sui_dashboard_screen.dart';
import 'screens/broadcast_flow_screen.dart';
import 'screens/dashboard_screen.dart';
import 'screens/multi_chain_overview_screen.dart';
import 'screens/send_tx_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/staking_screen.dart';
import 'services/hot_app_state.dart';
import 'theme/hot_theme.dart';
import 'widgets/wallet_profiles_dialog.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const HotWalletWebApp());
}

class HotWalletWebApp extends StatefulWidget {
  final HotAppState? appState;

  const HotWalletWebApp({super.key, this.appState});

  @override
  State<HotWalletWebApp> createState() => _HotWalletWebAppState();
}

class _HotWalletWebAppState extends State<HotWalletWebApp> {
  late final HotAppState _appState;
  bool _showOverview = false;

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

  @override
  void initState() {
    super.initState();
    _appState = widget.appState ?? HotAppState();
    if (!_appState.loaded) {
      _appState.init();
    }
  }

  @override
  void dispose() {
    if (widget.appState == null) {
      _appState.dispose();
    }
    super.dispose();
  }

  void _openSubScreen(BuildContext context, String title, WidgetBuilder bodyBuilder) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          appBar: AppBar(
            title: Text(title),
            bottom: const PreferredSize(
              preferredSize: Size.fromHeight(1),
              child: Divider(height: 1),
            ),
          ),
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 430),
              child: ListenableBuilder(
                listenable: _appState,
                builder: (ctx, _) => bodyBuilder(ctx),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _openStep2ScanSubmit(BuildContext context) {
    final s = _appState.strings;
    final built = _appState.lastBuiltTx;
    if (built != null) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => BroadcastFlowScreen(
            appState: _appState,
            buildResult: built,
          ),
        ),
      );
      return;
    }

    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.info_outline, color: HotTheme.primary),
            const SizedBox(width: 8),
            Expanded(child: Text(s.needStep1Title)),
          ],
        ),
        content: Text(
          s.needStep1Desc,
          style: const TextStyle(color: HotTheme.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(s.close),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _openSubScreen(context, s.tabSend, (_) => SendTxScreen(appState: _appState));
            },
            child: Text(s.tabSend),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _appState,
      builder: (context, _) {
        final s = _appState.strings;
        return MaterialApp(
          title: s.appTitle,
          debugShowCheckedModeBanner: false,
          locale: Locale(_appState.locale.name),
          supportedLocales: const [Locale('vi'), Locale('en')],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          theme: HotTheme.buildThemeData(),
          home: !_appState.loaded
              ? const Scaffold(body: Center(child: CircularProgressIndicator()))
              : Builder(
                  builder: (shellContext) => _buildHubShell(shellContext, s),
                ),
        );
      },
    );
  }

  static String _cardanoNetworkDisplay(CardanoNetwork net) {
    switch (net) {
      case CardanoNetwork.preprod:
        return 'Preprod';
      case CardanoNetwork.preview:
        return 'Preview';
      case CardanoNetwork.mainnet:
        return 'Mainnet';
    }
  }

  static String _shortNetworkName(ChainNetwork net) {
    final lower = net.name.toLowerCase();
    if (lower.contains('preprod')) return 'Preprod';
    if (lower.contains('preview')) return 'Preview';
    if (lower.contains('mainnet')) return 'Mainnet';
    if (lower.contains('testnet4')) return 'Testnet4';
    if (lower.contains('testnet')) return 'Testnet';
    if (lower.contains('devnet')) return 'Devnet';
    if (lower.contains('sepolia')) return 'Sepolia';
    if (lower.contains('signet')) return 'Signet';
    if (lower.contains('l1')) return 'L1';
    return net.name;
  }

  void _showHotChainNetworkSelector(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: HotTheme.surface,
      constraints: BoxConstraints(
        maxWidth: 430,
        maxHeight: MediaQuery.of(context).size.height * 0.85,
      ),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        side: BorderSide(color: HotTheme.borderSubtle),
      ),
      isScrollControlled: true,
      builder: (ctx) => _HotChainNetworkSelectorModal(
        appState: _appState,
        showOverview: _showOverview,
        onSelectOverview: () {
          setState(() => _showOverview = true);
        },
        onSelectChainAndNetwork: (chain, net) {
          setState(() {
            _showOverview = false;
            _appState.setActiveChain(chain);
            _appState.setActiveChainNetwork(net);
          });
        },
      ),
    );
  }

  Widget _buildHubShell(BuildContext context, dynamic s) {
    final activeNet = _appState.activeChainNetwork;
    final isTestnet = activeNet.isTestnet;
    final isCardano = !_showOverview && _appState.activeChainId == ChainId.cardano;
    final isBitcoin = !_showOverview && _appState.activeChainId == ChainId.bitcoin;
    final isSolana = !_showOverview && _appState.activeChainId == ChainId.solana;
    final isSui = !_showOverview && _appState.activeChainId == ChainId.sui;

    final activeProfileName = isCardano
        ? (_appState.activeProfile?.name ?? s.subtitle)
        : isBitcoin
            ? (_appState.activeBtcProfile?.name ?? (s.isVi ? 'Tài khoản Bitcoin' : 'Bitcoin Account'))
            : isSolana
                ? (_appState.activeSolProfile?.name ?? (s.isVi ? 'Tài khoản Solana' : 'Solana Account'))
                : isSui
                    ? (_appState.activeSuiProfile?.name ?? (s.isVi ? 'Tài khoản Sui' : 'Sui Account'))
                    : (_appState.activeEvmProfile?.name ?? (s.isVi ? 'Tài khoản EVM' : 'EVM Account'));

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 430),
        child: Scaffold(
          appBar: AppBar(
            titleSpacing: 12,
            title: Text(
              _showOverview
                  ? (s.isVi ? 'Danh Mục Đa Chuỗi' : 'Multi-Chain Portfolio')
                  : (isCardano ? s.appTitle : '${_appState.activeChainPlugin.displayName} Watch-Only'),
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
              overflow: TextOverflow.ellipsis,
            ),
            actions: [
              // Quick Portfolio Switcher
              IconButton(
                tooltip: s.isVi ? 'Danh mục đa chuỗi' : 'Multi-Chain Portfolio',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                onPressed: () => setState(() => _showOverview = !_showOverview),
                icon: Icon(
                  _showOverview ? Icons.pie_chart : Icons.pie_chart_outline,
                  size: 20,
                  color: _showOverview ? HotTheme.primary : HotTheme.textSecondary,
                ),
              ),
              if (!_showOverview) ...[
                IconButton(
                  tooltip: s.syncBtn,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                  onPressed: isCardano
                      ? ((_appState.activeProfile == null || _appState.syncing)
                          ? null
                          : _appState.syncActiveWallet)
                      : isBitcoin
                          ? ((_appState.activeBtcProfile == null || _appState.btcLoading)
                              ? null
                              : _appState.refreshBtcState)
                          : ((_appState.activeEvmProfile == null || _appState.evmLoading)
                              ? null
                              : _appState.refreshEvmState),
                  icon: (isCardano
                          ? _appState.syncing
                          : isBitcoin
                              ? _appState.btcLoading
                              : _appState.evmLoading)
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.sync, size: 20),
                ),
              ],
              IconButton(
                key: const Key('appbar_settings_btn'),
                tooltip: s.tabSettings,
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                onPressed: () => _openSubScreen(
                  context,
                  s.tabSettings,
                  (_) => SettingsScreen(appState: _appState),
                ),
                icon: const Icon(Icons.settings_outlined, size: 20),
              ),
              TextButton(
                style: TextButton.styleFrom(
                  minimumSize: const Size(32, 34),
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                ),
                onPressed: _appState.toggleLocale,
                child: Text(
                  _appState.locale.name.toUpperCase(),
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: HotTheme.primary,
                  ),
                ),
              ),
            ],
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(40),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    // 1. Chain & Network Selector Button (Left, under wallet title)
                    Flexible(
                      child: InkWell(
                        key: const Key('chain_network_selector_btn'),
                        onTap: () => _showHotChainNetworkSelector(context),
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: _showOverview
                                ? HotTheme.primary.withValues(alpha: 0.16)
                                : _chainBrandColor(_appState.activeChainId).withValues(alpha: 0.16),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: _showOverview
                                  ? HotTheme.primary.withValues(alpha: 0.5)
                                  : _chainBrandColor(_appState.activeChainId).withValues(alpha: 0.5),
                              width: 1.0,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                _showOverview ? Icons.dashboard : _chainIcon(_appState.activeChainId),
                                size: 13,
                                color: _showOverview
                                    ? HotTheme.primary
                                    : _chainBrandColor(_appState.activeChainId),
                              ),
                              const SizedBox(width: 5),
                              Flexible(
                                child: Text(
                                  _showOverview
                                      ? (s.isVi ? 'Tổng Quan' : 'Overview')
                                      : '${_appState.activeChainPlugin.displayName} ',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    color: Colors.white,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (!_showOverview) ...[
                                Flexible(
                                  child: Text(
                                    isCardano ? _cardanoNetworkDisplay(_appState.network) : _shortNetworkName(activeNet),
                                    style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w800,
                                      color: isTestnet ? HotTheme.primary : HotTheme.warning,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                              const SizedBox(width: 3),
                              const Icon(
                                Icons.keyboard_arrow_down,
                                size: 14,
                                color: HotTheme.textSecondary,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),

                    // 2. Profile Menu Button (when !_showOverview)
                    if (!_showOverview) ...[
                      const SizedBox(width: 8),
                      Flexible(
                        child: InkWell(
                          key: const Key('wallet_profile_menu_btn'),
                          onTap: () => showWalletProfilesDialog(context, _appState),
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: HotTheme.surfaceElevated,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: HotTheme.borderSubtle),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.account_circle_outlined,
                                  size: 13,
                                  color: HotTheme.primary,
                                ),
                                const SizedBox(width: 4),
                                Flexible(
                                  child: Text(
                                    activeProfileName,
                                    style: const TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: HotTheme.textPrimary,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                const SizedBox(width: 2),
                                const Icon(
                                  Icons.keyboard_arrow_down,
                                  size: 14,
                                  color: HotTheme.textSecondary,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          body: _showOverview
              ? MultiChainOverviewScreen(
                  appState: _appState,
                  onOpenSettings: () => _openSubScreen(
                    context,
                    s.tabSettings,
                    (_) => SettingsScreen(appState: _appState),
                  ),
                  onOpenAccounts: () => showWalletProfilesDialog(context, _appState),
                  onSelectChain: (chain) {
                    setState(() {
                      _showOverview = false;
                      _appState.setActiveChain(chain);
                    });
                  },
                )
              : isCardano
                  ? DashboardScreen(
                      appState: _appState,
                      onOpenAccounts: () => showWalletProfilesDialog(context, _appState),
                      onOpenSettings: () => _openSubScreen(
                        context,
                        s.tabSettings,
                        (_) => SettingsScreen(appState: _appState),
                      ),
                      onOpenSendTx: () => _openSubScreen(
                        context,
                        s.tabSend,
                        (_) => SendTxScreen(appState: _appState),
                      ),
                      onOpenStaking: () => _openSubScreen(
                        context,
                        s.tabStaking,
                        (_) => StakingScreen(appState: _appState),
                      ),
                      onOpenScanSubmit: () => _openStep2ScanSubmit(context),
                    )
                  : isBitcoin
                      ? BtcDashboardScreen(appState: _appState)
                      : isSolana
                          ? SolDashboardScreen(appState: _appState)
                          : isSui
                              ? SuiDashboardScreen(appState: _appState)
                              : EvmDashboardScreen(appState: _appState),
        ),
      ),
    );
  }
}

class _HotChainNetworkSelectorModal extends StatefulWidget {
  final HotAppState appState;
  final bool showOverview;
  final void Function(ChainId chain, ChainNetwork network) onSelectChainAndNetwork;
  final VoidCallback onSelectOverview;

  const _HotChainNetworkSelectorModal({
    required this.appState,
    required this.showOverview,
    required this.onSelectChainAndNetwork,
    required this.onSelectOverview,
  });

  @override
  State<_HotChainNetworkSelectorModal> createState() => _HotChainNetworkSelectorModalState();
}

class _HotChainNetworkSelectorModalState extends State<_HotChainNetworkSelectorModal> {
  IHotChainPlugin? _selectedPlugin;

  @override
  Widget build(BuildContext context) {
    final s = widget.appState.strings;
    final isVi = s.isVi;

    return Padding(
      padding: EdgeInsets.only(
        top: 16,
        left: 16,
        right: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        child: _selectedPlugin == null
            ? _buildChainStep(context, isVi)
            : _buildNetworkStep(context, isVi, _selectedPlugin!),
      ),
    );
  }

  Widget _buildChainStep(BuildContext context, bool isVi) {
    return Column(
      key: const ValueKey('hot_step_chain'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: HotTheme.primary.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.hub_outlined, size: 18, color: HotTheme.primary),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                isVi ? 'Chọn Nền Tảng & Mạng' : 'Select Blockchain & Network',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 20, color: HotTheme.textSecondary),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          isVi
              ? 'Chọn nền tảng blockchain hoặc theo dõi toàn bộ danh mục:'
              : 'Choose a blockchain or open the multi-chain portfolio:',
          style: const TextStyle(fontSize: 12, color: HotTheme.textSecondary),
        ),
        const SizedBox(height: 14),
        Flexible(
          child: SingleChildScrollView(
            child: Column(
              children: [
                // Option 0: Multi-Chain Portfolio Overview
                Card(
                  margin: const EdgeInsets.only(bottom: 10),
                  color: widget.showOverview
                      ? HotTheme.primary.withValues(alpha: 0.15)
                      : HotTheme.surfaceElevated,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(
                      color: widget.showOverview ? HotTheme.primary : HotTheme.borderSubtle,
                      width: widget.showOverview ? 1.5 : 1.0,
                    ),
                  ),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
                    leading: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: HotTheme.primary.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(Icons.dashboard, color: HotTheme.primary, size: 20),
                    ),
                    title: Row(
                      children: [
                        Flexible(
                          child: Text(
                            isVi ? 'TỔNG QUAN ĐA CHUỖI' : 'MULTI-CHAIN PORTFOLIO',
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 14,
                              color: Colors.white,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (widget.showOverview) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: HotTheme.primary.withValues(alpha: 0.25),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: HotTheme.primary, width: 0.8),
                            ),
                            child: Text(
                              isVi ? 'Đang xem' : 'Viewing',
                              style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: HotTheme.primary),
                            ),
                          ),
                        ],
                      ],
                    ),
                    subtitle: Text(
                      isVi
                          ? 'Theo dõi số dư 6 blockchain trên 1 màn hình'
                          : 'View balances across all 6 blockchains',
                      style: const TextStyle(fontSize: 11, color: HotTheme.textSecondary),
                    ),
                    trailing: const Icon(Icons.arrow_forward_ios, size: 14, color: HotTheme.textSecondary),
                    onTap: () {
                      widget.onSelectOverview();
                      Navigator.of(context).pop();
                    },
                  ),
                ),
                const Divider(height: 16),

                // Blockchains
                for (final plugin in widget.appState.chainRegistry.allPlugins) ...[
                  Builder(
                    builder: (_) {
                      final isCurrent = !widget.showOverview && widget.appState.activeChainId == plugin.chainId;
                      final brand = _HotWalletWebAppState._chainBrandColor(plugin.chainId);
                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        color: isCurrent ? brand.withValues(alpha: 0.12) : HotTheme.surfaceElevated,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: BorderSide(
                            color: isCurrent ? brand : HotTheme.borderSubtle,
                            width: isCurrent ? 1.5 : 1.0,
                          ),
                        ),
                        child: ListTile(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
                          leading: Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: brand.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Icon(_HotWalletWebAppState._chainIcon(plugin.chainId), color: brand, size: 20),
                          ),
                          title: Row(
                            children: [
                              Flexible(
                                child: Text(
                                  plugin.displayName,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 15,
                                    color: Colors.white,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (isCurrent) ...[
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: brand.withValues(alpha: 0.25),
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(color: brand, width: 0.8),
                                  ),
                                  child: Text(
                                    isVi ? 'Đang chọn' : 'Active',
                                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: brand),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          subtitle: Text(
                            isCurrent
                                ? '${isVi ? 'Mạng' : 'Network'}: ${plugin.chainId == ChainId.cardano ? widget.appState.network.name : widget.appState.activeChainNetwork.name}'
                                : '${plugin.supportedNetworks.length} ${isVi ? 'mạng khả dụng' : 'networks available'}',
                            style: const TextStyle(fontSize: 11, color: HotTheme.textSecondary),
                          ),
                          trailing: const Icon(Icons.arrow_forward_ios, size: 14, color: HotTheme.textSecondary),
                          onTap: () {
                            if (plugin.supportedNetworks.length == 1) {
                              widget.onSelectChainAndNetwork(plugin.chainId, plugin.supportedNetworks.first);
                              Navigator.of(context).pop();
                            } else {
                              setState(() => _selectedPlugin = plugin);
                            }
                          },
                        ),
                      );
                    },
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildNetworkStep(BuildContext context, bool isVi, IHotChainPlugin plugin) {
    final brand = _HotWalletWebAppState._chainBrandColor(plugin.chainId);

    return Column(
      key: const ValueKey('hot_step_network'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back, size: 20, color: Colors.white),
              onPressed: () => setState(() => _selectedPlugin = null),
            ),
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: brand.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(_HotWalletWebAppState._chainIcon(plugin.chainId), size: 16, color: brand),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '${isVi ? 'Mạng' : 'Network'} ${plugin.displayName}',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 20, color: HotTheme.textSecondary),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          isVi
              ? 'Chọn môi trường mạng cho ${plugin.displayName}:'
              : 'Select environment network for ${plugin.displayName}:',
          style: const TextStyle(fontSize: 12, color: HotTheme.textSecondary),
        ),
        const SizedBox(height: 14),
        Flexible(
          child: SingleChildScrollView(
            child: Column(
              children: [
                for (final net in plugin.supportedNetworks) ...[
                  Builder(
                    builder: (_) {
                      final isSelected = !widget.showOverview &&
                          widget.appState.activeChainId == plugin.chainId &&
                          widget.appState.activeChainNetwork.id == net.id;
                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        color: isSelected ? brand.withValues(alpha: 0.15) : HotTheme.surfaceElevated,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: BorderSide(
                            color: isSelected ? brand : HotTheme.borderSubtle,
                            width: isSelected ? 1.5 : 1.0,
                          ),
                        ),
                        child: ListTile(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
                          leading: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: net.isTestnet
                                  ? Colors.greenAccent.withValues(alpha: 0.15)
                                  : HotTheme.warning.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: net.isTestnet
                                    ? Colors.greenAccent.withValues(alpha: 0.4)
                                    : HotTheme.warning.withValues(alpha: 0.4),
                              ),
                            ),
                            child: Text(
                              net.isTestnet ? 'TESTNET' : 'MAINNET',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w800,
                                color: net.isTestnet ? Colors.greenAccent : HotTheme.warning,
                              ),
                            ),
                          ),
                          title: Text(
                            net.name,
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Colors.white),
                          ),
                          subtitle: Text(
                            'ID: ${net.id}',
                            style: const TextStyle(fontSize: 11, color: HotTheme.textSecondary),
                          ),
                          trailing: isSelected
                              ? Icon(Icons.check_circle, color: brand, size: 20)
                              : const Icon(Icons.radio_button_unchecked, size: 18, color: HotTheme.textSecondary),
                          onTap: () {
                            widget.onSelectChainAndNetwork(plugin.chainId, net);
                            Navigator.of(context).pop();
                          },
                        ),
                      );
                    },
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}
