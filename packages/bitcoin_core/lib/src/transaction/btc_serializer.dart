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
}
