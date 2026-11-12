import 'dart:convert';
import 'dart:typed_data';

import '../crypto/bytes.dart';

/// Base class for deterministic RFC 8949 CBOR values.
sealed class CborValue {
  const CborValue();

  Uint8List encode() {
    final builder = BytesBuilder(copy: false);
    writeTo(builder);
    return builder.toBytes();
  }

  void writeTo(BytesBuilder out);

  static CborValue decode(Uint8List bytes) {
    final reader = _CborReader(bytes);
    final val = reader.readValue();
    if (!reader.isAtEnd) {
      throw FormatException(
        'Trailing ${bytes.length - reader.offset} bytes after CBOR root value',
      );
    }
    return val;
  }
}

class CborInt extends CborValue {
  final BigInt value;

  const CborInt(this.value);

  factory CborInt.fromInt(int v) => CborInt(BigInt.from(v));

  int toInt() => value.toInt();

  @override
  void writeTo(BytesBuilder out) {
    if (value >= BigInt.zero) {
      _writeBigUintHeader(out, 0, value);
    } else {
      final mag = -value - BigInt.one;
      _writeBigUintHeader(out, 1, mag);
    }
  }

  @override
  bool operator ==(Object other) => other is CborInt && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'CborInt($value)';
}

class CborBytes extends CborValue {
  final Uint8List bytes;

  CborBytes(Uint8List bytes) : bytes = Uint8List.fromList(bytes);

  @override
  void writeTo(BytesBuilder out) {
    _writeUintHeader(out, 2, bytes.length);
    out.add(bytes);
  }

  @override
  bool operator ==(Object other) =>
      other is CborBytes && constantTimeEquals(other.bytes, bytes);

  @override
  int get hashCode => Object.hashAll(bytes);

  @override
  String toString() => 'CborBytes(${bytes.length}B)';
}

class CborText extends CborValue {
  final String text;

  const CborText(this.text);

  @override
  void writeTo(BytesBuilder out) {
    final utf8Bytes = utf8.encode(text);
    _writeUintHeader(out, 3, utf8Bytes.length);
    out.add(utf8Bytes);
  }

  @override
  bool operator ==(Object other) => other is CborText && other.text == text;

  @override
  int get hashCode => text.hashCode;

  @override
  String toString() => 'CborText("$text")';
}

class CborArray extends CborValue {
  final List<CborValue> items;
  final bool indefinite;

  const CborArray(this.items, {this.indefinite = false});

  @override
  void writeTo(BytesBuilder out) {
    if (indefinite) {
      out.addByte((4 << 5) | 31);
      for (final item in items) {
        item.writeTo(out);
      }
      out.addByte(0xff);
    } else {
      _writeUintHeader(out, 4, items.length);
      for (final item in items) {
        item.writeTo(out);
      }
    }
  }

