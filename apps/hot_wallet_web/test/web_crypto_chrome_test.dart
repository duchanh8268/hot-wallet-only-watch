@TestOn('browser')
library;

import 'package:cardano_core/cardano_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hot_wallet_web/main.dart';
import 'package:hot_wallet_web/services/hot_app_state.dart';
import 'package:hot_wallet_web/services/web_crypto_storage.dart';

void main() {
  testWidgets('Browser test: WebCryptoStorage + HotWalletWebApp UI interactions', (tester) async {
    final storage = WebCryptoStorage();
    // Note: `flutter test --platform chrome` uses a synthetic test harness without
    // web/crypto_storage.js; real SubtleCrypto + IndexedDB is tested against built web bundle.
    await storage.saveEncrypted('chrome_test_key', '{"secret":"preprod_123"}');
    final loaded = await storage.loadEncrypted('chrome_test_key');
    expect(loaded, '{"secret":"preprod_123"}');
    await storage.deleteEncrypted('chrome_test_key');
    expect(await storage.loadEncrypted('chrome_test_key'), isNull);

    final state = HotAppState(storage: storage);
    await state.init();

    await tester.pumpWidget(HotWalletWebApp(appState: state));
    await tester.pumpAndSettle();

    // Default Vietnamese & Preprod
    expect(find.textContaining('Cardano Hot Wallet'), findsOneWidget);
    expect(find.text('Preprod'), findsOneWidget);

    // Navigate to API Settings via AppBar settings button
    await tester.tap(find.byKey(const Key('appbar_settings_btn')));
    await tester.pumpAndSettle();
    expect(find.textContaining('SubtleCrypto AES-256-GCM'), findsOneWidget);

    // Return to Dashboard & open Wallet Profiles dialog
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('wallet_profile_menu_btn')));
    await tester.pumpAndSettle();
    expect(find.text('Quản lý Đa hồ sơ Watch-Only'), findsOneWidget);

    await tester.tap(find.text('VI'));
    await tester.pumpAndSettle();
    expect(find.text('Multi-Profile Watch-Only Manager'), findsOneWidget);

    // Switch back to VI for clean state
    await tester.tap(find.text('EN'));
    await tester.pumpAndSettle();
    expect(find.text('Quản lý Đa hồ sơ Watch-Only'), findsOneWidget);

    // Verify network tag sanity
    expect(CardanoNetwork.preprod.urCode, 0);
  });
}
