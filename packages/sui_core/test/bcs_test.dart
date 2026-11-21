import 'package:test/test.dart';
import 'package:sui_core/sui_core.dart';

void main() {
  group('BCS Serialization & Deserialization Tests', () {
    test('u8 serialization', () {
      final writer = BcsWriter()..writeU8(42);
      final reader = BcsReader(writer.toBytes());
      expect(reader.readU8(), equals(42));
    });

    test('u16 serialization', () {
      final writer = BcsWriter()..writeU16(12345);
      final reader = BcsReader(writer.toBytes());
      expect(reader.readU16(), equals(12345));
    });

    test('u32 serialization', () {
      final writer = BcsWriter()..writeU32(305419896);
      final reader = BcsReader(writer.toBytes());
      expect(reader.readU32(), equals(305419896));
    });

    test('u64 serialization', () {
      final val = BigInt.parse('18446744073709551600');
      final writer = BcsWriter()..writeU64(val);
      final reader = BcsReader(writer.toBytes());
      expect(reader.readU64(), equals(val));
    });

    test('uleb128 serialization', () {
      final testValues = [0, 1, 127, 128, 255, 300, 16384, 2097151];
      for (final v in testValues) {
        final writer = BcsWriter()..writeUleb128(v);
        final reader = BcsReader(writer.toBytes());
        expect(reader.readUleb128(), equals(v), reason: 'Failed for $v');
      }
    });

    test('bool serialization', () {
      final writer = BcsWriter()
        ..writeBool(true)
        ..writeBool(false);
      final reader = BcsReader(writer.toBytes());
      expect(reader.readBool(), isTrue);
      expect(reader.readBool(), isFalse);
    });

    test('string serialization', () {
      final str = 'Xin chào Sui Blockchain!';
      final writer = BcsWriter()..writeString(str);
      final reader = BcsReader(writer.toBytes());
      expect(reader.readString(), equals(str));
    });

    test('address serialization 32 bytes', () {
      final addr = '0x0000000000000000000000000000000000000000000000000000000000000006';
      final writer = BcsWriter()..writeAddress(addr);
      final reader = BcsReader(writer.toBytes());
      expect(reader.readAddress().toLowerCase(), equals(addr.toLowerCase()));
    });
  });
}