  @override
  bool operator ==(Object other) {
    if (other is! CborArray || other.items.length != items.length) return false;
    for (var i = 0; i < items.length; i++) {
      if (other.items[i] != items[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(items);

  @override
  String toString() => 'CborArray(${items.length})';
}

class CborMapEntry {
  final CborValue key;
  final CborValue value;

  const CborMapEntry(this.key, this.value);
}

class CborMap extends CborValue {
  final List<CborMapEntry> entries;
  final bool canonicalSort;

  const CborMap(this.entries, {this.canonicalSort = true});

  factory CborMap.fromMap(
    Map<CborValue, CborValue> map, {
    bool canonicalSort = true,
  }) {
    return CborMap(
      [for (final e in map.entries) CborMapEntry(e.key, e.value)],
      canonicalSort: canonicalSort,
    );
  }

  CborValue? getByIntKey(int key) {
    final target = BigInt.from(key);
    for (final entry in entries) {
      final k = entry.key;
      if (k is CborInt && k.value == target) {
        return entry.value;
      }
    }
    return null;
  }

  @override
  void writeTo(BytesBuilder out) {
    final encodedEntries = [
      for (final e in entries)
        (keyBytes: e.key.encode(), valBytes: e.value.encode()),
    ];
    if (canonicalSort) {
      encodedEntries.sort((a, b) => compareBytes(a.keyBytes, b.keyBytes));
    }
    _writeUintHeader(out, 5, encodedEntries.length);
    for (final item in encodedEntries) {
      out.add(item.keyBytes);
      out.add(item.valBytes);
    }
  }

  @override
  bool operator ==(Object other) {
    if (other is! CborMap || other.entries.length != entries.length) return false;
    for (var i = 0; i < entries.length; i++) {
      if (other.entries[i].key != entries[i].key ||
          other.entries[i].value != entries[i].value) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(entries.map((e) => Object.hash(e.key, e.value)));

  @override
  String toString() => 'CborMap(${entries.length})';
}

class CborTag extends CborValue {
  final int tag;
  final CborValue value;

  const CborTag(this.tag, this.value);

  @override
  void writeTo(BytesBuilder out) {
    _writeUintHeader(out, 6, tag);
    value.writeTo(out);
  }

  @override
  bool operator ==(Object other) =>
      other is CborTag && other.tag == tag && other.value == value;

  @override
  int get hashCode => Object.hash(tag, value);

  @override
  String toString() => 'CborTag($tag, $value)';
}

class CborBool extends CborValue {
  final bool value;

  const CborBool(this.value);

  @override
  void writeTo(BytesBuilder out) {
    out.addByte(value ? 0xf5 : 0xf4);
  }

  @override
  bool operator ==(Object other) => other is CborBool && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'CborBool($value)';
}

class CborNull extends CborValue {
  const CborNull();

  @override
  void writeTo(BytesBuilder out) {
    out.addByte(0xf6);
  }

  @override
  bool operator ==(Object other) => other is CborNull;

  @override
  int get hashCode => 0xf6;

  @override
  String toString() => 'CborNull()';
}

void _writeUintHeader(BytesBuilder out, int majorType, int value) {
  _writeBigUintHeader(out, majorType, BigInt.from(value));
}

void _writeBigUintHeader(BytesBuilder out, int majorType, BigInt value) {
  if (value < BigInt.zero) {
    throw ArgumentError('Negative value in CBOR unsigned header: $value');
  }
  final prefix = majorType << 5;
  if (value <= BigInt.from(23)) {
    out.addByte(prefix | value.toInt());
  } else if (value <= BigInt.from(0xff)) {
    out.addByte(prefix | 24);
    out.addByte(value.toInt());
  } else if (value <= BigInt.from(0xffff)) {
    final v = value.toInt();
    out.addByte(prefix | 25);
    out.addByte((v >> 8) & 0xff);
    out.addByte(v & 0xff);
  } else if (value <= BigInt.from(0xffffffff)) {
    final v = value.toInt();
    out.addByte(prefix | 26);
    out.addByte((v >> 24) & 0xff);
    out.addByte((v >> 16) & 0xff);
    out.addByte((v >> 8) & 0xff);
    out.addByte(v & 0xff);
  } else {
    if (value >= (BigInt.one << 64)) {
      throw ArgumentError('CBOR integer exceeds uint64 range: $value');
    }
    out.addByte(prefix | 27);
    for (var shift = 56; shift >= 0; shift -= 8) {
      out.addByte(((value >> shift) & BigInt.from(0xff)).toInt());
    }
  }
}

class _CborReader {
  final Uint8List bytes;
  int offset = 0;

  _CborReader(this.bytes);

  bool get isAtEnd => offset >= bytes.length;

  int _readByte() {
    if (offset >= bytes.length) {
      throw const FormatException('Unexpected end of CBOR input');
    }
    return bytes[offset++];
  }

  Uint8List _readBytes(int len) {
    if (len < 0 || offset + len > bytes.length) {
      throw FormatException(
        'Unexpected end of CBOR input while reading $len bytes at offset $offset',
      );
    }
    final slice = Uint8List.sublistView(bytes, offset, offset + len);
    offset += len;
    return slice;
  }

  BigInt _readArg(int addInfo) {
    if (addInfo < 24) {
      return BigInt.from(addInfo);
    } else if (addInfo == 24) {
      return BigInt.from(_readByte());
    } else if (addInfo == 25) {
      final b = _readBytes(2);
      return BigInt.from((b[0] << 8) | b[1]);
    } else if (addInfo == 26) {
      final b = _readBytes(4);
      return BigInt.from(
        (b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3],
      );
    } else if (addInfo == 27) {
      final b = _readBytes(8);
      var v = BigInt.zero;
      for (var i = 0; i < 8; i++) {
        v = (v << 8) | BigInt.from(b[i]);
      }
      return v;
    }
    throw FormatException('Invalid CBOR additional info: $addInfo');
  }

  CborValue readValue() {
    final initial = _readByte();
    final majorType = (initial >> 5) & 0x07;
    final addInfo = initial & 0x1f;

    switch (majorType) {
      case 0:
        return CborInt(_readArg(addInfo));
      case 1:
        return CborInt(-BigInt.one - _readArg(addInfo));
      case 2:
        if (addInfo == 31) {
          final builder = BytesBuilder(copy: false);
          while (true) {
            if (offset >= bytes.length) {
              throw const FormatException('Unterminated indefinite CBOR byte string');
            }
            if (bytes[offset] == 0xff) {
              offset++;
              break;
            }
            final chunk = readValue();
            if (chunk is! CborBytes) {
              throw const FormatException('Invalid chunk inside indefinite CBOR byte string');
            }
            builder.add(chunk.bytes);
          }
          return CborBytes(builder.toBytes());
        }
        final len = _readArg(addInfo).toInt();
        return CborBytes(_readBytes(len));
      case 3:
        if (addInfo == 31) {
          final sb = StringBuffer();
          while (true) {
            if (offset >= bytes.length) {
              throw const FormatException('Unterminated indefinite CBOR text string');
            }
            if (bytes[offset] == 0xff) {
              offset++;
              break;
            }
            final chunk = readValue();
            if (chunk is! CborText) {
              throw const FormatException('Invalid chunk inside indefinite CBOR text string');
            }
            sb.write(chunk.text);
          }
          return CborText(sb.toString());
        }
        final len = _readArg(addInfo).toInt();
        return CborText(utf8.decode(_readBytes(len)));
      case 4:
        if (addInfo == 31) {
          final items = <CborValue>[];
          while (true) {
            if (offset >= bytes.length) {
              throw const FormatException('Unterminated indefinite CBOR array');
            }
            if (bytes[offset] == 0xff) {
              offset++;
              break;
            }
            items.add(readValue());
          }
          return CborArray(items, indefinite: true);
        }
        final count = _readArg(addInfo).toInt();
        final items = <CborValue>[
          for (var i = 0; i < count; i++) readValue(),
        ];
        return CborArray(items);
      case 5:
        final entries = <CborMapEntry>[];
        if (addInfo == 31) {
          while (true) {
            if (offset >= bytes.length) {
              throw const FormatException('Unterminated indefinite CBOR map');
            }
            if (bytes[offset] == 0xff) {
              offset++;
              break;
            }
            final k = readValue();
            final v = readValue();
            entries.add(CborMapEntry(k, v));
          }
          return CborMap(entries, canonicalSort: false);
        }
        final count = _readArg(addInfo).toInt();
        for (var i = 0; i < count; i++) {
          final k = readValue();
          final v = readValue();
          entries.add(CborMapEntry(k, v));
        }
        return CborMap(entries, canonicalSort: false);
      case 6:
        final tag = _readArg(addInfo).toInt();
        final val = readValue();
        return CborTag(tag, val);
      case 7:
        if (addInfo == 20) return const CborBool(false);
        if (addInfo == 21) return const CborBool(true);
        if (addInfo == 22 || addInfo == 23) return const CborNull();
        throw FormatException('Unsupported CBOR simple value: $addInfo');
      default:
        throw FormatException('Invalid CBOR major type: $majorType');
    }
  }
}
