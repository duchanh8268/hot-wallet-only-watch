import 'dart:async';
import 'package:flutter/material.dart';

/// Non-web / widget-test stub for Web Webcam QR scanner.
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
  StreamSubscription<String>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = widget.testScanStream?.listen((code) {
      if (mounted) widget.onCodeScanned(code);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.videocam_off, size: 56, color: Colors.white38),
          const SizedBox(height: 8),
          Text(
            widget.unavailableMessage ?? 'Webcam QR Scanner (Web Runtime)',
            style: const TextStyle(color: Colors.white70, fontSize: 12),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
