import 'package:cardano_core/cardano_core.dart';
import 'package:flutter/material.dart';

import '../services/conway_tx_builder.dart';
import '../services/hot_app_state.dart';
import '../theme/hot_theme.dart';
import 'broadcast_flow_screen.dart';
import 'dashboard_screen.dart';

enum _DRepOption { alwaysAbstain, alwaysNoConfidence, custom }

class StakingScreen extends StatefulWidget {
  final HotAppState appState;

  const StakingScreen({super.key, required this.appState});

  @override
  State<StakingScreen> createState() => _StakingScreenState();
}

class _StakingScreenState extends State<StakingScreen> {
  final TextEditingController _poolCtrl = TextEditingController();
  final TextEditingController _drepCtrl = TextEditingController();
  _DRepOption _drepOption = _DRepOption.alwaysAbstain;
  String? _error;

  @override
  void dispose() {
    _poolCtrl.dispose();
    _drepCtrl.dispose();
    super.dispose();
  }

  DRep _resolveDRep() {
    switch (_drepOption) {
      case _DRepOption.alwaysAbstain:
        return const DRepAlwaysAbstain();
      case _DRepOption.alwaysNoConfidence:
        return const DRepAlwaysNoConfidence();
      case _DRepOption.custom:
        final decoded = CardanoAddress.decodeDRepId(_drepCtrl.text.trim());
        return decoded.isScriptHash
            ? DRepScriptHash(decoded.hash28)
            : DRepKeyHash(decoded.hash28);
    }
  }

  void _executeAction({
    bool delegate = false,
    bool withdraw = false,
    bool deregister = false,
  }) {
    final profile = widget.appState.activeProfile;
    final sync = widget.appState.syncState;
    if (profile == null || sync == null) {
      setState(() => _error = 'Sync wallet first');
      return;
    }

    try {
      final result = ConwayTxBuilder.buildStakingAction(
        profile: profile,
        syncState: sync,
        poolId: delegate ? _poolCtrl.text.trim() : null,
        drep: delegate ? _resolveDRep() : null,
        withdrawRewards: withdraw,
        deregisterStake: deregister,
      );
      setState(() => _error = null);
      widget.appState.setLastBuiltTx(result);
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => BroadcastFlowScreen(
            appState: widget.appState,
            buildResult: result,
          ),
        ),
      );
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.appState.strings;
    final sync = widget.appState.syncState;
    final stakeInfo = sync?.stakeInfo;

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          s.stakingTitle,
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 14),
        if (sync != null)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    stakeInfo!.registered
                        ? s.stakeStatusRegistered
                        : s.stakeStatusUnregistered,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: stakeInfo.registered ? HotTheme.success : HotTheme.warning,
                    ),
                  ),
                  const SizedBox(height: 8),
                  SelectableText(
                    'Stake Address: ${sync.stakeAddress}',
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  ),
                  if (stakeInfo.poolId != null)
                    Text('Pool: ${sync.poolName ?? stakeInfo.poolId}'),
                  if (stakeInfo.drepId != null)
                    Text('DRep: ${stakeInfo.drepId}'),
                  const SizedBox(height: 8),
                  Text(
                    stakeInfo.registered
                        ? '${s.controlledStakeLabel}: ${formatAda(stakeInfo.controlledAmount)} ADA'
                        : '${s.controlledStakeLabel}: 0 ADA (${s.isVi ? "sẽ stake toàn bộ" : "will stake full"} ${formatAda(sync.totalLovelace)} ADA)',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                      color: HotTheme.balanceAccent,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${s.rewardsAda}: ${formatAda(stakeInfo.withdrawableAmount)} ADA',
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                  ),
                ],
              ),
            ),
          ),
        Card(
          color: HotTheme.stakingCardBg,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: HotTheme.stakingCardBorder),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.info_outline, size: 18, color: HotTheme.balanceAccent),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    s.stakingMechanismNote,
                    style: const TextStyle(fontSize: 12, color: Colors.white70),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _poolCtrl,
                  decoration: InputDecoration(
                    labelText: s.poolIdLabel,
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 14),
                Text(s.drepModeLabel, style: const TextStyle(fontWeight: FontWeight.bold)),
                RadioGroup<_DRepOption>(
                  groupValue: _drepOption,
                  onChanged: (v) {
                    if (v != null) setState(() => _drepOption = v);
                  },
                  child: Column(
                    children: [
                      RadioListTile<_DRepOption>(
                        value: _DRepOption.alwaysAbstain,
                        title: Text(s.drepAlwaysAbstain),
                      ),
                      RadioListTile<_DRepOption>(
                        value: _DRepOption.alwaysNoConfidence,
                        title: Text(s.drepAlwaysNoConf),
                      ),
                      RadioListTile<_DRepOption>(
                        value: _DRepOption.custom,
                        title: Text(s.drepCustom),
                      ),
                    ],
                  ),
                ),
                if (_drepOption == _DRepOption.custom) ...[
                  TextField(
                    controller: _drepCtrl,
                    decoration: const InputDecoration(
                      labelText: 'drep1...',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                FilledButton.icon(
                  onPressed: sync == null ? null : () => _executeAction(delegate: true),
                  icon: const Icon(Icons.how_to_vote),
                  label: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    child: Text(s.delegateBtn),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            OutlinedButton.icon(
              onPressed: (sync != null && sync.stakeInfo.withdrawableAmount > BigInt.zero)
                  ? () => _executeAction(withdraw: true)
                  : null,
              icon: const Icon(Icons.savings),
              label: Text(s.withdrawBtn),
            ),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(foregroundColor: Colors.redAccent),
              onPressed: (sync != null && sync.stakeInfo.registered)
                  ? () => _executeAction(deregister: true)
                  : null,
              icon: const Icon(Icons.link_off),
              label: Text(s.deregisterBtn),
            ),
          ],
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: const TextStyle(color: Colors.redAccent)),
        ],
      ],
    );
  }
}
