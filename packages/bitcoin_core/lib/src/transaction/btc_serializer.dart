import 'dart:typed_data';
import 'package:chain_core_interface/chain_core_interface.dart' show hexEncode;
import '../crypto/hash256.dart';
import 'btc_models.dart';

/// Encodes and decodes Bitcoin transactions into standard wire format (Legacy and SegWit BIP-141).
class BtcSerializer {
  const BtcSerializer._();

  /// Encodes [value] into Bitcoin VarInt format.
  static Uint8List encodeVarInt(int value) {
    if (value < 0xfd) {
      return Uint8List.fromList([value]);
    } else if (value <= 0xffff) {
      return Uint8List.fromList([
        0xfd,
        value & 0xff,
        (value >> 8) & 0xff,
      ]);
    } else if (value <= 0xffffffff) {
      return Uint8List.fromList([
        0xfe,
        value & 0xff,
        (value >> 8) & 0xff,
        (value >> 16) & 0xff,
        (value >> 24) & 0xff,
      ]);
    } else {
      final b = Uint8List(9);
      b[0] = 0xff;
      var v = value;
      for (var i = 0; i < 8; i++) {
        b[1 + i] = v & 0xff;
        v >>= 8;
      }
      return b;
    }
  }

  /// Serializes a transaction into raw wire bytes.
  /// If [forceLegacy] is true, strips witness and markers (used for computing TxID).
  static Uint8List serialize(BtcTransaction tx, {bool forceLegacy = false}) {
    final useWitness = !forceLegacy && tx.hasWitness;
    final bb = BytesBuilder();

    // 1. Version (4 bytes LE)
    _writeUint32(bb, tx.version);

    // 2. Marker & Flag (if witness present and not forced legacy)
    if (useWitness) {
      bb.addByte(0x00); // Marker
      bb.addByte(0x01); // Flag
    }

    // 3. Inputs count & inputs
    bb.add(encodeVarInt(tx.inputs.length));
    for (final inp in tx.inputs) {
      bb.add(inp.previousOutput.toBytes());
      bb.add(encodeVarInt(inp.scriptSig.length));
      bb.add(inp.scriptSig);
      _writeUint32(bb, inp.sequence);
    }

    // 4. Outputs count & outputs
    bb.add(encodeVarInt(tx.outputs.length));
    for (final out in tx.outputs) {
      _writeUint64(bb, out.valueSat);
      bb.add(encodeVarInt(out.scriptPubKey.length));
      bb.add(out.scriptPubKey);
    }

    // 5. Witness data (if SegWit)
    if (useWitness) {
      for (final inp in tx.inputs) {
        bb.add(encodeVarInt(inp.witness.items.length));
        for (final item in inp.witness.items) {
          bb.add(encodeVarInt(item.length));
          bb.add(item);
        }
      }
    }

    // 6. Locktime (4 bytes LE)
    _writeUint32(bb, tx.lockTime);

    return bb.toBytes();
  }

