import 'dart:typed_data';

/// Pure Dart Base58 codec using the Bitcoin / Solana alphabet.
class Base58 {
  static const String alphabet =
      '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';

  static final Map<int, int> _alphabetMap = () {
    final map = <int, int>{};
    for (var i = 0; i < alphabet.length; i++) {
      map[alphabet.codeUnitAt(i)] = i;
    }
    return map;
  }();

  const Base58._();

  /// Encodes raw [bytes] into a Base58 string.
  static String encode(Uint8List bytes) {
    if (bytes.isEmpty) return '';

    // Count leading zeros
    var leadingZeros = 0;
    while (leadingZeros < bytes.length && bytes[leadingZeros] == 0) {
      leadingZeros++;
    }

    // Convert bytes to BigInt (Big-endian)
    var value = BigInt.zero;
    for (var i = leadingZeros; i < bytes.length; i++) {
      value = (value << 8) | BigInt.from(bytes[i]);
    }

    final chars = <String>[];
    final radix = BigInt.from(58);
    while (value > BigInt.zero) {
      final mod = (value % radix).toInt();
      value ~/= radix;
      chars.add(alphabet[mod]);
    }

    final sb = StringBuffer();
    for (var i = 0; i < leadingZeros; i++) {
      sb.write('1');
    }
    for (var i = chars.length - 1; i >= 0; i--) {
      sb.write(chars[i]);
    }
    return sb.toString();
  }

  /// Decodes a Base58 [input] string into raw bytes.
  static Uint8List decode(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return Uint8List(0);

    // Count leading '1's
    var leadingZeros = 0;
    while (leadingZeros < trimmed.length && trimmed[leadingZeros] == '1') {
      leadingZeros++;
    }

    var value = BigInt.zero;
    final radix = BigInt.from(58);
    for (var i = leadingZeros; i < trimmed.length; i++) {
      final code = trimmed.codeUnitAt(i);
      final digit = _alphabetMap[code];
      if (digit == null) {
        throw FormatException('Ký tự Base58 không hợp lệ: "${trimmed[i]}"');
      }
      value = value * radix + BigInt.from(digit);
    }

    // Convert BigInt to big-endian bytes
    final byteList = <int>[];
    while (value > BigInt.zero) {
      byteList.add((value & BigInt.from(0xff)).toInt());
      value >>= 8;
    }

    final result = Uint8List(leadingZeros + byteList.length);
    for (var i = 0; i < leadingZeros; i++) {
      result[i] = 0;
    }
    for (var i = 0; i < byteList.length; i++) {
      result[leadingZeros + i] = byteList[byteList.length - 1 - i];
    }
    return result;
  }
}
