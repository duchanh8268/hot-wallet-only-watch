import 'package:flutter/material.dart';

import '../chains/evm/services/evm_rpc_service.dart';
import '../chains/solana/services/solana_rpc_service.dart';
import '../services/cardano_rpc_service.dart';
import '../services/hot_app_state.dart';
import '../theme/hot_theme.dart';

class SettingsScreen extends StatefulWidget {
  final HotAppState appState;

  const SettingsScreen({super.key, required this.appState});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final Map<String, TextEditingController> _rpcControllers;
  final Map<String, String?> _testStatuses = {};
  final Map<String, bool> _testing = {};
  late int _gapLimit;
  bool _saving = false;

  static const Map<String, String> _defaultEndpoints = {
    'cardano_preprod': CardanoRpcService.defaultPreprodRpcUrl,
    'cardano_preview': CardanoRpcService.defaultPreviewRpcUrl,
    'cardano_mainnet': CardanoRpcService.defaultMainnetRpcUrl,
    'btc_testnet4': 'https://mempool.space/testnet4/api',
    'btc_mainnet': 'https://mempool.space/api',
    'eth_sepolia': EvmRpcService.defaultSepoliaRpcUrl,
    'eth_mainnet': EvmRpcService.defaultMainnetRpcUrl,
    'hl_mainnet': 'https://api.hyperliquid.xyz',
    'sol_devnet': SolanaRpcService.defaultDevnetRpcUrl,
    'sol_mainnet-beta': SolanaRpcService.defaultMainnetRpcUrl,
    'sui_testnet': 'https://fullnode.testnet.sui.io:443',
    'sui_mainnet': 'https://fullnode.mainnet.sui.io:443',
  };

  @override
  void initState() {
    super.initState();
    widget.appState.addListener(_onAppStateChanged);
    _rpcControllers = {
      for (final e in _defaultEndpoints.entries)
        e.key: TextEditingController(
          text: widget.appState.getCustomRpcEndpoint(e.key, e.value),
        ),
    };
    _gapLimit = widget.appState.gapLimit;
  }

  void _onAppStateChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.appState.removeListener(_onAppStateChanged);
    for (final c in _rpcControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _testMultiChainEndpoint(String chainKey, String netId, String rpcKey) async {
    final ep = _rpcControllers[rpcKey]?.text.trim() ?? '';
    setState(() {
      _testing[rpcKey] = true;
      _testStatuses[rpcKey] = null;
    });
    try {
      final res = await widget.appState.testEndpointConnection(chainKey, netId, ep);
      if (mounted) {
        setState(() => _testStatuses[rpcKey] = res);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _testStatuses[rpcKey] = 'Thất bại: $e');
      }
    } finally {
      if (mounted) setState(() => _testing[rpcKey] = false);
    }
  }

