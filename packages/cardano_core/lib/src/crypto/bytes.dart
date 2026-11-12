import 'dart:typed_data';

/// Overwrites all bytes in [buffer] with zeros to minimize sensitive data lifetime in RAM.
void zeroize(Uint8List? buffer) {
  if (buffer == null) return;
  buffer.fillRange(0, buffer.length, 0);
}

/// Overwrites all buffers in [buffers] with zeros.
void zeroizeAll(Iterable<Uint8List?> buffers) {
  for (final buffer in buffers) {
    zeroize(buffer);
  }
}

/// Constant-time comparison of two byte buffers of equal or different lengths.
bool constantTimeEquals(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// Lexicographical comparison of two byte arrays (used in canonical CBOR map sorting).
int compareBytes(Uint8List a, Uint8List b) {
  final minLen = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < minLen; i++) {
    if (a[i] != b[i]) {
      return a[i].compareTo(b[i]);
    }
  }
  return a.length.compareTo(b.length);
}

/// Encodes [bytes] into lowercase hexadecimal string.
String hexEncode(List<int> bytes) {
  const digits = '0123456789abcdef';
  final sb = StringBuffer();
  for (final b in bytes) {
    sb.write(digits[(b >> 4) & 0x0f]);
    sb.write(digits[b & 0x0f]);
  }
  return sb.toString();
}

/// Decodes a hexadecimal string (with optional `0x` prefix) into [Uint8List].
Uint8List hexDecode(String hex) {
  var clean = hex.trim();
  if (clean.startsWith('0x') || clean.startsWith('0X')) {
    clean = clean.substring(2);
  }
  if (clean.length.isOdd) {
    throw FormatException('Invalid hex string length: ${clean.length}');
  }
  final out = Uint8List(clean.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    final hi = _hexVal(clean.codeUnitAt(i * 2));
    final lo = _hexVal(clean.codeUnitAt(i * 2 + 1));
    out[i] = (hi << 4) | lo;
  }
  return out;
}

int _hexVal(int unit) {
  if (unit >= 48 && unit <= 57) return unit - 48;
  if (unit >= 65 && unit <= 70) return unit - 55;
  if (unit >= 97 && unit <= 102) return unit - 87;
  throw FormatException('Invalid hex character code: $unit');
}

/// Concatenates multiple byte lists into a single [Uint8List].
Uint8List concatBytes(List<List<int>> parts) {
  var total = 0;
  for (final p in parts) {
    total += p.length;
  }
  final out = Uint8List(total);
  var offset = 0;
  for (final p in parts) {
    out.setRange(offset, offset + p.length, p);
    offset += p.length;
  }
  return out;
}

/// Encodes an unsigned 32-bit integer in little-endian order.
Uint8List uint32ToLe(int value) {
  final out = Uint8List(4);
  out[0] = value & 0xff;
  out[1] = (value >> 8) & 0xff;
  out[2] = (value >> 16) & 0xff;
  out[3] = (value >> 24) & 0xff;
  return out;
}

/// Encodes an unsigned 32-bit integer in big-endian order.
Uint8List uint32ToBe(int value) {
  final out = Uint8List(4);
  out[0] = (value >> 24) & 0xff;
  out[1] = (value >> 16) & 0xff;
  out[2] = (value >> 8) & 0xff;
  out[3] = value & 0xff;
  return out;
}
