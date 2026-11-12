import 'dart:typed_data';

import '../crypto/bytes.dart';
import 'bytewords_table.dart';
import 'crc32.dart';

export 'bytewords_table.dart' show bytewordsTable;

enum BytewordsStyle { standard, uri, minimal }

/// Blockchain Commons Bytewords encoder/decoder with CRC-32 verification (BCR-2020-012).
class Bytewords {
  static final List<String> _minimalTable = [
    for (final w in bytewordsTable) '${w[0]}${w[3]}',
  ];

  static final Map<String, int> _wordToByte = {
    for (var i = 0; i < bytewordsTable.length; i++) bytewordsTable[i]: i,
  };

  static final Map<String, int> _minimalToByte = {
    for (var i = 0; i < _minimalTable.length; i++) _minimalTable[i]: i,
  };

  /// Encodes [payload] (appending 4-byte CRC-32) using [style].
  static String encode(
    Uint8List payload, {
    BytewordsStyle style = BytewordsStyle.minimal,
  }) {
    final withCrc = concatBytes([payload, Crc32.computeBytes(payload)]);
    switch (style) {
      case BytewordsStyle.standard:
        return [for (final b in withCrc) bytewordsTable[b]].join(' ');
      case BytewordsStyle.uri:
        return [for (final b in withCrc) bytewordsTable[b]].join('-');
      case BytewordsStyle.minimal:
        final sb = StringBuffer();
        for (final b in withCrc) {
          sb.write(_minimalTable[b]);
        }
        return sb.toString();
    }
  }

  /// Decodes Bytewords string of [style] and verifies trailing 4-byte CRC-32.
  static Uint8List decode(
    String encoded, {
    BytewordsStyle style = BytewordsStyle.minimal,
  }) {
    final clean = encoded.trim().toLowerCase();
    final List<int> decodedBytes;

    switch (style) {
      case BytewordsStyle.standard:
        final words = clean.split(RegExp(r'\s+'));
        decodedBytes = [
          for (final w in words)
            _wordToByte[w] ?? (throw FormatException('Invalid Byteword: $w')),
        ];
      case BytewordsStyle.uri:
        final words = clean.split('-');
        decodedBytes = [
          for (final w in words)
            _wordToByte[w] ?? (throw FormatException('Invalid Byteword: $w')),
        ];
      case BytewordsStyle.minimal:
        if (clean.length.isOdd) {
          throw const FormatException('Minimal Bytewords length must be even');
        }
        decodedBytes = <int>[];
        for (var i = 0; i < clean.length; i += 2) {
          final pair = clean.substring(i, i + 2);
          final b = _minimalToByte[pair];
          if (b == null) {
            throw FormatException('Invalid minimal Bytewords pair: $pair');
          }
          decodedBytes.add(b);
        }
    }

    if (decodedBytes.length < 4) {
      throw const FormatException('Bytewords payload too short for CRC-32');
    }

    final raw = Uint8List.fromList(decodedBytes);
    final payload = Uint8List.sublistView(raw, 0, raw.length - 4);
    final actualCrc = Uint8List.sublistView(raw, raw.length - 4);
    final expectedCrc = Crc32.computeBytes(payload);
    if (!constantTimeEquals(actualCrc, expectedCrc)) {
      throw const FormatException('Bytewords CRC-32 checksum mismatch');
    }

    return Uint8List.fromList(payload);
  }
}
