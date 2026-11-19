import 'dart:typed_data';

import 'bytewords.dart';
import 'fountain.dart';

/// Encodes binary payloads into single-part or multi-part BC-UR strings (`ur:<type>/...`).
class UrEncoder {
  final String type;
  final Uint8List cborPayload;
  final FountainEncoder _fountain;

  UrEncoder({
    required String type,
    required this.cborPayload,
    int maxFragmentLen = 90,
    int minFragmentLen = 10,
  })  : type = type.toLowerCase(),
        _fountain = FountainEncoder(
          cborPayload,
          maxFragmentLen: maxFragmentLen,
          minFragmentLen: minFragmentLen,
        );

  bool get isSinglePart => _fountain.isSinglePart;
  int get seqLen => _fountain.seqLen;

  /// Encodes as a single-part UR if payload fits, or returns the next fountain part UR.
  /// Output is uppercase for compact QR Alphanumeric mode.
  String nextPart({bool uppercase = true}) {
    final String raw;
    if (_fountain.isSinglePart) {
      final body = Bytewords.encode(cborPayload, style: BytewordsStyle.minimal);
      raw = 'ur:$type/$body';
    } else {
      final part = _fountain.nextPart();
      final body = Bytewords.encode(
        part.toCborBytes(),
        style: BytewordsStyle.minimal,
      );
      raw = 'ur:$type/${part.seqNum}-${part.seqLen}/$body';
    }
    return uppercase ? raw.toUpperCase() : raw;
  }

  /// Convenience helper for payloads guaranteed to fit in a single QR frame.
  static String encodeSingle(
    String type,
    Uint8List cborPayload, {
    bool uppercase = true,
  }) {
    final body = Bytewords.encode(cborPayload, style: BytewordsStyle.minimal);
    final raw = 'ur:${type.toLowerCase()}/$body';
    return uppercase ? raw.toUpperCase() : raw;
  }
}

/// Decoded complete BC-UR message.
class UrResult {
  final String type;
  final Uint8List cborPayload;

  const UrResult(this.type, this.cborPayload);
}

/// Stateful BC-UR decoder accepting single-part or streaming multi-part QR frames.
class UrDecoder {
  String? _expectedType;
  final FountainDecoder _fountain = FountainDecoder();
  UrResult? _result;

  bool get isComplete => _result != null;
  UrResult? get result => _result;
  String? get expectedType => _expectedType;
  int? get expectedPartCount => _fountain.expectedPartCount;
  int get receivedPartCount => _fountain.receivedPartCount;
  double get estimatedProgress => _result != null ? 1.0 : _fountain.estimatedProgress;

  /// Feeds one scanned QR string (case-insensitive) into the decoder.
  /// Returns true if the frame was valid BC-UR and accepted.
  bool receivePart(String urString) {
    if (_result != null) return true;

    final trimmed = urString.trim().toLowerCase();
    if (!trimmed.startsWith('ur:')) {
      return false;
    }

    final withoutScheme = trimmed.substring(3);
    final segments = withoutScheme.split('/');
    if (segments.length != 2 && segments.length != 3) {
      return false;
    }

    final type = segments[0];
    if (!_isValidType(type)) return false;

    if (_expectedType == null) {
      _expectedType = type;
    } else if (_expectedType != type) {
      return false;
    }

    try {
      if (segments.length == 2) {
        // Single-part UR
        final payload = Bytewords.decode(
          segments[1],
          style: BytewordsStyle.minimal,
        );
        _result = UrResult(type, payload);
        return true;
      } else {
        // Multi-part UR: ur:<type>/<seq>-<seqLen>/<body_bytewords>
        final seqPieces = segments[1].split('-');
        if (seqPieces.length != 2) return false;
        final seqNum = int.tryParse(seqPieces[0]);
        final seqLen = int.tryParse(seqPieces[1]);
        if (seqNum == null || seqLen == null || seqNum <= 0 || seqLen <= 0) {
          return false;
        }

        final partBytes = Bytewords.decode(
          segments[2],
          style: BytewordsStyle.minimal,
        );
        final part = FountainPart.fromCborBytes(partBytes);
        if (part.seqNum != seqNum || part.seqLen != seqLen) {
          return false;
        }

        final ok = _fountain.receivePart(part);
        if (ok && _fountain.isComplete) {
          _result = UrResult(type, _fountain.result!);
        }
        return ok;
      }
    } catch (_) {
      return false;
    }
  }

  /// Convenience helper for decoding a single-part UR immediately.
  static UrResult decodeSingle(String urString) {
    final decoder = UrDecoder();
    if (!decoder.receivePart(urString) || !decoder.isComplete) {
      throw const FormatException('Not a valid single-part BC-UR string');
    }
    return decoder.result!;
  }

  static bool _isValidType(String type) {
    if (type.isEmpty) return false;
    return RegExp(r'^[a-z0-9-]+$').hasMatch(type);
  }
}
