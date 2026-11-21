import 'dart:convert';

import 'package:chain_core_interface/chain_core_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hot_wallet_web/chains/bitcoin/services/mempool_service.dart';
import 'package:hot_wallet_web/chains/evm/services/evm_rpc_service.dart';
import 'package:hot_wallet_web/chains/evm/services/hyperliquid_service.dart';
import 'package:hot_wallet_web/chains/solana/services/solana_rpc_service.dart';
import 'package:hot_wallet_web/chains/sui/services/sui_rpc_service.dart';
import 'package:hot_wallet_web/core/models/chain_tx_record.dart';
import 'package:hot_wallet_web/main.dart';
import 'package:hot_wallet_web/services/blockfrost_service.dart';
import 'package:hot_wallet_web/services/hot_app_state.dart';
import 'package:hot_wallet_web/services/web_crypto_storage.dart';
import 'package:hot_wallet_web/widgets/recent_txs_section.dart';
import 'package:hot_wallet_web/widgets/wallet_profiles_dialog.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('Multi-chain UX & Functional Fixes Tests', () {
    test('HotAppState manages Add, Rename, Switch, Delete, and Persist for BTC/ETH/HL/SOL/SUI', () async {
      final storage = WebCryptoStorage();
      final appState = HotAppState(
        storage: storage,
        blockfrost: BlockfrostService(
          client: MockClient((_) async => http.Response('{}', 200)),
        ),
      );
      await appState.init();

      // Bitcoin
      appState.setActiveChain(ChainId.bitcoin);
      final btc1 = await appState.addBtcProfile(
        name: 'BTC Main',
        receiveAddress: 'tb1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu',
        networkId: 'testnet4',
      );
      final btc2 = await appState.addBtcProfile(
        name: 'BTC Vault',
        receiveAddress: 'tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx',
        networkId: 'testnet4',
      );
      expect(appState.allBtcProfiles.length, 2);
      expect(appState.activeBtcProfile?.id, btc2.id);
      await appState.renameBtcProfile(btc1.id, 'BTC Renamed');
      expect(appState.allBtcProfiles.first.name, 'BTC Renamed');
      await appState.selectBtcProfile(btc1.id);
      expect(appState.activeBtcProfile?.id, btc1.id);

      // Ethereum vs Hyperliquid separation
      appState.setActiveChain(ChainId.ethereum);
      final eth1 = await appState.addEvmProfile(
        name: 'ETH Hot',
        chainId: ChainId.ethereum,
        address: '0x2f2206afD0e692dE34dF681E97175f143A92a8BB',
        networkId: 'sepolia',
      );
      appState.setActiveChain(ChainId.hyperliquid);
      final hl1 = await appState.addEvmProfile(
        name: 'HL Perp',
        chainId: ChainId.hyperliquid,
        address: '0x742d35Cc6634C0532925a3b844Bc454e4438f44e',
        networkId: 'testnet',
      );
      expect(appState.currentChainEvmProfiles.map((p) => p.id), [hl1.id]);
      appState.setActiveChain(ChainId.ethereum);
      expect(appState.currentChainEvmProfiles.map((p) => p.id), [eth1.id]);
      await appState.renameEvmProfile(eth1.id, 'ETH Renamed');
      expect(appState.activeEvmProfile?.name, 'ETH Renamed');

      // Solana
      appState.setActiveChain(ChainId.solana);
      final sol1 = await appState.addSolProfile(
        name: 'SOL A',
        address: 'Ab6JNNGNQJbj1EPZ4Fa6wCitFxzuAh1YG23kBxxYFKib',
        networkId: 'devnet',
      );
      await appState.renameSolProfile(sol1.id, 'SOL Renamed');
      expect(appState.activeSolProfile?.name, 'SOL Renamed');

      // Sui
      appState.setActiveChain(ChainId.sui);
      final sui1 = await appState.addSuiProfile(
        name: 'SUI A',
        address: '0xd404e60fc990df26ad7355c607f61c93162b5ed3e778015757f5b44d5bfe7f07',
        networkId: 'testnet',
      );
      await appState.renameSuiProfile(sui1.id, 'SUI Renamed');
      expect(appState.activeSuiProfile?.name, 'SUI Renamed');

      // Local broadcast tx persistence + merge
      await appState.recordRecentBroadcastTx(
        chainId: ChainId.ethereum,
        networkId: 'sepolia',
        address: eth1.address,
        txHash: '0xabc123',
        summary: '-0.1 ETH',
      );

      // Delete & verify persistence round-trip
      await appState.deleteBtcProfile(btc2.id);
      final reloaded = HotAppState(storage: storage);
      await reloaded.init();
      expect(reloaded.allBtcProfiles.length, 1);
      expect(reloaded.allBtcProfiles.first.name, 'BTC Renamed');
      expect(reloaded.allEvmProfiles.any((p) => p.name == 'ETH Renamed'), isTrue);
      expect(reloaded.allSolProfiles.first.name, 'SOL Renamed');
      expect(reloaded.allSuiProfiles.first.name, 'SUI Renamed');

      final merged = reloaded.recentTxsFor(
        chainId: ChainId.ethereum,
        networkId: 'sepolia',
        address: eth1.address,
        remoteTxs: const [
          ChainTxRecord(
            txHash: '0xabc123',
            timestampMs: 1730005000000,
            status: 'confirmed',
            direction: 'out',
            blockOrSlot: 'Block #1234',
          ),
        ],
      );
      expect(merged.length, 1);
      expect(merged.first.status, 'confirmed');
      expect(merged.first.summary, '-0.1 ETH');
    });

    test('Recent tx history parsers decode BTC, ETH (Blockscout), Hyperliquid, SOL, and SUI payloads', () async {
      // Bitcoin Mempool /txs
      const btcAddr = 'tb1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu';
      final btcService = MempoolService(
        client: MockClient((req) async {
          expect(req.url.path, endsWith('/address/$btcAddr/txs'));
          return http.Response(
            jsonEncode([
              {
                'txid': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
                'status': {'confirmed': true, 'block_height': 42000, 'block_time': 1730000000},
                'vin': [],
                'vout': [
                  {'scriptpubkey_address': btcAddr, 'value': 250000},
                ],
              }
            ]),
            200,
          );
        }),
      );
      final btcTxs = await btcService.getRecentTxs('testnet4', btcAddr);
      expect(btcTxs.length, 1);
      expect(btcTxs.first.direction, 'in');
      expect(btcTxs.first.summary, '+0.00250000 BTC');
      expect(btcTxs.first.explorerUrl, contains('/testnet4/tx/'));

      // Ethereum Blockscout v2 /addresses/<addr>/transactions
      const ethAddr = '0x2f2206afD0e692dE34dF681E97175f143A92a8BB';
      final ethService = EvmRpcService(
        client: MockClient((req) async {
          expect(req.url.host, 'eth-sepolia.blockscout.com');
          return http.Response(
            jsonEncode({
              'items': [
                {
                  'hash': '0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef',
                  'block_number': 7123456,
                  'timestamp': '2026-01-01T12:00:00.000000Z',
                  'status': 'ok',
                  'from': {'hash': ethAddr},
                  'to': {'hash': '0x1111111111111111111111111111111111111111'},
                  'value': '500000000000000000',
                  'method': 'transfer',
                }
              ],
            }),
            200,
          );
        }),
      );
      final ethTxs = await ethService.getRecentTxs('sepolia', ethAddr);
      expect(ethTxs.length, 1);
      expect(ethTxs.first.direction, 'out');
      expect(ethTxs.first.summary, '-0.500000 ETH (transfer)');
      expect(ethTxs.first.blockOrSlot, 'Block #7123456');
      expect(ethTxs.first.explorerUrl, startsWith('https://sepolia.etherscan.io/tx/'));

      // Hyperliquid /info userNonFundingLedgerUpdates + userFills
      final hlService = HyperliquidService(
        client: MockClient((req) async {
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          if (body['type'] == 'userNonFundingLedgerUpdates') {
            return http.Response(
              jsonEncode([
                {
                  'time': 1730001000000,
                  'hash': '0x9999999999999999999999999999999999999999999999999999999999999999',
                  'delta': {'type': 'deposit', 'usdc': '100.0'},
                }
              ]),
              200,
            );
          }
          return http.Response(jsonEncode([]), 200);
        }),
      );
      final hlTxs = await hlService.getRecentActivity('testnet', ethAddr);
      expect(hlTxs.length, 1);
      expect(hlTxs.first.direction, 'in');
      expect(hlTxs.first.summary, 'deposit • +100.0 USDC');

      // Solana getSignaturesForAddress
      const solAddr = 'Ab6JNNGNQJbj1EPZ4Fa6wCitFxzuAh1YG23kBxxYFKib';
      final solService = SolanaRpcService(
        client: MockClient((req) async {
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          expect(body['method'], 'getSignaturesForAddress');
          return http.Response(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': 1,
              'result': [
                {'signature': '5VERvSig', 'slot': 312000, 'err': null, 'blockTime': 1730002000},
              ],
            }),
            200,
          );
        }),
      );
      final solTxs = await solService.getRecentSignatures(address: solAddr, networkId: 'devnet');
      expect(solTxs.length, 1);
      expect(solTxs.first.blockOrSlot, 'Slot #312000');
      expect(solTxs.first.explorerUrl, contains('?cluster=devnet'));

      // Sui suix_queryTransactionBlocks
      const suiAddr = '0xd404e60fc990df26ad7355c607f61c93162b5ed3e778015757f5b44d5bfe7f07';
      final suiService = SuiRpcService(
        client: MockClient((req) async {
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          expect(body['method'], 'suix_queryTransactionBlocks');
          return http.Response(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': 1,
              'result': {
                'data': [
                  {
                    'digest': 'Byw8Digest',
                    'timestampMs': '1730003000000',
                    'checkpoint': '9999',
                    'effects': {
                      'status': {'status': 'success'}
                    },
                  }
                ],
              },
            }),
            200,
          );
        }),
      );
      final suiTxs = await suiService.getRecentTransactions(address: suiAddr, networkId: 'testnet');
      expect(suiTxs.length, 1);
      expect(suiTxs.first.txHash, 'Byw8Digest');
      expect(suiTxs.first.direction, 'self');
      expect(suiTxs.first.explorerUrl, 'https://suiscan.xyz/testnet/tx/Byw8Digest');
    });

    testWidgets('Chain & Network bottom sheet is constrained to 430px on desktop and top-right wallet button works on non-Cardano chains', (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final storage = WebCryptoStorage();
      final appState = HotAppState(
        storage: storage,
        blockfrost: BlockfrostService(
          client: MockClient((_) async => http.Response('{}', 200)),
        ),
      );

      await tester.pumpWidget(HotWalletWebApp(appState: appState));
      await tester.pumpAndSettle();

      // Open chain selector bottom sheet on desktop viewport -> width must stay <= 430px
      await tester.tap(find.byKey(const Key('chain_network_selector_btn')));
      await tester.pumpAndSettle();

      final modalFinder = find.text('Chọn Nền Tảng & Mạng');
      expect(modalFinder, findsOneWidget);
      final sheetBox = tester.getRect(find.byKey(const ValueKey('hot_step_chain')));
      expect(sheetBox.width, lessThanOrEqualTo(430.0));

      // Switch to Ethereum -> Sepolia Testnet
      await tester.tap(find.text('Ethereum'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sepolia Testnet'));
      await tester.pumpAndSettle();

      // Top-right wallet profile button is enabled for Ethereum and opens unified dialog
      await tester.tap(find.byKey(const Key('wallet_profile_menu_btn')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('add_wallet_qr_btn')), findsOneWidget);

      // Add an Ethereum address via unified dialog
      await tester.tap(find.byKey(const Key('add_wallet_qr_btn')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('add_wallet_name_input')), 'My Sepolia Wallet');
      await tester.enterText(
        find.byKey(const Key('add_wallet_input')),
        '0x2f2206afD0e692dE34dF681E97175f143A92a8BB',
      );
      await tester.tap(find.byKey(const Key('confirm_add_wallet_btn')));
      await tester.pumpAndSettle();

      expect(appState.activeEvmProfile?.name, 'My Sepolia Wallet');
      expect(find.byKey(Key('wallet_profile_item_${appState.activeEvmProfile!.id}')), findsOneWidget);

      // Close WalletProfilesDialog cleanly via TextButton('Đóng') and verify RecentTxsSection shows
      await tester.tap(find.text('Đóng'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Lịch sử Giao dịch Gần đây'), findsOneWidget);
    });

    testWidgets('WalletProfilesDialog supports rename & delete on Bitcoin and RecentTxsSection renders records cleanly', (tester) async {
      final storage = WebCryptoStorage();
      final appState = HotAppState(storage: storage);
      await appState.init();
      appState.setActiveChain(ChainId.bitcoin);
      final btc = await appState.addBtcProfile(
        name: 'BTC Old',
        receiveAddress: 'tb1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu',
        networkId: 'testnet4',
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: Builder(
              builder: (ctx) => Column(
                children: [
                  FilledButton(
                    onPressed: () => showWalletProfilesDialog(ctx, appState),
                    child: const Text('Open'),
                  ),
                  const RecentTxsSection(
                    txs: [
                      ChainTxRecord(
                        txHash: 'abcdef1234567890',
                        timestampMs: 1730005000000,
                        status: 'confirmed',
                        direction: 'in',
                        summary: '+0.15 BTC',
                        blockOrSlot: 'Block #123',
                        explorerUrl: 'https://mempool.space/testnet4/tx/abcdef1234567890',
                      ),
                    ],
                    isVi: true,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('recent_tx_item_abcdef1234567890')), findsOneWidget);
      expect(find.byKey(const Key('tx_explorer_link_abcdef1234567890')), findsOneWidget);
      expect(find.text('+0.15 BTC'), findsOneWidget);

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(Key('rename_profile_btn_${btc.id}')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('rename_wallet_input')), 'BTC New');
      await tester.tap(find.byKey(const Key('confirm_rename_wallet_btn')));
      await tester.pumpAndSettle();

      expect(appState.activeBtcProfile?.name, 'BTC New');

      await tester.tap(find.byKey(Key('delete_profile_btn_${btc.id}')));
      await tester.pumpAndSettle();
      expect(appState.allBtcProfiles, isEmpty);
    });
  });
}
