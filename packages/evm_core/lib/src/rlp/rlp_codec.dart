import 'dart:typed_data';
import '../crypto/bytes_utils.dart';

/// Pure Dart Recursive Length Prefix (RLP) encoder and decoder per Ethereum Yellow Paper.
class Rlp {
  const Rlp._();

  /// Encodes any RLP item: [Uint8List] (byte array), [int], [BigInt], [String] (utf8), or [List] of items.
  static Uint8List encode(dynamic item) {
    if (item is List<int>) {
      return encodeBytes(Uint8List.fromList(item));
    } else if (item is int) {
      return encodeBigInt(BigInt.from(item));
    } else if (item is BigInt) {
      return encodeBigInt(item);
    } else if (item is String) {
      if (item.startsWith('0x') || item.startsWith('0X')) {
        return encodeBytes(hexDecode(item));
      }
      return encodeBytes(Uint8List.fromList(item.codeUnits));
    } else if (item is List) {
      return encodeList(item);
    } else {
      throw ArgumentError('Unsupported RLP item type: ${item.runtimeType}');
    }
  }

  /// Encodes a byte array into RLP.
  static Uint8List encodeBytes(Uint8List bytes) {
    if (bytes.length == 1 && bytes[0] < 0x80) {
      return bytes;
    }
    if (bytes.length <= 55) {
      final header = Uint8List.fromList([0x80 + bytes.length]);
      return concatBytes([header, bytes]);
    }
    final lenBytes = _toMinimalBigEndian(BigInt.from(bytes.length));
    final header = concatBytes([
      Uint8List.fromList([0xb7 + lenBytes.length]),
      lenBytes,
    ]);
    return concatBytes([header, bytes]);
  }

  /// Encodes a positive [BigInt] into RLP. Zero is encoded as empty byte array (0x80).
  static Uint8List encodeBigInt(BigInt value) {
    if (value < BigInt.zero) {
      throw ArgumentError('RLP only encodes non-negative integers');
    }
    if (value == BigInt.zero) {
      return Uint8List.fromList([0x80]);
    }
    return encodeBytes(_toMinimalBigEndian(value));
  }

  /// Encodes a list of RLP-encodable items into an RLP list.
  static Uint8List encodeList(List<dynamic> items) {
    final encodedItems = items.map(encode).toList();
    final totalLen = encodedItems.fold<int>(0, (sum, b) => sum + b.length);

    if (totalLen <= 55) {
      final header = Uint8List.fromList([0xc0 + totalLen]);
      return concatBytes([header, ...encodedItems]);
    }
    final lenBytes = _toMinimalBigEndian(BigInt.from(totalLen));
    final header = concatBytes([
      Uint8List.fromList([0xf7 + lenBytes.length]),
      lenBytes,
    ]);
    return concatBytes([header, ...encodedItems]);
  }

  static Uint8List _toMinimalBigEndian(BigInt value) {
    if (value == BigInt.zero) return Uint8List(0);
    var v = value;
    final bytes = <int>[];
    while (v > BigInt.zero) {
      bytes.add((v & BigInt.from(0xff)).toInt());
      v = v >> 8;
    }
    return Uint8List.fromList(bytes.reversed.toList());
  }

  /// Strictly decodes canonical RLP [bytes] into nested [Uint8List] and [List<dynamic>] items.
  /// Rejects non-canonical lengths, leading-zero length prefixes, excessive nesting, and trailing bytes.
  static dynamic decode(Uint8List bytes, {int maxDepth = 32}) {
    if (bytes.isEmpty) {
      throw const FormatException('Empty RLP input');
    }
    final (item, nextOffset) = _decodeAt(bytes, 0, 0, maxDepth);
    if (nextOffset != bytes.length) {
      throw FormatException(
        'Trailing bytes after RLP item: consumed $nextOffset of ${bytes.length}',
      );
    }
    return item;
  }

  /// Decodes a canonical RLP scalar byte array into a non-negative [BigInt].
  /// Rejects leading zero bytes (e.g., 0x00 for zero or 0x0001 for 1).
  static BigInt decodeBigInt(Uint8List bytes) {
    if (bytes.isEmpty) return BigInt.zero;
    if (bytes[0] == 0) {
      throw const FormatException('Non-canonical RLP integer with leading zero byte');
    }
    var result = BigInt.zero;
    for (final b in bytes) {
      result = (result << 8) | BigInt.from(b);
    }
    return result;
  }

