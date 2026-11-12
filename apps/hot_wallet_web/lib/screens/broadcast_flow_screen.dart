import 'dart:async';

import 'package:cardano_core/cardano_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../services/conway_tx_builder.dart';
import '../services/hot_app_state.dart';
import '../theme/hot_theme.dart';
import '../utils/token_utils.dart';
import '../widgets/external_link_text.dart';
import '../widgets/web_qr_scanner.dart';
import 'dashboard_screen.dart';

enum _FlowStep { showSignRequest, scanSignResponse, readyToBroadcast, submitted }

class BroadcastFlowScreen extends StatefulWidget {
  final HotAppState appState;
  final TxBuildResult buildResult;
  final Stream<String>? testResponseStream;

  const BroadcastFlowScreen({
    super.key,
    required this.appState,
    required this.buildResult,
    this.testResponseStream,
  });

  @override
  State<BroadcastFlowScreen> createState() => _BroadcastFlowScreenState();
}

class _BroadcastFlowScreenState extends State<BroadcastFlowScreen> {
  _FlowStep _step = _FlowStep.showSignRequest;

  // Step 1: Animated Sign Request QR
  late UrEncoder _reqEncoder;
  late String _currentPart;
  Timer? _qrTimer;
  double _fps = 8;
  int _maxFragmentLen = 90;
  bool _paused = false;

  // Step 2: Scan Sign Response
  final UrDecoder _respDecoder = UrDecoder();
  final TextEditingController _pasteRespCtrl = TextEditingController();
  String? _scanError;

