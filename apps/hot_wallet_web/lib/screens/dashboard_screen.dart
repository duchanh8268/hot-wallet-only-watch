import 'package:cardano_core/cardano_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../l10n/app_strings.dart';
import '../services/blockfrost_service.dart';
import '../services/hd_wallet_sync_service.dart';
import '../services/hot_app_state.dart';
import '../theme/hot_theme.dart';
import '../utils/token_utils.dart';
import '../widgets/external_link_text.dart';

enum _TokenFilter { all, ft, nft }

class DashboardScreen extends StatefulWidget {
  final HotAppState appState;
  final VoidCallback onOpenAccounts;
  final VoidCallback onOpenSettings;
  final VoidCallback? onOpenSendTx;
  final VoidCallback? onOpenStaking;
  final VoidCallback? onOpenScanSubmit;

  const DashboardScreen({
    super.key,
    required this.appState,
    required this.onOpenAccounts,
    required this.onOpenSettings,
    this.onOpenSendTx,
    this.onOpenStaking,
    this.onOpenScanSubmit,
  });

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  bool _showBaseAddress = false;
  final TextEditingController _tokenSearchCtrl = TextEditingController();
  _TokenFilter _tokenFilter = _TokenFilter.all;

  @override
  void dispose() {
    _tokenSearchCtrl.dispose();
    super.dispose();
  }

