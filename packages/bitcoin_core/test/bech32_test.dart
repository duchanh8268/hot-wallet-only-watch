import 'package:bitcoin_core/bitcoin_core.dart';
import 'package:chain_core_interface/chain_core_interface.dart' show hexDecode, hexEncode;
import 'package:test/test.dart';

void main() {
  group('BIP-173 Bech32 SegWit Address Tests', () {
    test('Valid BIP-173 test vector: P2WPKH 20-byte program', () {
      const addr = 'bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4';
      final decoded = Bech32Segwit.decode(addr);
      expect(decoded.hrp, equals('bc'));
      expect(decoded.witnessVersion, equals(0));
      expect(hexEncode(decoded.program), equals('751e76e8199196d454941c45d1b3a323f1433bd6'));

      final reEncoded = Bech32Segwit.encodeP2wpkh(
        hrp: 'bc',
        program20: hexDecode('751e76e8199196d454941c45d1b3a323f1433bd6'),
      );
      expect(reEncoded, equals(addr));
    });

    test('Valid BIP-173 test vector: Testnet P2WPKH', () {
      final prog = hexDecode('751e76e8199196d454941c45d1b3a323f1433bd6');
      final tbAddr = Bech32Segwit.encodeP2wpkh(hrp: 'tb', program20: prog);
      expect(tbAddr.startsWith('tb1q'), isTrue);

      final dec = Bech32Segwit.decode(tbAddr);
      expect(dec.hrp, equals('tb'));
      expect(dec.witnessVersion, equals(0));
      expect(dec.program, equals(prog));
    });

    test('Rejects invalid addresses', () {
      // Invalid checksum
      expect(() => Bech32Segwit.decode('bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t5'), throwsFormatException);
      // Mixed case
      expect(() => Bech32Segwit.decode('bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8F3t4'), throwsFormatException);
      // Wrong HRP check
      expect(Bech32Segwit.isValid(address: 'bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4', expectedHrp: 'tb'), isFalse);
    });
  });
}
