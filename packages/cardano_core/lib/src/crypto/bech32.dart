import 'dart:typed_data';

/// Decoded result of a Bech32 string.
class Bech32Data {
  final String hrp;
  final Uint8List data;

  const Bech32Data(this.hrp, this.data);
}

/// Standard BIP-173 Bech32 codec supporting Cardano CIP-5/CIP-19 extended payload lengths.
class Bech32 {
  static const String _charset = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l';
  static const List<int> _generator = [
    0x3b6a57b2,
    0x26508e6d,
    0x1ea119fa,
    0x3d4233dd,
    0x2a1462b3,
  ];

  static final Map<int, int> _revCharset = {
    for (var i = 0; i < _charset.length; i++) _charset.codeUnitAt(i): i,
  };

  /// Encodes raw byte [data] with human-readable prefix [hrp] into Bech32.
  static String encode(String hrp, Uint8List data) {
    final normalizedHrp = hrp.toLowerCase();
    _validateHrp(normalizedHrp);
    final words = convertBits(data, 8, 5, pad: true);
    final checksum = _createChecksum(normalizedHrp, words);
    final combined = [...words, ...checksum];
    final sb = StringBuffer(normalizedHrp)..write('1');
    for (final w in combined) {
      sb.write(_charset[w]);
    }
    return sb.toString();
  }

  /// Decodes a Bech32 [input] string, returning its [hrp] and raw 8-bit [data].
  static Bech32Data decode(String input) {
    final trimmed = input.trim();
    if (trimmed.length < 8) {
      throw const FormatException('Bech32 string too short');
    }
    var hasLower = false;
    var hasUpper = false;
    for (var i = 0; i < trimmed.length; i++) {
      final code = trimmed.codeUnitAt(i);
      if (code < 33 || code > 126) {
        throw const FormatException('Bech32 contains invalid ASCII character');
      }
      if (code >= 97 && code <= 122) hasLower = true;
      if (code >= 65 && code <= 90) hasUpper = true;
    }
    if (hasLower && hasUpper) {
      throw const FormatException('Bech32 mixes upper and lower case');
    }

    final lower = trimmed.toLowerCase();
    final sepIndex = lower.lastIndexOf('1');
    if (sepIndex < 1 || sepIndex + 7 > lower.length) {
      throw const FormatException('Bech32 separator position invalid');
    }

    final hrp = lower.substring(0, sepIndex);
    _validateHrp(hrp);

    final dataPart = lower.substring(sepIndex + 1);
    final words = <int>[];
    for (var i = 0; i < dataPart.length; i++) {
      final val = _revCharset[dataPart.codeUnitAt(i)];
      if (val == null) {
        throw FormatException('Invalid Bech32 character: ${dataPart[i]}');
      }
      words.add(val);
    }

    if (!_verifyChecksum(hrp, words)) {
      throw const FormatException('Invalid Bech32 checksum');
    }

    final payloadWords = words.sublist(0, words.length - 6);
    final bytes = convertBits(Uint8List.fromList(payloadWords), 5, 8, pad: false);
    return Bech32Data(hrp, bytes);
  }

  /// General power-of-2 base conversion between [fromBits] and [toBits].
  static Uint8List convertBits(
    List<int> data,
    int fromBits,
    int toBits, {
    required bool pad,
  }) {
    var acc = 0;
    var bits = 0;
    final ret = <int>[];
    final maxv = (1 << toBits) - 1;
    final maxAcc = (1 << (fromBits + toBits - 1)) - 1;

    for (final value in data) {
      if (value < 0 || (value >> fromBits) != 0) {
        throw FormatException('Invalid value during bit conversion: $value');
      }
      acc = ((acc << fromBits) | value) & maxAcc;
      bits += fromBits;
      while (bits >= toBits) {
        bits -= toBits;
        ret.add((acc >> bits) & maxv);
      }
    }

    if (pad) {
      if (bits > 0) {
        ret.add((acc << (toBits - bits)) & maxv);
      }
    } else if (bits >= fromBits || ((acc << (toBits - bits)) & maxv) != 0) {
      throw const FormatException('Invalid padding in Bech32 data');
    }

    return Uint8List.fromList(ret);
  }

  static void _validateHrp(String hrp) {
    if (hrp.isEmpty || hrp.length > 83) {
      throw const FormatException('Invalid Bech32 HRP length');
    }
    for (var i = 0; i < hrp.length; i++) {
      final code = hrp.codeUnitAt(i);
      if (code < 33 || code > 126) {
        throw const FormatException('Invalid Bech32 HRP character');
      }
    }
  }

  static int _polymod(List<int> values) {
    var chk = 1;
    for (final v in values) {
      final top = chk >> 25;
      chk = ((chk & 0x1ffffff) << 5) ^ v;
      for (var i = 0; i < 5; i++) {
        if (((top >> i) & 1) != 0) {
          chk ^= _generator[i];
        }
      }
    }
    return chk;
  }

  static List<int> _hrpExpand(String hrp) {
    final ret = <int>[];
    for (var i = 0; i < hrp.length; i++) {
      ret.add(hrp.codeUnitAt(i) >> 5);
    }
    ret.add(0);
    for (var i = 0; i < hrp.length; i++) {
      ret.add(hrp.codeUnitAt(i) & 31);
    }
    return ret;
  }

  static bool _verifyChecksum(String hrp, List<int> data) {
    return _polymod([..._hrpExpand(hrp), ...data]) == 1;
  }

  static List<int> _createChecksum(String hrp, List<int> data) {
    final values = [..._hrpExpand(hrp), ...data, 0, 0, 0, 0, 0, 0];
    final mod = _polymod(values) ^ 1;
    return [for (var i = 0; i < 6; i++) (mod >> (5 * (5 - i))) & 31];
  }
}
