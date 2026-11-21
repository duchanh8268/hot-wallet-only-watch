import 'dart:typed_data';
import 'package:solana_core/solana_core.dart';
import 'package:test/test.dart';

void main() {
  group('Solana Transaction & CompactU16 Tests', () {
    test('CompactU16 encodes and decodes correctly', () {
      final testCases = [0, 1, 127, 128, 255, 300, 16383, 16384, 65535];
      for (final val in testCases) {
        final enc = CompactU16.encode(val);
        final (dec, size) = CompactU16.decode(enc);
        expect(dec, equals(val));
        expect(size, equals(enc.length));
      }
    });

    test('Compiles and roundtrips SolanaMessage', () {
      final feePayer = Uint8List.fromList(List.filled(32, 0x11));
      final recipient = Uint8List.fromList(List.filled(32, 0x22));
      final blockhash = Uint8List.fromList(List.filled(32, 0x33));

      final ix = SystemProgram.transfer(
        fromPubkey: feePayer,
        toPubkey: recipient,
        lamports: BigInt.from(1500000000), // 1.5 SOL
      );

      final msg = SolanaMessage.compile(
        feePayer: feePayer,
        recentBlockhash: blockhash,
        instructions: [ix],
      );

      expect(msg.header.numRequiredSignatures, equals(1));
      expect(msg.accountKeys.length, equals(3)); // feePayer, recipient, SystemProgram
      expect(msg.instructions.length, equals(1));

      final serialized = msg.serialize();
      final deserialized = SolanaMessage.deserialize(serialized);

      expect(deserialized.header.numRequiredSignatures, equals(msg.header.numRequiredSignatures));
      expect(deserialized.accountKeys.length, equals(msg.accountKeys.length));
      expect(deserialized.recentBlockhash, equals(msg.recentBlockhash));
      expect(deserialized.instructions.length, equals(1));
      expect(deserialized.instructions.first.data, equals(ix.data));
    });

    test('Constructs and serializes SolanaTransaction with signature', () {
      final feePayer = Uint8List.fromList(List.filled(32, 0x11));
      final recipient = Uint8List.fromList(List.filled(32, 0x22));
      final blockhash = Uint8List.fromList(List.filled(32, 0x33));

      final ix = SystemProgram.transfer(
        fromPubkey: feePayer,
        toPubkey: recipient,
        lamports: BigInt.from(500000000),
      );

      final msg = SolanaMessage.compile(
        feePayer: feePayer,
        recentBlockhash: blockhash,
        instructions: [ix],
      );

      final sig = Uint8List.fromList(List.filled(64, 0xaa));
      final tx = SolanaTransaction(
        signatures: [sig],
        message: msg,
      );

      final wireBytes = tx.serialize();
      expect(wireBytes.length, greaterThan(100));

      final parsedTx = SolanaTransaction.deserialize(wireBytes);
      expect(parsedTx.signatures.length, equals(1));
      expect(parsedTx.signatures.first, equals(sig));
      expect(parsedTx.message.instructions.length, equals(1));
    });
  });
}
