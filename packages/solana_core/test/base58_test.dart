import 'dart:typed_data';
import 'package:solana_core/solana_core.dart';
import 'package:test/test.dart';

void main() {
  group('Base58 Codec Tests', () {
    test('Encodes and decodes empty bytes', () {
      expect(Base58.encode(Uint8List(0)), equals(''));
      expect(Base58.decode(''), equals(Uint8List(0)));
    });

    test('Preserves leading zero bytes as "1"', () {
      final bytes = Uint8List.fromList([0, 0, 1, 2, 3]);
      final encoded = Base58.encode(bytes);
      expect(encoded.startsWith('11'), isTrue);

      final decoded = Base58.decode(encoded);
      expect(decoded, equals(bytes));
    });

    test('Encodes and decodes 32-byte public key roundtrip', () {
      final rawKey = Uint8List.fromList(List.generate(32, (i) => i * 7 % 256));
      final b58 = Base58.encode(rawKey);
      expect(b58.length, greaterThanOrEqualTo(32));

      final decoded = Base58.decode(b58);
      expect(decoded, equals(rawKey));
    });

    test('Rejects invalid Base58 characters', () {
      expect(() => Base58.decode('0OIl'), throwsFormatException);
    });
  });
}
