import 'package:evm_core/evm_core.dart';
import 'package:test/test.dart';

void main() {
  group('EIP-55 Checksum & Validation Tests', () {
    test('Standard EIP-55 test vectors format correctly', () {
      final vectors = [
        '0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed',
        '0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359',
        '0xdbF03B407c01E7cD3CBea99509d93f8DDDC8C6FB',
        '0xD1220A0cf47c7B9Be7A2E6BA89F429762e7b9aDb',
      ];

      for (final addr in vectors) {
        final lower = addr.toLowerCase();
        expect(Eip55.toChecksumAddress(lower), equals(addr));
        expect(Eip55.isValidAddress(addr), isTrue);
      }
    });

    test('Rejects invalid checksums and invalid lengths', () {
      // Intentionally wrong case
      expect(Eip55.isValidAddress('0x5AAeb6053F3E94C9b9A09f33669435E7Ef1BeAed'), isFalse);
      // Too short
      expect(Eip55.isValidAddress('0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAe'), isFalse);
      // Invalid hex chars
      expect(Eip55.isValidAddress('0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAeZ'), isFalse);
    });
  });
}
