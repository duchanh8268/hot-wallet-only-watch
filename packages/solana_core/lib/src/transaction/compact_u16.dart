import 'dart:typed_data';

/// Encodes and decodes Solana's Compact-u16 length prefix.
class CompactU16 {
  const CompactU16._();

  /// Encodes [value] into compact-u16 bytes.
  static Uint8List encode(int value) {
    if (value < 0) throw ArgumentError('value must be non-negative');
    final out = <int>[];
    var rem = value;
    while (true) {
      var elem = rem & 0x7f;
      rem >>= 7;
      if (rem == 0) {
        out.add(elem);
        break;
      } else {
        elem |= 0x80;
        out.add(elem);
      }
    }
    return Uint8List.fromList(out);
  }

  /// Decodes a compact-u16 value from [bytes] at [offset].
  /// Returns a record with `(value, bytesRead)`.
  static (int value, int bytesRead) decode(Uint8List bytes, {int offset = 0}) {
    if (offset < 0 || offset >= bytes.length) {
      throw const FormatException('CompactU16 offset out of bounds');
    }
    var value = 0;
    var size = 0;
    for (var i = offset; i < bytes.length; i++) {
      if (size >= 3) {
        throw const FormatException('CompactU16 exceeds maximum 3 bytes');
      }
      final elem = bytes[i];
      if (size == 2 && (elem & 0x80) != 0) {
        throw const FormatException('CompactU16 3rd byte cannot have continuation bit');
      }
      value |= (elem & 0x7f) << (size * 7);
      size++;
      if ((elem & 0x80) == 0) {
        if (size > 1 && elem == 0) {
          throw const FormatException('Non-canonical CompactU16 encoding');
        }
        if (value > 0xffff) {
          throw FormatException('CompactU16 exceeds uint16 range: $value');
        }
        return (value, size);
      }
    }
    throw const FormatException('Truncated CompactU16 encoding');
  }
}
