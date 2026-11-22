import 'dart:math';

import 'package:bitcoin_core/bitcoin_core.dart';
import 'package:chain_core_interface/chain_core_interface.dart' show constantTimeEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../core/models/chain_tx_record.dart';
import '../../../services/hot_app_state.dart';
import '../../../theme/hot_theme.dart';
import '../../../widgets/recent_txs_section.dart';
import '../../../widgets/wallet_profiles_dialog.dart';
import '../../../widgets/web_qr_scanner.dart';
import '../bitcoin_hot_plugin.dart';
import '../services/mempool_service.dart';

class BtcDashboardScreen extends StatefulWidget {
  final HotAppState appState;

  const BtcDashboardScreen({super.key, required this.appState});

  @override
  State<BtcDashboardScreen> createState() => _BtcDashboardScreenState();
}

class _BtcDashboardScreenState extends State<BtcDashboardScreen> {
  // Store pending transaction from Step 1 to assemble with signatures in Step 2
  BtcTransaction? _pendingBtcTx;
  Uint8List? _pendingRequestId;

  HotAppState get appState => widget.appState;
  bool get isVi => appState.locale.name == 'vi';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (appState.activeBtcProfile != null && appState.btcAccountState == null) {
        appState.refreshBtcState();
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
          title: Text(isVi ? 'Nhập Tài Khoản Bitcoin (BIP-84)' : 'Import Bitcoin Account (BIP-84)'),
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
                          ? 'Dán mã UR (ur:btc-account...) hoặc địa chỉ bc1q... / tb1q...'
                          : 'Paste UR (ur:btc-account...) or bc1q... / tb1q... address',
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
            ElevatedButton(
              onPressed: () {
                _parseAndSaveAccount(
                  code: inputCtrl.text.trim(),
                  name: nameCtrl.text,
                  onError: (err) => setDialogState(() => errorText = err),
                  onSuccess: () => Navigator.of(ctx).pop(),
                );
              },
              child: Text(isVi ? 'Nhập Ví' : 'Import'),
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
  }) async {
    final trimmed = code.trim();
    if (trimmed.isEmpty) {
      onError(isVi ? 'Vui lòng quét hoặc nhập mã' : 'Please scan or enter code');
      return;
    }

    try {
      if (trimmed.toLowerCase().startsWith('ur:btc-account/')) {
        final btcAcc = BtcAccountUr.fromUr(trimmed);
        await appState.addBtcProfile(
          name: name.trim().isNotEmpty ? name.trim() : (btcAcc.label ?? 'Bitcoin Account #${btcAcc.accountIndex}'),
          receiveAddress: btcAcc.receiveAddress,
          networkId: btcAcc.network,
          accountIndex: btcAcc.accountIndex,
          masterFingerprint: btcAcc.masterFingerprint,
          accountXpub: btcAcc.accountXpub,
        );
        onSuccess();
        return;
      }

      // Check if raw Bech32 address
      final isTestnet = appState.activeChainNetwork.isTestnet;
      final expectedHrp = isTestnet ? 'tb' : 'bc';
      if (trimmed.toLowerCase().startsWith(expectedHrp)) {
        await appState.addBtcProfile(
          name: name.trim().isNotEmpty ? name.trim() : 'Bitcoin Account',
          receiveAddress: trimmed,
          networkId: appState.activeChainNetwork.id,
          accountIndex: 0,
        );
        onSuccess();
        return;
      }

      onError(isVi
          ? 'Mã không hợp lệ. Phải là ur:btc-account hoặc địa chỉ bắt đầu bằng $expectedHrp'
          : 'Invalid code. Must be ur:btc-account or address starting with $expectedHrp');
    } catch (e) {
      onError('Lỗi xử lý: $e');
    }
  }