  void _showReceiveQrDialog(
    BuildContext context,
    HotStrings s,
    WatchOnlyProfile profile,
    String receiveAddr,
    int displayedIndex,
  ) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          s.receiveAddressWithPath(profile.accountIndex, displayedIndex),
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
              ),
              child: QrImageView(data: receiveAddr, size: 220),
            ),
            const SizedBox(height: 12),
            SelectableText(
              receiveAddr,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
              textAlign: TextAlign.center,
            ),
          ],
        ),
        actions: [
          TextButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: receiveAddr));
              if (!ctx.mounted) return;
              ScaffoldMessenger.of(ctx)
                ..clearSnackBars()
                ..showSnackBar(SnackBar(content: Text(s.copiedAddressMsg)));
            },
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('Copy'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(s.close),
          ),
        ],
      ),
    );
  }

  void _showTokenDetailDialog(
    BuildContext context,
    HotStrings s,
    WalletSyncState sync,
    AssetKey key,
    BigInt totalQty,
    AssetMetadataInfo? meta,
  ) {
    var decimals = widget.appState.tokenDecimalsFor(key.unit, meta);
    final displayName = resolveAssetDisplayName(key, meta);
    final holdingUtxos = sync.utxos
        .where((u) => u.utxo.multiAsset[key] > BigInt.zero)
        .toList();

    showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Row(
            children: [
              Icon(
                isAssetNft(totalQty, meta)
                    ? Icons.image_outlined
                    : Icons.token_outlined,
                color: HotTheme.balanceAccent,
              ),
              const SizedBox(width: 8),
              Expanded(child: Text(displayName)),
            ],
          ),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _detailRow(
                    ctx,
                    s.isVi ? 'Số dư hiển thị' : 'Formatted Balance',
                    '${formatTokenAmount(totalQty, decimals)}${meta?.ticker != null ? ' ${meta!.ticker}' : ''}',
                  ),
                  _detailRow(
                    ctx,
                    s.isVi ? 'Số lượng gốc (Atomic)' : 'Raw Atomic Units',
                    formatTokenAmount(totalQty, 0),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    s.isVi
                        ? 'Số chữ số thập phân (Decimals: $decimals)'
                        : 'Token Decimals (Decimals: $decimals)',
                    style: const TextStyle(fontSize: 11, color: HotTheme.textSecondary),
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 6,
                    children: [
                      for (final d in const [0, 2, 6, 8, 9])
                        ChoiceChip(
                          label: Text('$d'),
                          selected: decimals == d,
                          visualDensity: VisualDensity.compact,
                          onSelected: (_) async {
                            await widget.appState.setCustomTokenDecimals(key.unit, d);
                            setDialogState(() => decimals = d);
                          },
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  if (meta?.onchainStandard != null)
                    _detailRow(ctx, 'Standard', meta!.onchainStandard!),
                  _copyableRow(ctx, 'Policy ID', key.policyIdHex, s),
                  _copyableRow(
                    ctx,
                    'Asset Name (Hex)',
                    key.assetNameHex.isEmpty ? '(empty)' : key.assetNameHex,
                    s,
                  ),
                  _copyableRow(ctx, 'Unit', key.unit, s),
                  if (meta?.fingerprint != null)
                    _copyableRow(ctx, 'Fingerprint', meta!.fingerprint!, s),
                  if (meta?.description != null &&
                      meta!.description!.trim().isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      s.isVi ? 'Mô tả' : 'Description',
                      style: const TextStyle(fontSize: 12, color: HotTheme.textSecondary),
                    ),
                    const SizedBox(height: 2),
                    Text(meta.description!, style: const TextStyle(fontSize: 13)),
                  ],
                  const SizedBox(height: 12),
                  Text(
                    s.isVi
                        ? 'UTXO đang giữ token (${holdingUtxos.length})'
                        : 'UTXOs holding this token (${holdingUtxos.length})',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 4),
                  for (final u in holdingUtxos)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(
                        '• ${u.utxo.txHash.substring(0, 10)}...#${u.utxo.outputIndex}: '
                        '${formatTokenAmount(u.utxo.multiAsset[key], decimals)}',
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(s.close),
            ),
          ],
        ),
      ),
    );
  }

  Widget _detailRow(BuildContext context, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 11, color: HotTheme.textSecondary)),
          SelectableText(value, style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Widget _copyableRow(
    BuildContext context,
    String label,
    String value,
    HotStrings s,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(fontSize: 11, color: HotTheme.textSecondary),
                ),
                SelectableText(
                  value,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Copy $label',
            icon: const Icon(Icons.copy, size: 15),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: value));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context)
                ..clearSnackBars()
                ..showSnackBar(
                  SnackBar(
                    content: Text(s.isVi ? 'Đã sao chép $label' : 'Copied $label'),
                  ),
                );
            },
          ),
        ],
      ),
    );
  }

  Widget _circleActionBtn({
    required Key? key,
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
    Color borderColor = HotTheme.borderSubtle,
    Color iconColor = HotTheme.textPrimary,
    Color? fillColor,
  }) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: fillColor ?? HotTheme.surface,
        shape: CircleBorder(
          side: BorderSide(color: borderColor, width: 1.2),
        ),
        child: InkWell(
          key: key,
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: SizedBox(
            width: 44,
            height: 44,
            child: Icon(icon, size: 19, color: iconColor),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.appState.strings;
    final profile = widget.appState.activeProfile;

    if (profile == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: HotTheme.primarySurface,
                      shape: BoxShape.circle,
                      border: Border.all(color: HotTheme.primaryBorder),
                    ),
                    child: const Icon(
                      Icons.qr_code_2,
                      size: 48,
                      color: HotTheme.primary,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    s.noWalletSelected,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: widget.onOpenAccounts,
                    icon: const Icon(Icons.add),
                    label: Text(s.addAccountQrBtn),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    final sync = widget.appState.syncState;
    final acctKey = CardanoAccountPublicKey.fromBech32(profile.acctXvkBech32);
    final nextUnusedIdx = sync?.nextUnusedExternalIndex ?? 0;
    final showingBase = _showBaseAddress || nextUnusedIdx == 0;
    final displayedIndex = showingBase ? 0 : nextUnusedIdx;
    final receiveAddr = showingBase
        ? (sync?.primaryReceiveAddress ??
            acctKey.deriveBaseAddress(role: 0, index: 0, network: profile.network))
        : (sync?.nextUnusedExternalAddress ??
            acctKey.deriveBaseAddress(role: 0, index: nextUnusedIdx, network: profile.network));

    final stakeAddr = sync?.stakeAddress ??
        acctKey.deriveRewardAddress(network: profile.network);
    final shortStake = stakeAddr.length > 22
        ? '${stakeAddr.substring(0, 12)}...${stakeAddr.substring(stakeAddr.length - 6)}'
        : stakeAddr;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (widget.appState.activeProjectId.trim().isEmpty) ...[
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: HotTheme.warningSurface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: HotTheme.warning.withValues(alpha: 0.5)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.warning_amber_rounded, color: HotTheme.warning, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        s.missingApiKey,
                        style: const TextStyle(fontSize: 12, color: HotTheme.textPrimary),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    OutlinedButton(
                      onPressed: widget.appState.loadDemoPreprodData,
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(44, 36),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      ),
                      child: Text(
                        s.isVi ? 'Nạp Demo UTXO' : 'Load Demo UTXOs',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    TextButton(
                      onPressed: widget.onOpenSettings,
                      style: TextButton.styleFrom(
                        minimumSize: const Size(44, 36),
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      ),
                      child: Text(s.tabSettings),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],
        if (widget.appState.syncError != null) ...[
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: HotTheme.dangerSurface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: HotTheme.danger),
            ),
            child: Row(
              children: [
                const Icon(Icons.error_outline, color: HotTheme.danger),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    widget.appState.syncError!,
                    style: const TextStyle(fontSize: 12, color: HotTheme.textPrimary),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],

        // 1. Address Bar & Quick Actions
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        s.receiveAddressWithPath(profile.accountIndex, displayedIndex),
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: HotTheme.textSecondary,
                        ),
                      ),
                    ),
                    if (nextUnusedIdx > 0)
                      TextButton.icon(
                        key: const Key('hot_toggle_base_addr_btn'),
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        ),
                        onPressed: () => setState(
                          () => _showBaseAddress = !_showBaseAddress,
                        ),
                        icon: const Icon(Icons.swap_horiz, size: 15),
                        label: Text(
                          _showBaseAddress
                              ? s.showNextAddrBtn(profile.accountIndex, nextUnusedIdx)
                              : s.showPrimaryAddrBtn(profile.accountIndex),
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                        decoration: BoxDecoration(
                          color: HotTheme.background,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: HotTheme.borderSubtle),
                        ),
                        child: SelectableText(
                          receiveAddr,
                          maxLines: 1,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                            color: HotTheme.textPrimary,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _circleActionBtn(
                      key: const Key('hot_show_receive_qr_btn'),
                      icon: Icons.qr_code_2,
                      tooltip: s.isVi ? 'Xem mã QR nhận' : 'Show Receive QR',
                      borderColor: HotTheme.primaryBorder,
                      iconColor: HotTheme.primary,
                      onPressed: () => _showReceiveQrDialog(
                        context,
                        s,
                        profile,
                        receiveAddr,
                        displayedIndex,
                      ),
                    ),
                    const SizedBox(width: 6),
                    _circleActionBtn(
                      key: const Key('hot_copy_receive_addr_btn'),
                      icon: Icons.copy,
                      tooltip: 'Copy',
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: receiveAddr));
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context)
                          ..clearSnackBars()
                          ..showSnackBar(SnackBar(content: Text(s.copiedAddressMsg)));
                      },
                    ),
                    const SizedBox(width: 6),
                    _circleActionBtn(
                      key: const Key('hot_sync_circle_btn'),
                      icon: Icons.sync,
                      tooltip: s.syncBtn,
                      iconColor: HotTheme.info,
                      onPressed: widget.appState.syncing
                          ? null
                          : widget.appState.syncActiveWallet,
                    ),
                    const SizedBox(width: 6),
                    _circleActionBtn(
                      key: null,
                      icon: Icons.check,
                      tooltip: profile.name,
                      fillColor: HotTheme.primary.withValues(alpha: 0.2),
                      borderColor: HotTheme.primary,
                      iconColor: HotTheme.primary,
                      onPressed: widget.onOpenAccounts,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),

        // 2. Hero Available Balance Card (Amber/Gold)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 22),
          decoration: BoxDecoration(
            color: HotTheme.balanceCardBg,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: HotTheme.balanceCardBorder, width: 1.2),
          ),
          child: Column(
            children: [
              Text(
                s.totalAda,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: HotTheme.textSecondary,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '${formatAda(sync?.totalLovelace ?? BigInt.zero)} ADA',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.w800,
                  color: HotTheme.balanceAccent,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(height: 6),
              Text(
                s.availableUtxosCount(sync?.utxos.length ?? 0),
                style: const TextStyle(
                  fontSize: 12,
                  color: HotTheme.textSecondary,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),

        // 3. Staking Rewards Card (Slate-Green)
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: HotTheme.stakingCardBg,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: HotTheme.stakingCardBorder, width: 1.2),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.stars, size: 16, color: HotTheme.warning),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            s.rewardsAda,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: HotTheme.textPrimary,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${formatAda(sync?.stakeInfo.withdrawableAmount ?? BigInt.zero)} ADA',
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: HotTheme.textSecondary,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Stake: $shortStake',
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        color: HotTheme.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                key: const Key('hub_withdraw_rewards_btn'),
                onPressed: widget.onOpenStaking,
                style: FilledButton.styleFrom(
                  backgroundColor: HotTheme.stakingButtonBg,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                ),
                icon: const Icon(Icons.arrow_downward, size: 16),
                label: Text(s.withdrawRewardShortBtn),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // 4. Primary 2-Step Action Flow Stack
        FilledButton.icon(
          key: const Key('hub_send_tx_btn'),
          onPressed: widget.onOpenSendTx,
          icon: const Icon(Icons.send_outlined, size: 18),
          label: Text(s.step1BuildTxBtn),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          key: const Key('hub_staking_btn'),
          onPressed: widget.onOpenStaking,
          icon: const Icon(Icons.how_to_vote_outlined, size: 18, color: HotTheme.balanceAccent),
          label: Text(s.stakeAndDrepBtn),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          key: const Key('hub_scan_submit_btn'),
          onPressed: widget.onOpenScanSubmit,
          icon: const Icon(Icons.qr_code_scanner, size: 18, color: HotTheme.primary),
          label: Text(s.step2ScanSubmitBtn),
        ),
        const SizedBox(height: 20),

        // 5. Native Tokens Section
        Text(
          '${s.nativeTokens} (${sync?.totalMultiAsset.assets.length ?? 0})',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        if (sync == null || sync.totalMultiAsset.isEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Text(s.noTokens, style: const TextStyle(color: HotTheme.textSecondary)),
            ),
          )
        else ...[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: double.infinity,
                child: TextField(
                  key: const Key('dashboard_token_search_field'),
                  controller: _tokenSearchCtrl,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: s.searchTokensHint,
                    prefixIcon: const Icon(Icons.search, size: 18),
                    suffixIcon: _tokenSearchCtrl.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear, size: 16),
                            onPressed: () {
                              _tokenSearchCtrl.clear();
                              setState(() {});
                            },
                          )
                        : null,
                    isDense: true,
                  ),
                ),
              ),
              ChoiceChip(
                key: const Key('dashboard_filter_all'),
                label: Text(s.filterAll),
                selected: _tokenFilter == _TokenFilter.all,
                onSelected: (_) => setState(() => _tokenFilter = _TokenFilter.all),
              ),
              ChoiceChip(
                key: const Key('dashboard_filter_ft'),
                label: Text(s.filterFt),
                selected: _tokenFilter == _TokenFilter.ft,
                onSelected: (_) => setState(() => _tokenFilter = _TokenFilter.ft),
              ),
              ChoiceChip(
                key: const Key('dashboard_filter_nft'),
                label: Text(s.filterNft),
                selected: _tokenFilter == _TokenFilter.nft,
                onSelected: (_) => setState(() => _tokenFilter = _TokenFilter.nft),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Builder(
            builder: (context) {
              final query = _tokenSearchCtrl.text.trim().toLowerCase();
              final filteredEntries = sync.totalMultiAsset.assets.entries.where((entry) {
                final meta = sync.assetMetadata[entry.key.unit];
                final isNft = isAssetNft(entry.value, meta);
                if (_tokenFilter == _TokenFilter.ft && isNft) return false;
                if (_tokenFilter == _TokenFilter.nft && !isNft) return false;
                if (query.isEmpty) return true;
                final name = resolveAssetDisplayName(entry.key, meta).toLowerCase();
                final ticker = (meta?.ticker ?? '').toLowerCase();
                final policy = entry.key.policyIdHex.toLowerCase();
                final fp = (meta?.fingerprint ?? '').toLowerCase();
                return name.contains(query) ||
                    ticker.contains(query) ||
                    policy.contains(query) ||
                    fp.contains(query);
              }).toList();

              if (filteredEntries.isEmpty) {
                return Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Text(
                      s.isVi
                          ? 'Không tìm thấy token phù hợp bộ lọc.'
                          : 'No tokens match current filter.',
                    ),
                  ),
                );
              }

              return Column(
                children: [
                  for (final entry in filteredEntries)
                    Builder(
                      builder: (context) {
                        final meta = sync.assetMetadata[entry.key.unit];
                        final decimals = widget.appState.tokenDecimalsFor(entry.key.unit, meta);
                        final isNft = isAssetNft(entry.value, meta);
                        final titleText = resolveAssetDisplayName(entry.key, meta);
                        final formatted = formatTokenAmount(entry.value, decimals);
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Card(
                            child: ListTile(
                              onTap: () => _showTokenDetailDialog(
                                context,
                                s,
                                sync,
                                entry.key,
                                entry.value,
                                meta,
                              ),
                              leading: Icon(
                                isNft ? Icons.image_outlined : Icons.token_outlined,
                                color: isNft ? HotTheme.warning : HotTheme.balanceAccent,
                              ),
                              title: Wrap(
                                spacing: 6,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  Text(
                                    titleText,
                                    style: const TextStyle(fontWeight: FontWeight.bold),
                                  ),
                                  if (meta?.ticker != null && meta!.ticker!.isNotEmpty)
                                    Chip(
                                      label: Text(
                                        meta.ticker!,
                                        style: const TextStyle(fontSize: 10),
                                      ),
                                      visualDensity: VisualDensity.compact,
                                      padding: EdgeInsets.zero,
                                    ),
                                  if (isNft)
                                    const Chip(
                                      label: Text('NFT', style: TextStyle(fontSize: 10)),
                                      visualDensity: VisualDensity.compact,
                                      padding: EdgeInsets.zero,
                                    ),
                                ],
                              ),
                              subtitle: Text(
                                meta?.fingerprint != null
                                    ? '${entry.key.shortPolicy} • ${meta!.fingerprint}'
                                    : entry.key.shortPolicy,
                                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                              ),
                              trailing: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text(
                                    formatted,
                                    style: const TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.bold,
                                      color: HotTheme.textPrimary,
                                    ),
                                  ),
                                  if (decimals > 0)
                                    Text(
                                      'raw: ${formatTokenAmount(entry.value, 0)}',
                                      style: const TextStyle(
                                        fontSize: 10,
                                        color: HotTheme.textSecondary,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                ],
              );
            },
          ),
        ],
        const SizedBox(height: 16),

        // 7. UTXOs Section
        Text(
          '${s.utxosTitle} (${sync?.utxos.length ?? 0})',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        if (sync != null)
          for (final u in sync.utxos) ...[
            Card(
              child: ListTile(
                dense: true,
                title: Text(
                  '${u.utxo.txHash.substring(0, 12)}...#${u.utxo.outputIndex} (${u.derivationRole}/${u.derivationIndex})',
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
                subtitle: Text(
                  u.utxo.multiAsset.isEmpty
                      ? 'Clean ADA UTXO'
                      : u.utxo.multiAsset.assets.entries.map((e) {
                          final meta = sync.assetMetadata[e.key.unit];
                          final sym = resolveAssetSymbol(e.key, meta);
                          final dec = widget.appState.tokenDecimalsFor(e.key.unit, meta);
                          final amt = formatTokenAmount(e.value, dec);
                          return '$amt $sym';
                        }).join(' • '),
                ),
                trailing: Text(
                  '${formatAda(u.utxo.lovelace)} ADA',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    color: HotTheme.balanceAccent,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
        const SizedBox(height: 12),

        // 8. Recent Transactions Section
        Text(
          s.txHistoryTitle,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        if (sync != null)
          for (final tx in sync.recentTxs) ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.receipt_long_outlined, size: 18, color: HotTheme.primary),
                        const SizedBox(width: 8),
                        Text(
                          'Block #${tx.blockHeight}',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: HotTheme.textSecondary,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    SelectableText(
                      tx.txHash,
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                    ),
                    const SizedBox(height: 6),
                    ExternalLinkText(
                      key: Key('tx_explorer_link_${tx.txHash}'),
                      url: profile.network.explorerTxUrl(tx.txHash),
                      fontSize: 11,
                      maxWidth: 360,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
      ],
    );
  }
}

String formatAda(BigInt lovelace) {
  final negative = lovelace < BigInt.zero;
  final absVal = negative ? -lovelace : lovelace;
  final ada = absVal ~/ BigInt.from(1000000);
  final frac = (absVal % BigInt.from(1000000)).toString().padLeft(6, '0');
  final trimmed = frac.replaceFirst(RegExp(r'0+$'), '');
  final sign = negative ? '-' : '';
  return trimmed.isEmpty ? '$sign$ada' : '$sign$ada.$trimmed';
}
