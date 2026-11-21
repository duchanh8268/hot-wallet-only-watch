import 'dart:typed_data';

/// BIP-173 / BIP-350 Bech32 and Bech32m encoder/decoder for Native SegWit Bitcoin addresses.
class Bech32Segwit {
  static const String charset = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l';
  static const int bech32Const = 1;
  static const int bech32mConst = 0x2bc830a3;

  const Bech32Segwit._();

  /// Encodes a SegWit Native P2WPKH address (witness version 0, 20-byte program).
  /// [hrp]: 'bc' for mainnet, 'tb' for testnet/signet.
  static String encodeP2wpkh({
    required String hrp,
    required Uint8List program20,
  }) {
    if (program20.length != 20) {
      throw ArgumentError('P2WPKH witness program must be 20 bytes, got ${program20.length}');
    }
    return encode(hrp: hrp, witnessVersion: 0, program: program20);
  }

  /// Encodes a SegWit address with specified [witnessVersion] (0 to 16) and [program].
  static String encode({
    required String hrp,
    required int witnessVersion,
    required Uint8List program,
  }) {
    if (witnessVersion < 0 || witnessVersion > 16) {
      throw ArgumentError('Invalid witness version: $witnessVersion');
    }
    if (program.length < 2 || program.length > 40) {
      throw ArgumentError('Witness program must be between 2 and 40 bytes');
    }

    final data5Bit = <int>[witnessVersion];
    data5Bit.addAll(_convertBits(program, 8, 5, pad: true));

    final isBech32m = witnessVersion > 0;
    final checksum = _createChecksum(hrp, data5Bit, isBech32m ? bech32mConst : bech32Const);

    final sb = StringBuffer('${hrp.toLowerCase()}1');
    for (final val in [...data5Bit, ...checksum]) {
      sb.write(charset[val]);
    }
    return sb.toString();
  }

  /// Decodes a Bech32 / Bech32m SegWit address into `(hrp, witnessVersion, program)`.
  static ({String hrp, int witnessVersion, Uint8List program}) decode(String address) {
    if (address.length < 8 || address.length > 90) {
      throw const FormatException('Invalid address length');
    }
    final lower = address.toLowerCase();
    final upper = address.toUpperCase();
    if (address != lower && address != upper) {
      throw const FormatException('Mixed case Bech32 address not allowed');
    }

    final str = lower;
    final sepIdx = str.lastIndexOf('1');
    if (sepIdx < 1 || sepIdx + 7 > str.length) {
      throw const FormatException('Missing or misplaced separator "1"');
    }

    final hrp = str.substring(0, sepIdx);
    final dataPart = str.substring(sepIdx + 1);

    final values = <int>[];
    for (var i = 0; i < dataPart.length; i++) {
      final idx = charset.indexOf(dataPart[i]);
      if (idx == -1) {
        throw FormatException('Invalid Bech32 character: ${dataPart[i]}');
      }
      values.add(idx);
    }

    final polymodVal = _polymod(_hrpExpand(hrp)..addAll(values));
    final isBech32 = polymodVal == bech32Const;
    final isBech32m = polymodVal == bech32mConst;
    if (!isBech32 && !isBech32m) {
      throw const FormatException('Invalid Bech32 checksum');
    }

    final dataWithoutChecksum = values.sublist(0, values.length - 6);
    if (dataWithoutChecksum.isEmpty) {
      throw const FormatException('Empty Bech32 payload');
    }

    final witnessVersion = dataWithoutChecksum[0];
    if (witnessVersion < 0 || witnessVersion > 16) {
      throw FormatException('Invalid witness version: $witnessVersion');
    }

    // BIP-350 check: version 0 must be Bech32; version 1+ must be Bech32m
    if (witnessVersion == 0 && !isBech32) {
      throw const FormatException('Witness version 0 must use Bech32 (not Bech32m)');
    }
    if (witnessVersion > 0 && !isBech32m) {
      throw const FormatException('Witness version > 0 must use Bech32m');
    }

    final programBytes = _convertBits(
      dataWithoutChecksum.sublist(1),
      5,
      8,
      pad: false,
    );

    if (programBytes.length < 2 || programBytes.length > 40) {
      throw FormatException('Invalid witness program length: ${programBytes.length}');
    }
    if (witnessVersion == 0 && programBytes.length != 20 && programBytes.length != 32) {
      throw FormatException('Witness version 0 must be 20 or 32 bytes, got ${programBytes.length}');
    }

    return (
      hrp: hrp,
      witnessVersion: witnessVersion,
      program: Uint8List.fromList(programBytes),
    );
  }

  /// Checks if [address] is a valid Bech32 address for [expectedHrp].
  static bool isValid({required String address, String? expectedHrp}) {
    try {
      final res = decode(address);
      if (expectedHrp != null && res.hrp != expectedHrp.toLowerCase()) {
        return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  static List<int> _convertBits(List<int> data, int fromBits, int toBits, {required bool pad}) {
    var acc = 0;
    var bits = 0;
    final maxv = (1 << toBits) - 1;
    final result = <int>[];

    for (final value in data) {
      if (value < 0 || (value >> fromBits) != 0) {
        throw const FormatException('Invalid value in bit conversion');
      }
      acc = (acc << fromBits) | value;
      bits += fromBits;
      while (bits >= toBits) {
        bits -= toBits;
        result.add((acc >> bits) & maxv);
      }
    }

    if (pad) {
      if (bits > 0) {
        result.add((acc << (toBits - bits)) & maxv);
      }
    } else if (bits >= fromBits || ((acc << (toBits - bits)) & maxv) != 0) {
      throw const FormatException('Excess padding in 5-to-8 bit conversion');
    }

    return result;
  }

  static int _polymod(List<int> values) {
    var chk = 1;
    for (final v in values) {
      final top = chk >> 25;
      chk = ((chk & 0x1ffffff) << 5) ^ v;
      if ((top & 1) != 0) chk ^= 0x3b6a57b2;
      if ((top & 2) != 0) chk ^= 0x26508e6d;
      if ((top & 4) != 0) chk ^= 0x1ea119fa;
      if ((top & 8) != 0) chk ^= 0x3d4233dd;
      if ((top & 16) != 0) chk ^= 0x2a1462b3;
    }
    return chk;
  }

  static List<int> _hrpExpand(String hrp) {
    final res = <int>[];
    for (var i = 0; i < hrp.length; i++) {
      res.add(hrp.codeUnitAt(i) >> 5);
    }
    res.add(0);
    for (var i = 0; i < hrp.length; i++) {
      res.add(hrp.codeUnitAt(i) & 31);
    }
    return res;
  }

  static List<int> _createChecksum(String hrp, List<int> data, int constVal) {
    final values = _hrpExpand(hrp)..addAll(data)..addAll([0, 0, 0, 0, 0, 0]);
    final mod = _polymod(values) ^ constVal;
    return List<int>.generate(6, (i) => (mod >> (5 * (5 - i))) & 31);
  }
}