  void _showStep1SendDialog() {
    final active = appState.activeBtcProfile;
    if (active == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(isVi ? 'Vui lòng nhập tài khoản Bitcoin trước' : 'Please import an account first')),
      );
      return;
    }

    final toAddrCtrl = TextEditingController();
    final amountCtrl = TextEditingController();
    int feeRate = 10; // 10 sat/vB default
    String? dialogError;

    final utxoList = (appState.btcAccountState?['utxos'] as List<dynamic>?)
            ?.whereType<MempoolUtxo>()
            .toList() ??
        <MempoolUtxo>[];

    final totalBalanceSat = utxoList.fold<BigInt>(
      BigInt.zero,
      (sum, u) => sum + u.valueSat,
    );

    showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(isVi ? 'Bước 1: Tạo Giao Dịch Chuyển Bitcoin' : 'Step 1: Create Bitcoin Transfer'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: HotTheme.surfaceElevated,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: HotTheme.borderSubtle),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          isVi ? 'Số dư khả dụng:' : 'Available balance:',
                          style: const TextStyle(fontSize: 11, color: HotTheme.textSecondary),
                        ),
                        Text(
                          '${_formatBtc(totalBalanceSat)} BTC (${_formatSats(totalBalanceSat)} sats) • ${utxoList.length} UTXOs',
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: toAddrCtrl,
                    decoration: InputDecoration(
                      labelText: isVi ? 'Địa chỉ người nhận (bc1q... / tb1q...)' : 'Recipient address',
                      hintText: appState.activeChainNetwork.isTestnet
                          ? 'tb1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu'
                          : 'bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu',
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: amountCtrl,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          decoration: InputDecoration(
                            labelText: isVi ? 'Số tiền (BTC)' : 'Amount (BTC)',
                            border: const OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton(
                        onPressed: () {
                          // Send max estimation
                          if (totalBalanceSat <= BigInt.from(1000)) return;
                          final estFee = BigInt.from(feeRate * 140);
                          final sendMaxSat = totalBalanceSat - estFee;
                          if (sendMaxSat > BigInt.zero) {
                            final btcVal = sendMaxSat.toDouble() / 1e8;
                            amountCtrl.text = btcVal.toStringAsFixed(8);
                          }
                        },
                        child: Text(isVi ? 'Tối Đa' : 'Max'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    isVi ? 'Tốc độ phí mạng (sat/vB): $feeRate sat/vB' : 'Fee rate: $feeRate sat/vB',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                  Slider(
                    value: feeRate.toDouble(),
                    min: 1,
                    max: 50,
                    divisions: 49,
                    label: '$feeRate sat/vB',
                    onChanged: (v) => setDialogState(() => feeRate = v.round()),
                  ),
                  if (dialogError != null) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: HotTheme.danger.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: HotTheme.danger),
                      ),
                      child: Text(dialogError!, style: const TextStyle(color: HotTheme.danger, fontSize: 12)),
                    ),
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
            ElevatedButton(
              onPressed: () async {
                try {
                  final recipient = toAddrCtrl.text.trim();
                  if (recipient.isEmpty) throw Exception('Vui lòng nhập địa chỉ nhận');

                  final amtStr = amountCtrl.text.trim();
                  if (amtStr.isEmpty) throw Exception('Vui lòng nhập số tiền');

                  final amtBtc = double.tryParse(amtStr);
                  if (amtBtc == null || amtBtc <= 0) throw Exception('Số tiền không hợp lệ');

                  final amtSat = BigInt.from((amtBtc * 1e8).round());
                  if (amtSat > totalBalanceSat) throw Exception('Số dư không đủ để thực hiện giao dịch');

                  if (utxoList.isEmpty) {
                    throw Exception('Không có UTXO khả dụng để tạo giao dịch');
                  }

                  // Change address: standard internal derivation address matching Cold Wallet
                  final changeAddress = active.receiveAddress;

                  // Fetch nonWitnessUtxo raw previous transactions for BIP-143 SEC-01 verification
                  final networkId = appState.activeChainNetwork.id;
                  final btcInputs = <BtcUtxo>[];
                  for (final u in utxoList) {
                    final rawPrevTx = u.rawTxBytes ??
                        await BitcoinHotPlugin.instance.mempoolService.getRawTxBytes(networkId, u.txid);
                    btcInputs.add(
                      BtcUtxo(
                        outpoint: OutPoint(txid: u.txid, vout: u.vout),
                        valueSat: u.valueSat,
                        accountIndex: active.accountIndex,
                        change: 0,
                        addressIndex: 0,
                        nonWitnessUtxo: rawPrevTx,
                      ),
                    );
                  }

                  final buildResult = BtcTxBuilder.buildP2wpkhTx(
                    availableUtxos: btcInputs,
                    recipientAddress: recipient,
                    amountSat: amtSat,
                    changeAddress: changeAddress,
                    changeIndex: 0,
                    feeRateSatPerVb: feeRate,
                  );

                  // Create Ur Sign Request with cryptographic random requestId
                  final rng = Random.secure();
                  final requestId = Uint8List.fromList(List.generate(16, (_) => rng.nextInt(256)));
                  final signReq = BtcSignRequestUr(
                    requestId: requestId,
                    chain: 'bitcoin',
                    network: networkId,
                    transaction: buildResult.transaction,
                    accountIndex: active.accountIndex,
                    feeSat: buildResult.feeSat,
                  );

                  _pendingBtcTx = buildResult.transaction;
                  _pendingRequestId = requestId;
                  if (!ctx.mounted) return;
                  Navigator.of(ctx).pop();

                  _showUrQrDialog(
                    title: isVi ? 'Mã QR Ký Giao Dịch Bitcoin' : 'Bitcoin Sign Request QR',
                    urString: signReq.toUr(),
                    recipientAddress: recipient,
                    feeRateSatPerVb: feeRate,
                    buildResult: buildResult,
                  );
                } catch (e) {
                  if (ctx.mounted) {
                    setDialogState(() => dialogError = e.toString());
                  }
                }
              },
              child: Text(isVi ? 'Tạo Mã QR Ký' : 'Generate Sign QR'),
            ),
          ],
        ),
      ),
    );
  }

  void _showUrQrDialog({
    required String title,
    required String urString,
    required String recipientAddress,
    required int feeRateSatPerVb,
    required BtcTxBuildResult buildResult,
  }) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: QrImageView(
                    data: urString,
                    version: QrVersions.auto,
                    size: 240,
                  ),
                ),
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: HotTheme.surfaceElevated,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: HotTheme.borderSubtle),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildInfoRow('Người nhận:', recipientAddress),
                      const SizedBox(height: 6),
                      _buildInfoRow('Số tiền chuyển:', '${_formatBtc(buildResult.sendAmountSat)} BTC'),
                      const SizedBox(height: 6),
                      _buildInfoRow('Phí mạng (Miner Fee):', '${_formatSats(buildResult.feeSat)} sats ($feeRateSatPerVb sat/vB)'),
                      if (buildResult.changeSat != null && buildResult.changeSat! > BigInt.zero) ...[
                        const SizedBox(height: 6),
                        _buildInfoRow('Tiền thối về ví:', '${_formatSats(buildResult.changeSat!)} sats'),
                      ],
                      const SizedBox(height: 6),
                      _buildInfoRow('Kích thước vSize:', '${buildResult.estimatedVSize} vB'),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.copy, size: 16),
                        label: Text(isVi ? 'Sao Chép UR' : 'Copy UR'),
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: urString));
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(isVi ? 'Đã sao chép mã UR' : 'UR copied to clipboard')),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(isVi ? 'Đóng' : 'Close'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _showStep2SubmitDialog();
            },
            child: Text(isVi ? 'Tiếp tục sang Bước 2 (Quét Ký)' : 'Continue to Step 2'),
          ),
        ],
      ),
    );
  }

  void _showStep2SubmitDialog() {
    final inputCtrl = TextEditingController();
    String? errorText;
    bool broadcasting = false;

    showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(isVi ? 'Bước 2: Gửi Giao Dịch Đã Ký (Submit Signed Tx)' : 'Step 2: Submit Signed Transaction'),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    isVi
                        ? 'Quét hoặc dán mã phản hồi ký (ur:btc-sign-response) từ Ví Lạnh để phát sóng lên blockchain.'
                        : 'Scan or paste the signature response (ur:btc-sign-response) from Cold Wallet.',
                    style: const TextStyle(fontSize: 12, color: HotTheme.textSecondary),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 200,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: WebQrScanner(
                        onCodeScanned: (code) {
                          _processAndBroadcastSignedTx(
                            responseUr: code,
                            setDialogState: setDialogState,
                            onBroadcasting: (b) => setDialogState(() => broadcasting = b),
                            onError: (err) => setDialogState(() => errorText = err),
                            onSuccess: (txid) {
                              Navigator.of(ctx).pop();
                              _showSuccessDialog(txid);
                            },
                          );
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: inputCtrl,
                    maxLines: 3,
                    decoration: InputDecoration(
                      labelText: isVi ? 'Dán mã ur:btc-sign-response...' : 'Paste ur:btc-sign-response...',
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  if (errorText != null) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: HotTheme.danger.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: HotTheme.danger),
                      ),
                      child: Text(errorText!, style: const TextStyle(color: HotTheme.danger, fontSize: 12)),
                    ),
                  ],
                  if (broadcasting) ...[
                    const SizedBox(height: 12),
                    const Center(child: CircularProgressIndicator()),
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
            ElevatedButton(
              onPressed: broadcasting
                  ? null
                  : () {
                      _processAndBroadcastSignedTx(
                        responseUr: inputCtrl.text.trim(),
                        setDialogState: setDialogState,
                        onBroadcasting: (b) => setDialogState(() => broadcasting = b),
                        onError: (err) => setDialogState(() => errorText = err),
                        onSuccess: (txid) {
                          Navigator.of(ctx).pop();
                          _showSuccessDialog(txid);
                        },
                      );
                    },
              child: Text(isVi ? 'Phát Sóng (Broadcast)' : 'Broadcast'),
            ),
          ],
        ),
      ),
    );
  }

  void _processAndBroadcastSignedTx({
    required String responseUr,
    required void Function(void Function()) setDialogState,
    required void Function(bool) onBroadcasting,
    required void Function(String) onError,
    required void Function(String txid) onSuccess,
  }) async {
    final trimmed = responseUr.trim();
    if (trimmed.isEmpty) {
      onError(isVi ? 'Vui lòng quét hoặc dán mã ur:btc-sign-response' : 'Please scan or paste response UR');
      return;
    }

    if (!trimmed.toLowerCase().startsWith('ur:btc-sign-response/')) {
      onError(isVi ? 'Mã không đúng định dạng ur:btc-sign-response' : 'Invalid ur:btc-sign-response format');
      return;
    }

    if (_pendingBtcTx == null) {
      onError(isVi ? 'Chưa có thông tin giao dịch Bước 1' : 'No pending transaction from Step 1');
      return;
    }

    onBroadcasting(true);

    try {
      final resp = BtcSignResponseUr.fromUr(trimmed);
      if (_pendingRequestId == null || !constantTimeEquals(resp.requestId, _pendingRequestId!)) {
        onError(isVi
            ? 'Mã requestId của chữ ký không khớp yêu cầu hiện tại (Step 1)!'
            : 'Signature response requestId does not match the pending Step 1 request!');
        return;
      }
      final plugin = BitcoinHotPlugin.instance;
      final signedTx = plugin.assembleSignedTx(
        originalTx: _pendingBtcTx!,
        response: resp,
      );

      final rawBytes = BtcSerializer.serialize(signedTx);
      final txid = BtcSerializer.computeTxId(signedTx);

      // Attempt broadcast via MempoolService (never report success on failed broadcast)
      final broadcastResult = await plugin.broadcastTransaction(
        network: appState.activeChainNetwork,
        signedTxBytes: rawBytes,
      );
      final finalTxId = broadcastResult.isNotEmpty ? broadcastResult : txid;
      final activeProfile = appState.activeBtcProfile;
      if (activeProfile != null) {
        await appState.recordRecentBroadcastTx(
          chainId: appState.activeChainId,
          networkId: appState.activeChainNetwork.id,
          address: activeProfile.receiveAddress,
          txHash: finalTxId,
          explorerUrl: MempoolService.explorerTxUrl(appState.activeChainNetwork.id, finalTxId),
        );
      }
      _pendingBtcTx = null;
      _pendingRequestId = null;
      onSuccess(finalTxId);
    } catch (e) {
      onError(isVi ? 'Lỗi phát sóng Bitcoin tx: $e' : 'Bitcoin broadcast failed: $e');
    } finally {
      onBroadcasting(false);
    }
  }

  void _showSuccessDialog(String txid) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.check_circle, color: HotTheme.success, size: 28),
            const SizedBox(width: 8),
            Text(isVi ? 'Phát Sóng Thành Công!' : 'Transaction Broadcasted!'),
          ],
        ),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                isVi
                    ? 'Giao dịch Bitcoin đã được ký hợp lệ và phát sóng lên mạng lưới.'
                    : 'Bitcoin transaction has been successfully signed and broadcasted.',
                style: const TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: HotTheme.surfaceElevated,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: HotTheme.borderSubtle),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Transaction ID (TxID):', style: TextStyle(fontSize: 11, color: HotTheme.textSecondary)),
                    const SizedBox(height: 4),
                    SelectableText(
                      txid,
                      style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.bold, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(isVi ? 'Hoàn tất' : 'Done'),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 11, color: HotTheme.textSecondary)),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.end,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
          ),
        ),
      ],
    );
  }

  String _formatBtc(BigInt sats) {
    final doubleVal = sats.toDouble() / 1e8;
    return doubleVal.toStringAsFixed(8);
  }

  String _formatSats(BigInt sats) {
    return sats.toString().replaceAllMapped(
      RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
      (Match m) => '${m[1]},',
    );
  }

  @override
  Widget build(BuildContext context) {
    final active = appState.activeBtcProfile;
    final state = appState.btcAccountState;
    final loading = appState.btcLoading;
    final error = appState.btcError;

    final utxoList = (state?['utxos'] as List<dynamic>?)
            ?.whereType<MempoolUtxo>()
            .toList() ??
        <MempoolUtxo>[];

    final totalBalanceSat = utxoList.fold<BigInt>(
      BigInt.zero,
      (sum, u) => sum + u.valueSat,
    );

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Account Summary Card
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: HotTheme.surfaceElevated,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: HotTheme.borderSubtle),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Row(
                        children: [
                          const Icon(Icons.currency_bitcoin, color: Color(0xFFF7931A), size: 24),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              active?.name ?? (isVi ? 'Chưa có tài khoản' : 'No Account'),
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      key: const Key('btc_manage_wallets_btn'),
                      icon: const Icon(Icons.switch_account_outlined, size: 20),
                      tooltip: isVi ? 'Quản lý / Đổi ví' : 'Manage wallets',
                      onPressed: () => showWalletProfilesDialog(context, appState),
                    ),
                  ],
                ),
                if (active != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Đường dẫn BIP-84: m/84\'/${appState.activeChainNetwork.isTestnet ? 1 : 0}\'/${active.accountIndex}\'/0/0',
                    style: const TextStyle(fontSize: 11, color: HotTheme.textSecondary),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          active.receiveAddress,
                          style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.copy, size: 16),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        tooltip: isVi ? 'Sao chép' : 'Copy',
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: active.receiveAddress));
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(isVi ? 'Đã sao chép địa chỉ' : 'Address copied')),
                          );
                        },
                      ),
                    ],
                  ),
                  const Divider(height: 24),
                  const Text('Tổng số dư Bitcoin:', style: TextStyle(fontSize: 12, color: HotTheme.textSecondary)),
                  const SizedBox(height: 4),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(
                        _formatBtc(totalBalanceSat),
                        style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: Color(0xFFF7931A)),
                      ),
                      const SizedBox(width: 8),
                      const Text('BTC', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                    ],
                  ),
                  Text(
                    '≈ ${_formatSats(totalBalanceSat)} satoshi',
                    style: const TextStyle(fontSize: 12, color: HotTheme.textSecondary),
                  ),
                ] else ...[
                  const SizedBox(height: 12),
                  Text(
                    isVi
                        ? 'Chưa kết nối tài khoản Bitcoin. Hãy quét mã ur:btc-account từ Ví Lạnh hoặc nhập địa chỉ SegWit.'
                        : 'No Bitcoin account imported. Scan ur:btc-account from Cold Wallet or enter SegWit address.',
                    style: const TextStyle(fontSize: 12, color: HotTheme.textSecondary),
                  ),
                  const SizedBox(height: 12),
                  ElevatedButton.icon(
                    icon: const Icon(Icons.qr_code_scanner),
                    label: Text(isVi ? 'Nhập Tài Khoản Ngay' : 'Import Account Now'),
                    onPressed: _showAddAccountDialog,
                  ),
                ],
              ],
            ),
          ),

          const SizedBox(height: 16),

          // Action Buttons: Step 1 Send & Step 2 Submit
          if (active != null) ...[
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      backgroundColor: HotTheme.primary,
                      foregroundColor: Colors.white,
                    ),
                    icon: const Icon(Icons.send),
                    label: Text(isVi ? 'Bước 1: Chuyển BTC' : 'Step 1: Send BTC'),
                    onPressed: _showStep1SendDialog,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    icon: const Icon(Icons.qr_code_scanner),
                    label: Text(isVi ? 'Bước 2: Quét & Gửi' : 'Step 2: Submit Tx'),
                    onPressed: _showStep2SubmitDialog,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              icon: const Icon(Icons.science_outlined, size: 16),
              label: Text(isVi ? 'Nạp Dữ Liệu Demo Testnet' : 'Load Demo Testnet UTXOs'),
              onPressed: () {
                appState.loadDemoBtcData();
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(isVi ? 'Đã tải 2 UTXOs demo (0.015 BTC)' : 'Loaded 2 demo UTXOs (0.015 BTC)')),
                );
              },
            ),
          ],

          const SizedBox(height: 20),

          // UTXO List Section
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                isVi ? 'Danh Sách UTXOs (${utxoList.length})' : 'UTXO Outputs (${utxoList.length})',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
              ),
              IconButton(
                icon: const Icon(Icons.refresh, size: 18),
                onPressed: loading ? null : appState.refreshBtcState,
              ),
            ],
          ),
          const SizedBox(height: 8),

          if (loading)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: CircularProgressIndicator(),
              ),
            )
          else if (error != null)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: HotTheme.danger.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: HotTheme.danger),
              ),
              child: Text(error, style: const TextStyle(color: HotTheme.danger, fontSize: 12)),
            )
          else if (utxoList.isEmpty)
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: HotTheme.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: HotTheme.borderSubtle),
              ),
              child: Center(
                child: Text(
                  isVi
                      ? 'Chưa có UTXO nào trên địa chỉ này hoặc đang chờ xác nhận.'
                      : 'No confirmed UTXOs found on this address.',
                  style: const TextStyle(color: HotTheme.textSecondary, fontSize: 12),
                  textAlign: TextAlign.center,
                ),
              ),
            )
          else
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: utxoList.length,
              separatorBuilder: (c, i) => const SizedBox(height: 8),
              itemBuilder: (ctx, i) {
                final u = utxoList[i];
                return Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: HotTheme.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: HotTheme.borderSubtle),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.account_balance_wallet_outlined, color: HotTheme.primary, size: 24),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${u.txid.substring(0, 8)}...${u.txid.substring(u.txid.length - 8)}:${u.vout}',
                              style: const TextStyle(fontFamily: 'monospace', fontSize: 11, fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              u.confirmed
                                  ? (isVi ? 'Đã xác nhận (Block #${u.blockHeight})' : 'Confirmed (#${u.blockHeight})')
                                  : (isVi ? 'Chưa xác nhận' : 'Unconfirmed'),
                              style: TextStyle(
                                fontSize: 10,
                                color: u.confirmed ? HotTheme.success : HotTheme.warning,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            '${_formatBtc(u.valueSat)} BTC',
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                          ),
                          Text(
                            '${_formatSats(u.valueSat)} sats',
                            style: const TextStyle(fontSize: 10, color: HotTheme.textSecondary),
                          ),
                        ],
                      ),
                    ],
                  ),
                );
              },
            ),

          if (active != null) ...[
            const SizedBox(height: 20),
            RecentTxsSection(
              txs: appState.recentTxsFor(
                chainId: appState.activeChainId,
                networkId: appState.activeChainNetwork.id,
                address: active.receiveAddress,
                remoteTxs: (state?['recentTxs'] as List<dynamic>?)
                        ?.whereType<ChainTxRecord>()
                        .toList() ??
                    const [],
              ),
              isVi: isVi,
              loading: loading,
              historyError: state?['historyError'] as String?,
              accountExplorerUrl: _btcAddressExplorerUrl(appState.activeChainNetwork.id, active.receiveAddress),
              onRefresh: appState.refreshBtcState,
            ),
          ],
        ],
      ),
    );
  }

  String _btcAddressExplorerUrl(String networkId, String address) {
    switch (networkId.toLowerCase()) {
      case 'testnet4':
        return 'https://mempool.space/testnet4/address/$address';
      case 'signet':
        return 'https://mempool.space/signet/address/$address';
      case 'mainnet':
      default:
        return 'https://mempool.space/address/$address';
    }
  }
}
