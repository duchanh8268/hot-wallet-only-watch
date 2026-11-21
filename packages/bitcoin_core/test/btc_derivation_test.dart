import 'dart:typed_data';
import 'package:bitcoin_core/bitcoin_core.dart';
import 'package:chain_core_interface/chain_core_interface.dart' show Bip39;
import 'package:test/test.dart';

void main() {
  group('BIP-84 Official Test Vector Derivations', () {
    // Official BIP-84 test vector mnemonic
    const mnemonic =
        'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';

    late Uint8List seed;
    late BtcHdKey master;

    setUp(() {
      seed = Bip39.mnemonicToSeed(mnemonic);
      master = BtcHdKey.fromSeed(seed);
    });

    tearDown(() {
      master.dispose();
    });

    test('Derives first receive address m/84\'/0\'/0\'/0/0 matching BIP-84 spec', () {
      final key0 = master.deriveBip84Address(accountIndex: 0, change: 0, addressIndex: 0);
      final addr0 = Bech32Segwit.encodeP2wpkh(hrp: 'bc', program20: key0.pubKeyHash);
      expect(addr0, equals('bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu'));
      key0.dispose();
    });

    test('Derives second receive address m/84\'/0\'/0\'/0/1 matching BIP-84 spec', () {
      final key1 = master.deriveBip84Address(accountIndex: 0, change: 0, addressIndex: 1);
      final addr1 = Bech32Segwit.encodeP2wpkh(hrp: 'bc', program20: key1.pubKeyHash);
      expect(addr1, equals('bc1qnjg0jd8228aq7egyzacy8cys3knf9xvrerkf9g'));
      key1.dispose();
    });

    test('Derives first change address m/84\'/0\'/0\'/1/0 matching BIP-84 spec', () {
      final change0 = master.deriveBip84Address(accountIndex: 0, change: 1, addressIndex: 0);
      final changeAddr0 = Bech32Segwit.encodeP2wpkh(hrp: 'bc', program20: change0.pubKeyHash);
      expect(changeAddr0, equals('bc1q8c6fshw2dlwun7ekn9qwf37cu2rn755upcp6el'));
      change0.dispose();
    });

    test('Derives Testnet BIP-84 addresses with tb1q prefix', () {
      final keyTb = master.deriveBip84Address(accountIndex: 0, change: 0, addressIndex: 0, isTestnet: true);
      final addrTb = Bech32Segwit.encodeP2wpkh(hrp: 'tb', program20: keyTb.pubKeyHash);
      expect(addrTb.startsWith('tb1q'), isTrue);
      keyTb.dispose();
    });

    test('AUDIT-20: Secp256k1Btc enforces canonical DER and rejects trailing bytes & high-S', () {
      final key0 = master.deriveBip84Address(accountIndex: 0, change: 0, addressIndex: 0);
      final sighash = Uint8List(32)..[0] = 0x42;
      final sig = Secp256k1Btc.sign(sighash, key0.privateKey);
      final der = Secp256k1Btc.encodeDerSignature(sig.r, sig.s);
      final pub = key0.publicKeyCompressed;

      expect(Secp256k1Btc.verifyDer(sighash, der, pub), isTrue);
      // Trailing byte appended to DER signature must fail
      final trailingDer = Uint8List.fromList([...der, 0x00]);
      expect(Secp256k1Btc.verifyDer(sighash, trailingDer, pub), isFalse);

      // Malleable high-S must be rejected
      final sVal = BigInt.parse(
        sig.s.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
        radix: 16,
      );
      final highS = Secp256k1Btc.n - sVal;
      final highSHex = highS.toRadixString(16).padLeft(64, '0');
      final highSBytes = Uint8List.fromList([
        for (var i = 0; i < 32; i++) int.parse(highSHex.substring(i * 2, i * 2 + 2), radix: 16),
      ]);
      expect(Secp256k1Btc.verify(sighash, sig.r, highSBytes, pub), isFalse);

      key0.dispose();
    });
  });
}
