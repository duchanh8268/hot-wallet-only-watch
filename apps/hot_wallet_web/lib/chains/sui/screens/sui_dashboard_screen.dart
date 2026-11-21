import 'dart:convert';
import 'dart:math';

import 'package:chain_core_interface/chain_core_interface.dart' show constantTimeEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:sui_core/sui_core.dart';

import '../../../core/models/chain_tx_record.dart';
import '../../../services/hot_app_state.dart';
import '../../../theme/hot_theme.dart';
import '../../../widgets/recent_txs_section.dart';
import '../../../widgets/wallet_profiles_dialog.dart';
import '../../../widgets/web_qr_scanner.dart';
import '../services/sui_rpc_service.dart';
import '../sui_hot_plugin.dart';

class SuiDashboardScreen extends StatefulWidget {
  final HotAppState appState;

  const SuiDashboardScreen({super.key, required this.appState});

  @override
  State<SuiDashboardScreen> createState() => _SuiDashboardScreenState();
}

class _SuiDashboardScreenState extends State<SuiDashboardScreen> {
  SuiTransactionData? _pendingTxData;
  Uint8List? _pendingRequestId;

  HotAppState get appState => widget.appState;
  bool get isVi => appState.locale.name == 'vi';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (appState.activeSuiProfile != null && appState.suiAccountState == null) {
        appState.refreshSuiState();
      }
    });
  }

  void _showAddAccountDialog() {
    final nameCtrl = TextEditingController();
    final inputCtrl = TextEditingController();
    String? errorText;

    showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(isVi ? 'Nhập Tài Khoản Sui' : 'Import Sui Account'),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: nameCtrl,
                    decoration: InputDecoration(
                      labelText: isVi ? 'Tên ví / nhãn (tùy chọn)' : 'Account label (optional)',
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 200,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: WebQrScanner(
                        onCodeScanned: (code) {
                          _parseAndSaveAccount(
                            code: code,
                            name: nameCtrl.text,
                            onError: (err) => setDialogState(() => errorText = err),
                            onSuccess: () => Navigator.of(ctx).pop(),
                          );
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: inputCtrl,
                    maxLines: 2,
                    decoration: InputDecoration(
                      labelText: isVi
                          ? 'Dán mã UR (ur:sui-account...) hoặc địa chỉ 0x...'
                          : 'Paste UR (ur:sui-account...) or 0x... address',
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  if (errorText != null) ...[
                    const SizedBox(height: 8),
                    Text(errorText!, style: const TextStyle(color: HotTheme.danger, fontSize: 12)),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(isVi ? 'Hủy' : 'Cancel'),
            ),
            FilledButton(
              onPressed: () {
                _parseAndSaveAccount(
                  code: inputCtrl.text.trim(),
                  name: nameCtrl.text,
                  onError: (err) => setDialogState(() => errorText = err),
                  onSuccess: () => Navigator.of(ctx).pop(),
                );
              },
              child: Text(isVi ? 'Lưu' : 'Save'),
            ),
          ],
        ),
      ),
    );
  }

  void _parseAndSaveAccount({
    required String code,
    required String name,
    required void Function(String) onError,
    required VoidCallback onSuccess,
  }) {
    if (code.isEmpty) {
      onError(isVi ? 'Vui lòng quét QR hoặc dán mã' : 'Scan QR or paste code');
      return;
    }

    try {
      if (code.toLowerCase().startsWith('ur:sui-account')) {
        final ur = SuiAccountUr.fromUr(code);
        appState.addSuiProfile(
          name: name.isEmpty ? (ur.label ?? 'Sui Account') : name,
          address: ur.address,
          networkId: ur.network,
          accountIndex: ur.accountIndex,
          addressIndex: ur.addressIndex,
        );
        onSuccess();
        return;
      }

      // Check if 0x hex address (up to 66 chars)
      if (code.startsWith('0x') && code.length >= 4) {
        appState.addSuiProfile(
          name: name.isEmpty ? 'Sui Account' : name,
          address: code,
          networkId: appState.activeChainNetwork.id,
          accountIndex: 0,
          addressIndex: 0,
        );
        onSuccess();
        return;
      }

      onError(isVi ? 'Không nhận diện được định dạng Sui' : 'Unrecognized Sui format');
    } catch (e) {
      onError('Lỗi: $e');
    }
  }

  void _showCreateTxDialog() {
    final profile = appState.activeSuiProfile;
    if (profile == null) return;

    final toCtrl = TextEditingController(text: '0x1111111111111111111111111111111111111111111111111111111111111111');
    final amountCtrl = TextEditingController(text: '0.5');
    final gasCtrl = TextEditingController(text: '0.01');
    String? errorText;

    showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(isVi ? 'Bước 1: Tạo Giao Dịch Sui' : 'Step 1: Create Sui Transaction'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    isVi
                        ? 'Giao dịch ngoại tuyến (Air-Gap). Hot Wallet tạo PTB SplitCoins + TransferObjects chưa ký và xuất Animated QR để Ví Lạnh kiểm duyệt SEC-01.'
                        : 'Offline Air-Gap transaction. Hot Wallet creates unsigned PTB and exports Animated QR for Cold Wallet SEC-01 audit.',
                    style: const TextStyle(fontSize: 12, color: HotTheme.textSecondary),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: toCtrl,
                    decoration: InputDecoration(
                      labelText: isVi ? 'Địa chỉ người nhận (0x...)' : 'Recipient Address (0x...)',
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: amountCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      labelText: isVi ? 'Số lượng SUI' : 'Amount SUI',
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: gasCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      labelText: isVi ? 'Ngân sách Gas (SUI)' : 'Gas Budget (SUI)',
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: HotTheme.surface,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: HotTheme.borderSubtle),
                    ),
                    child: Column(
                      children: [
                        _buildSummaryRow(
                          isVi ? 'Người gửi:' : 'Sender:',
                          profile.address,
                        ),
                        const SizedBox(height: 4),
                        _buildSummaryRow(
                          isVi ? 'Mạng:' : 'Network:',
                          appState.activeChainNetwork.name,
                        ),
                      ],
                    ),
                  ),
                  if (errorText != null) ...[
                    const SizedBox(height: 8),
                    Text(errorText!, style: const TextStyle(color: HotTheme.danger, fontSize: 12)),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(isVi ? 'Hủy' : 'Cancel'),
            ),
            FilledButton.icon(
              icon: const Icon(Icons.qr_code, size: 18),
              onPressed: () async {
                final to = toCtrl.text.trim();
                final amtSui = double.tryParse(amountCtrl.text.trim());
                final budgetSui = double.tryParse(gasCtrl.text.trim()) ?? 0.01;
                if (amtSui == null || amtSui <= 0) {
                  setDialogState(() => errorText = isVi ? 'Số lượng không hợp lệ' : 'Invalid amount');
                  return;
                }

                try {
                  final amountMist = BigInt.from((amtSui * 1e9).round());
                  final gasBudgetMist = BigInt.from((budgetSui * 1e9).round());

                  final coins = await SuiHotPlugin.instance.rpcService.getCoins(
                    address: profile.address,
                    networkId: appState.activeChainNetwork.id,
                  );

                  final txData = SuiTransactionData.createTransfer(
                    sender: profile.address,
                    recipient: to,
                    amountMIST: amountMist,
                    gasPayment: coins,
                    gasBudget: gasBudgetMist,
                  );

                  final rng = Random.secure();
                  final reqId = Uint8List.fromList(List.generate(16, (_) => rng.nextInt(256)));
                  final reqUr = SuiSignRequestUr(
                    requestId: reqId,
                    chain: 'sui',
                    network: appState.activeChainNetwork.id,
                    txBytes: txData.toBcs(),
                    accountIndex: profile.accountIndex,
                    addressIndex: profile.addressIndex,
                  );

                  _pendingTxData = txData;
                  _pendingRequestId = reqId;

                  if (!mounted || !ctx.mounted) return;
                  Navigator.of(ctx).pop();
                  _showSignRequestQrDialog(reqUr);
                } catch (e) {
                  setDialogState(() => errorText = 'Lỗi tạo giao dịch: $e');
                }
              },
              label: Text(isVi ? 'Xuất QR Ký Giao Dịch' : 'Generate Sign Request QR'),
            ),
          ],
        ),
      ),
    );
  }

  void _showSignRequestQrDialog(SuiSignRequestUr reqUr) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isVi ? 'Mã QR Ký Giao Dịch Sui (ur:sui-sign-request)' : 'Sui Sign Request QR'),
        content: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                isVi
                    ? 'Dùng Ví Lạnh Ngoại Tuyến quét mã QR này để kiểm duyệt SEC-01 và ký.'
                    : 'Use the Offline Cold Wallet to scan this QR code for SEC-01 audit and signing.',
                style: const TextStyle(fontSize: 12, color: HotTheme.textSecondary),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: QrImageView(
                  data: reqUr.toUr(),
                  version: QrVersions.auto,
                  size: 260,
                  errorCorrectionLevel: QrErrorCorrectLevel.M,
                ),
              ),
              const SizedBox(height: 12),
              SelectableText(
                reqUr.toUr(),
                style: const TextStyle(fontSize: 9, fontFamily: 'monospace'),
                maxLines: 2,
              ),
            ],
          ),
        ),
        actions: [
          OutlinedButton.icon(
            icon: const Icon(Icons.copy, size: 16),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: reqUr.toUr()));
              if (ctx.mounted) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                  SnackBar(content: Text(isVi ? 'Đã sao chép UR' : 'Copied UR')),
                );
              }
            },
            label: Text(isVi ? 'Sao Chép' : 'Copy'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(isVi ? 'Xong' : 'Done'),
          ),
        ],
      ),
    );
  }

  void _showSubmitSignedTxDialog() {
    final pasteCtrl = TextEditingController();
    String? errorText;
    bool broadcasting = false;

    showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(isVi ? 'Bước 2: Quét Chữ Ký & Phát Sóng Sui' : 'Step 2: Scan Signature & Broadcast Sui'),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    isVi
                        ? 'Quét mã QR (ur:sui-sign-response) từ màn hình Ví Lạnh sau khi ký.'
                        : 'Scan QR code (ur:sui-sign-response) from Cold Wallet after signing.',
                    style: const TextStyle(fontSize: 12, color: HotTheme.textSecondary),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 200,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: WebQrScanner(
                        onCodeScanned: (code) {
                          _processSignature(
                            code: code,
                            setDialogState: setDialogState,
                            onError: (err) => setDialogState(() => errorText = err),
                            onBroadcasting: (b) => setDialogState(() => broadcasting = b),
                            onSuccess: (digest) {
                              Navigator.of(ctx).pop();
                              _showSuccessDialog(digest);
                            },
                          );
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: pasteCtrl,
                    maxLines: 2,
                    decoration: InputDecoration(
                      labelText: isVi ? 'Hoặc dán mã ur:sui-sign-response' : 'Or paste ur:sui-sign-response',
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  if (errorText != null) ...[
                    const SizedBox(height: 8),
                    Text(errorText!, style: const TextStyle(color: HotTheme.danger, fontSize: 12)),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(isVi ? 'Đóng' : 'Close'),
            ),
            FilledButton.icon(
              icon: broadcasting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.send, size: 16),
              onPressed: broadcasting
                  ? null
                  : () {
                      _processSignature(
                        code: pasteCtrl.text.trim(),
                        setDialogState: setDialogState,
                        onError: (err) => setDialogState(() => errorText = err),
                        onBroadcasting: (b) => setDialogState(() => broadcasting = b),
                        onSuccess: (digest) {
                          Navigator.of(ctx).pop();
                          _showSuccessDialog(digest);
                        },
                      );
                    },
              label: Text(broadcasting
                  ? (isVi ? 'Đang phát sóng...' : 'Broadcasting...')
                  : (isVi ? 'Phát Sóng' : 'Broadcast')),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _processSignature({
    required String code,
    required void Function(void Function()) setDialogState,
    required void Function(String) onError,
    required void Function(bool) onBroadcasting,
    required void Function(String) onSuccess,
  }) async {
    if (code.isEmpty) {
      onError(isVi ? 'Vui lòng quét QR hoặc dán mã chữ ký' : 'Scan QR or paste signature');
      return;
    }

    try {
      final resp = SuiSignResponseUr.fromUr(code);
      final txData = _pendingTxData;
      if (txData == null || _pendingRequestId == null) {
        onError(isVi ? 'Không tìm thấy giao dịch chờ ở Bước 1' : 'Pending tx not found from Step 1');
        return;
      }
      if (!constantTimeEquals(resp.requestId, _pendingRequestId!)) {
        onError(isVi ? 'Mã requestId của chữ ký không khớp yêu cầu Step 1' : 'Signature requestId mismatch');
        return;
      }

      onBroadcasting(true);

      final payload = jsonEncode({
        'txBytes': base64Encode(txData.toBcs()),
        'signatures': [resp.base64Signature],
      });

      final digest = await SuiHotPlugin.instance.broadcastTransaction(
        network: appState.activeChainNetwork,
        signedTxBytes: Uint8List.fromList(utf8.encode(payload)),
      );
      final activeProfile = appState.activeSuiProfile;
      if (activeProfile != null) {
        await appState.recordRecentBroadcastTx(
          chainId: appState.activeChainId,
          networkId: appState.activeChainNetwork.id,
          address: activeProfile.address,
          txHash: digest,
          explorerUrl: SuiRpcService.explorerTxUrl(appState.activeChainNetwork.id, digest),
        );
      }

      onBroadcasting(false);
      onSuccess(digest);
    } catch (e) {
      onBroadcasting(false);
      onError('Lỗi phát sóng: $e');
    }
  }

  void _showSuccessDialog(String digest) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.check_circle, color: HotTheme.success),
            const SizedBox(width: 8),
            Text(isVi ? 'Phát Sóng Thành Công!' : 'Broadcast Successful!'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(isVi ? 'Mã băm giao dịch (Tx Digest):' : 'Transaction Digest:'),
            const SizedBox(height: 8),
            SelectableText(
              digest,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: HotTheme.primary),
            ),
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              appState.refreshSuiState();
            },
            child: Text(isVi ? 'Đóng' : 'Close'),
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(fontSize: 12, color: HotTheme.textSecondary)),
        Flexible(
          child: SelectableText(
            value,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, fontFamily: 'monospace'),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final profile = appState.activeSuiProfile;
    final state = appState.suiAccountState;
    final loading = appState.suiLoading;
    final error = appState.suiError;

    final balanceSui = state?['sui']?.toString() ?? '0.0000';
    final mist = state?['mist']?.toString() ?? '0';

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Top Bar
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                isVi ? 'Bảng Điều Khiển Sui Watch-Only' : 'Sui Watch-Only Dashboard',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.science_outlined, size: 16),
                      onPressed: appState.loadDemoSuiData,
                      label: Text(isVi ? 'Nạp Demo Data' : 'Load Demo Data'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.icon(
                      icon: const Icon(Icons.add, size: 16),
                      onPressed: _showAddAccountDialog,
                      label: Text(isVi ? 'Nhập Tài Khoản' : 'Import Account'),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Account selector and details
          if (profile == null)
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: HotTheme.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: HotTheme.borderSubtle),
              ),
              child: Column(
                children: [
                  const Icon(Icons.account_balance_wallet_outlined, size: 48, color: HotTheme.textSecondary),
                  const SizedBox(height: 12),
                  Text(
                    isVi ? 'Chưa có tài khoản Sui Watch-Only nào' : 'No Sui Watch-Only Account',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    isVi
                        ? 'Bấm "Nạp Demo Data" để trải nghiệm hoặc "Nhập Tài Khoản" để kết nối Ví Lạnh.'
                        : 'Tap "Load Demo Data" to test or "Import Account" to link your Cold Wallet.',
                    style: const TextStyle(fontSize: 12, color: HotTheme.textSecondary),
                  ),
                ],
              ),
            )
          else ...[
            Card(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: const BorderSide(color: HotTheme.borderSubtle),
              ),
              color: HotTheme.surface,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: HotTheme.primary.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(Icons.water_drop_outlined, color: HotTheme.primary, size: 28),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                profile.name,
                                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'Sui • m/44\'/784\'/${profile.accountIndex}\'/0\'/${profile.addressIndex}\' • ${appState.activeChainNetwork.name}',
                                style: const TextStyle(fontSize: 12, color: HotTheme.textSecondary),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          key: const Key('sui_manage_wallets_btn'),
                          icon: const Icon(Icons.switch_account_outlined, size: 20),
                          onPressed: () => showWalletProfilesDialog(context, appState),
                          tooltip: isVi ? 'Quản lý / Đổi ví' : 'Manage wallets',
                        ),
                        IconButton(
                          icon: const Icon(Icons.refresh, size: 20),
                          onPressed: loading ? null : appState.refreshSuiState,
                          tooltip: isVi ? 'Làm mới số dư' : 'Refresh balance',
                        ),
                      ],
                    ),
                    const Divider(height: 24),
                    Text(
                      isVi ? 'Số dư khả dụng:' : 'Available Balance:',
                      style: const TextStyle(fontSize: 12, color: HotTheme.textSecondary),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Text(
                          balanceSui,
                          style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: HotTheme.primary),
                        ),
                        const SizedBox(width: 8),
                        const Text(
                          'SUI',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: HotTheme.textSecondary),
                        ),
                        const SizedBox(width: 12),
                        Flexible(
                          child: Text(
                            '($mist MIST)',
                            style: const TextStyle(fontSize: 12, color: HotTheme.textSecondary, fontFamily: 'monospace'),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        const Text('Địa chỉ: ', style: TextStyle(fontSize: 12, color: HotTheme.textSecondary)),
                        Expanded(
                          child: SelectableText(
                            profile.address,
                            style: const TextStyle(fontSize: 12, fontFamily: 'monospace', fontWeight: FontWeight.bold),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.copy, size: 16),
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: profile.address));
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(isVi ? 'Đã sao chép địa chỉ' : 'Address copied')),
                            );
                          },
                        ),
                      ],
                    ),
                    if (error != null) ...[
                      const SizedBox(height: 8),
                      Text(error, style: const TextStyle(color: HotTheme.danger, fontSize: 12)),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),

            // Two-Step Air-Gap Transaction Flow Cards
            Text(
              isVi ? 'Quy Trình Ký Giao Dịch Ngoại Tuyến (Air-Gap)' : 'Offline Air-Gap Signing Flow',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Card(
                    color: HotTheme.surface,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                      side: const BorderSide(color: HotTheme.borderSubtle),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                width: 28,
                                height: 28,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: HotTheme.primary,
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: const Text('1', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  isVi ? 'Bước 1: Tạo Giao Dịch & Xuất QR' : 'Step 1: Create Tx & Export QR',
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Text(
                            isVi
                                ? 'Nhập người nhận & số lượng SUI, tạo Programmable Transaction Block (PTB) và hiển thị Animated QR cho Ví Lạnh.'
                                : 'Enter recipient & amount, prepare PTB and display Animated QR for Cold Wallet to scan.',
                            style: const TextStyle(fontSize: 12, color: HotTheme.textSecondary),
                          ),
                          const SizedBox(height: 16),
                          FilledButton.icon(
                            icon: const Icon(Icons.send_outlined, size: 16),
                            onPressed: _showCreateTxDialog,
                            label: Text(isVi ? 'Tạo Giao Dịch' : 'Create Transaction'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Card(
                    color: HotTheme.surface,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                      side: const BorderSide(color: HotTheme.borderSubtle),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                width: 28,
                                height: 28,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: HotTheme.balanceAccent,
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: const Text('2', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  isVi ? 'Bước 2: Quét Chữ Ký & Phát Sóng' : 'Step 2: Scan Signature & Broadcast',
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Text(
                            isVi
                                ? 'Quét mã QR chữ ký từ Ví Lạnh, ghép với Intent Message và thực thi trực tiếp trên mạng Sui.'
                                : 'Scan signed QR from Cold Wallet and execute transaction block directly on Sui fullnode.',
                            style: const TextStyle(fontSize: 12, color: HotTheme.textSecondary),
                          ),
                          const SizedBox(height: 16),
                          FilledButton.tonalIcon(
                            icon: const Icon(Icons.qr_code_scanner, size: 16),
                            onPressed: _showSubmitSignedTxDialog,
                            label: Text(isVi ? 'Quét & Phát Sóng' : 'Scan & Broadcast'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            RecentTxsSection(
              txs: appState.recentTxsFor(
                chainId: appState.activeChainId,
                networkId: appState.activeChainNetwork.id,
                address: profile.address,
                remoteTxs: (state?['recentTxs'] as List<dynamic>?)
                        ?.whereType<ChainTxRecord>()
                        .toList() ??
                    const [],
              ),
              isVi: isVi,
              loading: loading,
              historyError: state?['historyError'] as String?,
              accountExplorerUrl: _suiAddressExplorerUrl(appState.activeChainNetwork.id, profile.address),
              onRefresh: appState.refreshSuiState,
            ),
          ],
        ],
      ),
    );
  }

  String _suiAddressExplorerUrl(String networkId, String address) {
    final key = networkId.toLowerCase();
    final net = (key == 'mainnet' || key == 'devnet' || key == 'testnet') ? key : 'testnet';
    return 'https://suiscan.xyz/$net/account/$address';
  }
}
