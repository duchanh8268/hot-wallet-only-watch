import 'dart:convert';
import 'dart:typed_data';

import 'package:cardano_core/cardano_core.dart';
import 'package:chain_core_interface/chain_core_interface.dart' hide Bip39, zeroize;
import 'package:flutter_test/flutter_test.dart';
import 'package:hot_wallet_web/chains/bitcoin/services/mempool_service.dart';
import 'package:hot_wallet_web/chains/solana/services/solana_rpc_service.dart';
import 'package:hot_wallet_web/chains/sui/services/sui_rpc_service.dart';
import 'package:hot_wallet_web/chains/sui/sui_hot_plugin.dart';
import 'package:hot_wallet_web/services/blockfrost_service.dart';
import 'package:hot_wallet_web/services/conway_tx_builder.dart';
import 'package:hot_wallet_web/services/hd_wallet_sync_service.dart';
import 'package:hot_wallet_web/services/hot_app_state.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('AUDIT-15: Fee/UTXO Bounds & Fail-Closed RPC Services', () {
    test('ProtocolParameters.fromBlockfrostJson clamps malicious out-of-range values', () {
      final pparams = ProtocolParameters.fromBlockfrostJson({
        'min_fee_a': 999999999,
        'min_fee_b': -500,
        'coins_per_utxo_size': 999999999,
        'key_deposit': '999999999999999',
        'pool_deposit': '-100',
        'max_tx_size': 100,
      });

      expect(pparams.minFeeA, 5000);
      expect(pparams.minFeeB, 0);
      expect(pparams.coinsPerUTxOByte, 100000);
      expect(pparams.keyDeposit, BigInt.from(20000000));
      expect(pparams.poolDeposit, BigInt.zero);
      expect(pparams.maxTxSize, 4096);
    });

    test('ConwayTxBuilder rejects excessive dust absorption and fee > 10 ADA', () {
      const mnemonic =
          'eight country switch draw meat scout mystery blade tip drift useless good keep usage title';
      final entropy = Bip39.mnemonicToEntropy(mnemonic);
      final master = CardanoMasterKey.fromEntropy(entropy);
      try {
        final acctXvkPub = master.exportAccountPublicKey();
        final acctXvk = acctXvkPub.toBech32();
        final recvAddr = acctXvkPub.deriveBaseAddress(
          role: 0,
          index: 0,
          network: CardanoNetwork.preprod,
        );
        final recipient = acctXvkPub.deriveBaseAddress(
          role: 0,
          index: 1,
          network: CardanoNetwork.preprod,
        );
        final stakeAddr = acctXvkPub.deriveRewardAddress(network: CardanoNetwork.preprod);

        // With minFeeB = 11_000_000 (11 ADA), tx fee exceeds 10 ADA safety limit
        final stateHighFee = WalletSyncState(
          totalLovelace: BigInt.from(30000000),
          totalMultiAsset: MultiAsset.empty,
          utxos: [
            DerivedUtxo(
              utxo: BlockfrostUtxo(
                txHash: 'a' * 64,
                outputIndex: 0,
                address: recvAddr,
                lovelace: BigInt.from(30000000),
                multiAsset: MultiAsset.empty,
              ),
              derivationRole: 0,
              derivationIndex: 0,
            ),
          ],
          primaryReceiveAddress: recvAddr,
          nextUnusedExternalAddress: recvAddr,
          nextUnusedInternalIndex: 0,
          stakeAddress: stakeAddr,
          stakeInfo: StakeAccountInfo.empty,
          assetMetadata: const {},
          recentTxs: const [],
          protocolParameters: ProtocolParameters(
            minFeeA: 44,
            minFeeB: 11000000,
            coinsPerUTxOByte: 4310,
            keyDeposit: BigInt.from(2000000),
            poolDeposit: BigInt.from(500000000),
            maxTxSize: 16384,
          ),
          latestSlot: 1000,
        );

        expect(
          () => ConwayTxBuilder.buildTransfer(
            profile: WatchOnlyProfile(
              id: 'p1',
              name: 'Test',
              network: CardanoNetwork.preprod,
              acctXvkBech32: acctXvk,
              createdAtMs: 1,
            ),
            syncState: stateHighFee,
            recipientAddress: recipient,
            lovelaceToSend: BigInt.from(2000000),
          ),
          throwsA(
            isA<Exception>().having(
              (e) => e.toString(),
              'message',
              contains('exceeds 10 ADA safety limit'),
            ),
          ),
        );

        // Inflated coinsPerUTxOByte raises pureAdaMinUtxo to ~4.54 ADA; ~2.82 ADA leftover surplus must NOT be silently burned into fee
        final stateDustTrap = WalletSyncState(
          totalLovelace: BigInt.from(8000000),
          totalMultiAsset: MultiAsset.empty,
          utxos: [
            DerivedUtxo(
              utxo: BlockfrostUtxo(
                txHash: 'b' * 64,
                outputIndex: 0,
                address: recvAddr,
                lovelace: BigInt.from(8000000),
                multiAsset: MultiAsset.empty,
              ),
              derivationRole: 0,
              derivationIndex: 0,
            ),
          ],
          primaryReceiveAddress: recvAddr,
          nextUnusedExternalAddress: recvAddr,
          nextUnusedInternalIndex: 0,
          stakeAddress: stakeAddr,
          stakeInfo: StakeAccountInfo.empty,
          assetMetadata: const {},
          recentTxs: const [],
          protocolParameters: ProtocolParameters(
            minFeeA: 44,
            minFeeB: 155381,
            coinsPerUTxOByte: 20000,
            keyDeposit: BigInt.from(2000000),
            poolDeposit: BigInt.from(500000000),
            maxTxSize: 16384,
          ),
          latestSlot: 1000,
        );

        expect(
          () => ConwayTxBuilder.buildTransfer(
            profile: WatchOnlyProfile(
              id: 'p1',
              name: 'Test',
              network: CardanoNetwork.preprod,
              acctXvkBech32: acctXvk,
              createdAtMs: 1,
            ),
            syncState: stateDustTrap,
            recipientAddress: recipient,
            lovelaceToSend: BigInt.from(5000000),
          ),
          throwsA(
            isA<Exception>().having(
              (e) => e.toString(),
              'message',
              contains('exceeds safe dust absorption limit'),
            ),
          ),
        );
      } finally {
        master.dispose();
        zeroize(entropy);
      }
    });

    test('MempoolUtxo rejects invalid txid, negative vout, and invalid value; fee rates clamp', () {
      expect(
        () => MempoolUtxo.fromJson({
          'txid': 'not-hex',
          'vout': 0,
          'value': 1000,
        }),
        throwsFormatException,
      );
      expect(
        () => MempoolUtxo.fromJson({
          'txid': 'a' * 64,
          'vout': -1,
          'value': 1000,
        }),
        throwsFormatException,
      );
      expect(
        () => MempoolUtxo.fromJson({
          'txid': 'a' * 64,
          'vout': 0,
          'value': 0,
        }),
        throwsFormatException,
      );

      final rates = MempoolFeeRates.fromJson({
        'fastestFee': 999999,
        'halfHourFee': 0,
        'hourFee': -5,
        'minimumFee': 999999,
      });
      expect(rates.fastestFee, 5000);
      expect(rates.halfHourFee, 1);
      expect(rates.hourFee, 1);
      expect(rates.minimumFee, 5000);
    });

    test('SolanaRpcService fails closed on RPC/HTTP errors without fake fallbacks', () async {
      final failingHttpClient = MockClient(
        (_) async => http.Response('Internal Server Error', 500),
      );
      final sol = SolanaRpcService(client: failingHttpClient);

      await expectLater(
        () => sol.getBalance(address: '11111111111111111111111111111111', networkId: 'devnet'),
        throwsException,
      );
      await expectLater(
        () => sol.getLatestBlockhash(networkId: 'devnet'),
        throwsException,
      );
      await expectLater(
        () => sol.sendTransaction(transactionBytes: Uint8List(80), networkId: 'devnet'),
        throwsException,
      );

      final rpcErrorClient = MockClient(
        (_) async => http.Response(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': 1,
            'error': {'message': 'Simulation failed'},
          }),
          200,
        ),
      );
      final solErr = SolanaRpcService(client: rpcErrorClient);
      await expectLater(
        () => solErr.sendTransaction(transactionBytes: Uint8List(80), networkId: 'devnet'),
        throwsException,
      );
    });

    test('SuiRpcService and SuiHotPlugin fail closed on RPC/HTTP errors without fake fallbacks', () async {
      final failingHttpClient = MockClient(
        (_) async => http.Response('Service Unavailable', 503),
      );
      final sui = SuiRpcService(client: failingHttpClient);

      await expectLater(
        () => sui.getBalance(address: '0x01', networkId: 'testnet'),
        throwsException,
      );
      await expectLater(
        () => sui.getCoins(address: '0x01', networkId: 'testnet'),
        throwsException,
      );
      await expectLater(
        () => sui.executeTransactionBlock(
          txBytesBase64: 'AAAA',
          signatures: ['BBBB'],
          networkId: 'testnet',
        ),
        throwsException,
      );

      final plugin = SuiHotPlugin.withRpc(sui);
      await expectLater(
        () => plugin.broadcastTransaction(
          network: const ChainNetwork(
            id: 'testnet',
            name: 'Sui Testnet',
            isTestnet: true,
            networkCode: 1,
          ),
          signedTxBytes: Uint8List.fromList(
            utf8.encode(jsonEncode({'txBytes': 'AAAA', 'signatures': ['BBBB']})),
          ),
        ),
        throwsException,
      );
    });

    test('AUDIT-19: validateCustomRpcUrl enforces HTTPS and permits localhost HTTP only', () {
      expect(() => HotAppState.validateCustomRpcUrl('https://rpc.example.com'), returnsNormally);
      expect(() => HotAppState.validateCustomRpcUrl('http://localhost:8545'), returnsNormally);
      expect(() => HotAppState.validateCustomRpcUrl('http://127.0.0.1:8899'), returnsNormally);
      expect(() => HotAppState.validateCustomRpcUrl('http://evil-rpc.example.com'), throwsArgumentError);
      expect(() => HotAppState.validateCustomRpcUrl('ftp://rpc.example.com'), throwsArgumentError);
      expect(() => HotAppState.validateCustomRpcUrl('not-a-url'), throwsArgumentError);
    });
  });
}
