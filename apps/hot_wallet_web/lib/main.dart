import 'package:cardano_core/cardano_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'screens/broadcast_flow_screen.dart';
import 'screens/dashboard_screen.dart';
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

  Widget _buildHubShell(BuildContext context, dynamic s) {
    final isMainnet = _appState.network == CardanoNetwork.mainnet;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 430),
        child: Scaffold(
          appBar: AppBar(
            titleSpacing: 12,
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  s.appTitle,
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 3),
                InkWell(
                  key: const Key('wallet_profile_menu_btn'),
                  onTap: () => showWalletProfilesDialog(context, _appState),
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: HotTheme.surfaceElevated,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: HotTheme.borderSubtle),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.menu,
                          size: 13,
                          color: HotTheme.primary,
                        ),
                        const SizedBox(width: 5),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: isMainnet
                                ? HotTheme.warning.withValues(alpha: 0.2)
                                : HotTheme.primary.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                              color: isMainnet ? HotTheme.warning : HotTheme.primaryBorder,
                            ),
                          ),
                          child: Text(
                            _appState.network.name.toUpperCase(),
                            style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w800,
                              color: isMainnet ? HotTheme.warning : HotTheme.primary,
                            ),
                          ),
                        ),
                        const SizedBox(width: 5),
                        Flexible(
                          child: Text(
                            _appState.activeProfile?.name ?? s.subtitle,
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
              ],
            ),
            actions: [
              DropdownButtonHideUnderline(
                child: DropdownButton<CardanoNetwork>(
                  value: _appState.network,
                  isDense: true,
                  dropdownColor: HotTheme.surfaceElevated,
                  borderRadius: BorderRadius.circular(10),
                  style: const TextStyle(fontSize: 12, color: HotTheme.textPrimary),
                  items: const [
                    DropdownMenuItem(value: CardanoNetwork.preprod, child: Text('Preprod')),
                    DropdownMenuItem(value: CardanoNetwork.preview, child: Text('Preview')),
                    DropdownMenuItem(
                      value: CardanoNetwork.mainnet,
                      child: Text('Mainnet', style: TextStyle(color: HotTheme.warning)),
                    ),
                  ],
                  onChanged: (net) {
                    if (net != null) _appState.setNetwork(net);
                  },
                ),
              ),
              IconButton(
                tooltip: s.syncBtn,
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                onPressed: (_appState.activeProfile == null || _appState.syncing)
                    ? null
                    : _appState.syncActiveWallet,
                icon: _appState.syncing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.sync, size: 20),
              ),
              IconButton(
                key: const Key('appbar_settings_btn'),
                tooltip: s.tabSettings,
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                onPressed: () => _openSubScreen(
                  context,
                  s.tabSettings,
                  (_) => SettingsScreen(appState: _appState),
                ),
                icon: const Icon(Icons.settings_outlined, size: 20),
              ),
              TextButton(
                style: TextButton.styleFrom(
                  minimumSize: const Size(34, 36),
                  padding: const EdgeInsets.symmetric(horizontal: 6),
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
            bottom: const PreferredSize(
              preferredSize: Size.fromHeight(1),
              child: Divider(height: 1),
            ),
          ),
          body: DashboardScreen(
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
          ),
        ),
      ),
    );
  }
}
