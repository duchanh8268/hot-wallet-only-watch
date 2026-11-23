import 'dart:convert';
import 'dart:typed_data';

import 'package:bitcoin_core/bitcoin_core.dart';
import 'package:chain_core_interface/chain_core_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hot_wallet_web/chains/bitcoin/bitcoin_hot_plugin.dart';
import 'package:hot_wallet_web/chains/bitcoin/models/btc_profile.dart';
import 'package:hot_wallet_web/chains/bitcoin/services/btc_hd_sync_service.dart';
import 'package:hot_wallet_web/chains/bitcoin/services/mempool_service.dart';
import 'package:hot_wallet_web/core/services/hot_chain_registry.dart';
import 'package:hot_wallet_web/services/hot_app_state.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('BitcoinHotPlugin & MempoolService Tests', () {
    test('HotChainRegistry contains Bitcoin plugin', () {
      final registry = HotChainRegistry();
      final btc = registry.getPlugin(ChainId.bitcoin);

      expect(btc.chainId, equals(ChainId.bitcoin));
      expect(btc.displayName, equals('Bitcoin'));
      expect(registry.findPluginForUr('btc-account'), isNotNull);
      expect(registry.findPluginForUr('btc-sign-request'), isNotNull);
      expect(registry.findPluginForUr('btc-sign-response'), isNotNull);
    });

    test('Assembles valid signed SegWit transaction from Cold Wallet response', () {
      final plugin = BitcoinHotPlugin.instance;

      final input = BtcTxIn(
        previousOutput: const OutPoint(
          txid: '1111111111111111111111111111111111111111111111111111111111111111',
          vout: 0,
        ),
        amountSat: BigInt.from(100000),
      );
      final output = BtcTxOut(
        valueSat: BigInt.from(95000),
        scriptPubKey: Uint8List.fromList([0x00, 0x14, ...List.filled(20, 0xaa)]),
      );
      final unsignedTx = BtcTransaction(
        version: 2,
        inputs: [input],
        outputs: [output],
      );

      final dummySig = Uint8List.fromList(List.filled(71, 0x30));
      final dummyPub = Uint8List.fromList(List.filled(33, 0x02));
      final resp = BtcSignResponseUr(
        requestId: Uint8List.fromList(List.filled(16, 0x42)),
        witnesses: [
          BtcWitness([dummySig, dummyPub]),
        ],
      );

      final signedTx = plugin.assembleSignedTx(
        originalTx: unsignedTx,
        response: resp,
      );

      expect(signedTx.hasWitness, isTrue);
      expect(signedTx.inputs[0].witness.items.length, equals(2));

      final rawBytes = BtcSerializer.serialize(signedTx);
      expect(rawBytes.length, greaterThan(100));

      final txid = BtcSerializer.computeTxId(signedTx);
      expect(txid.length, equals(64));
    });

    test('MempoolService interacts with mock API endpoints', () async {
      final mockClient = MockClient((request) async {
        final path = request.url.path;

        if (path.contains('/utxo')) {
          return http.Response(
            jsonEncode([
              {
                'txid': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
                'vout': 0,
                'value': 50000,
                'status': {'confirmed': true, 'block_height': 850000},
              },
            ]),
            200,
          );
        } else if (path.contains('/v1/fees/recommended')) {
          return http.Response(
            jsonEncode({
              'fastestFee': 20,
              'halfHourFee': 15,
              'hourFee': 8,
              'minimumFee': 2,
            }),
            200,
          );
        } else if (path.endsWith('/tx')) {
          return http.Response('bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb', 200);
        } else if (path.endsWith('/raw')) {
          return http.Response.bytes(Uint8List.fromList([0x02, 0x00, 0x00, 0x00, 0xaa]), 200);
        }
        return http.Response('Not found', 404);
      });

      final service = MempoolService(client: mockClient);

      final utxos = await service.getUtxos('testnet4', 'tb1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu');
      expect(utxos.length, equals(1));
      expect(utxos.first.valueSat, equals(BigInt.from(50000)));
      expect(utxos.first.confirmed, isTrue);

      final rawBytes = await service.getRawTxBytes(
        'testnet4',
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      );
      expect(rawBytes, equals(Uint8List.fromList([0x02, 0x00, 0x00, 0x00, 0xaa])));
      expect(() => service.getRawTxBytes('testnet4', 'bad-txid'), throwsFormatException);

      final fees = await service.getRecommendedFees('testnet4');
      expect(fees.fastestFee, equals(20));
      expect(fees.hourFee, equals(8));

      final broadcastTxid = await service.broadcastRawTx('testnet4', '02000000000101...');
      expect(broadcastTxid, equals('bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'));
    });

    test('HotAppState manages Bitcoin watch-only profiles and demo data', () async {
      final appState = HotAppState();
      appState.setActiveChain(ChainId.bitcoin);

      expect(appState.activeChainId, equals(ChainId.bitcoin));
      expect(appState.activeChainPlugin.displayName, equals('Bitcoin'));

      final prof = await appState.addBtcProfile(
        name: 'My BTC Vault',
        receiveAddress: 'tb1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu',
        networkId: 'testnet4',
        accountIndex: 0,
      );

      expect(appState.allBtcProfiles.length, equals(1));
      expect(appState.activeBtcProfile?.name, equals('My BTC Vault'));
      expect(appState.activeBtcProfile?.receiveAddress, equals('tb1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu'));

      // Demo data
      appState.loadDemoBtcData();
      final state = appState.btcAccountState;
      expect(state, isNotNull);
      expect(state!['balanceSat'], equals('1500000'));
      expect(state['utxoCount'], equals(2));

      await appState.deleteBtcProfile(prof.id);
      expect(appState.allBtcProfiles.isEmpty, isTrue);
    });

    test('BtcHdWalletSyncService scans change 0 & 1 and builds change=1 tx passing BtcSec01Guard', () async {
      const mnemonic =
          'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
      final entropy = Bip39.mnemonicToEntropy(mnemonic);
      final master = BtcHdKey.fromSeed(Bip39.mnemonicToSeed(mnemonic));
      final acctPub = master.exportBip84AccountPublicKey(accountIndex: 0, isTestnet: true);
      final addrExt0 = acctPub.deriveP2wpkhAddress(change: 0, addressIndex: 0);
      final addrChg0 = acctPub.deriveP2wpkhAddress(change: 1, addressIndex: 0);
      final expectedNextChg1 = acctPub.deriveP2wpkhAddress(change: 1, addressIndex: 1);

      final keyChg0 = master.deriveBip84Address(
        accountIndex: 0,
        change: 1,
        addressIndex: 0,
        isTestnet: true,
      );
      final fundingTx = BtcTransaction(
        version: 2,
        inputs: [
          BtcTxIn(
            previousOutput: const OutPoint(
              txid: '2222222222222222222222222222222222222222222222222222222222222222',
              vout: 0,
            ),
          ),
        ],
        outputs: [
          BtcTxOut.p2wpkh(valueSat: BigInt.from(80000), program20: keyChg0.pubKeyHash),
        ],
      );
      final fundingRaw = BtcSerializer.serialize(fundingTx);
      final fundingTxId = BtcSerializer.computeTxId(fundingTx);

      final mockClient = MockClient((request) async {
        final path = request.url.path;
        if (path.endsWith('/address/$addrExt0')) {
          return http.Response(
            jsonEncode({
              'address': addrExt0,
              'chain_stats': {'tx_count': 1},
              'mempool_stats': {'tx_count': 0},
            }),
            200,
          );
        }
        if (path.endsWith('/address/$addrChg0')) {
          return http.Response(
            jsonEncode({
              'address': addrChg0,
              'chain_stats': {'tx_count': 1},
              'mempool_stats': {'tx_count': 0},
            }),
            200,
          );
        }
        if (path.contains('/address/') && !path.endsWith('/utxo') && !path.endsWith('/txs')) {
          return http.Response(
            jsonEncode({
              'chain_stats': {'tx_count': 0},
              'mempool_stats': {'tx_count': 0},
            }),
            200,
          );
        }
        if (path.endsWith('/address/$addrChg0/utxo')) {
          return http.Response(
            jsonEncode([
              {
                'txid': fundingTxId,
                'vout': 0,
                'value': 80000,
                'status': {'confirmed': true, 'block_height': 100},
              },
            ]),
            200,
          );
        }
        if (path.endsWith('/utxo') || path.endsWith('/txs')) {
          return http.Response('[]', 200);
        }
        return http.Response('Not found', 404);
      });

      final mempool = MempoolService(client: mockClient);
      final hdSync = BtcHdWalletSyncService(mempool);
      final profile = BtcWatchOnlyProfile(
        id: 'btc_hd_1',
        name: 'HD Testnet',
        networkId: 'testnet4',
        receiveAddress: addrExt0,
        accountIndex: 0,
        accountXpub: acctPub.toExtendedKey(),
      );

      final synced = await hdSync.syncProfile(
        profile: profile,
        networkId: 'testnet4',
        gapLimit: 3,
      );

      expect(synced.isHdSynced, isTrue);
      expect(synced.totalSat, equals(BigInt.from(80000)));
      expect(synced.utxos.length, equals(1));
      expect(synced.utxos.first.change, equals(1));
      expect(synced.utxos.first.addressIndex, equals(0));
      expect(synced.nextUnusedExternalIndex, equals(1));
      expect(synced.nextUnusedChangeIndex, equals(1));
      expect(synced.nextUnusedChangeAddress, equals(expectedNextChg1));

      // Build tx spending change=1/0 and returning new change to change=1/1
      final built = BtcTxBuilder.buildP2wpkhTx(
        availableUtxos: [
          BtcUtxo(
            outpoint: OutPoint(txid: fundingTxId, vout: 0),
            valueSat: BigInt.from(80000),
            accountIndex: 0,
            change: synced.utxos.first.change,
            addressIndex: synced.utxos.first.addressIndex,
            nonWitnessUtxo: fundingRaw,
          ),
        ],
        recipientAddress: 'tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx',
        amountSat: BigInt.from(30000),
        changeAddress: synced.nextUnusedChangeAddress,
        changeIndex: synced.nextUnusedChangeIndex,
        feeRateSatPerVb: 5,
      );

      final signReq = BtcSignRequestUr(
        requestId: Uint8List.fromList(List.filled(16, 0x33)),
        chain: 'bitcoin',
        network: 'testnet4',
        transaction: built.transaction,
        accountIndex: 0,
        feeSat: built.feeSat,
      );

      final signResp = BtcSec01Guard.auditAndSign(
        entropy: entropy,
        request: signReq,
        expectedAccountIndex: 0,
        expectedNetwork: 'testnet4',
      );
      expect(signResp.witnesses.length, equals(1));

      master.dispose();
      keyChg0.dispose();
    });
  });
}
