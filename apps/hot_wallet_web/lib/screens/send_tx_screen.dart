import 'package:cardano_core/cardano_core.dart';
import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import '../services/conway_tx_builder.dart';
import '../services/hd_wallet_sync_service.dart';
import '../services/hot_app_state.dart';
import '../theme/hot_theme.dart';
import '../utils/token_utils.dart';
import '../widgets/web_qr_scanner.dart';
import 'broadcast_flow_screen.dart';
import 'dashboard_screen.dart';

class SendTxScreen extends StatefulWidget {
  final HotAppState appState;

  const SendTxScreen({super.key, required this.appState});

  @override
  State<SendTxScreen> createState() => _SendTxScreenState();
}

class _SendTxScreenState extends State<SendTxScreen> {
  final TextEditingController _recipientCtrl = TextEditingController();
  final TextEditingController _adaCtrl = TextEditingController();
  final Map<AssetKey, TextEditingController> _tokenCtrls = {};
  final List<AssetKey> _selectedOrder = [];

  bool _autoMinAda = true;
  bool _sendMaxAda = false;
  bool _sweepAll = false;
  String? _error;

  String? _lastProfileId;
  CardanoNetwork? _lastNetwork;

  @override
  void dispose() {
    _recipientCtrl.dispose();
    _adaCtrl.dispose();
    for (final c in _tokenCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _reconcileWalletState(WatchOnlyProfile? profile, WalletSyncState? sync) {
    final profileChanged = profile?.id != _lastProfileId;
    final networkChanged = widget.appState.network != _lastNetwork;
    if (profileChanged || networkChanged) {
      _lastProfileId = profile?.id;
      _lastNetwork = widget.appState.network;
      _selectedOrder.clear();
      for (final c in _tokenCtrls.values) {
        c.dispose();
      }
      _tokenCtrls.clear();
      _sendMaxAda = false;
      _sweepAll = false;
      _error = null;
    }

    final owned = sync?.totalMultiAsset.assets ?? const <AssetKey, BigInt>{};
    _selectedOrder.removeWhere((k) {
      final keep = (owned[k] ?? BigInt.zero) > BigInt.zero;
      if (!keep) {
        _tokenCtrls.remove(k)?.dispose();
      }
      return !keep;
    });
  }

  Future<void> _scanRecipientAddress() async {
    final s = widget.appState.strings;
    final scanned = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.scanRecipientQr),
        content: SizedBox(
          width: 380,
          height: 280,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: WebQrScanner(
              onCodeScanned: (raw) {
                final clean = raw.trim().replaceFirst('web+cardano:', '');
                try {
                  CardanoAddress.decode(clean);
                  Navigator.of(ctx).pop(clean);
                } catch (_) {}
              },
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: Text(s.cancel),
          ),
        ],
      ),
    );
    if (scanned != null && mounted) {
      setState(() {
        _recipientCtrl.text = scanned;
        _maybeApplyAutoMinAda();
      });
    }
  }

  BigInt _parseAdaToLovelace(String text) {
    final clean = text.trim();
    if (clean.isEmpty) throw const FormatException('Empty ADA amount');
    final parts = clean.split('.');
    if (parts.length > 2) throw const FormatException('Invalid ADA number');
    final whole = BigInt.parse(parts[0].isEmpty ? '0' : parts[0]);
    var fracStr = parts.length == 2 ? parts[1] : '';
    if (fracStr.length > 6) {
      throw const FormatException('Max 6 decimal places for ADA');
    }
    fracStr = fracStr.padRight(6, '0');
    return whole * BigInt.from(1000000) + BigInt.parse(fracStr);
  }

  MultiAsset _buildDraftTokenMap(WalletSyncState sync) {
    if (_sweepAll) {
      return sync.totalMultiAsset;
    }
    final map = <AssetKey, BigInt>{};
    for (final key in _selectedOrder) {
      final avail = sync.totalMultiAsset.assets[key] ?? BigInt.zero;
      if (avail <= BigInt.zero) continue;
      final meta = sync.assetMetadata[key.unit];
      final decimals = widget.appState.tokenDecimalsFor(key.unit, meta);
      final rawText = _tokenCtrls[key]?.text.trim() ?? '';
      if (rawText.isEmpty) {
        // Use 1 atomic unit as probe for Min-ADA estimation while user hasn't typed qty yet
        map[key] = BigInt.one;
      } else {
        final parsed = parseTokenAmount(rawText, decimals);
        if (parsed > BigInt.zero) {
          map[key] = parsed;
        }
      }
    }
    return MultiAsset(map);
  }

  void _maybeApplyAutoMinAda({bool forceMinIfEmptyOrLower = true}) {
    final profile = widget.appState.activeProfile;
    final sync = widget.appState.syncState;
    if (profile == null || sync == null) return;
    if (_sendMaxAda || _sweepAll || !_autoMinAda || _selectedOrder.isEmpty) {
      return;
    }

    final probeTokens = _buildDraftTokenMap(sync);
    final minAda = ConwayTxBuilder.estimateRecipientMinAda(
      profile: profile,
      syncState: sync,
      recipientAddress: _recipientCtrl.text,
      tokensToSend: probeTokens,
    );

    if (!forceMinIfEmptyOrLower) return;
    final current = _adaCtrl.text.trim();
    if (current.isEmpty) {
      _adaCtrl.text = formatAda(minAda);
      return;
    }
    try {
      final parsed = _parseAdaToLovelace(current);
      if (parsed < minAda) {
        _adaCtrl.text = formatAda(minAda);
      }
    } catch (_) {
      _adaCtrl.text = formatAda(minAda);
    }
  }

  Future<void> _openTokenPicker(WalletSyncState sync) async {
    final s = widget.appState.strings;
    final available = sync.totalMultiAsset.assets.entries
        .where((e) => e.value > BigInt.zero && !_selectedOrder.contains(e.key))
        .toList();

    if (available.isEmpty) return;

    final searchCtrl = TextEditingController();
    final picked = await showDialog<AssetKey>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final q = searchCtrl.text.trim().toLowerCase();
          final filtered = available.where((entry) {
            if (q.isEmpty) return true;
            final meta = sync.assetMetadata[entry.key.unit];
            final name = resolveAssetDisplayName(entry.key, meta).toLowerCase();
            final ticker = (meta?.ticker ?? '').toLowerCase();
            final policy = entry.key.policyIdHex.toLowerCase();
            final fp = (meta?.fingerprint ?? '').toLowerCase();
            return name.contains(q) ||
                ticker.contains(q) ||
                policy.contains(q) ||
                fp.contains(q);
          }).toList();

          return AlertDialog(
            title: Text(s.addTokenBtn),
            content: SizedBox(
              width: 460,
              height: 360,
              child: Column(
                children: [
                  TextField(
                    controller: searchCtrl,
                    onChanged: (_) => setDialogState(() {}),
                    decoration: InputDecoration(
                      hintText: s.searchTokensHint,
                      prefixIcon: const Icon(Icons.search, size: 18),
                      isDense: true,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: filtered.isEmpty
                        ? Center(
                            child: Text(
                              s.isVi
                                  ? 'Không có token phù hợp trong ví.'
                                  : 'No matching wallet tokens.',
                            ),
                          )
                        : ListView.builder(
                            itemCount: filtered.length,
                            itemBuilder: (_, i) {
                              final entry = filtered[i];
                              final meta = sync.assetMetadata[entry.key.unit];
                              final decimals = widget.appState.tokenDecimalsFor(entry.key.unit, meta);
                              final title = resolveAssetDisplayName(entry.key, meta);
                              final formatted = formatTokenAmount(entry.value, decimals);
                              final isNft = isAssetNft(entry.value, meta);
                              return ListTile(
                                dense: true,
                                leading: Icon(
                                  isNft ? Icons.image_outlined : Icons.token_outlined,
                                  color: isNft ? Colors.purpleAccent : Colors.lightBlueAccent,
                                ),
                                title: Text(
                                  meta?.ticker != null ? '$title (${meta!.ticker})' : title,
                                  style: const TextStyle(fontWeight: FontWeight.w600),
                                ),
                                subtitle: Text(
                                  entry.key.shortPolicy,
                                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                                ),
                                trailing: Text(
                                  formatted,
                                  style: const TextStyle(fontWeight: FontWeight.bold),
                                ),
                                onTap: () => Navigator.of(ctx).pop(entry.key),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(null),
                child: Text(s.cancel),
              ),
            ],
          );
        },
      ),
    );
    searchCtrl.dispose();

    if (picked != null && mounted) {
      final meta = sync.assetMetadata[picked.unit];
      final avail = sync.totalMultiAsset.assets[picked] ?? BigInt.zero;
      setState(() {
        _selectedOrder.add(picked);
        _tokenCtrls[picked] = TextEditingController(
          text: isAssetNft(avail, meta) ? '1' : '',
        );
        _maybeApplyAutoMinAda();
      });
    }
  }

  _DraftEvaluation _evaluateDraft(
    WatchOnlyProfile profile,
    WalletSyncState sync,
    HotStrings s,
  ) {
    final recipientText = _recipientCtrl.text.trim();
    var hasValidRecipient = false;
    String? recipientError;
    if (recipientText.isNotEmpty) {
      try {
        final decoded = CardanoAddress.decode(recipientText);
        if (decoded.networkTag != profile.network.networkTag) {
          recipientError = s.isVi
              ? 'Địa chỉ nhận không thuộc mạng ${profile.network.id}'
              : 'Recipient address does not match ${profile.network.id}';
        } else {
          hasValidRecipient = true;
        }
      } catch (_) {
        recipientError = s.isVi
            ? 'Địa chỉ nhận Cardano không hợp lệ'
            : 'Invalid Cardano recipient address';
      }
    }

    final strictTokens = <AssetKey, BigInt>{};
    final probeTokens = <AssetKey, BigInt>{};
    String? tokenError;

    if (_sweepAll) {
      strictTokens.addAll(sync.totalMultiAsset.assets);
      probeTokens.addAll(sync.totalMultiAsset.assets);
    } else {
      for (final key in _selectedOrder) {
        final avail = sync.totalMultiAsset.assets[key] ?? BigInt.zero;
        final meta = sync.assetMetadata[key.unit];
        final decimals = widget.appState.tokenDecimalsFor(key.unit, meta);
        final label = resolveAssetSymbol(key, meta);
        final rawText = _tokenCtrls[key]?.text.trim() ?? '';

        if (rawText.isEmpty) {
          probeTokens[key] = BigInt.one;
          tokenError ??= s.isVi
              ? 'Vui lòng nhập số lượng cho token $label'
              : 'Enter quantity for $label';
          continue;
        }
        try {
          final qty = parseTokenAmount(rawText, decimals);
          if (qty <= BigInt.zero) {
            probeTokens[key] = BigInt.one;
            tokenError ??= s.isVi
                ? 'Số lượng $label phải > 0'
                : 'Quantity for $label must be > 0';
          } else if (qty > avail) {
            probeTokens[key] = avail;
            tokenError ??= s.isVi
                ? 'Số dư $label không đủ (khả dụng: ${formatTokenAmount(avail, decimals)})'
                : 'Insufficient $label balance (available: ${formatTokenAmount(avail, decimals)})';
          } else {
            strictTokens[key] = qty;
            probeTokens[key] = qty;
          }
        } on FormatException catch (e) {
          probeTokens[key] = BigInt.one;
          tokenError ??= '$label: ${e.message}';
        }
      }
    }

    final probeMultiAsset = MultiAsset(probeTokens);
    final recipientMinAda = ConwayTxBuilder.estimateRecipientMinAda(
      profile: profile,
      syncState: sync,
      recipientAddress: hasValidRecipient ? recipientText : null,
      tokensToSend: probeMultiAsset,
    );

    if (recipientError != null || tokenError != null) {
      return _DraftEvaluation(
        recipientMinAda: recipientMinAda,
        error: recipientError ?? tokenError,
        isEstimated: !hasValidRecipient,
      );
    }

    BigInt lovelaceToSend = BigInt.zero;
    if (!_sendMaxAda && !_sweepAll) {
      final adaText = _adaCtrl.text.trim();
      if (adaText.isEmpty) {
        if (_autoMinAda && _selectedOrder.isNotEmpty) {
          lovelaceToSend = recipientMinAda;
        } else {
          return _DraftEvaluation(
            recipientMinAda: recipientMinAda,
            error: s.isVi ? 'Vui lòng nhập số lượng ADA' : 'Enter ADA amount',
            isEstimated: !hasValidRecipient,
          );
        }
      } else {
        try {
          lovelaceToSend = _parseAdaToLovelace(adaText);
          if (_autoMinAda && _selectedOrder.isNotEmpty && lovelaceToSend < recipientMinAda) {
            lovelaceToSend = recipientMinAda;
          } else if (lovelaceToSend < recipientMinAda) {
            return _DraftEvaluation(
              recipientMinAda: recipientMinAda,
              error: s.isVi
                  ? 'Lượng ADA thấp hơn mức tối thiểu (${formatAda(recipientMinAda)} ADA)'
                  : 'ADA amount is below Min-ADA (${formatAda(recipientMinAda)} ADA)',
              isEstimated: !hasValidRecipient,
            );
          }
        } on FormatException catch (e) {
          return _DraftEvaluation(
            recipientMinAda: recipientMinAda,
            error: e.message,
            isEstimated: !hasValidRecipient,
          );
        }
      }
    }

    try {
      final dryRunRecipient =
          hasValidRecipient ? recipientText : sync.primaryReceiveAddress;
      final built = ConwayTxBuilder.buildTransfer(
        profile: profile,
        syncState: sync,
        recipientAddress: dryRunRecipient,
        lovelaceToSend: lovelaceToSend,
        tokensToSend: MultiAsset(strictTokens),
        sendMax: _sendMaxAda || _sweepAll,
        keepRemainingTokens: _sendMaxAda && !_sweepAll,
        autoMinAda: _autoMinAda && !_sendMaxAda && !_sweepAll,
      );
      return _DraftEvaluation(
        recipientMinAda: built.recipientMinAda ?? recipientMinAda,
        buildResult: built,
        isEstimated: !hasValidRecipient,
      );
    } catch (e) {
      return _DraftEvaluation(
        recipientMinAda: recipientMinAda,
        error: e.toString(),
        isEstimated: !hasValidRecipient,
      );
    }
  }

  void _buildAndLaunch() {
    final s = widget.appState.strings;
    final profile = widget.appState.activeProfile;
    final sync = widget.appState.syncState;
    if (profile == null || sync == null) {
      setState(() => _error = s.isVi ? 'Hãy đồng bộ ví trước' : 'Sync wallet first');
      return;
    }

    if (_recipientCtrl.text.trim().isEmpty) {
      setState(() => _error = s.isVi ? 'Vui lòng nhập địa chỉ người nhận' : 'Enter recipient address');
      return;
    }

    final eval = _evaluateDraft(profile, sync, s);
    if (eval.error != null || eval.buildResult == null) {
      setState(() => _error = eval.error ?? 'Unable to build transaction');
      return;
    }

    setState(() => _error = null);
    widget.appState.setLastBuiltTx(eval.buildResult!);
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BroadcastFlowScreen(
          appState: widget.appState,
          buildResult: eval.buildResult!,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.appState.strings;
    final profile = widget.appState.activeProfile;
    final sync = widget.appState.syncState;
    _reconcileWalletState(profile, sync);

    final walletTokens = sync?.totalMultiAsset.assets ?? const <AssetKey, BigInt>{};
    final ownedEntries = walletTokens.entries
        .where((e) => e.value > BigInt.zero)
        .toList();
    final unselectedCount = ownedEntries
        .where((e) => !_selectedOrder.contains(e.key))
        .length;

    final preview = (profile != null && sync != null)
        ? _evaluateDraft(profile, sync, s)
        : null;

    final maxModeActive = _sendMaxAda || _sweepAll;
    final sentOutputLovelace = preview?.buildResult?.txBody.outputs.isNotEmpty == true
        ? preview!.buildResult!.txBody.outputs.first.lovelace
        : null;

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          s.sendTitle,
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const Key('send_recipient_field'),
                controller: _recipientCtrl,
                onChanged: (_) => setState(() {
                  _maybeApplyAutoMinAda(forceMinIfEmptyOrLower: true);
                }),
                decoration: InputDecoration(
                  labelText: s.recipientAddrLabel,
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 10),
            IconButton.filledTonal(
              tooltip: s.scanRecipientQr,
              onPressed: _scanRecipientAddress,
              icon: const Icon(Icons.qr_code_scanner),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                key: const Key('send_ada_field'),
                controller: _adaCtrl,
                enabled: !maxModeActive,
                onChanged: (_) => setState(() {}),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: s.adaAmountLabel,
                  helperText: (!maxModeActive && _selectedOrder.isNotEmpty && preview != null)
                      ? 'Min-ADA: ${formatAda(preview.recipientMinAda)} ADA'
                      : null,
                  border: const OutlineInputBorder(),
                  suffixText: 'ADA',
                ),
              ),
            ),
            const SizedBox(width: 10),
            if (!maxModeActive && _selectedOrder.isNotEmpty && preview != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: OutlinedButton(
                  key: const Key('use_min_ada_btn'),
                  onPressed: () => setState(() {
                    _adaCtrl.text = formatAda(preview.recipientMinAda);
                  }),
                  child: const Text('Min'),
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilterChip(
              key: const Key('send_max_ada_chip'),
              selected: _sendMaxAda,
              label: Text(s.sendMaxBtn),
              onSelected: (v) {
                setState(() {
                  _sendMaxAda = v;
                  if (v) _sweepAll = false;
                });
              },
            ),
            if (ownedEntries.isNotEmpty)
              FilterChip(
                key: const Key('sweep_all_chip'),
                selected: _sweepAll,
                label: Text(s.sweepAllBtn),
                onSelected: (v) {
                  setState(() {
                    _sweepAll = v;
                    if (v) _sendMaxAda = false;
                  });
                },
              ),
          ],
        ),
        if (!_sweepAll && ownedEntries.isNotEmpty) ...[
          const SizedBox(height: 18),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                s.selectTokensLabel,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              FilledButton.tonalIcon(
                key: const Key('add_token_picker_btn'),
                onPressed: (sync == null || unselectedCount == 0)
                    ? null
                    : () => _openTokenPicker(sync),
                icon: const Icon(Icons.add, size: 18),
                label: Text(
                  unselectedCount == 0 ? s.noMoreTokensToAdd : s.addTokenBtn,
                ),
              ),
            ],
          ),
          if (_selectedOrder.isNotEmpty && !maxModeActive)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(s.autoMinAdaLabel, style: const TextStyle(fontSize: 13)),
              value: _autoMinAda,
              onChanged: (v) => setState(() {
                _autoMinAda = v;
                if (v) _maybeApplyAutoMinAda();
              }),
            ),
          const SizedBox(height: 8),
          for (final key in _selectedOrder)
            Builder(
              builder: (context) {
                final avail = walletTokens[key] ?? BigInt.zero;
                final meta = sync?.assetMetadata[key.unit];
                final decimals = widget.appState.tokenDecimalsFor(key.unit, meta);
                final displayName = resolveAssetDisplayName(key, meta);
                final ctrl = _tokenCtrls.putIfAbsent(key, () => TextEditingController());
                return Card(
                  key: Key('selected_token_card_${key.unit}'),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                meta?.ticker != null
                                    ? '$displayName (${meta!.ticker})'
                                    : displayName,
                                style: const TextStyle(fontWeight: FontWeight.w600),
                              ),
                              Text(
                                '${s.isVi ? 'Khả dụng' : 'Available'}: ${formatTokenAmount(avail, decimals)} • ${key.shortPolicy}',
                                style: const TextStyle(fontSize: 11, color: Colors.white60),
                              ),
                            ],
                          ),
                        ),
                        SizedBox(
                          width: 140,
                          child: TextField(
                            key: Key('token_qty_field_${key.unit}'),
                            controller: ctrl,
                            onChanged: (_) => setState(() {
                              _maybeApplyAutoMinAda(forceMinIfEmptyOrLower: false);
                            }),
                            keyboardType: TextInputType.numberWithOptions(
                              decimal: decimals > 0,
                            ),
                            decoration: InputDecoration(
                              labelText: decimals > 0 ? 'Qty (dec $decimals)' : 'Qty',
                              isDense: true,
                              border: const OutlineInputBorder(),
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        TextButton(
                          key: Key('token_max_btn_${key.unit}'),
                          onPressed: () => setState(() {
                            ctrl.text = formatTokenAmount(
                              avail,
                              decimals,
                              includeGrouping: false,
                            );
                            _maybeApplyAutoMinAda();
                          }),
                          child: const Text('Max'),
                        ),
                        IconButton(
                          key: Key('token_remove_btn_${key.unit}'),
                          tooltip: s.delete,
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () => setState(() {
                            _selectedOrder.remove(key);
                            _tokenCtrls.remove(key)?.dispose();
                            _maybeApplyAutoMinAda();
                          }),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
        ],
        if (_sweepAll && ownedEntries.isNotEmpty) ...[
          const SizedBox(height: 14),
          Card(
            color: Colors.amber.withValues(alpha: 0.12),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                s.isVi
                    ? 'Chế độ Quét sạch ví sẽ chuyển toàn bộ ADA và ${ownedEntries.length} loại Native Token sang địa chỉ nhận.'
                    : 'Sweep All mode will transfer 100% of ADA and all ${ownedEntries.length} Native Token(s) to the recipient.',
                style: const TextStyle(fontSize: 12, color: Colors.amber),
              ),
            ),
          ),
        ],
        if (preview != null) ...[
          const SizedBox(height: 16),
          Card(
            key: const Key('tx_live_preview_card'),
            color: Colors.blueGrey.withValues(alpha: 0.18),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.calculate_outlined, size: 18, color: HotTheme.balanceAccent),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          s.txPreviewTitle,
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                        ),
                      ),
                      if (preview.isEstimated)
                        Text(
                          s.isVi ? '(Ước tính)' : '(Estimated)',
                          style: const TextStyle(fontSize: 11, color: Colors.white54),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (_selectedOrder.isNotEmpty || _sweepAll)
                    _previewRow(
                      s.attachedMinAdaLabel,
                      '${formatAda(preview.recipientMinAda)} ADA',
                    ),
                  if (sentOutputLovelace != null)
                    _previewRow(
                      s.isVi ? 'ADA người nhận thực nhận' : 'Recipient Receives (ADA)',
                      '${formatAda(sentOutputLovelace)} ADA',
                    ),
                  _previewRow(
                    s.estimatedFeeLabel,
                    preview.buildResult != null
                        ? '${formatAda(preview.buildResult!.fee)} ADA'
                        : '—',
                  ),
                  if (preview.buildResult?.changeMinAda != null)
                    _previewRow(
                      s.changeMinAdaLabel,
                      '${formatAda(preview.buildResult!.changeMinAda!)} ADA',
                    ),
                  if (preview.buildResult != null && sentOutputLovelace != null)
                    _previewRow(
                      s.totalAdaDeductedLabel,
                      '${formatAda(sentOutputLovelace + preview.buildResult!.fee)} ADA',
                      bold: true,
                    ),
                  if (preview.error != null && _recipientCtrl.text.trim().isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      preview.error!,
                      style: const TextStyle(color: Colors.amberAccent, fontSize: 12),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.red.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.redAccent),
            ),
            child: Text(_error!, style: const TextStyle(color: Colors.redAccent)),
          ),
        ],
        const SizedBox(height: 20),
        FilledButton.icon(
          key: const Key('build_sign_qr_btn'),
          onPressed: (profile == null || sync == null) ? null : _buildAndLaunch,
          icon: const Icon(Icons.qr_code_2),
          label: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Text(s.buildSignQrBtn),
          ),
        ),
      ],
    );
  }

  Widget _previewRow(String label, String value, {bool bold = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: bold ? Colors.white : Colors.white70,
                fontWeight: bold ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            value,
            style: TextStyle(
              fontSize: 12,
              fontFamily: 'monospace',
              fontWeight: bold ? FontWeight.bold : FontWeight.w600,
              color: bold ? HotTheme.balanceAccent : HotTheme.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

class _DraftEvaluation {
  final BigInt recipientMinAda;
  final TxBuildResult? buildResult;
  final String? error;
  final bool isEstimated;

  const _DraftEvaluation({
    required this.recipientMinAda,
    this.buildResult,
    this.error,
    this.isEstimated = false,
  });
}