  static (dynamic, int) _decodeAt(
    Uint8List bytes,
    int offset,
    int depth,
    int maxDepth,
  ) {
    if (depth > maxDepth) {
      throw const FormatException('RLP max nesting depth exceeded');
    }
    if (offset >= bytes.length) {
      throw const FormatException('Unexpected end of RLP input');
    }

    final prefix = bytes[offset];

    // 1. Single byte [0x00, 0x7f]
    if (prefix <= 0x7f) {
      return (Uint8List.fromList([prefix]), offset + 1);
    }

    // 2. Short string [0x80, 0xb7]
    if (prefix <= 0xb7) {
      final len = prefix - 0x80;
      final start = offset + 1;
      final end = start + len;
      if (end > bytes.length) {
        throw const FormatException('RLP short string exceeds buffer');
      }
      if (len == 1 && bytes[start] < 0x80) {
        throw const FormatException('Non-canonical single-byte RLP string');
      }
      return (Uint8List.fromList(bytes.sublist(start, end)), end);
    }

    // 3. Long string [0xb8, 0xbf]
    if (prefix <= 0xbf) {
      final lenBytesCount = prefix - 0xb7;
      final lenStart = offset + 1;
      final lenEnd = lenStart + lenBytesCount;
      if (lenEnd > bytes.length) {
        throw const FormatException('RLP long string length exceeds buffer');
      }
      final len = _readCanonicalLength(bytes, lenStart, lenBytesCount);
      if (len <= 55) {
        throw const FormatException('Non-canonical RLP long string length <= 55');
      }
      final end = lenEnd + len;
      if (end > bytes.length || len > bytes.length - lenEnd) {
        throw const FormatException('RLP long string payload exceeds buffer');
      }
      return (Uint8List.fromList(bytes.sublist(lenEnd, end)), end);
    }

    // 4. Short list [0xc0, 0xf7]
    if (prefix <= 0xf7) {
      final len = prefix - 0xc0;
      final start = offset + 1;
      final end = start + len;
      if (end > bytes.length) {
        throw const FormatException('RLP short list exceeds buffer');
      }
      return (_decodeListRange(bytes, start, end, depth + 1, maxDepth), end);
    }

    // 5. Long list [0xf8, 0xff]
    final lenBytesCount = prefix - 0xf7;
    final lenStart = offset + 1;
    final lenEnd = lenStart + lenBytesCount;
    if (lenEnd > bytes.length) {
      throw const FormatException('RLP long list length exceeds buffer');
    }
    final len = _readCanonicalLength(bytes, lenStart, lenBytesCount);
    if (len <= 55) {
      throw const FormatException('Non-canonical RLP long list length <= 55');
    }
    final end = lenEnd + len;
    if (end > bytes.length || len > bytes.length - lenEnd) {
      throw const FormatException('RLP long list payload exceeds buffer');
    }
    return (_decodeListRange(bytes, lenEnd, end, depth + 1, maxDepth), end);
  }

  static List<dynamic> _decodeListRange(
    Uint8List bytes,
    int start,
    int end,
    int depth,
    int maxDepth,
  ) {
    final items = <dynamic>[];
    var cursor = start;
    while (cursor < end) {
      final (item, next) = _decodeAt(bytes, cursor, depth, maxDepth);
      if (next > end) {
        throw const FormatException('RLP list item exceeds enclosing list boundary');
      }
      items.add(item);
      cursor = next;
    }
    if (cursor != end) {
      throw const FormatException('RLP list length mismatch');
    }
    return items;
  }

  static int _readCanonicalLength(Uint8List bytes, int start, int count) {
    if (count <= 0 || count > 4) {
      throw FormatException('Unsupported RLP length byte count: $count');
    }
    if (bytes[start] == 0) {
      throw const FormatException('Non-canonical RLP length with leading zero byte');
    }
    var len = 0;
    for (var i = 0; i < count; i++) {
      len = (len << 8) | bytes[start + i];
    }
    if (len < 0) {
      throw const FormatException('RLP length overflow');
    }
    return len;
  }
}
