import 'package:bitcoin_core/bitcoin_core.dart';
import 'package:cardano_core/cardano_core.dart';
import 'package:chain_core_interface/chain_core_interface.dart';
import 'package:evm_core/evm_core.dart';
import 'package:flutter/material.dart';
import 'package:solana_core/solana_core.dart';
import 'package:sui_core/sui_core.dart';

import '../services/hot_app_state.dart';
import '../theme/hot_theme.dart';
import 'web_qr_scanner.dart';

class _ProfileDisplayItem {
  final String id;
  final String name;
  final String networkId;
  final String identifier;
  final Future<void> Function() onSelect;

  const _ProfileDisplayItem({
    required this.id,
    required this.name,
    required this.networkId,
    required this.identifier,
    required this.onSelect,
  });
}

/// Opens the unified Watch-Only Wallet Profile Manager dialog across all 6 blockchains.
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

  List<_ProfileDisplayItem> _itemsForActiveChain(BuildContext context) {
    switch (appState.activeChainId) {
      case ChainId.cardano:
        return [
          for (final p in appState.allProfiles)
            _ProfileDisplayItem(
              id: p.id,
              name: p.name,
              networkId: p.network.id,
              identifier: p.acctXvkBech32,
              onSelect: () async {
                if (p.network != appState.network) {
                  await appState.setNetwork(p.network);
                }
                await appState.selectProfile(p.id);
              },
            ),
        ];
      case ChainId.bitcoin:
        return [
          for (final p in appState.allBtcProfiles)
            _ProfileDisplayItem(
              id: p.id,
              name: p.name,
              networkId: p.networkId,
              identifier: p.receiveAddress,
              onSelect: () async {
                _switchNetworkIfNeeded(p.networkId);
                await appState.selectBtcProfile(p.id);
              },
            ),
        ];
      case ChainId.ethereum:
      case ChainId.hyperliquid:
        return [
          for (final p in appState.currentChainEvmProfiles)
            _ProfileDisplayItem(
              id: p.id,
              name: p.name,
              networkId: p.networkId,
              identifier: p.address,
              onSelect: () async {
                _switchNetworkIfNeeded(p.networkId);
                await appState.selectEvmProfile(p.id);
              },
            ),
        ];
      case ChainId.solana:
        return [
          for (final p in appState.allSolProfiles)
            _ProfileDisplayItem(
              id: p.id,
              name: p.name,
              networkId: p.networkId,
              identifier: p.address,
              onSelect: () async {
                _switchNetworkIfNeeded(p.networkId);
                await appState.selectSolProfile(p.id);
              },
            ),
        ];
      case ChainId.sui:
        return [
          for (final p in appState.allSuiProfiles)
            _ProfileDisplayItem(
              id: p.id,
              name: p.name,
              networkId: p.networkId,
              identifier: p.address,
              onSelect: () async {
                _switchNetworkIfNeeded(p.networkId);
                await appState.selectSuiProfile(p.id);
              },
            ),
        ];
    }
  }

  String? _activeProfileId() {
    switch (appState.activeChainId) {
      case ChainId.cardano:
        return appState.activeProfile?.id;
      case ChainId.bitcoin:
        return appState.activeBtcProfile?.id;
      case ChainId.ethereum:
      case ChainId.hyperliquid:
        return appState.activeEvmProfile?.id;
      case ChainId.solana:
        return appState.activeSolProfile?.id;
      case ChainId.sui:
        return appState.activeSuiProfile?.id;
    }
  }

  void _switchNetworkIfNeeded(String targetNetworkId) {
    if (appState.activeChainNetwork.id == targetNetworkId) return;
    final match = appState.activeChainPlugin.supportedNetworks.where(
      (n) => n.id.toLowerCase() == targetNetworkId.toLowerCase(),
    );
    if (match.isNotEmpty) {
      appState.setActiveChainNetwork(match.first);
    }
  }

  Future<bool?> _confirmNetworkSwitch(
    BuildContext context,
    String targetNetId,
    String currentNetId,
  ) {
    final s = appState.strings;
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.networkMismatchTitle),
        content: Text(
          s.networkMismatchBody(
            targetNetId.toUpperCase(),
            currentNetId.toUpperCase(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(s.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('Switch -> ${targetNetId.toUpperCase()}'),
          ),
        ],
      ),
    );
  }

  Future<void> _openAddAccountDialog(BuildContext context) async {
    final chainId = appState.activeChainId;
    if (chainId == ChainId.cardano) {
      await _openAddCardanoAccountDialog(context);
      return;
    }
    await _openAddMultiChainAccountDialog(context, chainId);
  }

  Future<void> _openAddCardanoAccountDialog(BuildContext context) async {
    final s = appState.strings;
    final result = await showDialog<CardanoAccountUr>(
      context: context,
      builder: (_) => _CardanoAddDialog(strings: s),
    );

    if (result == null || !context.mounted) return;

    if (result.network != appState.network) {
      final switchNet = await _confirmNetworkSwitch(
        context,
        result.network.id,
        appState.network.id,
      );
      if (switchNet != true || !context.mounted) return;
      await appState.setNetwork(result.network);
    }

    if (!context.mounted) return;
    final confirmedName = await _promptText(
      context,
      title: s.walletNameLabel,
      label: s.walletNameLabel,
      initialValue: result.label ?? 'Ví Watch-Only #${appState.allProfiles.length + 1}',
    );

    if (confirmedName != null && context.mounted) {
      await appState.addProfile(name: confirmedName, accountUr: result);
    }
  }

  Future<void> _openAddMultiChainAccountDialog(
    BuildContext context,
    ChainId chainId,
  ) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _MultiChainAddDialog(
        appState: appState,
        chainId: chainId,
        onImport: _tryImportChainAccount,
      ),
    );
  }

  Future<bool> _tryImportChainAccount({
    required BuildContext context,
    required ChainId chainId,
    required String code,
    required String customName,
    required void Function(String) onError,
  }) async {
    final isVi = appState.strings.isVi;
    final trimmed = code.trim();
    if (trimmed.isEmpty) {
      onError(isVi ? 'Vui lòng quét QR hoặc dán mã ví' : 'Please scan QR or paste wallet data');
      return false;
    }

    try {
      switch (chainId) {
        case ChainId.bitcoin:
          if (trimmed.toLowerCase().startsWith('ur:btc-account/')) {
            final btcAcc = BtcAccountUr.fromUr(trimmed);
            if (btcAcc.network != appState.activeChainNetwork.id) {
              _switchNetworkIfNeeded(btcAcc.network);
            }
            await appState.addBtcProfile(
              name: customName.trim().isNotEmpty
                  ? customName.trim()
                  : (btcAcc.label ?? 'Bitcoin Account #${appState.allBtcProfiles.length + 1}'),
              receiveAddress: btcAcc.receiveAddress,
              networkId: btcAcc.network,
              accountIndex: btcAcc.accountIndex,
              masterFingerprint: btcAcc.masterFingerprint,
              accountXpub: btcAcc.accountXpub,
            );
            return true;
          }
          final lowerBtc = trimmed.toLowerCase();
          final expectedHrp = appState.activeChainNetwork.isTestnet ? 'tb' : 'bc';
          if (lowerBtc.startsWith(expectedHrp) && trimmed.length >= 14) {
            await appState.addBtcProfile(
              name: customName.trim().isNotEmpty
                  ? customName.trim()
                  : 'Bitcoin Account #${appState.allBtcProfiles.length + 1}',
              receiveAddress: trimmed,
              networkId: appState.activeChainNetwork.id,
              accountIndex: 0,
            );
            return true;
          }
          onError(isVi
              ? 'Mã Bitcoin không hợp lệ (cần ur:btc-account hoặc $expectedHrp...)'
              : 'Invalid Bitcoin input (expected ur:btc-account or $expectedHrp...)');
          return false;

        case ChainId.ethereum:
        case ChainId.hyperliquid:
          String address;
          int accountIndex = 0;
          if (trimmed.toLowerCase().startsWith('ur:eth-account')) {
            final ur = EthAccountUr.fromUr(trimmed);
            address = ur.address;
            accountIndex = ur.accountIndex;
          } else if (trimmed.startsWith('0x') && trimmed.length == 42) {
            address = Eip55.toChecksumAddress(trimmed);
          } else {
            onError(isVi
                ? 'Hỗ trợ ur:eth-account... hoặc địa chỉ 0x (42 ký tự)'
                : 'Supports ur:eth-account... or 42-char 0x address');
            return false;
          }
          final existingCount = appState.currentChainEvmProfiles.length;
          await appState.addEvmProfile(
            name: customName.trim().isNotEmpty
                ? customName.trim()
                : '${appState.activeChainPlugin.displayName} Account #${existingCount + 1}',
            chainId: chainId,
            address: address,
            networkId: appState.activeChainNetwork.id,
            accountIndex: accountIndex,
          );
          return true;

        case ChainId.solana:
          if (trimmed.toLowerCase().startsWith('ur:sol-account')) {
            final ur = SolAccountUr.fromUr(trimmed);
            if (ur.network != appState.activeChainNetwork.id) {
              _switchNetworkIfNeeded(ur.network);
            }
            await appState.addSolProfile(
              name: customName.trim().isNotEmpty
                  ? customName.trim()
                  : (ur.label ?? 'Solana Account #${appState.allSolProfiles.length + 1}'),
              address: ur.address,
              networkId: ur.network,
              accountIndex: ur.accountIndex,
            );
            return true;
          }
          if (trimmed.length >= 32 && trimmed.length <= 44) {
            final decoded = Base58.decode(trimmed);
            if (decoded.length == 32) {
              await appState.addSolProfile(
                name: customName.trim().isNotEmpty
                    ? customName.trim()
                    : 'Solana Account #${appState.allSolProfiles.length + 1}',
                address: trimmed,
                networkId: appState.activeChainNetwork.id,
                accountIndex: 0,
              );
              return true;
            }
          }
          onError(isVi
              ? 'Mã Solana không hợp lệ (cần ur:sol-account hoặc Base58 32-byte)'
              : 'Invalid Solana input (expected ur:sol-account or Base58 address)');
          return false;

        case ChainId.sui:
          if (trimmed.toLowerCase().startsWith('ur:sui-account')) {
            final ur = SuiAccountUr.fromUr(trimmed);
            if (ur.network != appState.activeChainNetwork.id) {
              _switchNetworkIfNeeded(ur.network);
            }
            await appState.addSuiProfile(
              name: customName.trim().isNotEmpty
                  ? customName.trim()
                  : (ur.label ?? 'Sui Account #${appState.allSuiProfiles.length + 1}'),
              address: ur.address,
              networkId: ur.network,
              accountIndex: ur.accountIndex,
              addressIndex: ur.addressIndex,
            );
            return true;
          }
          if (RegExp(r'^0x[0-9a-fA-F]{4,64}$').hasMatch(trimmed)) {
            await appState.addSuiProfile(
              name: customName.trim().isNotEmpty
                  ? customName.trim()
                  : 'Sui Account #${appState.allSuiProfiles.length + 1}',
              address: trimmed,
              networkId: appState.activeChainNetwork.id,
              accountIndex: 0,
              addressIndex: 0,
            );
            return true;
          }
          onError(isVi
              ? 'Mã Sui không hợp lệ (cần ur:sui-account hoặc địa chỉ 0x...)'
              : 'Invalid Sui input (expected ur:sui-account or 0x... address)');
          return false;

        case ChainId.cardano:
          return false;
      }
    } catch (e) {
      onError('${isVi ? 'Lỗi xử lý' : 'Parse error'}: $e');
      return false;
    }
  }

  Future<String?> _promptText(
    BuildContext context, {
    required String title,
    String? label,
    required String initialValue,
    Key? inputKey,
    Key? confirmKey,
  }) {
    final s = appState.strings;
    return showDialog<String>(
      context: context,
      builder: (_) => _TextPromptDialog(
        title: title,
        label: label,
        initialValue: initialValue,
        cancelLabel: s.cancel,
        saveLabel: s.save,
        inputKey: inputKey,
        confirmKey: confirmKey,
      ),
    );
  }

  Future<void> _renameProfile(
    BuildContext context,
    _ProfileDisplayItem item,
  ) async {
    final s = appState.strings;
    final next = await _promptText(
      context,
      title: s.rename,
      initialValue: item.name,
      inputKey: const Key('rename_wallet_input'),
      confirmKey: const Key('confirm_rename_wallet_btn'),
    );
    if (next == null || next.trim().isEmpty) return;

    switch (appState.activeChainId) {
      case ChainId.cardano:
        await appState.renameProfile(item.id, next);
      case ChainId.bitcoin:
        await appState.renameBtcProfile(item.id, next);
      case ChainId.ethereum:
      case ChainId.hyperliquid:
        await appState.renameEvmProfile(item.id, next);
      case ChainId.solana:
        await appState.renameSolProfile(item.id, next);
      case ChainId.sui:
        await appState.renameSuiProfile(item.id, next);
    }
  }

  Future<void> _deleteProfile(String id) async {
    switch (appState.activeChainId) {
      case ChainId.cardano:
        await appState.deleteProfile(id);
      case ChainId.bitcoin:
        await appState.deleteBtcProfile(id);
      case ChainId.ethereum:
      case ChainId.hyperliquid:
        await appState.deleteEvmProfile(id);
      case ChainId.solana:
        await appState.deleteSolProfile(id);
      case ChainId.sui:
        await appState.deleteSuiProfile(id);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        final s = appState.strings;
        final items = _itemsForActiveChain(context);
        final activeId = _activeProfileId();
        final chainLabel = appState.activeChainPlugin.displayName;

        return AlertDialog(
          insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
          title: Row(
            children: [
              const Icon(Icons.account_balance_wallet_outlined, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      s.accountsTitle,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      chainLabel,
                      style: const TextStyle(fontSize: 11, color: HotTheme.textSecondary),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              FilledButton.tonalIcon(
                key: const Key('add_wallet_qr_btn'),
                onPressed: () => _openAddAccountDialog(context),
                icon: const Icon(Icons.qr_code_scanner, size: 16),
                label: Text(
                  s.isVi ? 'Thêm ví' : 'Add',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: SizedBox(
              width: 390,
              child: items.isEmpty
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
                          Text(s.noWalletSelected, textAlign: TextAlign.center),
                        ],
                      ),
                    )
                  : ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 380),
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: items.length,
                        itemBuilder: (ctx, i) {
                          final p = items[i];
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
                                runSpacing: 4,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  Text(
                                    p.name,
                                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                                  ),
                                  Chip(
                                    label: Text(
                                      p.networkId.toUpperCase(),
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
                                p.identifier,
                                style: const TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 11,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              onTap: () async {
                                await p.onSelect();
                                if (context.mounted) Navigator.of(context).pop();
                              },
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    key: Key('rename_profile_btn_${p.id}'),
                                    tooltip: s.rename,
                                    onPressed: () => _renameProfile(context, p),
                                    icon: const Icon(Icons.edit_outlined, size: 18),
                                  ),
                                  IconButton(
                                    key: Key('delete_profile_btn_${p.id}'),
                                    tooltip: s.delete,
                                    onPressed: () => _deleteProfile(p.id),
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

class _CardanoAddDialog extends StatefulWidget {
  final dynamic strings;
  const _CardanoAddDialog({required this.strings});

  @override
  State<_CardanoAddDialog> createState() => _CardanoAddDialogState();
}

class _CardanoAddDialogState extends State<_CardanoAddDialog> {
  final _urController = TextEditingController();
  CardanoAccountUr? _parsedAccount;
  String? _parseError;

  @override
  void dispose() {
    _urController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.strings;
    return AlertDialog(
      title: Text(s.addAccountQrBtn),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: 220,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: WebQrScanner(
                    onCodeScanned: (code) {
                      if (_parsedAccount != null) return;
                      try {
                        final acc = CardanoAccountUr.fromUr(code);
                        _parsedAccount = acc;
                        Navigator.of(context).pop(acc);
                      } catch (_) {}
                    },
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('add_wallet_input'),
                controller: _urController,
                decoration: InputDecoration(
                  labelText: s.pasteUrOptional,
                  border: const OutlineInputBorder(),
                ),
              ),
              if (_parseError != null) ...[
                const SizedBox(height: 6),
                Text(
                  _parseError!,
                  style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: Text(s.cancel),
        ),
        FilledButton(
          key: const Key('confirm_add_wallet_btn'),
          onPressed: () {
            try {
              final acc = CardanoAccountUr.fromUr(_urController.text.trim());
              Navigator.of(context).pop(acc);
            } catch (e) {
              setState(() => _parseError = e.toString());
            }
          },
          child: Text(s.parseUrBtn),
        ),
      ],
    );
  }
}

class _MultiChainAddDialog extends StatefulWidget {
  final HotAppState appState;
  final ChainId chainId;
  final Future<bool> Function({
    required BuildContext context,
    required ChainId chainId,
    required String code,
    required String customName,
    required void Function(String) onError,
  }) onImport;

  const _MultiChainAddDialog({
    required this.appState,
    required this.chainId,
    required this.onImport,
  });

  @override
  State<_MultiChainAddDialog> createState() => _MultiChainAddDialogState();
}

class _MultiChainAddDialogState extends State<_MultiChainAddDialog> {
  final _nameCtrl = TextEditingController();
  final _inputCtrl = TextEditingController();
  String? _errorText;
  bool _handledQr = false;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _inputCtrl.dispose();
    super.dispose();
  }

  String _hintLabel(bool isVi) {
    switch (widget.chainId) {
      case ChainId.bitcoin:
        return isVi
            ? 'Dán ur:btc-account... hoặc địa chỉ bc1q... / tb1q...'
            : 'Paste ur:btc-account... or bc1q... / tb1q... address';
      case ChainId.ethereum:
      case ChainId.hyperliquid:
        return isVi
            ? 'Dán ur:eth-account... hoặc địa chỉ 0x...'
            : 'Paste ur:eth-account... or 0x... address';
      case ChainId.solana:
        return isVi
            ? 'Dán ur:sol-account... hoặc địa chỉ Base58'
            : 'Paste ur:sol-account... or Base58 address';
      case ChainId.sui:
        return isVi
            ? 'Dán ur:sui-account... hoặc địa chỉ 0x...'
            : 'Paste ur:sui-account... or 0x... address';
      case ChainId.cardano:
        return widget.appState.strings.pasteUrOptional;
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.appState.strings;
    final isVi = s.isVi;
    return AlertDialog(
      title: Text(
        isVi
            ? 'Thêm Tài Khoản ${widget.appState.activeChainPlugin.displayName}'
            : 'Add ${widget.appState.activeChainPlugin.displayName} Account',
      ),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                key: const Key('add_wallet_name_input'),
                controller: _nameCtrl,
                decoration: InputDecoration(
                  labelText: isVi ? 'Tên ví / nhãn (tùy chọn)' : 'Wallet label (optional)',
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 200,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: WebQrScanner(
                    onCodeScanned: (code) async {
                      if (_handledQr) return;
                      final ok = await widget.onImport(
                        context: context,
                        chainId: widget.chainId,
                        code: code,
                        customName: _nameCtrl.text,
                        onError: (err) => setState(() => _errorText = err),
                      );
                      if (ok && context.mounted) {
                        _handledQr = true;
                        Navigator.of(context).pop();
                      }
                    },
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('add_wallet_input'),
                controller: _inputCtrl,
                maxLines: 2,
                decoration: InputDecoration(
                  labelText: _hintLabel(isVi),
                  border: const OutlineInputBorder(),
                ),
              ),
              if (_errorText != null) ...[
                const SizedBox(height: 8),
                Text(
                  _errorText!,
                  style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(s.cancel),
        ),
        FilledButton(
          key: const Key('confirm_add_wallet_btn'),
          onPressed: () async {
            final ok = await widget.onImport(
              context: context,
              chainId: widget.chainId,
              code: _inputCtrl.text.trim(),
              customName: _nameCtrl.text,
              onError: (err) => setState(() => _errorText = err),
            );
            if (ok && context.mounted) {
              Navigator.of(context).pop();
            }
          },
          child: Text(isVi ? 'Lưu ví' : 'Import'),
        ),
      ],
    );
  }
}

class _TextPromptDialog extends StatefulWidget {
  final String title;
  final String? label;
  final String initialValue;
  final String cancelLabel;
  final String saveLabel;
  final Key? inputKey;
  final Key? confirmKey;

  const _TextPromptDialog({
    required this.title,
    this.label,
    required this.initialValue,
    required this.cancelLabel,
    required this.saveLabel,
    this.inputKey,
    this.confirmKey,
  });

  @override
  State<_TextPromptDialog> createState() => _TextPromptDialogState();
}

class _TextPromptDialogState extends State<_TextPromptDialog> {
  late final TextEditingController _ctrl = TextEditingController(text: widget.initialValue);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        key: widget.inputKey,
        controller: _ctrl,
        decoration: InputDecoration(
          labelText: widget.label,
          border: const OutlineInputBorder(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: Text(widget.cancelLabel),
        ),
        FilledButton(
          key: widget.confirmKey,
          onPressed: () => Navigator.of(context).pop(_ctrl.text),
          child: Text(widget.saveLabel),
        ),
      ],
    );
  }
}