  // Step 3: Assembled Signed Tx
  Uint8List? _signedTxCbor;
  bool _broadcasting = false;
  String? _broadcastError;
  String? _txHash;
  bool _confirmed = false;
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    _initEncoder();
  }

  void _initEncoder() {
    _reqEncoder = widget.buildResult.signRequest.createEncoder(
      maxFragmentLen: _maxFragmentLen,
    );
    _currentPart = _reqEncoder.nextPart();
    _restartQrTimer();
  }

  void _restartQrTimer() {
    _qrTimer?.cancel();
    if (_reqEncoder.isSinglePart || _paused || _step != _FlowStep.showSignRequest) {
      return;
    }
    final ms = (1000 / _fps).round();
    _qrTimer = Timer.periodic(Duration(milliseconds: ms), (_) {
      if (!mounted) return;
      setState(() => _currentPart = _reqEncoder.nextPart());
    });
  }

  @override
  void dispose() {
    _qrTimer?.cancel();
    _pollTimer?.cancel();
    _pasteRespCtrl.dispose();
    super.dispose();
  }

  void _onResponseFrameScanned(String raw) {
    if (_step != _FlowStep.scanSignResponse) return;
    final accepted = _respDecoder.receivePart(raw);
    if (!accepted) {
      setState(() => _scanError = 'Ignored non-matching frame');
      return;
    }

    if (_respDecoder.isComplete) {
      final res = _respDecoder.result!;
      if (res.type != CardanoSignResponseUr.urType) {
        setState(() => _scanError = 'Unexpected UR type: ur:${res.type}');
        return;
      }
      try {
        final signResp = CardanoSignResponseUr.fromCborBytes(res.cborPayload);
        if (!constantTimeEquals(
          signResp.requestId,
          widget.buildResult.signRequest.requestId,
        )) {
          setState(() => _scanError = 'Request ID mismatch with active transaction!');
          return;
        }
        final assembled = ConwayTxSerializer.assembleSignedTransaction(
          txBodyCbor: widget.buildResult.signRequest.txBodyCbor,
          witnesses: signResp.vkeyWitnesses,
          verifySignatures: true,
        );
        setState(() {
          _signedTxCbor = assembled;
          _scanError = null;
          _step = _FlowStep.readyToBroadcast;
        });
      } catch (e) {
        setState(() => _scanError = e.toString());
      }
    } else {
      setState(() => _scanError = null);
    }
  }

  Future<void> _broadcastTx() async {
    final cbor = _signedTxCbor;
    if (cbor == null) return;
    setState(() {
      _broadcasting = true;
      _broadcastError = null;
    });
    try {
      final net = widget.appState.network;
      final key = widget.appState.activeProjectId;
      final hash = await widget.appState.blockfrost.submitTransaction(
        net,
        key,
        cbor,
      );
      if (!mounted) return;
      setState(() {
        _txHash = hash.replaceAll('"', '').trim();
        _step = _FlowStep.submitted;
      });
      _startConfirmationPolling();
    } catch (e) {
      if (mounted) setState(() => _broadcastError = e.toString());
    } finally {
      if (mounted) setState(() => _broadcasting = false);
    }
  }

  void _startConfirmationPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      final hash = _txHash;
      if (hash == null || !mounted || _confirmed) return;
      try {
        final ok = await widget.appState.blockfrost.isTransactionConfirmed(
          widget.appState.network,
          widget.appState.activeProjectId,
          hash,
        );
        if (ok && mounted) {
          setState(() => _confirmed = true);
          _pollTimer?.cancel();
          widget.appState.syncActiveWallet();
        }
      } catch (_) {}
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.appState.strings;

    return Scaffold(
      appBar: AppBar(title: Text(s.appTitle)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: switch (_step) {
              _FlowStep.showSignRequest => _buildStep1(s),
              _FlowStep.scanSignResponse => _buildStep2(s),
              _FlowStep.readyToBroadcast => _buildStep3(s),
              _FlowStep.submitted => _buildSubmittedStep(s),
            },
          ),
        ),
      ),
    );
  }

  Widget _buildStep1(dynamic s) {
    return SingleChildScrollView(
      child: Column(
        children: [
          Text(
            s.signReqStepTitle,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            'Fee: ${formatAda(widget.buildResult.fee)} ADA • Outputs: ${widget.buildResult.txBody.outputs.length} • Inputs: ${widget.buildResult.txBody.inputs.length}',
            style: const TextStyle(color: Colors.white70),
          ),
          if (widget.buildResult.txBody.outputs.isNotEmpty) ...[
            const SizedBox(height: 10),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      s.isVi ? 'Chi tiết tài sản gửi (Output #0)' : 'Transfer Summary (Output #0)',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'ADA: ${formatAda(widget.buildResult.txBody.outputs.first.lovelace)} ADA'
                      '${widget.buildResult.recipientMinAda != null ? ' (Min-ADA: ${formatAda(widget.buildResult.recipientMinAda!)} ADA)' : ''}',
                      style: const TextStyle(fontSize: 12),
                    ),
                    if (widget.buildResult.txBody.outputs.first.multiAsset.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      for (final e in widget.buildResult.txBody.outputs.first.multiAsset.assets.entries)
                        Builder(
                          builder: (context) {
                            final meta = widget.appState.syncState?.assetMetadata[e.key.unit];
                            final sym = resolveAssetSymbol(e.key, meta);
                            final dec = widget.appState.tokenDecimalsFor(e.key.unit, meta);
                            final amt = formatTokenAmount(e.value, dec);
                            return Text(
                              '• $amt $sym (${e.key.shortPolicy})',
                              style: const TextStyle(fontSize: 12, color: Colors.lightBlueAccent),
                            );
                          },
                        ),
                    ],
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(18),
            ),
            child: QrImageView(
              data: _currentPart,
              version: QrVersions.auto,
              size: 290,
              gapless: true,
              errorCorrectionLevel: QrErrorCorrectLevel.L,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            _reqEncoder.isSinglePart
                ? 'Single-part UR (${_currentPart.length} chars)'
                : 'Parts: ${_reqEncoder.seqLen} • Chunk chars: ${_currentPart.length}',
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
          if (!_reqEncoder.isSinglePart) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Text('FPS: ${_fps.round()}'),
                Expanded(
                  child: Slider(
                    min: 4,
                    max: 12,
                    divisions: 8,
                    value: _fps,
                    onChanged: (v) {
                      setState(() => _fps = v);
                      _restartQrTimer();
                    },
                  ),
                ),
                IconButton(
                  onPressed: () {
                    setState(() => _paused = !_paused);
                    _restartQrTimer();
                  },
                  icon: Icon(_paused ? Icons.play_arrow : Icons.pause),
                ),
              ],
            ),
            Row(
              children: [
                Text('Chunk bytes: $_maxFragmentLen'),
                Expanded(
                  child: Slider(
                    min: 60,
                    max: 140,
                    divisions: 4,
                    value: _maxFragmentLen.toDouble(),
                    onChanged: (v) {
                      setState(() {
                        _maxFragmentLen = v.round();
                        _initEncoder();
                      });
                    },
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () async {
              final messenger = ScaffoldMessenger.of(context);
              final singleUr = UrEncoder.encodeSingle(
                CardanoSignRequestUr.urType,
                widget.buildResult.signRequest.toCborBytes(),
              );
              await Clipboard.setData(ClipboardData(text: singleUr));
              if (!mounted) return;
              messenger.showSnackBar(
                SnackBar(
                  content: Text(
                    s.isVi
                        ? 'Đã sao chép ur:cardano-sign-request để dán vào Ví Lạnh'
                        : 'Copied ur:cardano-sign-request for Cold Wallet Simulator',
                  ),
                ),
              );
            },
            icon: const Icon(Icons.copy, size: 16),
            label: Text(
              s.isVi
                  ? 'Sao chép UR (mô phỏng quét QR sang Ví Lạnh)'
                  : 'Copy Sign Request UR (Browser Simulator)',
            ),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () {
                _qrTimer?.cancel();
                setState(() => _step = _FlowStep.scanSignResponse);
              },
              icon: const Icon(Icons.qr_code_scanner),
              label: Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: Text(s.scanRespStepBtn),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStep2(dynamic s) {
    final progress = _respDecoder.estimatedProgress;
    return Column(
      children: [
        Text(
          s.scanRespStepTitle,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 10),
        LinearProgressIndicator(value: progress),
        const SizedBox(height: 6),
        Text('${(progress * 100).toStringAsFixed(0)}% • ${_respDecoder.receivedPartCount} frames'),
        const SizedBox(height: 12),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: WebQrScanner(
              onCodeScanned: _onResponseFrameScanned,
              testScanStream: widget.testResponseStream,
            ),
          ),
        ),
        if (_scanError != null) ...[
          const SizedBox(height: 8),
          Text(_scanError!, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
        ],
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _pasteRespCtrl,
                decoration: InputDecoration(
                  labelText: s.pasteUrOptional,
                  isDense: true,
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: () {
                final parts = _pasteRespCtrl.text.trim().split(RegExp(r'\s+'));
                for (final part in parts) {
                  if (part.isNotEmpty) {
                    _onResponseFrameScanned(part);
                  }
                }
              },
              child: Text(s.parseUrBtn),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildStep3(dynamic s) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.verified, size: 72, color: HotTheme.success),
        const SizedBox(height: 14),
        Text(
          s.broadcastReadyTitle,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 10),
        Text('Signed CBOR Size: ${_signedTxCbor!.length} bytes'),
        if (_broadcastError != null) ...[
          const SizedBox(height: 12),
          Text(_broadcastError!, style: const TextStyle(color: Colors.redAccent)),
        ],
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: _broadcasting ? null : _broadcastTx,
          icon: const Icon(Icons.send),
          label: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 20),
            child: _broadcasting
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(s.broadcastBtn),
          ),
        ),
      ],
    );
  }

  Widget _buildSubmittedStep(dynamic s) {
    final hash = _txHash ?? '';
    final explorerUrl = widget.appState.network.explorerTxUrl(hash);
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          _confirmed ? Icons.check_circle : Icons.hourglass_top,
          size: 72,
          color: _confirmed ? HotTheme.success : HotTheme.warning,
        ),
        const SizedBox(height: 14),
        Text(
          s.txSubmittedTitle,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 10),
        SelectableText(
          hash,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 10),
        Text(
          _confirmed ? s.confirmStatusConfirmed : s.confirmStatusWaiting,
          style: TextStyle(
            color: _confirmed ? HotTheme.success : HotTheme.warning,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 12),
        ExternalLinkText(
          url: explorerUrl,
          fontSize: 12,
        ),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: () => Navigator.of(context).popUntil((r) => r.isFirst),
          child: Text(s.close),
        ),
      ],
    );
  }
}
