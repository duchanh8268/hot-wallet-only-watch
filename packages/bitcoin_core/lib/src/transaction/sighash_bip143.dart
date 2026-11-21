import 'dart:typed_data';
import '../crypto/hash256.dart';
import 'btc_models.dart';
import 'btc_serializer.dart';

/// BIP-143 Transaction Digest algorithm for SegWit V0 (P2WPKH).
class Bip143Sighash {
  static const int sighashAll = 0x01;

  const Bip143Sighash._();

  /// Computes the 32-byte BIP-143 SIGHASH_ALL digest for SegWit V0 P2WPKH input at [inputIndex].
  static Uint8List computeP2wpkhSighash({
    required BtcTransaction tx,
    required int inputIndex,
    required Uint8List pubKeyHash20,
    required BigInt amountSat,
    int sighashType = sighashAll,
  }) {
    if (inputIndex < 0 || inputIndex >= tx.inputs.length) {
      throw RangeError.index(inputIndex, tx.inputs, 'inputIndex');
    }
    if (pubKeyHash20.length != 20) {
      throw ArgumentError('pubKeyHash20 must be 20 bytes');
    }

    final bb = BytesBuilder();

    // 1. nVersion (4 bytes LE)
    _writeUint32(bb, tx.version);

    // 2. hashPrevouts (32 bytes): double-SHA256 of all OutPoints
    final prevoutsBb = BytesBuilder();
    for (final inp in tx.inputs) {
      prevoutsBb.add(inp.previousOutput.toBytes());
    }
    final hashPrevouts = hash256(prevoutsBb.toBytes());
    bb.add(hashPrevouts);

    // 3. hashSequence (32 bytes): double-SHA256 of all sequences
    final seqBb = BytesBuilder();
    for (final inp in tx.inputs) {
      _writeUint32(seqBb, inp.sequence);
    }
    final hashSequence = hash256(seqBb.toBytes());
    bb.add(hashSequence);

    // 4. outpoint (36 bytes): the outpoint being spent
    bb.add(tx.inputs[inputIndex].previousOutput.toBytes());

    // 5. scriptCode (25 bytes for P2WPKH): OP_DUP (0x76) OP_HASH160 (0xa9) 0x14 <20-byte-hash> OP_EQUALVERIFY (0x88) OP_CHECKSIG (0xac)
    final scriptCode = Uint8List(25);
    scriptCode[0] = 0x19; // Length: 25 bytes
    scriptCode[1] = 0x76; // OP_DUP
    scriptCode[2] = 0xa9; // OP_HASH160
    scriptCode[3] = 0x14; // Push 20 bytes
    scriptCode.setRange(4, 24, pubKeyHash20);
    scriptCode[24] = 0x88; // OP_EQUALVERIFY
    // Note: In standard BIP-143, scriptCode does not include leading length prefix, length is 25 bytes:
    // 0x76 0xa9 0x14 <pubKeyHash> 0x88 0xac
    final standardScriptCode = Uint8List(25);
    standardScriptCode[0] = 0x19;
    standardScriptCode[1] = 0x76;
    standardScriptCode[2] = 0xa9;
    standardScriptCode[3] = 0x14;
    standardScriptCode.setRange(4, 24, pubKeyHash20);
    standardScriptCode[24] = 0x88;
    // Actually BIP-143 specification states:
    // For P2WPKH witness program:
    // scriptCode is 0x1976a914{20-byte-keyhash}88ac (25 bytes: 0x19 is the length byte, 0x76 0xa9 0x14 <hash> 0x88 0xac)
    bb.add(Uint8List.fromList([
      0x19, 0x76, 0xa9, 0x14,
      ...pubKeyHash20,
      0x88, 0xac,
    ]));

    // 6. amount (8 bytes LE)
    _writeUint64(bb, amountSat);

    // 7. nSequence (4 bytes LE)
    _writeUint32(bb, tx.inputs[inputIndex].sequence);

    // 8. hashOutputs (32 bytes): double-SHA256 of all serialized outputs
    final outBb = BytesBuilder();
    for (final out in tx.outputs) {
      _writeUint64(outBb, out.valueSat);
      outBb.add(BtcSerializer.encodeVarInt(out.scriptPubKey.length));
      outBb.add(out.scriptPubKey);
    }
    final hashOutputs = hash256(outBb.toBytes());
    bb.add(hashOutputs);

    // 9. nLockTime (4 bytes LE)
    _writeUint32(bb, tx.lockTime);

    // 10. sighashType (4 bytes LE)
    _writeUint32(bb, sighashType);

    final preimage = bb.toBytes();
    return hash256(preimage);
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
