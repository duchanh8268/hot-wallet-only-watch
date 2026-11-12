import 'package:cardano_core/cardano_core.dart';
import 'package:flutter/material.dart';

import '../services/hd_wallet_sync_service.dart';
import '../services/hot_app_state.dart';
import '../theme/hot_theme.dart';
import 'web_qr_scanner.dart';

/// Opens the Watch-Only Wallet Profile Manager dialog from the top-right wallet button.
Future<void> showWalletProfilesDialog(
  BuildContext context,
  HotAppState appState,
) async {
  await showDialog<void>(
    context: context,
    builder: (ctx) => _WalletProfilesDialog(appState: appState),
  );
}

class _WalletProfilesDialog extends StatelessWidget {
  final HotAppState appState;

  const _WalletProfilesDialog({required this.appState});

  Future<void> _openAddAccountDialog(BuildContext context) async {
    final s = appState.strings;
    final urController = TextEditingController();
    CardanoAccountUr? parsedAccount;
    String? parseError;

    final result = await showDialog<CardanoAccountUr>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(s.addAccountQrBtn),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  height: 240,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: WebQrScanner(
                      onCodeScanned: (code) {
                        if (parsedAccount != null) return;
                        try {
                          final acc = CardanoAccountUr.fromUr(code);
                          parsedAccount = acc;
                          Navigator.of(ctx).pop(acc);
                        } catch (_) {}
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: urController,
                  decoration: InputDecoration(
                    labelText: s.pasteUrOptional,
                    border: const OutlineInputBorder(),
                  ),
                ),
                if (parseError != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    parseError!,
                    style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(null),
              child: Text(s.cancel),
            ),
            FilledButton(
              onPressed: () {
                try {
                  final acc = CardanoAccountUr.fromUr(urController.text.trim());
                  Navigator.of(ctx).pop(acc);
                } catch (e) {
                  setDialogState(() => parseError = e.toString());
                }
              },
              child: Text(s.parseUrBtn),
            ),
          ],
        ),
      ),
    );
    urController.dispose();

    if (result == null || !context.mounted) return;

    if (result.network != appState.network) {
      final switchNet = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(s.networkMismatchTitle),
          content: Text(
            s.networkMismatchBody(
              result.network.id.toUpperCase(),
              appState.network.id.toUpperCase(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(s.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text('Switch -> ${result.network.id.toUpperCase()}'),
            ),
          ],
        ),
      );
      if (switchNet != true || !context.mounted) return;
      await appState.setNetwork(result.network);
    }

    if (!context.mounted) return;
    final nameCtrl = TextEditingController(
      text: result.label ?? 'Ví Watch-Only #${appState.allProfiles.length + 1}',
    );
    final confirmedName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.walletNameLabel),
        content: TextField(
          controller: nameCtrl,
          decoration: InputDecoration(
            labelText: s.walletNameLabel,
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: Text(s.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(nameCtrl.text),
            child: Text(s.save),
          ),
        ],
      ),
    );
    nameCtrl.dispose();

    if (confirmedName != null && context.mounted) {
      await appState.addProfile(name: confirmedName, accountUr: result);
    }
  }

  Future<void> _renameProfile(
    BuildContext context,
    WatchOnlyProfile profile,
  ) async {
    final s = appState.strings;
    final ctrl = TextEditingController(text: profile.name);
    final next = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.rename),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: Text(s.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text),
            child: Text(s.save),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (next != null) {
      await appState.renameProfile(profile.id, next);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        final s = appState.strings;
        final profiles = appState.allProfiles;
        final activeId = appState.activeProfile?.id;

        return AlertDialog(
          title: Row(
            children: [
              const Icon(Icons.account_balance_wallet_outlined, size: 22),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  s.accountsTitle,
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ),
              FilledButton.tonalIcon(
                key: const Key('add_wallet_qr_btn'),
                onPressed: () => _openAddAccountDialog(context),
                icon: const Icon(Icons.qr_code_scanner, size: 18),
                label: Text(s.isVi ? 'Thêm ví' : 'Add Wallet'),
              ),
            ],
          ),
          content: SizedBox(
            width: 560,
            child: profiles.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.account_balance_wallet_outlined,
                          size: 48,
                          color: Colors.white54,
                        ),
                        const SizedBox(height: 10),
                        Text(s.noWalletSelected),
                      ],
                    ),
                  )
                : ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 380),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: profiles.length,
                      itemBuilder: (ctx, i) {
                        final p = profiles[i];
                        final isActive = p.id == activeId;
                        return Card(
                          key: Key('wallet_profile_item_${p.id}'),
                          child: ListTile(
                            leading: Icon(
                              isActive
                                  ? Icons.check_circle
                                  : Icons.account_balance_wallet_outlined,
                              color: isActive ? HotTheme.primary : null,
                            ),
                            title: Wrap(
                              spacing: 6,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                Text(
                                  p.name,
                                  style: const TextStyle(fontWeight: FontWeight.bold),
                                ),
                                Chip(
                                  label: Text(
                                    p.network.id.toUpperCase(),
                                    style: const TextStyle(fontSize: 10),
                                  ),
                                  visualDensity: VisualDensity.compact,
                                  padding: EdgeInsets.zero,
                                ),
                                if (isActive)
                                  Chip(
                                    label: Text(
                                      s.active,
                                      style: const TextStyle(fontSize: 10),
                                    ),
                                    backgroundColor: const Color(0xFF0E3A2F),
                                    visualDensity: VisualDensity.compact,
                                    padding: EdgeInsets.zero,
                                  ),
                              ],
                            ),
                            subtitle: Text(
                              p.acctXvkBech32,
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 11,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onTap: () async {
                              if (p.network != appState.network) {
                                await appState.setNetwork(p.network);
                              }
                              await appState.selectProfile(p.id);
                              if (context.mounted) Navigator.of(context).pop();
                            },
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  tooltip: s.rename,
                                  onPressed: () => _renameProfile(context, p),
                                  icon: const Icon(Icons.edit_outlined, size: 18),
                                ),
                                IconButton(
                                  tooltip: s.delete,
                                  onPressed: () => appState.deleteProfile(p.id),
                                  icon: const Icon(
                                    Icons.delete_outline,
                                    size: 18,
                                    color: Colors.redAccent,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(s.close),
            ),
          ],
        );
      },
    );
  }
}
