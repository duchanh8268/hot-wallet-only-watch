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
}