  Future<void> _saveAll() async {
    setState(() => _saving = true);
    try {
      await widget.appState.saveSettings(
        gapLimit: _gapLimit,
        customRpcEndpoints: {
          for (final e in _rpcControllers.entries)
            if (e.value.text.trim().isNotEmpty &&
                e.value.text.trim() != _defaultEndpoints[e.key])
              e.key: e.value.text.trim(),
        },
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(widget.appState.strings.settingsSaved)),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _buildEndpointRow({
    required String label,
    required String rpcKey,
    required String chainKey,
    required String netId,
    required String hint,
  }) {
    final status = _testStatuses[rpcKey];
    final isTesting = _testing[rpcKey] == true;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                label,
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
              ),
              const Spacer(),
              SizedBox(
                height: 32,
                child: OutlinedButton(
                  onPressed: isTesting ? null : () => _testMultiChainEndpoint(chainKey, netId, rpcKey),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    visualDensity: VisualDensity.compact,
                  ),
                  child: Text(
                    isTesting ? '...' : (widget.appState.strings.isVi ? 'Kiểm tra' : 'Test'),
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _rpcControllers[rpcKey],
            style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
            decoration: InputDecoration(
              hintText: hint,
              isDense: true,
              border: const OutlineInputBorder(),
              contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            ),
          ),
          if (status != null) ...[
            const SizedBox(height: 4),
            Text(
              status,
              style: TextStyle(
                fontSize: 11,
                color: status.startsWith('OK') ? HotTheme.success : HotTheme.danger,
              ),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.appState.strings;
    final isVi = s.isVi;

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          s.settingsTitle,
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: HotTheme.stakingCardBg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: HotTheme.success.withValues(alpha: 0.6)),
          ),
          child: Row(
            children: [
              const Icon(Icons.enhanced_encryption, color: HotTheme.success),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  s.webCryptoBadge,
                  style: const TextStyle(color: HotTheme.textPrimary, fontSize: 13),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // MULTI-CHAIN RPC ACCORDION (Cardano, Bitcoin, EVM, Solana, Sui)
        Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              initiallyExpanded: true,
              tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
              leading: const Icon(Icons.hub, color: HotTheme.primary),
              title: Text(
                isVi ? 'Cấu hình RPC Đa Chuỗi (ADA, BTC, EVM, SOL, SUI)' : 'Multi-Chain RPC (ADA, BTC, EVM, SOL, SUI)',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
              ),
              subtitle: Text(
                isVi
                    ? 'Tự động kết nối không cần API key • Có thể tùy chỉnh URL RPC riêng'
                    : 'Zero-key default endpoints • Custom RPC overrides supported',
                style: const TextStyle(fontSize: 11, color: HotTheme.textSecondary),
              ),
              childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
              children: [
                const Divider(),
                // Cardano
                const Text('Cardano (Koios REST RPC)', style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF0033AD))),
                const SizedBox(height: 6),
                _buildEndpointRow(
                  label: 'Cardano Preprod RPC',
                  rpcKey: 'cardano_preprod',
                  chainKey: 'cardano',
                  netId: 'preprod',
                  hint: _defaultEndpoints['cardano_preprod']!,
                ),
                _buildEndpointRow(
                  label: 'Cardano Preview RPC',
                  rpcKey: 'cardano_preview',
                  chainKey: 'cardano',
                  netId: 'preview',
                  hint: _defaultEndpoints['cardano_preview']!,
                ),
                _buildEndpointRow(
                  label: 'Cardano Mainnet RPC',
                  rpcKey: 'cardano_mainnet',
                  chainKey: 'cardano',
                  netId: 'mainnet',
                  hint: _defaultEndpoints['cardano_mainnet']!,
                ),

                const Divider(),
                // Bitcoin
                const Text('Bitcoin (Mempool.space API)', style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFFF7931A))),
                const SizedBox(height: 6),
                _buildEndpointRow(
                  label: 'Bitcoin Testnet4 API',
                  rpcKey: 'btc_testnet4',
                  chainKey: 'btc',
                  netId: 'testnet4',
                  hint: 'https://mempool.space/testnet4/api',
                ),
                _buildEndpointRow(
                  label: 'Bitcoin Mainnet API',
                  rpcKey: 'btc_mainnet',
                  chainKey: 'btc',
                  netId: 'mainnet',
                  hint: 'https://mempool.space/api',
                ),

                const Divider(),
                // EVM
                const Text('Ethereum & Hyperliquid (JSON-RPC)', style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF627EEA))),
                const SizedBox(height: 6),
                _buildEndpointRow(
                  label: 'Ethereum Sepolia RPC',
                  rpcKey: 'eth_sepolia',
                  chainKey: 'eth',
                  netId: 'sepolia',
                  hint: _defaultEndpoints['eth_sepolia']!,
                ),
                _buildEndpointRow(
                  label: 'Ethereum Mainnet RPC',
                  rpcKey: 'eth_mainnet',
                  chainKey: 'eth',
                  netId: 'mainnet',
                  hint: _defaultEndpoints['eth_mainnet']!,
                ),
                _buildEndpointRow(
                  label: 'Hyperliquid L1 API',
                  rpcKey: 'hl_mainnet',
                  chainKey: 'hl',
                  netId: 'mainnet',
                  hint: _defaultEndpoints['hl_mainnet']!,
                ),

