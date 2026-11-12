import 'dart:convert';
import 'dart:typed_data';
import 'package:cardano_core/cardano_core.dart';
import 'package:test/test.dart';

void main() {
  group('Deterministic CBOR', () {
    test('Encodes and decodes canonical map keys and 64-bit BigInts', () {
      final map = CborMap([
        CborMapEntry(CborInt.fromInt(10), const CborText('ten')),
        CborMapEntry(CborInt.fromInt(1), const CborText('one')),
        CborMapEntry(CborInt(BigInt.parse('10000000000000')), const CborBool(true)),
      ]);
      final encoded = map.encode();
      final decoded = CborValue.decode(encoded) as CborMap;
      // Canonical sorting puts key 1 first, then 10, then 10^13
      expect((decoded.entries[0].key as CborInt).toInt(), 1);
      expect((decoded.entries[1].key as CborInt).toInt(), 10);
      expect(
        (decoded.entries[2].key as CborInt).value,
        BigInt.parse('10000000000000'),
      );
    });
  });

  group('Conway TxBody, Min-ADA, and Signed Transaction Assembly', () {
    const mnemonic =
        'eight country switch draw meat scout mystery blade tip drift useless good keep usage title';

    test('Serializes and deserializes Conway TxBody with MultiAsset, Certs, and Withdrawals', () {
      final entropy = Bip39.mnemonicToEntropy(mnemonic);
      final master = CardanoMasterKey.fromEntropy(entropy);
      try {
        final addr0 = master.deriveBaseAddressBytes(
          role: 0,
          index: 0,
          network: CardanoNetwork.preprod,
        );
        final rewardAddr = master.deriveRewardAddressBytes(
          network: CardanoNetwork.preprod,
        );
        final stakeHash = master.deriveStakeKeyHash();
        final poolHash = Uint8List.fromList(List<int>.filled(28, 0xab));
        final policyId = Uint8List.fromList(List<int>.filled(28, 0xcd));
        final assetName = Uint8List.fromList(utf8.encode('HOSKY'));

        final txBody = ConwayTxBody(
          inputs: [
            TxInput(txHash: Uint8List.fromList(List<int>.filled(32, 0x11)), index: 0),
          ],
          outputs: [
            TxOutput(
              addressBytes: addr0,
              lovelace: BigInt.from(2000000),
              multiAsset: MultiAsset({
                AssetKey.fromBytes(policyId, assetName): BigInt.from(500000),
              }),
            ),
          ],
          fee: BigInt.from(185000),
          ttl: 75000000,
          certificates: [
            StakeRegistrationCert(
              StakeCredential(hash28: stakeHash),
              coin: BigInt.from(2000000),
            ),
            StakeDelegationCert(StakeCredential(hash28: stakeHash), poolHash),
            VoteDelegationCert(
              StakeCredential(hash28: stakeHash),
              const DRepAlwaysAbstain(),
            ),
          ],
          withdrawals: [
            Withdrawal(
              rewardAddressBytes: rewardAddr,
              coin: BigInt.from(1234567),
            ),
          ],
          networkId: CardanoNetwork.preprod.networkTag,
        );

        final encoded = ConwayTxSerializer.encodeTxBody(txBody);
        final decoded = ConwayTxSerializer.decodeTxBody(encoded);

        expect(decoded.inputs.length, 1);
        expect(decoded.outputs.length, 1);
        expect(decoded.outputs[0].lovelace, BigInt.from(2000000));
        expect(
          decoded.outputs[0].multiAsset[AssetKey.fromBytes(policyId, assetName)],
          BigInt.from(500000),
        );
        expect(decoded.fee, BigInt.from(185000));
        expect(decoded.ttl, 75000000);
        expect(decoded.certificates.length, 3);
        expect(decoded.certificates[0], isA<StakeRegistrationCert>());
        expect(decoded.certificates[1], isA<StakeDelegationCert>());
        expect(decoded.certificates[2], isA<VoteDelegationCert>());
        expect(decoded.withdrawals.length, 1);
        expect(decoded.withdrawals[0].coin, BigInt.from(1234567));
        expect(decoded.networkId, 0);
      } finally {
        master.dispose();
        zeroize(entropy);
      }
    });

    test('calculateMinUtxo grows with MultiAsset payload size', () {
      final addr = Uint8List.fromList([0x00, ...List<int>.filled(56, 1)]);
      final adaOnly = TxOutput(addressBytes: addr, lovelace: BigInt.from(1000000));
      final withToken = TxOutput(
        addressBytes: addr,
        lovelace: BigInt.from(1000000),
        multiAsset: MultiAsset({
          AssetKey.fromBytes(
            Uint8List.fromList(List<int>.filled(28, 2)),
            Uint8List.fromList(utf8.encode('MyAwesomeToken')),
          ): BigInt.from(100),
        }),
      );

      final minAdaOnly = calculateMinUtxo(adaOnly);
      final minToken = calculateMinUtxo(withToken);
      expect(minAdaOnly, greaterThan(BigInt.from(900000)));
      expect(minToken, greaterThan(minAdaOnly));

      // Fixed-point invariant: re-evaluating with the calculated minUTxO as lovelace returns identical value
      final exactOut = TxOutput(
        addressBytes: addr,
        lovelace: minToken,
        multiAsset: withToken.multiAsset,
      );
      expect(calculateMinUtxo(exactOut), minToken);

      // Small coinsPerUTxOByte crossing CBOR integer byte lengths converges deterministically
      final lowParamMin = calculateMinUtxo(adaOnly, coinsPerUTxOByte: 1);
      expect(lowParamMin, lessThan(BigInt.from(300)));
    });

    test('assembleSignedTransaction verifies witnesses and preserves txBodyCbor', () {
      final entropy = Bip39.mnemonicToEntropy(mnemonic);
      final master = CardanoMasterKey.fromEntropy(entropy);
      final payKey = master.deriveAddressSigningKey(role: 0, index: 0);
      try {
        final addr = master.deriveBaseAddressBytes(
          role: 0,
          index: 0,
          network: CardanoNetwork.preprod,
        );
        final txBody = ConwayTxBody(
          inputs: [
            TxInput(txHash: Uint8List.fromList(List<int>.filled(32, 0x22)), index: 1),
          ],
          outputs: [TxOutput(addressBytes: addr, lovelace: BigInt.from(5000000))],
          fee: BigInt.from(170000),
          ttl: 80000000,
          networkId: 0,
        );
        final bodyBytes = ConwayTxSerializer.encodeTxBody(txBody);
        final bodyHash = ConwayTxSerializer.computeTxBodyHash(bodyBytes);
        final sig = payKey.sign(bodyHash);

        final signedTxBytes = ConwayTxSerializer.assembleSignedTransaction(
          txBodyCbor: bodyBytes,
          witnesses: [VKeyWitness(vkey: payKey.publicKey, signature: sig)],
        );

        final root = CborValue.decode(signedTxBytes) as CborArray;
        expect(root.items.length, 4);
        expect(root.items[0].encode(), equals(bodyBytes));
        expect(root.items[2], equals(const CborBool(true)));
        expect(root.items[3], equals(const CborNull()));
      } finally {
        payKey.dispose();
        master.dispose();
        zeroize(entropy);
      }
    });
  });
}
