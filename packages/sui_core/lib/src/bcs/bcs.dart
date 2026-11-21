import 'dart:convert';
import 'dart:typed_data';

/// Pure Dart Binary Canonical Serialization (BCS) encoder and decoder.
///
/// Implements the Diem/Move/Sui BCS specification:
/// - Little-endian representation for fixed-size integers.
/// - ULEB128 for sequence lengths and enum variants.
/// - Canonical byte sequences.
class BcsWriter {
  final BytesBuilder _builder = BytesBuilder();

  BcsWriter();

  /// Writes a single unsigned 8-bit integer.
  void writeU8(int value) {
    if (value < 0 || value > 0xff) {
      throw RangeError.value(value, 'value', 'Giá trị u8 phải từ 0 đến 255');
    }
    _builder.addByte(value);
  }

  /// Writes a boolean (0x00 for false, 0x01 for true).
  void writeBool(bool value) {
    _builder.addByte(value ? 1 : 0);
  }

  /// Writes a little-endian unsigned 16-bit integer.
  void writeU16(int value) {
    if (value < 0 || value > 0xffff) {
      throw RangeError.value(value, 'value', 'Giá trị u16 phải từ 0 đến 65535');
    }
    _builder.addByte(value & 0xff);
    _builder.addByte((value >> 8) & 0xff);
  }

  /// Writes a little-endian unsigned 32-bit integer.
  void writeU32(int value) {
    if (value < 0 || value > 0xffffffff) {
      throw RangeError.value(value, 'value', 'Giá trị u32 vượt giới hạn');
    }
    _builder.addByte(value & 0xff);
    _builder.addByte((value >> 8) & 0xff);
    _builder.addByte((value >> 16) & 0xff);
    _builder.addByte((value >> 24) & 0xff);
  }

  /// Writes a little-endian unsigned 64-bit integer from [BigInt] or [int].
  void writeU64(dynamic value) {
    final BigInt v;
    if (value is int) {
      v = BigInt.from(value);
    } else if (value is BigInt) {
      v = value;
    } else {
      throw ArgumentError('Giá trị u64 phải là int hoặc BigInt');
    }
    if (v < BigInt.zero || v > BigInt.parse('18446744073709551615')) {
      throw RangeError('Giá trị u64 vượt giới hạn: $v');
    }
    for (int i = 0; i < 8; i++) {
      _builder.addByte(((v >> (i * 8)) & BigInt.from(0xff)).toInt());
    }
  }

  /// Writes a little-endian unsigned 128-bit integer.
  void writeU128(BigInt v) {
    if (v < BigInt.zero) throw RangeError('u128 không âm: $v');
    for (int i = 0; i < 16; i++) {
      _builder.addByte(((v >> (i * 8)) & BigInt.from(0xff)).toInt());
    }
  }

  /// Writes a little-endian unsigned 256-bit integer.
  void writeU256(BigInt v) {
    if (v < BigInt.zero) throw RangeError('u256 không âm: $v');
    for (int i = 0; i < 32; i++) {
      _builder.addByte(((v >> (i * 8)) & BigInt.from(0xff)).toInt());
    }
  }

  /// Writes an unsigned variable-length integer (ULEB128).
  void writeUleb128(int value) {
    if (value < 0) {
      throw ArgumentError('ULEB128 không hỗ trợ số âm: $value');
    }
    int v = value;
    while (v >= 0x80) {
      _builder.addByte((v & 0x7f) | 0x80);
      v >>= 7;
    }
    _builder.addByte(v & 0x7f);
  }

  /// Writes raw fixed-size bytes without length prefix.
  void writeFixedBytes(Uint8List bytes) {
    _builder.add(bytes);
  }

  /// Writes a byte sequence with ULEB128 length prefix (vector<u8>).
  void writeBytes(Uint8List bytes) {
    writeUleb128(bytes.length);
    _builder.add(bytes);
  }

  /// Writes a UTF-8 string with ULEB128 byte length prefix.
  void writeString(String str) {
    final bytes = utf8.encode(str);
    writeUleb128(bytes.length);
    _builder.add(bytes);
  }

  /// Writes an address / objectId (32 bytes fixed).
  void writeAddress(String hexAddress) {
    String clean = hexAddress.trim();
    if (clean.startsWith('0x') || clean.startsWith('0X')) {
      clean = clean.substring(2);
    }
    if (clean.length > 64) {
      throw ArgumentError('Địa chỉ Sui quá dài (> 32 bytes): $hexAddress');
    }
    clean = clean.padLeft(64, '0');
    final bytes = Uint8List(32);
    for (int i = 0; i < 32; i++) {
      bytes[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
    }
    writeFixedBytes(bytes);
  }

  /// Returns the complete serialized bytes.
  Uint8List toBytes() {
    return _builder.toBytes();
  }
}

/// Pure Dart Binary Canonical Serialization (BCS) decoder.
class BcsReader {
  final Uint8List _data;
  int _offset = 0;

  BcsReader(this._data);

  int get offset => _offset;
  int get remaining => _data.length - _offset;

  int readU8() {
    if (_offset >= _data.length) throw RangeError('Đã hết dữ liệu đọc u8');
    return _data[_offset++];
  }

  bool readBool() {
    final b = readU8();
    if (b == 0) return false;
    if (b == 1) return true;
    throw FormatException('Giá trị bool BCS không hợp lệ: $b');
  }

  int readU16() {
    if (_offset + 2 > _data.length) throw RangeError('Hết dữ liệu đọc u16');
    final val = _data[_offset] | (_data[_offset + 1] << 8);
    _offset += 2;
    return val;
  }

  int readU32() {
    if (_offset + 4 > _data.length) throw RangeError('Hết dữ liệu đọc u32');
    final val = _data[_offset] |
        (_data[_offset + 1] << 8) |
        (_data[_offset + 2] << 16) |
        (_data[_offset + 3] << 24);
    _offset += 4;
    return val;
  }

  BigInt readU64() {
    if (_offset + 8 > _data.length) throw RangeError('Hết dữ liệu đọc u64');
    BigInt val = BigInt.zero;
    for (int i = 0; i < 8; i++) {
      val |= BigInt.from(_data[_offset + i]) << (i * 8);
    }
    _offset += 8;
    return val;
  }

  int readUleb128() {
    int result = 0;
    int shift = 0;
    while (true) {
      if (_offset >= _data.length) {
        throw RangeError('Hết dữ liệu khi đọc ULEB128');
      }
      final byte = _data[_offset++];
      result |= (byte & 0x7f) << shift;
      if ((byte & 0x80) == 0) break;
      shift += 7;
      if (shift >= 35) {
        throw FormatException('Tràn ULEB128 (shift >= 35)');
      }
    }
    return result;
  }

  Uint8List readFixedBytes(int length) {
    if (_offset + length > _data.length) {
      throw RangeError('Hết dữ liệu đọc $length fixed bytes');
    }
    final sub = Uint8List.sublistView(_data, _offset, _offset + length);
    _offset += length;
    return Uint8List.fromList(sub);
  }

  Uint8List readBytes() {
    final len = readUleb128();
    return readFixedBytes(len);
  }

  String readString() {
    final bytes = readBytes();
    return utf8.decode(bytes);
  }

  String readAddress() {
    final bytes = readFixedBytes(32);
    final sb = StringBuffer('0x');
    for (final b in bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }
}
