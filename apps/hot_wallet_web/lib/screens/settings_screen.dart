import 'package:cardano_core/cardano_core.dart';
import 'package:flutter/material.dart';

import '../services/hot_app_state.dart';
import '../theme/hot_theme.dart';

class SettingsScreen extends StatefulWidget {
  final HotAppState appState;

  const SettingsScreen({super.key, required this.appState});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final Map<CardanoNetwork, TextEditingController> _controllers;
  final Map<CardanoNetwork, String?> _testStatuses = {};
  final Map<CardanoNetwork, bool> _testing = {};
  late int _gapLimit;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _controllers = {
      for (final net in CardanoNetwork.values)
        net: TextEditingController(text: widget.appState.projectIdFor(net)),
    };
    _gapLimit = widget.appState.gapLimit;
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _testConnection(CardanoNetwork net) async {
    final key = _controllers[net]!.text.trim();
    if (key.isEmpty) {
      setState(() => _testStatuses[net] = 'Error: Empty Project ID');
      return;
    }
    setState(() {
      _testing[net] = true;
      _testStatuses[net] = null;
    });
    try {
      final slot = await widget.appState.testBlockfrostConnection(net, key);
      if (mounted) {
        setState(() => _testStatuses[net] = 'OK • Latest slot: $slot');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _testStatuses[net] = 'Failed: $e');
      }
    } finally {
      if (mounted) setState(() => _testing[net] = false);
    }
  }

  Future<void> _saveAll() async {
    setState(() => _saving = true);
    try {
      await widget.appState.saveSettings(
        projectIds: {
          for (final e in _controllers.entries) e.key: e.value.text.trim(),
        },
        gapLimit: _gapLimit,
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

  @override
  Widget build(BuildContext context) {
    final s = widget.appState.strings;
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
        for (final net in [CardanoNetwork.preprod, CardanoNetwork.preview, CardanoNetwork.mainnet]) ...[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        net.id.toUpperCase(),
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          net.blockfrostBaseUrl,
                          style: const TextStyle(fontSize: 11, color: Colors.white60, fontFamily: 'monospace'),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _controllers[net],
                          obscureText: true,
                          decoration: InputDecoration(
                            labelText: s.projectIdLabel(net.id.toUpperCase()),
                            border: const OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      OutlinedButton(
                        onPressed: _testing[net] == true ? null : () => _testConnection(net),
                        child: Text(
                          _testing[net] == true ? '...' : s.testConnectionBtn,
                        ),
                      ),
                    ],
                  ),
                  if (_testStatuses[net] != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _testStatuses[net]!,
                      style: TextStyle(
                        fontSize: 12,
                        color: _testStatuses[net]!.startsWith('OK')
                            ? HotTheme.success
                            : HotTheme.danger,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
        ],
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
      ],
    );
  }
}
