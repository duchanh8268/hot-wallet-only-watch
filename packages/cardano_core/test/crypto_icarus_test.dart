import 'dart:typed_data';
import 'package:cardano_core/cardano_core.dart';
import 'package:test/test.dart';

void main() {
  group('Blake2b & Bech32', () {
    test('Blake2b-256 empty input matches RFC 7693 vector', () {
      final digest = blake2b256(Uint8List(0));
      expect(
        hexEncode(digest),
        '0e5751c026e543b2e8ab2eb06099daa1d1e5df47778f7787faab45cdf12fe3a8',
      );
    });

    test('Blake2b-224 empty input matches official vector', () {
      final digest = blake2b224(Uint8List(0));
      expect(
        hexEncode(digest),
        '836cc68931c2e4e3e838602eca1902591d216837bafddfe6f0c8cb07',
      );
    });

    test('Bech32 supports long Cardano acct_xvk and Base addresses', () {
      final payload64 = Uint8List.fromList(List<int>.generate(64, (i) => i));
      final encoded = Bech32.encode('acct_xvk', payload64);
      expect(encoded.startsWith('acct_xvk1'), isTrue);
      expect(encoded.length, greaterThan(100));
      final decoded = Bech32.decode(encoded);
      expect(decoded.hrp, 'acct_xvk');
      expect(decoded.data, equals(payload64));
    });
  });

  group('BIP-39', () {
    test('12, 15, and 24-word entropy <-> mnemonic round-trip', () {
      for (final len in [16, 20, 32]) {
        final entropy = Uint8List.fromList(List<int>.generate(len, (i) => i * 7 + 3));
        final mnemonic = Bip39.entropyToMnemonic(entropy);
        expect(Bip39.validateMnemonic(mnemonic), isTrue);
        final decoded = Bip39.mnemonicToEntropy(mnemonic);
        expect(decoded, equals(entropy));
      }
    });

    test('Rejects invalid checksum or unknown word', () {
      const valid15 =
          'eight country switch draw meat scout mystery blade tip drift useless good keep usage title';
      expect(Bip39.validateMnemonic(valid15), isTrue);

      const badChecksum =
          'eight country switch draw meat scout mystery blade tip drift useless good keep usage abandon';
      expect(Bip39.validateMnemonic(badChecksum), isFalse);

      const unknownWord =
          'eight country switch draw meat scout mystery blade tip drift useless good keep usage notaword';
      expect(Bip39.validateMnemonic(unknownWord), isFalse);
    });
  });

  group('Icarus V2 & CIP-1852 Official Test Vectors', () {
    const cip3Mnemonic =
        'eight country switch draw meat scout mystery blade tip drift useless good keep usage title';

    test('Matches CIP-0003 Icarus root_xsk without passphrase', () {
      final entropy = Bip39.mnemonicToEntropy(cip3Mnemonic);
      final master = CardanoMasterKey.fromEntropy(entropy);
      try {
        expect(
          hexEncode(master.rootKey.bytes),
          'c065afd2832cd8b087c4d9ab7011f481ee1e0721e78ea5dd609f3ab3f156d245'
          'd176bd8fd4ec60b4731c3918a2a72a0226c0cd119ec35b47e4d55884667f552a'
          '23f7fdcd4a10c6cd2c7393ac61d877873e248f417634aa3d812af327ffe9d620',
        );
      } finally {
        master.dispose();
        zeroize(entropy);
      }
    });

    test('Matches CIP-0003 Icarus root_xsk with passphrase "foo"', () {
      final entropy = Bip39.mnemonicToEntropy(cip3Mnemonic);
      final master = CardanoMasterKey.fromEntropy(entropy, passphrase: 'foo');
      try {
        expect(
          hexEncode(master.rootKey.bytes),
          '70531039904019351e1afb361cd1b312a4d0565d4ff9f8062d38acf4b15cce41'
          'd7b5738d9c893feea55512a3004acb0d222c35d3e3d5cde943a15a9824cbac59'
          '443cf67e589614076ba01e354b1a432e0e6db3b59e37fc56b5fb0222970a010e',
        );
      } finally {
        master.dispose();
        zeroize(entropy);
      }
    });

    test('Private derivation and Watch-Only acct_xvk public derivation produce identical addresses', () {
      final entropy = Bip39.mnemonicToEntropy(cip3Mnemonic);
      final master = CardanoMasterKey.fromEntropy(entropy);
      try {
        final acctXvk = master.exportAccountPublicKey();
        final xvkBech32 = acctXvk.toBech32();
        expect(xvkBech32.startsWith('acct_xvk1'), isTrue);

        final reimported = CardanoAccountPublicKey.fromBech32(xvkBech32);

        for (final net in CardanoNetwork.values) {
          for (var role = 0; role <= 1; role++) {
            for (var idx = 0; idx < 3; idx++) {
              final privAddr = master.deriveBaseAddress(
                role: role,
                index: idx,
                network: net,
              );
              final pubAddr = reimported.deriveBaseAddress(
                role: role,
                index: idx,
                network: net,
              );
              expect(pubAddr, equals(privAddr));
              if (net == CardanoNetwork.mainnet) {
                expect(pubAddr.startsWith('addr1'), isTrue);
              } else {
                expect(pubAddr.startsWith('addr_test1'), isTrue);
              }
            }
          }

          final privStake = master.deriveRewardAddress(network: net);
          final pubStake = reimported.deriveRewardAddress(network: net);
          expect(pubStake, equals(privStake));
          if (net == CardanoNetwork.mainnet) {
            expect(pubStake.startsWith('stake1'), isTrue);
          } else {
            expect(pubStake.startsWith('stake_test1'), isTrue);
          }
        }
      } finally {
        master.dispose();
        zeroize(entropy);
      }
    });

    test('Different passphrases produce distinct Deterrence Wallets', () {
      final entropy = Bip39.mnemonicToEntropy(cip3Mnemonic);
      final wDefault = CardanoMasterKey.fromEntropy(entropy, passphrase: '');
      final wHidden = CardanoMasterKey.fromEntropy(entropy, passphrase: 'decoy');
      try {
        expect(
          wDefault.deriveBaseAddress(role: 0, index: 0, network: CardanoNetwork.preprod),
          isNot(
            equals(
              wHidden.deriveBaseAddress(role: 0, index: 0, network: CardanoNetwork.preprod),
            ),
          ),
        );
      } finally {
        wDefault.dispose();
        wHidden.dispose();
        zeroize(entropy);
      }
    });

    test('Ed25519-BIP32 extended signing and verification', () {
      final entropy = Bip39.mnemonicToEntropy(cip3Mnemonic);
      final master = CardanoMasterKey.fromEntropy(entropy);
      final payKey = master.deriveAddressSigningKey(role: 0, index: 0);
      try {
        final msg = blake2b256(Uint8List.fromList([1, 2, 3, 4, 5]));
        final sig = payKey.sign(msg);
        expect(sig.length, 64);
        expect(Ed25519.verify(payKey.publicKey, msg, sig), isTrue);

        // Tamper message
        final badMsg = Uint8List.fromList(msg)..[0] ^= 0xff;
        expect(Ed25519.verify(payKey.publicKey, badMsg, sig), isFalse);

        // Tamper signature
        final badSig = Uint8List.fromList(sig)..[10] ^= 0x01;
        expect(Ed25519.verify(payKey.publicKey, msg, badSig), isFalse);
      } finally {
        payKey.dispose();
        master.dispose();
        zeroize(entropy);
      }
    });

    test('Dispose zeroizes private key material', () {
      final entropy = Bip39.mnemonicToEntropy(cip3Mnemonic);
      final master = CardanoMasterKey.fromEntropy(entropy);
      master.dispose();
      expect(master.rootKey.bytes.every((b) => b == 0), isTrue);
      zeroize(entropy);
    });
  });
}
