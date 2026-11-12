import 'dart:convert';

import 'package:cardano_core/cardano_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hot_wallet_web/main.dart';
import 'package:hot_wallet_web/screens/dashboard_screen.dart';
import 'package:hot_wallet_web/screens/send_tx_screen.dart';
import 'package:hot_wallet_web/services/blockfrost_service.dart';
import 'package:hot_wallet_web/services/conway_tx_builder.dart';
import 'package:hot_wallet_web/services/hd_wallet_sync_service.dart';
import 'package:hot_wallet_web/services/hot_app_state.dart';
import 'package:hot_wallet_web/services/web_crypto_storage.dart';
import 'package:hot_wallet_web/utils/token_utils.dart';
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
  late String addr1;
  late String stakeAddr;
  late String recipientAddr;

  setUp(() {
    final ent = Bip39.mnemonicToEntropy(mnemonic);
    master = CardanoMasterKey.fromEntropy(ent);
    acctXvk = master.exportAccountPublicKey();
    addr0 = acctXvk.deriveBaseAddress(role: 0, index: 0, network: CardanoNetwork.preprod);
    addr1 = acctXvk.deriveBaseAddress(role: 0, index: 1, network: CardanoNetwork.preprod);
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

  group('Token formatting and parsing', () {
    test('formats and parses decimal and integer token quantities', () {
      expect(formatTokenAmount(BigInt.from(125500000), 6), '125.5');
      expect(formatTokenAmount(BigInt.from(1705631351), 6), '1,705.631351');
      expect(formatTokenAmount(BigInt.from(1000000), 6), '1');
      expect(formatTokenAmount(BigInt.from(5), 6), '0.000005');
      expect(formatTokenAmount(BigInt.from(250000), 0), '250,000');
      expect(
        formatTokenAmount(BigInt.from(250000), 0, includeGrouping: false),
        '250000',
      );

      expect(parseTokenAmount('1,705.631351', 6), BigInt.from(1705631351));
      expect(parseTokenAmount('125.5', 6), BigInt.from(125500000));
      expect(parseTokenAmount('0.000005', 6), BigInt.from(5));
      expect(parseTokenAmount('250,000', 0), BigInt.from(250000));
      expect(() => parseTokenAmount('1.5', 0), throwsFormatException);
      expect(() => parseTokenAmount('1.1234567', 6), throwsFormatException);
    });

    test('parses decimals from onchain_metadata when registry metadata is null', () async {
      final client = MockClient((req) async {
        return http.Response(
          jsonEncode({
            'fingerprint': 'asset1mwmj9cp99pa9wg4evkucsrj6uk0vdkeektksl',
            'metadata': null,
            'onchain_metadata': {
              'name': 'MIN',
              'ticker': 'MIN',
              'decimals': '6',
            },
            'onchain_metadata_standard': 'CIP68v1',
          }),
          200,
        );
      });
      final bf = BlockfrostService(client: client);
      final meta = await bf.getAssetMetadata(
        CardanoNetwork.preprod,
        'key',
        'c16c2dc80000000000000000000000000000000000000000000000009fed72',
      );
      expect(meta, isNotNull);
      expect(meta!.decimals, 6);
      expect(meta.ticker, 'MIN');
      expect(meta.name, 'MIN');
    });

    test('resolves CIP-67/CIP-68 prefixed asset names', () {
      final policy = hexEncode(List<int>.filled(28, 0xaa));
      final cip68Hex = '000de140${hexEncode(utf8.encode('SpaceBudz'))}';
      final key = AssetKey(policy, cip68Hex);
      expect(resolveAssetDisplayName(key, null), 'SpaceBudz');
      expect(
        resolveAssetDisplayName(
          key,
          AssetMetadataInfo(unit: key.unit, name: 'Custom Name'),
        ),
        'Custom Name',
      );
    });
  });

  group('UTXO Pagination, Batched Metadata & Multi-Token ConwayTxBuilder', () {
    test('paginates >100 UTXOs and tolerates missing/failing asset metadata', () async {
      final policyA = hexEncode(List<int>.filled(28, 0xa1));
      final policyB = hexEncode(List<int>.filled(28, 0xb2));
      final assets = [
        for (var i = 0; i < 7; i++)
          AssetKey(i % 2 == 0 ? policyA : policyB, hexEncode(utf8.encode('TOK$i'))),
      ];

      final client = MockClient((req) async {
        final path = req.url.path;
        if (path.endsWith('/blocks/latest')) {
          return http.Response(jsonEncode({'slot': 90000000}), 200);
        }
        if (path.endsWith('/epochs/latest/parameters')) {
          return http.Response(
            jsonEncode({
              'min_fee_a': 44,
              'min_fee_b': 155381,
              'coins_per_utxo_size': '4310',
              'key_deposit': '2000000',
              'pool_deposit': '500000000',
              'max_tx_size': 16384,
            }),
            200,
          );
        }
        if (path.endsWith('/addresses/$addr0/transactions')) {
          return http.Response(
            jsonEncode([
              {'tx_hash': hexEncode(List<int>.filled(32, 0x11)), 'block_height': 1, 'block_time': 1},
            ]),
            200,
          );
        }
        if (path.endsWith('/addresses/$addr0/utxos')) {
          final page = int.tryParse(req.url.queryParameters['page'] ?? '1') ?? 1;
          if (page == 1) {
            return http.Response(
              jsonEncode([
                for (var i = 0; i < 100; i++)
                  {
                    'tx_hash': hexEncode(List<int>.filled(32, i % 250)),
                    'output_index': i,
                    'amount': [
                      {'unit': 'lovelace', 'quantity': '2000000'},
                      if (i < 6) {'unit': assets[i].unit, 'quantity': '100'},
                    ],
                  },
              ]),
              200,
            );
          }
          return http.Response(
            jsonEncode([
              {
                'tx_hash': hexEncode(List<int>.filled(32, 0xfe)),
                'output_index': 0,
                'amount': [
                  {'unit': 'lovelace', 'quantity': '3000000'},
                  {'unit': assets[6].unit, 'quantity': '50'},
                ],
              },
            ]),
            200,
          );
        }
        if (path.contains('/addresses/') && path.endsWith('/transactions')) {
          return http.Response(jsonEncode([]), 200);
        }
        if (path.contains('/addresses/') && path.endsWith('/utxos')) {
          return http.Response(jsonEncode([]), 200);
        }
        if (path.endsWith('/accounts/$stakeAddr')) {
          return http.Response('Not found', 404);
        }
        if (path.endsWith('/assets/${assets[3].unit}')) {
          // Simulate failure on one metadata request
          return http.Response('Server Error', 500);
        }
        if (path.contains('/assets/')) {
          final unit = path.split('/').last;
          return http.Response(
            jsonEncode({
              'fingerprint': 'asset1test$unit'.substring(0, 20),
              'metadata': {'name': 'Token $unit', 'ticker': 'TK', 'decimals': 2},
            }),
            200,
          );
        }
        return http.Response('Not found', 404);
      });

      final bf = BlockfrostService(client: client);
      final syncSvc = HdWalletSyncService(bf);
      final profile = WatchOnlyProfile(
        id: 'p_paginated',
        name: 'Paginated',
        network: CardanoNetwork.preprod,
        acctXvkBech32: acctXvk.toBech32(),
        createdAtMs: 0,
      );

      final syncState = await syncSvc.syncProfile(
        profile: profile,
        projectId: 'key',
        gapLimit: 3,
      );

      expect(syncState.utxos.length, 101);
      expect(syncState.totalMultiAsset.assets.length, 7);
      expect(syncState.totalMultiAsset[assets[6]], BigInt.from(50));
      // Failed metadata on assets[3] did not abort sync or drop assets[3]
      expect(syncState.assetMetadata.containsKey(assets[3].unit), isFalse);
      expect(syncState.assetMetadata.containsKey(assets[0].unit), isTrue);
    });

    test('builds multi-token tx with autoMinAda, exact fee convergence, and passes SEC-01', () {
      final profile = WatchOnlyProfile(
        id: 'p_multi',
        name: 'Multi',
        network: CardanoNetwork.preprod,
        acctXvkBech32: acctXvk.toBech32(),
        createdAtMs: 0,
      );

      final appState = HotAppState(storage: WebCryptoStorage());
      appState.loadDemoPreprodData(); // wait - needs activeProfile, let's build syncState directly
      final p1 = 'a0028f350aaabe0545fdcb56b039bfb08e4bb4d8c4d7c3c7d481c235';
      final p2 = '29d222ce763455e3d7a09a665ce554f00ac89d2e99a1a83d267170c6';
      final k1 = AssetKey(p1, hexEncode(utf8.encode('tHOSKY')));
      final k2 = AssetKey(p2, hexEncode(utf8.encode('tMIN')));
      final k3 = AssetKey(p2, hexEncode(utf8.encode('DemoNFT')));

      final utxos = [
        DerivedUtxo(
          utxo: BlockfrostUtxo(
            txHash: hexEncode(List<int>.filled(32, 0x01)),
            outputIndex: 0,
            address: addr0,
            lovelace: BigInt.from(20000000),
            multiAsset: MultiAsset({k1: BigInt.from(500), k2: BigInt.from(10000000)}),
          ),
          derivationRole: 0,
          derivationIndex: 0,
        ),
        DerivedUtxo(
          utxo: BlockfrostUtxo(
            txHash: hexEncode(List<int>.filled(32, 0x02)),
            outputIndex: 1,
            address: addr1,
            lovelace: BigInt.from(5000000),
            multiAsset: MultiAsset({k3: BigInt.one}),
          ),
          derivationRole: 0,
          derivationIndex: 1,
        ),
      ];

      final syncState = WalletSyncState(
        totalLovelace: BigInt.from(25000000),
        totalMultiAsset: MultiAsset({
          k1: BigInt.from(500),
          k2: BigInt.from(10000000),
          k3: BigInt.one,
        }),
        utxos: utxos,
        primaryReceiveAddress: addr0,
        nextUnusedExternalAddress: addr1,
        nextUnusedInternalIndex: 0,
        stakeAddress: stakeAddr,
        stakeInfo: StakeAccountInfo.empty,
        assetMetadata: const {},
        recentTxs: const [],
        protocolParameters: ProtocolParameters.cardanoDefaults,
        latestSlot: 90000000,
      );

      final tokensToSend = MultiAsset({
        k1: BigInt.from(200),
        k2: BigInt.from(5000000),
        k3: BigInt.one,
      });

      final built = ConwayTxBuilder.buildTransfer(
        profile: profile,
        syncState: syncState,
        recipientAddress: recipientAddr,
        lovelaceToSend: BigInt.zero,
        tokensToSend: tokensToSend,
        autoMinAda: true,
      );

      expect(built.txBody.outputs.length, 2);
      expect(built.txBody.outputs[0].lovelace, built.recipientMinAda);
      expect(built.txBody.outputs[0].multiAsset, tokensToSend);
      expect(built.txBody.outputs[1].multiAsset[k1], BigInt.from(300));
      expect(built.txBody.outputs[1].multiAsset[k2], BigInt.from(5000000));
      expect(built.txBody.outputs[1].multiAsset[k3], BigInt.zero);

      // Verify Cold Wallet SEC-01 audit + exact fee check
      final signResp = Sec01Guard.auditAndSign(
        request: built.signRequest,
        masterKey: master,
        expectedNetwork: CardanoNetwork.preprod,
      );
      final signed = ConwayTxSerializer.assembleSignedTransaction(
        txBodyCbor: built.signRequest.txBodyCbor,
        witnesses: signResp.vkeyWitnesses,
      );
      final minFee = BigInt.from(
        ProtocolParameters.cardanoDefaults.minFeeA * signed.length +
            ProtocolParameters.cardanoDefaults.minFeeB,
      );
      expect(built.fee, minFee);
    });

    test('Send Max ADA keeps remaining tokens in change and maximizes recipient ADA', () {
      final profile = WatchOnlyProfile(
        id: 'p_max_ada',
        name: 'MaxAda',
        network: CardanoNetwork.preprod,
        acctXvkBech32: acctXvk.toBech32(),
        createdAtMs: 0,
      );
      final p1 = 'a0028f350aaabe0545fdcb56b039bfb08e4bb4d8c4d7c3c7d481c235';
      final k1 = AssetKey(p1, hexEncode(utf8.encode('tHOSKY')));

      final syncState = WalletSyncState(
        totalLovelace: BigInt.from(15000000),
        totalMultiAsset: MultiAsset({k1: BigInt.from(500)}),
        utxos: [
          DerivedUtxo(
            utxo: BlockfrostUtxo(
              txHash: hexEncode(List<int>.filled(32, 0x01)),
              outputIndex: 0,
              address: addr0,
              lovelace: BigInt.from(10000000),
              multiAsset: MultiAsset.empty,
            ),
            derivationRole: 0,
            derivationIndex: 0,
          ),
          DerivedUtxo(
            utxo: BlockfrostUtxo(
              txHash: hexEncode(List<int>.filled(32, 0x02)),
              outputIndex: 0,
              address: addr1,
              lovelace: BigInt.from(5000000),
              multiAsset: MultiAsset({k1: BigInt.from(500)}),
            ),
            derivationRole: 0,
            derivationIndex: 1,
          ),
        ],
        primaryReceiveAddress: addr0,
        nextUnusedExternalAddress: addr1,
        nextUnusedInternalIndex: 0,
        stakeAddress: stakeAddr,
        stakeInfo: StakeAccountInfo.empty,
        assetMetadata: const {},
        recentTxs: const [],
        protocolParameters: ProtocolParameters.cardanoDefaults,
        latestSlot: 90000000,
      );

      final built = ConwayTxBuilder.buildTransfer(
        profile: profile,
        syncState: syncState,
        recipientAddress: recipientAddr,
        lovelaceToSend: BigInt.zero,
        sendMax: true,
        keepRemainingTokens: true,
      );

      // Should consolidate both UTXOs because UTXO #2 frees ~3.8 ADA above its changeMinAda
      expect(built.txBody.inputs.length, 2);
      expect(built.txBody.outputs.length, 2);
      expect(built.txBody.outputs[0].lovelace, greaterThan(BigInt.from(13000000)));
      expect(built.txBody.outputs[1].multiAsset[k1], BigInt.from(500));
      expect(built.txBody.outputs[1].lovelace, built.changeMinAda);

      final signResp = Sec01Guard.auditAndSign(
        request: built.signRequest,
        masterKey: master,
        expectedNetwork: CardanoNetwork.preprod,
      );
      expect(signResp.vkeyWitnesses.length, 2);
    });
  });

  group('Dashboard & SendTxScreen Widget Tests', () {
    Future<HotAppState> createLoadedState() async {
      final appState = HotAppState(storage: WebCryptoStorage());
      await appState.init();
      await appState.addProfile(
        name: 'Demo Wallet',
        accountUr: CardanoAccountUr(
          network: CardanoNetwork.preprod,
          acctXvk: acctXvk.bytes,
          accountIndex: 0,
          label: 'Demo Wallet',
        ),
      );
      appState.loadDemoPreprodData();
      return appState;
    }

    void setMobileViewport(WidgetTester tester) {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
    }

    testWidgets('Dashboard displays decimal-formatted tokens, search/filter, and UTXO tokens', (tester) async {
      setMobileViewport(tester);
      final appState = await createLoadedState();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DashboardScreen(
              appState: appState,
              onOpenAccounts: () {},
              onOpenSettings: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Shows 3 native tokens from demo data with decimal formatting (125.5 tMIN)
      await tester.scrollUntilVisible(
        find.byKey(const Key('dashboard_token_search_field')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Cold Wallet Demo NFT'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(find.text('Test Minswap Token'), findsOneWidget);
      expect(find.text('125.5'), findsOneWidget);
      expect(find.text('Test HOSKY Token'), findsOneWidget);
      expect(find.text('Cold Wallet Demo NFT'), findsOneWidget);

      // Filter by NFT only
      await tester.scrollUntilVisible(
        find.byKey(const Key('dashboard_filter_nft')),
        -200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byKey(const Key('dashboard_filter_nft')));
      await tester.pumpAndSettle();
      expect(find.text('Cold Wallet Demo NFT'), findsOneWidget);
      expect(find.text('Test Minswap Token'), findsNothing);

      // Back to All and search
      await tester.tap(find.byKey(const Key('dashboard_filter_all')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('dashboard_token_search_field')),
        'tMIN',
      );
      await tester.pumpAndSettle();
      expect(find.text('Test Minswap Token'), findsOneWidget);
      expect(find.text('Test HOSKY Token'), findsNothing);
    });

    testWidgets('SendTxScreen picker shows only wallet tokens, prevents duplicates, and auto-calculates Min-ADA & Fee', (tester) async {
      setMobileViewport(tester);
      final appState = await createLoadedState();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SendTxScreen(appState: appState),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Open token picker
      await tester.tap(find.byKey(const Key('add_token_picker_btn')));
      await tester.pumpAndSettle();

      // Only the 3 wallet tokens appear in picker
      expect(find.text('Test HOSKY Token (tHOSKY)'), findsOneWidget);
      expect(find.text('Test Minswap Token (tMIN)'), findsOneWidget);
      expect(find.text('Cold Wallet Demo NFT'), findsOneWidget);

      // Pick tMIN (decimals = 6)
      await tester.tap(find.text('Test Minswap Token (tMIN)'));
      await tester.pumpAndSettle();

      // Auto Min-ADA populated ADA field and live preview appeared
      final adaField = tester.widget<TextField>(find.byKey(const Key('send_ada_field')));
      expect(adaField.controller!.text, isNotEmpty);
      await tester.scrollUntilVisible(
        find.byKey(const Key('tx_live_preview_card')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.byKey(const Key('tx_live_preview_card')), findsOneWidget);

      // Open picker again: tMIN is no longer listed in the picker dialog, only remaining 2 tokens
      await tester.tap(find.byKey(const Key('add_token_picker_btn')));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Test Minswap Token (tMIN)'),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Test HOSKY Token (tHOSKY)'),
        ),
        findsOneWidget,
      );

      // Pick tHOSKY too (multi-token in 1 tx)
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Test HOSKY Token (tHOSKY)'),
        ),
      );
      await tester.pumpAndSettle();

      // Enter decimal qty for tMIN and Max for tHOSKY
      const p1 = 'a0028f350aaabe0545fdcb56b039bfb08e4bb4d8c4d7c3c7d481c235';
      const p2 = '29d222ce763455e3d7a09a665ce554f00ac89d2e99a1a83d267170c6';
      const tMinUnit = '${p2}744d494e';
      const tHoskyUnit = '${p1}74484f534b59';

      await tester.scrollUntilVisible(
        find.byKey(const Key('token_qty_field_$tMinUnit')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(find.byKey(const Key('token_qty_field_$tMinUnit')), '12.5');
      await tester.scrollUntilVisible(
        find.byKey(const Key('token_max_btn_$tHoskyUnit')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byKey(const Key('token_max_btn_$tHoskyUnit')));
      await tester.scrollUntilVisible(
        find.byKey(const Key('send_recipient_field')),
        -200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(find.byKey(const Key('send_recipient_field')), recipientAddr);
      await tester.pumpAndSettle();

      // Build & navigate to BroadcastFlowScreen
      await tester.scrollUntilVisible(
        find.byKey(const Key('build_sign_qr_btn')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byKey(const Key('build_sign_qr_btn')));
      await tester.pumpAndSettle();

      // BroadcastFlowScreen shows both tokens in Transfer Summary
      expect(find.textContaining('12.5 tMIN'), findsOneWidget);
      expect(find.textContaining('250,000 tHOSKY'), findsOneWidget);
    });

    testWidgets('SendTxScreen clears selected tokens when switching wallet profile', (tester) async {
      setMobileViewport(tester);
      final appState = await createLoadedState();

      await tester.pumpWidget(HotWalletWebApp(appState: appState));
      await tester.pumpAndSettle();

      // Navigate to Send screen via Hub action button
      await tester.scrollUntilVisible(
        find.byKey(const Key('hub_send_tx_btn')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await Scrollable.ensureVisible(
        tester.element(find.byKey(const Key('hub_send_tx_btn'))),
        alignment: 0.5,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('hub_send_tx_btn')));
      await tester.pumpAndSettle();

      // Add a token
      await tester.ensureVisible(find.byKey(const Key('add_token_picker_btn')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('add_token_picker_btn')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Test HOSKY Token (tHOSKY)'));
      await tester.pumpAndSettle();

      const tHoskyUnit = 'a0028f350aaabe0545fdcb56b039bfb08e4bb4d8c4d7c3c7d481c23574484f534b59';
      expect(find.byKey(const Key('selected_token_card_$tHoskyUnit')), findsOneWidget);

      // Add a second profile with no tokens -> active profile switches & syncState becomes null
      final rEnt = Bip39.mnemonicToEntropy(recipientMnemonic);
      final rMaster = CardanoMasterKey.fromEntropy(rEnt);
      final rXvk = rMaster.exportAccountPublicKey();
      rMaster.dispose();
      zeroize(rEnt);

      await appState.addProfile(
        name: 'Empty Wallet',
        accountUr: CardanoAccountUr(
          network: CardanoNetwork.preprod,
          acctXvk: rXvk.bytes,
          accountIndex: 0,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('selected_token_card_$tHoskyUnit')), findsNothing);
    });

    testWidgets('Wallet profile manager opens from top-right AppBar button without separate tab', (tester) async {
      setMobileViewport(tester);
      final appState = await createLoadedState();

      await tester.pumpWidget(HotWalletWebApp(appState: appState));
      await tester.pumpAndSettle();

      // Separate "Hồ sơ Ví" tab is removed
      expect(find.text('Hồ sơ Ví'), findsNothing);

      // Top-right wallet button shows active profile and opens manager dialog
      final walletBtn = find.byKey(const Key('wallet_profile_menu_btn'));
      expect(walletBtn, findsOneWidget);
      await tester.tap(walletBtn);
      await tester.pumpAndSettle();

      expect(find.text('Quản lý Đa hồ sơ Watch-Only'), findsOneWidget);
      expect(find.byKey(const Key('add_wallet_qr_btn')), findsOneWidget);
    });
  });
}
