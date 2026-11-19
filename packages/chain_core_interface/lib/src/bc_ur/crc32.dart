import 'dart:typed_data';

/// Standard IEEE 802.3 CRC-32 checksum used by BC-UR and Bytewords.
class Crc32 {
  static final Uint32List _table = _buildTable();

  static Uint32List _buildTable() {
    final table = Uint32List(256);
    for (var i = 0; i < 256; i++) {
      var c = i;
      for (var k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? (0xedb88320 ^ (c >>> 1)) : (c >>> 1);
      }
      table[i] = c;
    }
    return table;
  }

  /// Computes the 32-bit unsigned CRC-32 checksum of [data].
  static int compute(Uint8List data) {
    var crc = 0xffffffff;
    for (var i = 0; i < data.length; i++) {
      crc = _table[(crc ^ data[i]) & 0xff] ^ (crc >>> 8);
    }
    return (crc ^ 0xffffffff) & 0xffffffff;
  }

  /// Returns 4-byte big-endian CRC-32 digest of [data].
  static Uint8List computeBytes(Uint8List data) {
    final crc = compute(data);
    return Uint8List.fromList([
      (crc >> 24) & 0xff,
      (crc >> 16) & 0xff,
      (crc >> 8) & 0xff,
      crc & 0xff,
    ]);
  }
}
