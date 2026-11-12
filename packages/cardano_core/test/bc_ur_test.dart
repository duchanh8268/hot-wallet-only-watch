import 'dart:math' as math;
import 'dart:typed_data';
import 'package:cardano_core/cardano_core.dart';
import 'package:test/test.dart';

void main() {
  group('Bytewords & CRC32', () {
    test('All 256 minimal Bytewords codes are unique', () {
      final minimalSet = {
        for (final w in bytewordsTable) '${w[0]}${w[3]}',
      };
      expect(bytewordsTable.length, 256);
      expect(minimalSet.length, 256);
    });

    test('Round-trips standard, uri, and minimal styles and detects corruption', () {
      final data = Uint8List.fromList(List<int>.generate(64, (i) => (i * 13) & 0xff));
      for (final style in BytewordsStyle.values) {
        final encoded = Bytewords.encode(data, style: style);
        final decoded = Bytewords.decode(encoded, style: style);
        expect(decoded, equals(data));
      }

      final min = Bytewords.encode(data, style: BytewordsStyle.minimal);
      final corrupted = 'aa${min.substring(2)}';
      expect(
        () => Bytewords.decode(corrupted, style: BytewordsStyle.minimal),
        throwsFormatException,
      );
    });
  });

  group('BC-UR Fountain Code (Luby Transform)', () {
    test('Recovers large payload despite 40% random packet loss and out-of-order delivery', () {
      final payload = Uint8List.fromList(
        List<int>.generate(1200, (i) => (i * 37 + 11) & 0xff),
      );
      final encoder = UrEncoder(
        type: 'cardano-sign-request',
        cborPayload: payload,
        maxFragmentLen: 80,
      );
      expect(encoder.isSinglePart, isFalse);
      expect(encoder.seqLen, greaterThan(10));

      // Generate 50 frames, drop ~40% randomly, shuffle the remaining frames
      final allFrames = [for (var i = 0; i < 50; i++) encoder.nextPart()];
      final rng = math.Random(42);
      final receivedFrames = [
        for (final f in allFrames)
          if (rng.nextDouble() >= 0.4) f,
      ]..shuffle(rng);

      final decoder = UrDecoder();
      for (final frame in receivedFrames) {
        expect(decoder.receivePart(frame), isTrue);
        if (decoder.isComplete) break;
      }

      expect(decoder.isComplete, isTrue);
      expect(decoder.result!.type, 'cardano-sign-request');
      expect(decoder.result!.cborPayload, equals(payload));
    });
  });

  group('Cardano BC-UR Messages Round-Trip', () {
    const mnemonic =
        'eight country switch draw meat scout mystery blade tip drift useless good keep usage title';

    test('ur:cardano-account round-trip', () {
      final entropy = Bip39.mnemonicToEntropy(mnemonic);
      final master = CardanoMasterKey.fromEntropy(entropy);
      try {
        final acctXvk = master.exportAccountPublicKey();
        final msg = CardanoAccountUr(
          network: CardanoNetwork.preprod,
          acctXvk: acctXvk.bytes,
          label: 'Ví Lạnh Chính',
        );
        final ur = msg.toUr();
        expect(ur.startsWith('UR:CARDANO-ACCOUNT/'), isTrue);

        final parsed = CardanoAccountUr.fromUr(ur);
        expect(parsed.version, 1);
        expect(parsed.network, CardanoNetwork.preprod);
        expect(parsed.acctXvk, equals(acctXvk.bytes));
        expect(parsed.label, 'Ví Lạnh Chính');
      } finally {
        master.dispose();
        zeroize(entropy);
      }
    });

    test('ur:cardano-sign-request and ur:cardano-sign-response multi-part round-trip', () {
      final entropy = Bip39.mnemonicToEntropy(mnemonic);
      final master = CardanoMasterKey.fromEntropy(entropy);
      try {
        final inAddr = master.deriveBaseAddressBytes(
          role: 0,
          index: 0,
          network: CardanoNetwork.preprod,
        );
        final chgAddr = master.deriveBaseAddressBytes(
          role: 1,
          index: 0,
          network: CardanoNetwork.preprod,
        );
        final txHash = Uint8List.fromList(List<int>.filled(32, 0x44));
        final txBody = ConwayTxBody(
          inputs: [TxInput(txHash: txHash, index: 0)],
          outputs: [
            TxOutput(addressBytes: chgAddr, lovelace: BigInt.from(4820000)),
          ],
          fee: BigInt.from(180000),
          ttl: 88000000,
          networkId: 0,
        );

        final req = CardanoSignRequestUr(
          requestId: Uint8List.fromList(List<int>.generate(16, (i) => i + 1)),
          network: CardanoNetwork.preprod,
          txBodyCbor: ConwayTxSerializer.encodeTxBody(txBody),
          utxoInputs: [
            UrUtxoInputContext(
              txHash: txHash,
              outputIndex: 0,
              addressBytes: inAddr,
              lovelace: BigInt.from(5000000),
              derivationRole: 0,
              derivationIndex: 0,
            ),
          ],
          changeOutputs: const [
            UrChangeOutputRef(txOutputIndex: 0, internalIndex: 0),
          ],
          requireStakeWitness: false,
        );

        final reqEnc = req.createEncoder(maxFragmentLen: 80);
        final reqDec = UrDecoder();
        while (!reqDec.isComplete) {
          reqDec.receivePart(reqEnc.nextPart());
        }
        final parsedReq = CardanoSignRequestUr.fromCborBytes(reqDec.result!.cborPayload);
        expect(parsedReq.requestId, equals(req.requestId));

        final res = Sec01Guard.auditAndSign(
          request: parsedReq,
          masterKey: master,
          expectedNetwork: CardanoNetwork.preprod,
        );

        final resEnc = res.createEncoder(maxFragmentLen: 80);
        final resDec = UrDecoder();
        while (!resDec.isComplete) {
          resDec.receivePart(resEnc.nextPart());
        }
        final parsedRes = CardanoSignResponseUr.fromCborBytes(resDec.result!.cborPayload);
        expect(parsedRes.requestId, equals(req.requestId));
        expect(parsedRes.vkeyWitnesses.length, 1);

        final signedTx = ConwayTxSerializer.assembleSignedTransaction(
          txBodyCbor: parsedReq.txBodyCbor,
          witnesses: parsedRes.vkeyWitnesses,
        );
        expect(signedTx.isNotEmpty, isTrue);
      } finally {
        master.dispose();
        zeroize(entropy);
      }
    });
  });
}
