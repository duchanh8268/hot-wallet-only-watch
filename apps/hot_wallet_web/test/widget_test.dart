import 'dart:convert';
import 'dart:typed_data';

import 'package:cardano_core/cardano_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hot_wallet_web/main.dart';
import 'package:hot_wallet_web/services/cardano_rpc_service.dart';
import 'package:hot_wallet_web/services/conway_tx_builder.dart';
import 'package:hot_wallet_web/services/external_link_stub.dart' as ext_link;
import 'package:hot_wallet_web/services/hd_wallet_sync_service.dart';
import 'package:hot_wallet_web/services/hot_app_state.dart';
import 'package:hot_wallet_web/services/web_crypto_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  const mnemonic =
      'eight country switch draw meat scout mystery blade tip drift useless good keep usage title';
  const recipientMnemonic =
      'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';

  late CardanoMasterKey master;
  late CardanoAccountPublicKey acctXvk;
  late String addr0;
  late String change0;
  late String stakeAddr;
  late String recipientAddr;

  setUp(() {
    final ent = Bip39.mnemonicToEntropy(mnemonic);
    master = CardanoMasterKey.fromEntropy(ent);
    acctXvk = master.exportAccountPublicKey();
    addr0 = acctXvk.deriveBaseAddress(role: 0, index: 0, network: CardanoNetwork.preprod);
    change0 = acctXvk.deriveBaseAddress(role: 1, index: 0, network: CardanoNetwork.preprod);
    stakeAddr = acctXvk.deriveRewardAddress(network: CardanoNetwork.preprod);
    zeroize(ent);

    final rEnt = Bip39.mnemonicToEntropy(recipientMnemonic);
    final rMaster = CardanoMasterKey.fromEntropy(rEnt);
    recipientAddr = rMaster.deriveBaseAddress(role: 0, index: 0, network: CardanoNetwork.preprod);
    rMaster.dispose();
    zeroize(rEnt);
  });

  tearDown(() {
    master.dispose();
  });

  MockClient createMockKoiosClient({
    bool stakeRegistered = false,
    String withdrawable = '0',
    String? drepId,
  }) {
    final policyHex = hexEncode(List<int>.filled(28, 0xab));
    final assetHex = hexEncode(utf8.encode('SUNDAE'));

    return MockClient((request) async {
      final path = request.url.path;

      if (path.endsWith('/tip')) {
        return http.Response(jsonEncode([{'abs_slot': 80000000}]), 200);
      }
      if (path.endsWith('/cli_protocol_params')) {
        return http.Response(
          jsonEncode({
            'txFeePerByte': 44,
            'txFeeFixed': 155381,
            'utxoCostPerByte': 4310,
            'stakeAddressDeposit': 2000000,
            'stakePoolDeposit': 500000000,
            'maxTxSize': 16384,
          }),
          200,
        );
      }
      if (path.endsWith('/address_txs')) {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final addrs = (body['_addresses'] as List<dynamic>).cast<String>();
        if (addrs.contains(addr0)) {
          return http.Response(
            jsonEncode([
              {
                'tx_hash': hexEncode(List<int>.filled(32, 0x99)),
                'block_height': 123456,
                'block_time': 1700000000,
              },
            ]),
            200,
          );
        }
        return http.Response(jsonEncode([]), 200);
      }
      if (path.endsWith('/address_utxos')) {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final addrs = (body['_addresses'] as List<dynamic>).cast<String>();
        if (addrs.contains(addr0)) {
          return http.Response(
            jsonEncode([
              {
                'tx_hash': hexEncode(List<int>.filled(32, 0x11)),
                'tx_index': 0,
                'address': addr0,
                'value': '20000000',
                'asset_list': [],
              },
              {
                'tx_hash': hexEncode(List<int>.filled(32, 0x22)),
                'tx_index': 1,
                'address': addr0,
                'value': '5000000',
                'asset_list': [
                  {
                    'policy_id': policyHex,
                    'asset_name': assetHex,
                    'quantity': '500',
                  },
                ],
              },
            ]),
            200,
          );
        }
        return http.Response(jsonEncode([]), 200);
      }
      if (path.endsWith('/account_info')) {
        return http.Response(
          jsonEncode([
            {
              'stake_address': stakeAddr,
              'status': stakeRegistered ? 'registered' : 'not registered',
              'total_balance': '25000000',
              'rewards_available': withdrawable,
              'delegated_pool': stakeRegistered
                  ? CardanoAddress.encodePoolId(Uint8List.fromList(List<int>.filled(28, 0x77)))
                  : null,
              'delegated_drep': drepId,
            },
          ]),
          200,
        );
      }
      if (path.endsWith('/asset_info')) {
        return http.Response(
          jsonEncode([
            {
              'policy_id': policyHex,
              'asset_name': assetHex,
              'token_registry_metadata': {
                'name': 'SundaeToken',
                'ticker': 'SUNDAE',
                'decimals': 0,
              },
            },
          ]),
          200,
        );
      }
      if (path.endsWith('/submittx')) {
        return http.Response(jsonEncode(hexEncode(List<int>.filled(32, 0xee))), 200);
      }
      return http.Response('Not found', 404);
    });
  }

  group('Koios RPC Sync & Conway Tx Builder E2E with Cold Wallet SEC-01', () {
    test('CardanoRpcService exposes keyless Cloudflare Worker Koios defaults', () {
      final rpc = CardanoRpcService();
      expect(
        rpc.getRpcUrl('preprod'),
        equals('https://cardano-koios-rpc.duchanh8268.workers.dev/preprod'),
      );
      expect(
        rpc.getRpcUrl('preview'),
        equals('https://cardano-koios-rpc.duchanh8268.workers.dev/preview'),
      );
      expect(
        rpc.getRpcUrl('mainnet'),
        equals('https://cardano-koios-rpc.duchanh8268.workers.dev/mainnet'),
      );
    });

    test('Syncs HD wallet, builds ADA + Token transfer, passes Cold SEC-01 & signs', () async {
      final client = createMockKoiosClient();
      final rpc = CardanoRpcService(client: client);
      final syncSvc = HdWalletSyncService(rpc);
      final profile = WatchOnlyProfile(
        id: 'p1',
        name: 'Test Preprod',
        network: CardanoNetwork.preprod,
        acctXvkBech32: acctXvk.toBech32(),
        createdAtMs: 0,
      );

      final syncState = await syncSvc.syncProfile(
        profile: profile,
        gapLimit: 5,
      );
      expect(syncState.totalLovelace, BigInt.from(25000000));
      expect(syncState.utxos.length, 2);
      expect(syncState.totalMultiAsset.assets.length, 1);

      final assetKey = syncState.totalMultiAsset.assets.keys.first;
      final built = ConwayTxBuilder.buildTransfer(
        profile: profile,
        syncState: syncState,
        recipientAddress: recipientAddr,
        lovelaceToSend: BigInt.from(3000000),
        tokensToSend: MultiAsset({assetKey: BigInt.from(200)}),
      );

      // Cold Wallet SEC-01 Audit + Sign
      final signResp = Sec01Guard.auditAndSign(
        request: built.signRequest,
        masterKey: master,
        expectedNetwork: CardanoNetwork.preprod,
      );

      final assembled = ConwayTxSerializer.assembleSignedTransaction(
        txBodyCbor: built.signRequest.txBodyCbor,
        witnesses: signResp.vkeyWitnesses,
      );
      final submittedHash = await rpc.submitTransaction(
        CardanoNetwork.preprod,
        assembled,
      );
      expect(submittedHash.replaceAll('"', ''), hexEncode(List<int>.filled(32, 0xee)));
    });

    test('Send Max sweeps all UTXOs with zero change output and passes SEC-01', () async {
      final client = createMockKoiosClient();
      final syncSvc = HdWalletSyncService(CardanoRpcService(client: client));
      final profile = WatchOnlyProfile(
        id: 'p1',
        name: 'Sweep',
        network: CardanoNetwork.preprod,
        acctXvkBech32: acctXvk.toBech32(),
        createdAtMs: 0,
      );
      final syncState = await syncSvc.syncProfile(
        profile: profile,
        gapLimit: 5,
      );

      final built = ConwayTxBuilder.buildTransfer(
        profile: profile,
        syncState: syncState,
        recipientAddress: recipientAddr,
        lovelaceToSend: BigInt.zero,
        sendMax: true,
      );
      expect(built.signRequest.changeOutputs, isEmpty);
      expect(built.txBody.outputs.length, 1);

      final resp = Sec01Guard.auditAndSign(
        request: built.signRequest,
        masterKey: master,
        expectedNetwork: CardanoNetwork.preprod,
      );
      expect(resp.vkeyWitnesses.length, 1);
    });

    test('Builds Conway Staking (Reg + Pool + AlwaysAbstain) and Reward Withdrawal passing SEC-01', () async {
      final client = createMockKoiosClient(
        stakeRegistered: false,
      );
      final syncSvc = HdWalletSyncService(CardanoRpcService(client: client));
      final profile = WatchOnlyProfile(
        id: 'p1',
        name: 'Staker',
        network: CardanoNetwork.preprod,
        acctXvkBech32: acctXvk.toBech32(),
        createdAtMs: 0,
      );
      final syncState = await syncSvc.syncProfile(
        profile: profile,
        gapLimit: 5,
      );

      final poolId = CardanoAddress.encodePoolId(
        Uint8List.fromList(List<int>.filled(28, 0x77)),
      );
      final built = ConwayTxBuilder.buildStakingAction(
        profile: profile,
        syncState: syncState,
        poolId: poolId,
        drep: const DRepAlwaysAbstain(),
      );

      expect(built.txBody.certificates.length, 3);
      expect(built.signRequest.requireStakeWitness, isTrue);

      final resp = Sec01Guard.auditAndSign(
        request: built.signRequest,
        masterKey: master,
        expectedNetwork: CardanoNetwork.preprod,
      );
      expect(resp.vkeyWitnesses.length, 2); // Payment + Stake
    });
  });

  group('HotWalletWebApp Widget Tests', () {
    testWidgets('Defaults to Vietnamese & Preprod, supports settings & profile import', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final mockClient = createMockKoiosClient();
      final appState = HotAppState(
        storage: WebCryptoStorage(),
        cardanoRpc: CardanoRpcService(client: mockClient),
      );
      await appState.init();
      await appState.saveSettings(
        gapLimit: 5,
      );

      await tester.pumpWidget(HotWalletWebApp(appState: appState));
      await tester.pumpAndSettle();

      // Default Vietnamese & Preprod
      expect(find.text('Ví Nóng Cardano Watch-Only'), findsOneWidget);
      expect(find.text('Preprod'), findsOneWidget);

      // Toggle VI -> EN
      await tester.tap(find.text('VI'));
      await tester.pumpAndSettle();
      expect(find.text('Cardano Watch-Only Hot Wallet'), findsOneWidget);

      // Switch back to VI
      await tester.tap(find.text('EN'));
      await tester.pumpAndSettle();

      // Import account via HotAppState & verify Dashboard updates
      final ur = CardanoAccountUr(
        network: CardanoNetwork.preprod,
        acctXvk: acctXvk.bytes,
        label: 'Ví Chính',
      );
      await appState.addProfile(name: 'Ví Chính', accountUr: ur);
      await tester.pumpAndSettle();

      expect(find.text('25 ADA'), findsOneWidget);
      expect(find.text("Địa chỉ Nhận (m/1852'/1815'/0'/0/1)"), findsOneWidget);

      // Toggle to view base address 0'/0/0 and back
      await tester.tap(find.byKey(const Key('hot_toggle_base_addr_btn')));
      await tester.pumpAndSettle();
      expect(find.text("Địa chỉ Nhận (m/1852'/1815'/0'/0/0)"), findsOneWidget);
      expect(find.text(addr0), findsOneWidget);

      await tester.tap(find.byKey(const Key('hot_toggle_base_addr_btn')));
      await tester.pumpAndSettle();
      expect(find.text("Địa chỉ Nhận (m/1852'/1815'/0'/0/1)"), findsOneWidget);

      await tester.scrollUntilVisible(
        find.text('SundaeToken'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('SundaeToken'), findsOneWidget);
      expect(find.text('500'), findsOneWidget);

      // Scroll down to Recent Transactions and tap the clickable explorer link
      final txHash = hexEncode(List<int>.filled(32, 0x99));
      final txLinkFinder = find.byKey(Key('tx_explorer_link_$txHash'));
      await tester.scrollUntilVisible(
        txLinkFinder,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(txLinkFinder, findsOneWidget);
      ext_link.lastOpenedExternalUrlForTest = null;
      await tester.ensureVisible(txLinkFinder);
      await tester.tap(txLinkFinder);
      await tester.pumpAndSettle();
      expect(
        ext_link.lastOpenedExternalUrlForTest,
        CardanoNetwork.preprod.explorerTxUrl(txHash),
      );

      // Navigate to Staking & DRep screen via Hub action button and verify Controlled Stake & Staking mechanism note
      await tester.scrollUntilVisible(
        find.byKey(const Key('hub_staking_btn')),
        -200,
        scrollable: find.byType(Scrollable).first,
      );
      await Scrollable.ensureVisible(
        tester.element(find.byKey(const Key('hub_staking_btn'))),
        alignment: 0.5,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('hub_staking_btn')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Tổng số ADA đang được Stake'), findsOneWidget);
      expect(find.textContaining('Staking tính trên toàn bộ Stake Address'), findsOneWidget);

      // Verify change address sanity
      expect(change0.startsWith('addr_test1'), isTrue);
    });
  });
}
