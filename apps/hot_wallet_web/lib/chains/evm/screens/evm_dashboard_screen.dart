import 'dart:convert';
import 'dart:math';

import 'package:chain_core_interface/chain_core_interface.dart';
import 'package:evm_core/evm_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../core/models/chain_tx_record.dart';
import '../../../services/hot_app_state.dart';
import '../../../theme/hot_theme.dart';
import '../../../widgets/recent_txs_section.dart';
import '../../../widgets/wallet_profiles_dialog.dart';
import '../../../widgets/web_qr_scanner.dart';
import '../evm_hot_plugin.dart';
import '../services/evm_rpc_service.dart';
import '../services/hyperliquid_service.dart';

class EvmDashboardScreen extends StatefulWidget {
  final HotAppState appState;

  const EvmDashboardScreen({super.key, required this.appState});

  @override
  State<EvmDashboardScreen> createState() => _EvmDashboardScreenState();
}

class _EvmDashboardScreenState extends State<EvmDashboardScreen> {
  // Store pending transactions created in Step 1 to broadcast in Step 2
  Eip1559Transaction? _pendingEthTx;
  HlUsdSendAction? _pendingHlAction;
  int? _pendingHlNonce;
  Uint8List? _pendingRequestId;

  HotAppState get appState => widget.appState;
  bool get isHyperliquid => appState.activeChainId == ChainId.hyperliquid;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (appState.activeEvmProfile != null && appState.evmAccountState == null) {
        appState.refreshEvmState();
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
          title: Text(
            appState.locale.name == 'vi'
                ? 'Nhập Tài Khoản ${appState.activeChainPlugin.displayName}'
                : 'Import ${appState.activeChainPlugin.displayName} Account',
          ),
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
                      labelText: appState.locale.name == 'vi'
                          ? 'Tên tài khoản (tùy chọn)'
                          : 'Account name (optional)',
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
                      labelText: appState.locale.name == 'vi'
                          ? 'Dán mã UR (ur:eth-account...) hoặc địa chỉ 0x...'
                          : 'Paste UR (ur:eth-account...) or 0x... address',
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  if (errorText != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      errorText!,
                      style: const TextStyle(color: Colors.redAccent, fontSize: 13),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(appState.locale.name == 'vi' ? 'Hủy' : 'Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final text = inputCtrl.text.trim();
                if (text.isEmpty) {
                  setDialogState(() => errorText = 'Vui lòng nhập dữ liệu');
                  return;
                }
                _parseAndSaveAccount(
                  code: text,
                  name: nameCtrl.text,
                  onError: (err) => setDialogState(() => errorText = err),
                  onSuccess: () => Navigator.of(ctx).pop(),
                );
              },
              child: Text(appState.locale.name == 'vi' ? 'Lưu' : 'Save'),
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
    try {
      String address;
      int accountIndex = 0;

      if (code.toLowerCase().startsWith('ur:eth-account')) {
        final ur = EthAccountUr.fromUr(code);
        address = ur.address;
        accountIndex = ur.accountIndex;
      } else if (code.startsWith('0x') && (code.length == 42)) {
        address = Eip55.toChecksumAddress(code);
      } else {
        onError('Định dạng không hợp lệ. Hỗ trợ ur:eth-account... hoặc 0x...');
        return;
      }

      appState.addEvmProfile(
        name: name.trim().isEmpty
            ? '${appState.activeChainPlugin.displayName} Account $accountIndex'
            : name.trim(),
        chainId: appState.activeChainId,
        address: address,
        networkId: appState.activeChainNetwork.id,
        accountIndex: accountIndex,
      );
      onSuccess();
    } catch (e) {
      onError('Lỗi giải mã tài khoản: $e');
    }
  }

  void _showAddressQrDialog(String address) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          appState.locale.name == 'vi' ? 'Địa chỉ ví' : 'Wallet Address',
          textAlign: TextAlign.center,
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
              ),
              child: QrImageView(
                data: address,
                version: QrVersions.auto,
                size: 220,
              ),
            ),
            const SizedBox(height: 12),
            SelectableText(
              address,
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
              textAlign: TextAlign.center,
            ),
          ],
        ),
        actions: [
          TextButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: address));
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    appState.locale.name == 'vi'
                        ? 'Đã sao chép địa chỉ!'
                        : 'Address copied!',
                  ),
                ),
              );
            },
            icon: const Icon(Icons.copy, size: 16),
            label: Text(appState.locale.name == 'vi' ? 'Sao chép' : 'Copy'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(appState.locale.name == 'vi' ? 'Đóng' : 'Close'),
          ),
        ],
      ),
    );
  }

  void _showSendDialog() {
    final toCtrl = TextEditingController();
    final amountCtrl = TextEditingController();
    String? errorText;

    showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(
            isHyperliquid
                ? (appState.locale.name == 'vi' ? 'Hyperliquid UsdSend' : 'Hyperliquid UsdSend')
                : (appState.locale.name == 'vi' ? 'Gửi Ethereum (ETH)' : 'Send Ethereum (ETH)'),
          ),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: toCtrl,
                    decoration: InputDecoration(
                      labelText: appState.locale.name == 'vi'
                          ? 'Địa chỉ nhận (0x...)'
                          : 'Recipient Address (0x...)',
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: amountCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      labelText: isHyperliquid ? 'Số lượng (USDC)' : 'Số lượng (ETH)',
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  if (errorText != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      errorText!,
                      style: const TextStyle(color: Colors.redAccent, fontSize: 13),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(appState.locale.name == 'vi' ? 'Hủy' : 'Cancel'),
            ),
            FilledButton.icon(
              onPressed: () {
                final to = toCtrl.text.trim();
                final amtStr = amountCtrl.text.trim();
                if (!to.startsWith('0x') || to.length != 42) {
                  setDialogState(() => errorText = 'Địa chỉ ví 0x... không hợp lệ');
                  return;
                }
                final amt = double.tryParse(amtStr);
                if (amt == null || amt <= 0) {
                  setDialogState(() => errorText = 'Số lượng không hợp lệ');
                  return;
                }

                Navigator.of(ctx).pop();
                _createSignRequestAndShowQr(to: to, amount: amt);
              },
              icon: const Icon(Icons.qr_code, size: 18),
              label: Text(
                appState.locale.name == 'vi'
                    ? 'Tạo mã QR ký (Step 1)'
                    : 'Create Sign QR (Step 1)',
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _createSignRequestAndShowQr({required String to, required double amount}) {
    final profile = appState.activeEvmProfile;
    if (profile == null) return;

    try {
      final reqId = Uint8List.fromList(List.generate(16, (i) => Random.secure().nextInt(256)));
      _pendingRequestId = reqId;
      String urString;

      if (isHyperliquid) {
        final isMainnet = !appState.activeChainNetwork.isTestnet;
        final nonce = DateTime.now().millisecondsSinceEpoch;
        final action = HlUsdSendAction(
          isMainnet: isMainnet,
          destination: to,
          amount: amount.toStringAsFixed(2),
          time: nonce,
        );
        _pendingHlAction = action;
        _pendingHlNonce = nonce;
        _pendingEthTx = null;

        final typedData = HyperliquidTxBuilder.buildUsdSendTypedData(action);
        final signRequestUr = EthSignRequestUr(
          requestId: reqId,
          chain: 'hyperliquid',
          network: appState.activeChainNetwork.id,
          payloadType: EthPayloadType.eip712,
          rawPayload: Uint8List.fromList(utf8.encode(jsonEncode(typedData.toJson()))),
          accountIndex: profile.accountIndex,
          addressIndex: 0,
          metadata: {
            'actionType': 'usdSend',
            'destination': to,
            'amount': amount.toStringAsFixed(2),
          },
        );
        urString = signRequestUr.toUr();
      } else {
        // Ethereum EIP-1559
        final state = appState.evmAccountState;
        final nonceInt = int.tryParse(state?['nonce']?.toString() ?? '0') ?? 0;
        final wei = BigInt.from((amount * 1e18).round());

        final tx = Eip1559Transaction(
          chainId: appState.activeChainNetwork.networkCode ?? 1,
          nonce: BigInt.from(nonceInt),
          maxPriorityFeePerGas: BigInt.from(2000000000), // 2 Gwei
          maxFeePerGas: BigInt.from(30000000000), // 30 Gwei
          gasLimit: BigInt.from(21000),
          to: to,
          value: wei,
        );
        _pendingEthTx = tx;
        _pendingHlAction = null;
        _pendingHlNonce = null;

        final signRequestUr = EthSignRequestUr(
          requestId: reqId,
          chain: 'ethereum',
          network: appState.activeChainNetwork.id,
          payloadType: EthPayloadType.eip1559,
          rawPayload: tx.unsignedSigningBytes,
          accountIndex: profile.accountIndex,
          addressIndex: 0,
          metadata: {
            'chainId': tx.chainId,
            'to': tx.to,
            'valueWei': tx.value.toString(),
            'maxFeePerGas': tx.maxFeePerGas.toString(),
            'gasLimit': tx.gasLimit.toString(),
          },
        );
        urString = signRequestUr.toUr();
      }

      _showSignRequestQrDialog(urString);
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Lỗi tạo yêu cầu ký: $e')),
      );
    }
  }

  void _showSignRequestQrDialog(String urString) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          appState.locale.name == 'vi'
              ? 'Mã QR Ký Giao Dịch (Step 1)'
              : 'Sign Request QR (Step 1)',
          textAlign: TextAlign.center,
        ),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                appState.locale.name == 'vi'
                    ? 'Dùng Ví Lạnh quét mã QR này ở mục "QUÉT MÃ QR GIAO DỊCH (KÝ)" để kiểm tra và ký.'
                    : 'Scan this QR code with your Cold Wallet in "SCAN SIGN REQUEST" to review and sign.',
                style: const TextStyle(fontSize: 13, color: HotTheme.textSecondary),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: QrImageView(
                  data: urString,
                  version: QrVersions.auto,
                  size: 260,
                ),
              ),
              const SizedBox(height: 12),
              SelectableText(
                urString.length > 80 ? '${urString.substring(0, 80)}...' : urString,
                style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
        actions: [
          TextButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: urString));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Đã sao chép mã UR!')),
              );
            },
            icon: const Icon(Icons.copy, size: 16),
            label: Text(appState.locale.name == 'vi' ? 'Sao chép UR' : 'Copy UR'),
          ),
          FilledButton.icon(
            onPressed: () {
              Navigator.of(ctx).pop();
              _showScanSignedResponseDialog();
            },
            icon: const Icon(Icons.qr_code_scanner, size: 18),
            label: Text(
              appState.locale.name == 'vi'
                  ? 'Tiếp tục: Nhập kết quả ký (Step 2)'
                  : 'Next: Submit Sign (Step 2)',
            ),
          ),
        ],
      ),
    );
  }

  void _showScanSignedResponseDialog() {
    final inputCtrl = TextEditingController();
    String? errorText;
    bool broadcasting = false;

    showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(
            appState.locale.name == 'vi'
                ? 'Nhập Kết Quả Ký Từ Ví Lạnh (Step 2)'
                : 'Submit Signed Response (Step 2)',
          ),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    appState.locale.name == 'vi'
                        ? 'Quét mã QR kết quả ký từ Ví Lạnh hoặc dán chuỗi ur:eth-sign-response...'
                        : 'Scan signed QR response from Cold Wallet or paste ur:eth-sign-response...',
                    style: const TextStyle(fontSize: 13, color: HotTheme.textSecondary),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 200,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: WebQrScanner(
                        onCodeScanned: (code) {
                          if (broadcasting) return;
                          _broadcastResponse(
                            code: code,
                            setBroadcasting: (b) => setDialogState(() => broadcasting = b),
                            onError: (err) => setDialogState(() => errorText = err),
                            onSuccess: (txHash) {
                              Navigator.of(ctx).pop();
                              _showSuccessBroadcastDialog(txHash);
                            },
                          );
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: inputCtrl,
                    maxLines: 2,
                    decoration: const InputDecoration(
                      labelText: 'Dán mã ur:eth-sign-response...',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  if (errorText != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      errorText!,
                      style: const TextStyle(color: Colors.redAccent, fontSize: 13),
                    ),
                  ],
                  if (broadcasting) ...[
                    const SizedBox(height: 12),
                    const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        CircularProgressIndicator(strokeWidth: 2),
                        SizedBox(width: 12),
                        Text('Đang phát sóng lên blockchain...'),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: broadcasting ? null : () => Navigator.of(ctx).pop(),
              child: Text(appState.locale.name == 'vi' ? 'Đóng' : 'Close'),
            ),
            FilledButton.icon(
              onPressed: broadcasting
                  ? null
                  : () {
                      final code = inputCtrl.text.trim();
                      if (code.isEmpty) {
                        setDialogState(() => errorText = 'Vui lòng dán chuỗi ur:eth-sign-response');
                        return;
                      }
                      _broadcastResponse(
                        code: code,
                        setBroadcasting: (b) => setDialogState(() => broadcasting = b),
                        onError: (err) => setDialogState(() => errorText = err),
                        onSuccess: (txHash) {
                          Navigator.of(ctx).pop();
                          _showSuccessBroadcastDialog(txHash);
                        },
                      );
                    },
              icon: const Icon(Icons.send, size: 18),
              label: Text(appState.locale.name == 'vi' ? 'Phát sóng' : 'Broadcast'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _broadcastResponse({
    required String code,
    required void Function(bool) setBroadcasting,
    required void Function(String) onError,
    required void Function(String) onSuccess,
  }) async {
    try {
      setBroadcasting(true);
      final resp = EthSignResponseUr.fromUr(code);
      if (_pendingRequestId == null || !constantTimeEquals(resp.requestId, _pendingRequestId!)) {
        setBroadcasting(false);
        onError('Mã requestId của chữ ký không khớp yêu cầu Step 1.');
        return;
      }

      if (isHyperliquid) {
        if (_pendingHlAction == null || _pendingHlNonce == null) {
          onError('Không tìm thấy hành động Hyperliquid đang chờ xử lý. Hãy tạo lại Step 1.');
          setBroadcasting(false);
          return;
        }

        final actionMap = {
          'type': 'usdSend',
          ..._pendingHlAction!.toMessageMap(),
        };

        final payload = {
          'action': actionMap,
          'nonce': _pendingHlNonce,
          'signature': {
            'r': hexEncode(resp.r),
            's': hexEncode(resp.s),
            'v': resp.v,
          },
        };

        final signedBytes = Uint8List.fromList(utf8.encode(jsonEncode(payload)));
        final result = await appState.activeChainPlugin.broadcastTransaction(
          network: appState.activeChainNetwork,
          signedTxBytes: signedBytes,
        );
        final activeProfile = appState.activeEvmProfile;
        if (activeProfile != null) {
          await appState.recordRecentBroadcastTx(
            chainId: appState.activeChainId,
            networkId: appState.activeChainNetwork.id,
            address: activeProfile.address,
            txHash: result == 'ok' ? 'hl_${DateTime.now().millisecondsSinceEpoch}' : result,
            summary: 'usdSend',
            explorerUrl: HyperliquidService.explorerTxUrl(appState.activeChainNetwork.id, result),
          );
        }
        setBroadcasting(false);
        onSuccess(result);
      } else {
        if (_pendingEthTx == null) {
          onError('Không tìm thấy giao dịch Ethereum đang chờ xử lý. Hãy tạo lại Step 1.');
          setBroadcasting(false);
          return;
        }

        final signedBytes = EvmHotPlugin.ethereum.assembleSignedEip1559Tx(
          _pendingEthTx!,
          resp,
        );

        final txHash = await appState.activeChainPlugin.broadcastTransaction(
          network: appState.activeChainNetwork,
          signedTxBytes: signedBytes,
        );
        final activeProfile = appState.activeEvmProfile;
        if (activeProfile != null) {
          await appState.recordRecentBroadcastTx(
            chainId: appState.activeChainId,
            networkId: appState.activeChainNetwork.id,
            address: activeProfile.address,
            txHash: txHash,
            explorerUrl: EvmRpcService.explorerTxUrl(appState.activeChainNetwork.id, txHash),
          );
        }
        setBroadcasting(false);
        onSuccess(txHash);
      }
    } catch (e) {
      setBroadcasting(false);
      onError('Lỗi phát sóng: $e');
    }
  }

  void _showSuccessBroadcastDialog(String txHash) {
    appState.refreshEvmState();
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.check_circle, color: Colors.green),
            const SizedBox(width: 8),
            Text(appState.locale.name == 'vi' ? 'Phát sóng thành công!' : 'Broadcast Success!'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              appState.locale.name == 'vi'
                  ? 'Giao dịch đã được gửi lên mạng lưới ${appState.activeChainPlugin.displayName}:'
                  : 'Transaction broadcasted to ${appState.activeChainPlugin.displayName}:',
            ),
            const SizedBox(height: 12),
            SelectableText(
              txHash,
              style: const TextStyle(fontWeight: FontWeight.bold, fontFamily: 'monospace'),
            ),
          ],
        ),
        actions: [
          TextButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: txHash));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Đã sao chép mã giao dịch!')),
              );
            },
            icon: const Icon(Icons.copy, size: 16),
            label: Text(appState.locale.name == 'vi' ? 'Sao chép' : 'Copy'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(appState.locale.name == 'vi' ? 'Xong' : 'Done'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final profile = appState.activeEvmProfile;
    final state = appState.evmAccountState;

    if (profile == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: const BoxDecoration(
                  color: HotTheme.surfaceElevated,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.account_balance_wallet_outlined,
                  size: 48,
                  color: HotTheme.primary,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                appState.locale.name == 'vi'
                    ? 'Chưa có tài khoản ${appState.activeChainPlugin.displayName} nào'
                    : 'No ${appState.activeChainPlugin.displayName} Account',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                appState.locale.name == 'vi'
                    ? 'Xuất mã QR từ Ví Lạnh (ở mục "Xuất QR Tài khoản") hoặc nhập địa chỉ 0x... để theo dõi số dư và tạo giao dịch ký ngoại tuyến.'
                    : 'Export Account QR from Cold Wallet or enter 0x... address to monitor balance and build transactions.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: HotTheme.textSecondary, fontSize: 13),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: _showAddAccountDialog,
                icon: const Icon(Icons.qr_code_scanner),
                label: Text(
                  appState.locale.name == 'vi'
                      ? 'Nhập Tài Khoản Ví Lạnh'
                      : 'Import Cold Wallet Account',
                ),
              ),
            ],
          ),
        ),
      );
    }

    // Display Account Info & Balance
    String balanceDisplay = '0.00';

    if (state != null) {
      if (isHyperliquid) {
        final val = state['accountValueUsd']?.toString() ?? '0.00';
        balanceDisplay = '\$$val';
      } else {
        final weiStr = state['balanceWei']?.toString() ?? '0';
        final wei = BigInt.tryParse(weiStr) ?? BigInt.zero;
        final ethVal = wei / BigInt.from(10).pow(18);
        final remainder = (wei % BigInt.from(10).pow(18)).toString().padLeft(18, '0');
        balanceDisplay = '${ethVal.toString()}.${remainder.substring(0, 6)} ETH';
      }
    }

    return RefreshIndicator(
      onRefresh: () => appState.refreshEvmState(),
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Account Card
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
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: HotTheme.primary.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                appState.activeChainPlugin.displayName.toUpperCase(),
                                style: const TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  color: HotTheme.primary,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                profile.name,
                                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        key: const Key('evm_manage_wallets_btn'),
                        tooltip: appState.locale.name == 'vi' ? 'Quản lý / Đổi ví' : 'Manage wallets',
                        icon: const Icon(Icons.swap_horiz, size: 20),
                        onPressed: () => showWalletProfilesDialog(context, appState),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  InkWell(
                    onTap: () => _showAddressQrDialog(profile.address),
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: HotTheme.surface,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              profile.address,
                              style: const TextStyle(
                                fontSize: 12,
                                fontFamily: 'monospace',
                                color: HotTheme.textSecondary,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 6),
                          const Icon(Icons.qr_code, size: 16, color: HotTheme.textSecondary),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Balance Card
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    HotTheme.surfaceElevated,
                    HotTheme.surfaceElevated.withValues(alpha: 0.8),
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: HotTheme.borderSubtle),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        appState.locale.name == 'vi' ? 'Tổng số dư khả dụng' : 'Total Balance',
                        style: const TextStyle(fontSize: 13, color: HotTheme.textSecondary),
                      ),
                      if (appState.evmLoading)
                        const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      else
                        InkWell(
                          onTap: () => appState.refreshEvmState(),
                          child: const Icon(Icons.refresh, size: 16, color: HotTheme.textSecondary),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    balanceDisplay,
                    style: const TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.5,
                    ),
                  ),
                  if (!isHyperliquid && state != null && state['nonce'] != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      'Nonce: ${state['nonce']}',
                      style: const TextStyle(fontSize: 12, color: HotTheme.textSecondary),
                    ),
                  ],
                  if (appState.evmError != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      appState.evmError!,
                      style: const TextStyle(fontSize: 11, color: Colors.amberAccent),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 24),

            // Actions: Step 1 (Send) & Step 2 (Submit Sign)
            FilledButton.icon(
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: _showSendDialog,
              icon: const Icon(Icons.send_rounded),
              label: Text(
                appState.locale.name == 'vi'
                    ? 'Tạo Lệnh Giao Dịch (Step 1)'
                    : 'Create Transaction (Step 1)',
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                side: const BorderSide(color: HotTheme.primaryBorder),
              ),
              onPressed: _showScanSignedResponseDialog,
              icon: const Icon(Icons.qr_code_scanner, color: HotTheme.primary),
              label: Text(
                appState.locale.name == 'vi'
                    ? 'Nhập Mã QR Đã Ký (Step 2)'
                    : 'Submit Signed QR (Step 2)',
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: HotTheme.primary,
                ),
              ),
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
              isVi: appState.locale.name == 'vi',
              loading: appState.evmLoading,
              historyError: state?['historyError'] as String?,
              accountExplorerUrl: _evmAddressExplorerUrl(appState.activeChainNetwork.id, profile.address),
              onRefresh: appState.refreshEvmState,
            ),
          ],
        ),
      ),
    );
  }

  String _evmAddressExplorerUrl(String networkId, String address) {
    if (isHyperliquid) {
      return networkId.toLowerCase() == 'testnet'
          ? 'https://app.hyperliquid-testnet.xyz/explorer/address/$address'
          : 'https://app.hyperliquid.xyz/explorer/address/$address';
    }
    switch (networkId.toLowerCase()) {
      case 'sepolia':
        return 'https://sepolia.etherscan.io/address/$address';
      case 'holesky':
        return 'https://holesky.etherscan.io/address/$address';
      case 'mainnet':
      default:
        return 'https://etherscan.io/address/$address';
    }
  }
}
