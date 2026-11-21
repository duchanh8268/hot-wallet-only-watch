import 'package:flutter/material.dart';

import '../core/models/chain_tx_record.dart';
import '../theme/hot_theme.dart';
import 'external_link_text.dart';

/// Shared Recent Transactions list card section modeled after Cardano DashboardScreen.
class RecentTxsSection extends StatelessWidget {
  final List<ChainTxRecord> txs;
  final bool isVi;
  final bool loading;
  final String? historyError;
  final String? accountExplorerUrl;
  final VoidCallback? onRefresh;

  const RecentTxsSection({
    super.key,
    required this.txs,
    required this.isVi,
    this.loading = false,
    this.historyError,
    this.accountExplorerUrl,
    this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Flexible(
              child: Text(
                isVi
                    ? 'Lịch sử Giao dịch Gần đây (${txs.length})'
                    : 'Recent Transactions (${txs.length})',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold, fontSize: 14),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (onRefresh != null)
              IconButton(
                key: const Key('refresh_tx_history_btn'),
                icon: const Icon(Icons.refresh, size: 18),
                tooltip: isVi ? 'Làm mới lịch sử' : 'Refresh history',
                onPressed: loading ? null : onRefresh,
              ),
          ],
        ),
        const SizedBox(height: 8),
        if (loading && txs.isEmpty)
          const Center(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          )
        else if (txs.isEmpty)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: HotTheme.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: historyError != null ? HotTheme.warning.withValues(alpha: 0.6) : HotTheme.borderSubtle,
              ),
            ),
            child: Column(
              children: [
                Text(
                  historyError != null
                      ? (isVi
                          ? 'Không thể tải lịch sử từ trình khám phá công khai lúc này.'
                          : 'Unable to fetch recent history from public explorer right now.')
                      : (isVi ? 'Chưa có giao dịch gần đây.' : 'No recent transactions found.'),
                  style: TextStyle(
                    fontSize: 12,
                    color: historyError != null ? Colors.amberAccent : HotTheme.textSecondary,
                  ),
                  textAlign: TextAlign.center,
                ),
                if (accountExplorerUrl != null && accountExplorerUrl!.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  ExternalLinkText(
                    key: const Key('account_explorer_link'),
                    url: accountExplorerUrl!,
                    label: isVi ? 'Xem lịch sử trên Explorer' : 'View history on Explorer',
                    fontSize: 11,
                    maxWidth: 320,
                  ),
                ],
              ],
            ),
          )
        else ...[
          for (final tx in txs) ...[
            Card(
              key: Key('recent_tx_item_${tx.txHash}'),
              color: HotTheme.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: const BorderSide(color: HotTheme.borderSubtle),
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        _statusIcon(tx),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _metaLine(tx),
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: HotTheme.textSecondary,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (tx.summary.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              tx.summary,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: _summaryColor(tx),
                              ),
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.end,
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 6),
                    SelectableText(
                      tx.txHash,
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                    ),
                    if (tx.explorerUrl.isNotEmpty || tx.timestampMs > 0) ...[
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          if (tx.explorerUrl.isNotEmpty)
                            Expanded(
                              child: ExternalLinkText(
                                key: Key('tx_explorer_link_${tx.txHash}'),
                                url: tx.explorerUrl,
                                fontSize: 11,
                                maxWidth: 260,
                              ),
                            ),
                          if (tx.timestampMs > 0)
                            Text(
                              _formatTimestamp(tx.timestampMs),
                              style: const TextStyle(
                                fontSize: 10,
                                color: HotTheme.textSecondary,
                              ),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
          if (historyError != null && accountExplorerUrl != null && accountExplorerUrl!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: ExternalLinkText(
                  url: accountExplorerUrl!,
                  label: isVi ? 'Xem thêm trên Explorer' : 'View more on Explorer',
                  fontSize: 11,
                  maxWidth: 320,
                ),
              ),
            ),
        ],
      ],
    );
  }

  Widget _statusIcon(ChainTxRecord tx) {
    if (tx.status == 'failed') {
      return const Icon(Icons.error_outline, size: 18, color: HotTheme.danger);
    }
    if (tx.status == 'pending') {
      return const Icon(Icons.schedule, size: 18, color: HotTheme.warning);
    }
    if (tx.direction == 'in') {
      return const Icon(Icons.call_received, size: 18, color: HotTheme.success);
    }
    if (tx.direction == 'out') {
      return const Icon(Icons.call_made, size: 18, color: HotTheme.warning);
    }
    return const Icon(Icons.receipt_long_outlined, size: 18, color: HotTheme.primary);
  }

  Color _summaryColor(ChainTxRecord tx) {
    if (tx.status == 'failed') return HotTheme.danger;
    if (tx.direction == 'in') return HotTheme.success;
    if (tx.direction == 'out') return HotTheme.warning;
    return HotTheme.balanceAccent;
  }

  String _metaLine(ChainTxRecord tx) {
    final parts = <String>[];
    if (tx.blockOrSlot.isNotEmpty) {
      parts.add(tx.blockOrSlot);
    }
    if (tx.status == 'pending') {
      parts.add(isVi ? 'Đang chờ' : 'Pending');
    } else if (tx.status == 'failed') {
      parts.add(isVi ? 'Thất bại' : 'Failed');
    } else if (parts.isEmpty) {
      parts.add(isVi ? 'Đã xác nhận' : 'Confirmed');
    }
    return parts.join(' • ');
  }

  String _formatTimestamp(int ms) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ms).toLocal();
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    return '$y-$m-$d $hh:$mm';
  }
}
