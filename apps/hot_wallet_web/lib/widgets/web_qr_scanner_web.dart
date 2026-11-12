import 'dart:async';
import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

@JS('CardanoWebQrScanner')
external _JsQrScanner? get _jsScanner;

extension type _JsQrScanner(JSObject _) implements JSObject {
  external JSPromise<_JsScannerHandle> startCameraScanner(
    web.HTMLElement containerEl,
    JSFunction onQrFound,
    JSFunction onError,
  );
}

extension type _JsScannerHandle(JSObject _) implements JSObject {
  external void stop();
}

/// Production Web Webcam QR Scanner via `getUserMedia` + `BarcodeDetector` / `jsQR`.
class WebQrScanner extends StatefulWidget {
  final ValueChanged<String> onCodeScanned;
  final Stream<String>? testScanStream;
  final String? unavailableMessage;

  const WebQrScanner({
    super.key,
    required this.onCodeScanned,
    this.testScanStream,
    this.unavailableMessage,
  });

  @override
  State<WebQrScanner> createState() => _WebQrScannerState();
}

class _WebQrScannerState extends State<WebQrScanner> {
  static int _viewCounter = 0;
  late final String _viewType;
  _JsScannerHandle? _handle;
  StreamSubscription<String>? _testSub;
  String? _errorText;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _viewCounter++;
    _viewType = 'cardano-web-qr-scanner-$_viewCounter';

    if (widget.testScanStream != null) {
      _testSub = widget.testScanStream!.listen((code) {
        if (mounted) widget.onCodeScanned(code);
      });
      return;
    }

    ui_web.platformViewRegistry.registerViewFactory(_viewType, (int viewId) {
      final div = web.document.createElement('div') as web.HTMLDivElement;
      div.style.width = '100%';
      div.style.height = '100%';
      div.style.backgroundColor = '#000000';
      div.style.position = 'relative';
      _startScanner(div);
      return div;
    });
  }

  Future<void> _startScanner(web.HTMLElement container) async {
    final js = _jsScanner;
    if (js == null) {
      if (mounted) setState(() => _errorText = 'QR scanner JS bridge not loaded');
      return;
    }

    final onFound = ((JSString raw) {
      if (!_disposed && mounted) {
        widget.onCodeScanned(raw.toDart);
      }
    }).toJS;

    final onErr = ((JSString err) {
      if (!_disposed && mounted) {
        setState(() => _errorText = err.toDart);
      }
    }).toJS;

    try {
      final handle = await js.startCameraScanner(container, onFound, onErr).toDart;
      if (_disposed) {
        handle.stop();
      } else {
        _handle = handle;
      }
    } catch (e) {
      if (!_disposed && mounted) {
        setState(() => _errorText = e.toString());
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _testSub?.cancel();
    _handle?.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.testScanStream != null) {
      return Container(
        color: Colors.black,
        alignment: Alignment.center,
        child: const Icon(Icons.qr_code_scanner, size: 64, color: Colors.white38),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        HtmlElementView(viewType: _viewType),
        Center(
          child: Container(
            width: 230,
            height: 230,
            decoration: BoxDecoration(
              border: Border.all(color: const Color(0xFF38BDF8), width: 2.5),
              borderRadius: BorderRadius.circular(16),
            ),
          ),
        ),
        if (_errorText != null)
          Positioned(
            bottom: 12,
            left: 12,
            right: 12,
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.red.shade900.withValues(alpha: 0.9),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _errorText!,
                style: const TextStyle(color: Colors.white, fontSize: 12),
                textAlign: TextAlign.center,
              ),
            ),
          ),
      ],
    );
  }
}
