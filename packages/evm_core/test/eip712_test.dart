import 'package:evm_core/evm_core.dart';
import 'package:test/test.dart';

void main() {
  group('EIP-712 Hashing Tests', () {
    test('Standard EIP-712 Mail test vector matches expected hash', () {
      final domain = Eip712Domain(
        name: 'Ether Mail',
        version: '1',
        chainId: 1,
        verifyingContract: '0xCcCCccccCCCCcCCCCCCcCcCccCcCCCcCcccccccC',
      );

      final types = <String, List<Eip712TypeProperty>>{
        'EIP712Domain': const [
          Eip712TypeProperty(name: 'name', type: 'string'),
          Eip712TypeProperty(name: 'version', type: 'string'),
          Eip712TypeProperty(name: 'chainId', type: 'uint256'),
          Eip712TypeProperty(name: 'verifyingContract', type: 'address'),
        ],
        'Person': const [
          Eip712TypeProperty(name: 'name', type: 'string'),
          Eip712TypeProperty(name: 'wallet', type: 'address'),
        ],
        'Mail': const [
          Eip712TypeProperty(name: 'from', type: 'Person'),
          Eip712TypeProperty(name: 'to', type: 'Person'),
          Eip712TypeProperty(name: 'contents', type: 'string'),
        ],
      };

      final message = <String, dynamic>{
        'from': {
          'name': 'Cow',
          'wallet': '0xCD2a3d9F938E13CD947Ec05AbC7FE734Df8DD826',
        },
        'to': {
          'name': 'Bob',
          'wallet': '0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB',
        },
        'contents': 'Hello, Bob!',
      };

      final typedData = Eip712TypedData(
        types: types,
        primaryType: 'Mail',
        domain: domain,
        message: message,
      );

      final domainHash = Eip712Hasher.hashDomain(typedData);
      expect(
        hexEncode(domainHash, prefix0x: true),
        equals('0xf2cee375fa42b42143804025fc449deafd50cc031ca257e0b194a650a912090f'),
      );

      final finalHash = Eip712Hasher.hashTypedData(typedData);
      expect(
        hexEncode(finalHash, prefix0x: true),
        equals('0xbe609aee343fb3c4b28e1df9e632fca64fcfaede20f02e86244efddf30957bd2'),
      );
      expect(
        hexEncode(finalHash, prefix0x: true),
        equals('0xbe609aee343fb3c4b28e1df9e632fca64fcfaede20f02e86244efddf30957bd2'),
      );
    });
  });
}