                const Divider(),
                // Solana
                const Text('Solana (Cluster RPC)', style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF9945FF))),
                const SizedBox(height: 6),
                _buildEndpointRow(
                  label: 'Solana Devnet RPC',
                  rpcKey: 'sol_devnet',
                  chainKey: 'sol',
                  netId: 'devnet',
                  hint: _defaultEndpoints['sol_devnet']!,
                ),
                _buildEndpointRow(
                  label: 'Solana Mainnet-Beta RPC',
                  rpcKey: 'sol_mainnet-beta',
                  chainKey: 'sol',
                  netId: 'mainnet-beta',
                  hint: _defaultEndpoints['sol_mainnet-beta']!,
                ),

                const Divider(),
                // Sui
                const Text('Sui (Fullnode JSON-RPC)', style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF4FA2FF))),
                const SizedBox(height: 6),
                _buildEndpointRow(
                  label: 'Sui Testnet Fullnode',
                  rpcKey: 'sui_testnet',
                  chainKey: 'sui',
                  netId: 'testnet',
                  hint: 'https://fullnode.testnet.sui.io:443',
                ),
                _buildEndpointRow(
                  label: 'Sui Mainnet Fullnode',
                  rpcKey: 'sui_mainnet',
                  chainKey: 'sui',
                  netId: 'mainnet',
                  hint: 'https://fullnode.mainnet.sui.io:443',
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: 10),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(child: Text(s.gapLimitLabel)),
                DropdownButton<int>(
                  value: _gapLimit,
                  items: const [
                    DropdownMenuItem(value: 10, child: Text('10')),
                    DropdownMenuItem(value: 20, child: Text('20 (Default)')),
                    DropdownMenuItem(value: 30, child: Text('30')),
                    DropdownMenuItem(value: 50, child: Text('50')),
                  ],
                  onChanged: (v) {
                    if (v != null) setState(() => _gapLimit = v);
                  },
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _saving ? null : _saveAll,
          icon: const Icon(Icons.save),
          label: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Text(s.saveSettingsBtn),
          ),
        ),
        const SizedBox(height: 24),
        Text(
          s.versionInfoTitle,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(s.appVersionLabel, style: const TextStyle(fontWeight: FontWeight.w600)),
                    Text(
                      'v${HotAppState.currentVersion}+${HotAppState.currentBuildNumber}',
                      style: const TextStyle(fontWeight: FontWeight.bold, color: HotTheme.primary),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    OutlinedButton.icon(
                      key: const Key('check_updates_btn'),
                      onPressed: widget.appState.checkingUpdate
                          ? null
                          : () => widget.appState.checkForUpdates(),
                      icon: widget.appState.checkingUpdate
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.refresh, size: 18),
                      label: Text(s.checkUpdatesBtn),
                    ),
                    const SizedBox(width: 12),
                    if (widget.appState.hasUpdateAvailable)
                      FilledButton.icon(
                        key: const Key('apply_update_btn'),
                        onPressed: () => _showUpdateDialog(context),
                        icon: const Icon(Icons.system_update_alt, size: 18),
                        label: Text(s.updateNowBtn),
                      ),
                  ],
                ),
                if (widget.appState.updateStatusMessage != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    widget.appState.updateStatusMessage!,
                    key: const Key('update_status_msg'),
                    style: const TextStyle(fontSize: 12, color: HotTheme.textSecondary),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  void _showUpdateDialog(BuildContext context) {
    final s = widget.appState.strings;
    final info = widget.appState.latestVersion;
    if (info == null) return;

    showDialog<void>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: HotTheme.surfaceElevated,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            const Icon(Icons.system_update, color: HotTheme.primary),
            const SizedBox(width: 8),
            Text(s.updateAvailableTitle),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${s.appVersionLabel}: ${HotAppState.currentVersion} → ${info.version} (build ${info.buildNumber})'),
            const SizedBox(height: 8),
            if (info.releaseNotes.isNotEmpty) ...[
              Text('${s.releaseNotesLabel}:', style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text(info.releaseNotes, style: const TextStyle(color: HotTheme.textSecondary, fontSize: 13)),
              const SizedBox(height: 12),
            ],
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: HotTheme.surface,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.greenAccent.withValues(alpha: 0.4)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.verified_user, color: Colors.greenAccent, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      s.dataBackupPreservedNotice,
                      style: const TextStyle(fontSize: 12, color: Colors.greenAccent),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(),
            child: Text(s.cancel),
          ),
          ElevatedButton(
            key: const Key('confirm_update_now_btn'),
            onPressed: () async {
              Navigator.of(dialogCtx).pop();
              await widget.appState.applyWebUpdate();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: HotTheme.primary,
              foregroundColor: Colors.white,
            ),
            child: Text(s.updateNowBtn),
          ),
        ],
      ),
    );
  }
}