  /// Computes the 32-byte TxID (hash256 of non-witness serialized tx, reversed to RPC display order).
  static String computeTxId(BtcTransaction tx) {
    final rawNonWitness = serialize(tx, forceLegacy: true);
    final hash = hash256(rawNonWitness);
    // Reverse for RPC display hex
    final reversed = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      reversed[i] = hash[31 - i];
    }
    return hexEncode(reversed);
  }

  static void _writeUint32(BytesBuilder bb, int value) {
    bb.addByte(value & 0xff);
    bb.addByte((value >> 8) & 0xff);
    bb.addByte((value >> 16) & 0xff);
    bb.addByte((value >> 24) & 0xff);
  }

  static void _writeUint64(BytesBuilder bb, BigInt value) {
    if (value < BigInt.zero || value >= (BigInt.one << 64)) {
      throw ArgumentError('uint64 value out of range: $value');
    }
    var v = value;
    for (var i = 0; i < 8; i++) {
      bb.addByte((v & BigInt.from(0xff)).toInt());
      v >>= 8;
    }
  }

  /// Parses raw legacy or SegWit Bitcoin transaction bytes and extracts outputs plus canonical txid.
  static ({int version, List<BtcTxOut> outputs, int lockTime, String txid})
      parseRawTransaction(Uint8List rawBytes) {
    var offset = 0;

    void requireBytes(int count) {
      if (count < 0 || offset + count > rawBytes.length) {
        throw const FormatException('Truncated raw Bitcoin transaction');
      }
    }

    int readUint32Le() {
      requireBytes(4);
      final val = rawBytes[offset] |
          (rawBytes[offset + 1] << 8) |
          (rawBytes[offset + 2] << 16) |
          (rawBytes[offset + 3] << 24);
      offset += 4;
      return val;
    }

    BigInt readUint64Le() {
      requireBytes(8);
      var val = BigInt.zero;
      for (var i = 0; i < 8; i++) {
        val |= BigInt.from(rawBytes[offset + i]) << (8 * i);
      }
      offset += 8;
      return val;
    }

    ({int value, int startOffset, int endOffset}) readVarInt() {
      final start = offset;
      requireBytes(1);
      final first = rawBytes[offset++];
      int val;
      if (first < 0xfd) {
        val = first;
      } else if (first == 0xfd) {
        requireBytes(2);
        val = rawBytes[offset] | (rawBytes[offset + 1] << 8);
        offset += 2;
        if (val < 0xfd) {
          throw const FormatException('Non-canonical Bitcoin VarInt');
        }
      } else if (first == 0xfe) {
        requireBytes(4);
        val = rawBytes[offset] |
            (rawBytes[offset + 1] << 8) |
            (rawBytes[offset + 2] << 16) |
            (rawBytes[offset + 3] << 24);
        offset += 4;
        if (val <= 0xffff) {
          throw const FormatException('Non-canonical Bitcoin VarInt');
        }
      } else {
        requireBytes(8);
        var big = BigInt.zero;
        for (var i = 0; i < 8; i++) {
          big |= BigInt.from(rawBytes[offset + i]) << (8 * i);
        }
        offset += 8;
        if (big <= BigInt.from(0xffffffff) || big > BigInt.from(0x7fffffff)) {
          throw const FormatException('Out-of-range or non-canonical Bitcoin VarInt');
        }
        val = big.toInt();
      }
      return (value: val, startOffset: start, endOffset: offset);
    }

    final nonWitnessBb = BytesBuilder();

    final version = readUint32Le();
    nonWitnessBb.add(rawBytes.sublist(0, 4));

    // Check optional BIP-144 SegWit marker (0x00) + flag (0x01)
    var hasWitness = false;
    if (offset + 1 < rawBytes.length &&
        rawBytes[offset] == 0x00 &&
        rawBytes[offset + 1] == 0x01) {
      hasWitness = true;
      offset += 2;
    }

    final inCountInfo = readVarInt();
    final inCount = inCountInfo.value;
    if (inCount <= 0 || inCount > 100000) {
      throw FormatException('Invalid input count in raw transaction: $inCount');
    }
    nonWitnessBb.add(rawBytes.sublist(inCountInfo.startOffset, inCountInfo.endOffset));

    for (var i = 0; i < inCount; i++) {
      final inpStart = offset;
      requireBytes(36); // prevout hash (32) + vout (4)
      offset += 36;
      final scriptLen = readVarInt().value;
      if (scriptLen > 100000) {
        throw FormatException('Oversized scriptSig in raw transaction: $scriptLen');
      }
      requireBytes(scriptLen);
      offset += scriptLen;
      requireBytes(4); // sequence
      offset += 4;
      nonWitnessBb.add(rawBytes.sublist(inpStart, offset));
    }

    final outCountInfo = readVarInt();
    final outCount = outCountInfo.value;
    if (outCount <= 0 || outCount > 100000) {
      throw FormatException('Invalid output count in raw transaction: $outCount');
    }
    nonWitnessBb.add(rawBytes.sublist(outCountInfo.startOffset, outCountInfo.endOffset));

    final outputs = <BtcTxOut>[];
    for (var o = 0; o < outCount; o++) {
      final outStart = offset;
      final valueSat = readUint64Le();
      final spkLen = readVarInt().value;
      if (spkLen > 100000) {
        throw FormatException('Oversized scriptPubKey in raw transaction: $spkLen');
      }
      requireBytes(spkLen);
      final spk = Uint8List.fromList(rawBytes.sublist(offset, offset + spkLen));
      offset += spkLen;
      nonWitnessBb.add(rawBytes.sublist(outStart, offset));
      outputs.add(BtcTxOut(valueSat: valueSat, scriptPubKey: spk));
    }

    if (hasWitness) {
      for (var i = 0; i < inCount; i++) {
        final itemCount = readVarInt().value;
        if (itemCount > 10000) {
          throw FormatException('Oversized witness stack in raw transaction: $itemCount');
        }
        for (var w = 0; w < itemCount; w++) {
          final itemLen = readVarInt().value;
          if (itemLen > 1000000) {
            throw FormatException('Oversized witness item in raw transaction: $itemLen');
          }
          requireBytes(itemLen);
          offset += itemLen;
        }
      }
    }

    final lockStart = offset;
    final lockTime = readUint32Le();
    nonWitnessBb.add(rawBytes.sublist(lockStart, offset));

    if (offset != rawBytes.length) {
      throw const FormatException('Trailing bytes after raw Bitcoin transaction');
    }

    final rawHash = hash256(nonWitnessBb.toBytes());
    final reversed = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      reversed[i] = rawHash[31 - i];
    }

    return (
      version: version,
      outputs: outputs,
      lockTime: lockTime,
      txid: hexEncode(reversed),
    );
  }
}
