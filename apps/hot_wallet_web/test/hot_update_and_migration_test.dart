import 'dart:convert';
import 'dart:typed_data';

import 'package:cardano_core/cardano_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hot_wallet_web/screens/dashboard_screen.dart';
import 'package:hot_wallet_web/screens/settings_screen.dart';
import 'package:hot_wallet_web/services/hot_app_state.dart';
import 'package:hot_wallet_web/services/update_service.dart';
import 'package:hot_wallet_web/services/web_crypto_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class InMemoryWebCryptoStorage implements WebCryptoStorage {
  final Map<String, String> _store = {};

  @override
  bool get isWebCryptoActive => false;

  @override
  Future<String?> loadEncrypted(String key) async => _store[key];

  @override
  Future<void> saveEncrypted(String key, String plaintext) async {
    _store[key] = plaintext;
  }

  @override
  Future<void> deleteEncrypted(String key) async {
    _store.remove(key);
  }
}

void main() {
  group('Hot Wallet Versioning & Semantic Comparison Tests', () {
    test('AppVersionInfo isNewerThan compares semver and build numbers accurately', () {
      const v100b1 = AppVersionInfo(
        version: '1.0.0',
        buildNumber: 1,
        schemaVersion: 1,
        minCompatibleSchema: 1,
        releaseNotes: 'Initial',
      );
      const v101b1 = AppVersionInfo(
        version: '1.0.1',
        buildNumber: 1,
        schemaVersion: 1,
        minCompatibleSchema: 1,
        releaseNotes: 'Patch',
      );
      const v110b2 = AppVersionInfo(
        version: '1.1.0',
        buildNumber: 2,
        schemaVersion: 1,
        minCompatibleSchema: 1,
        releaseNotes: 'Minor',
      );

      // Newer patch
      expect(v101b1.isNewerThan(currentVersion: '1.0.0', currentBuildNumber: 1), isTrue);
      // Newer build number
      expect(v110b2.isNewerThan(currentVersion: '1.0.0', currentBuildNumber: 1), isTrue);
      // Same version & build
      expect(v100b1.isNewerThan(currentVersion: '1.0.0', currentBuildNumber: 1), isFalse);
      // Older version
      expect(v100b1.isNewerThan(currentVersion: '1.1.0', currentBuildNumber: 2), isFalse);
    });

    test('UpdateCheckService fetches version.json and parses JSON correctly', () async {
      final mockClient = MockClient((request) async {
        if (request.url.path.endsWith('version.json')) {
          return http.Response(
            jsonEncode({
              'version': '1.2.0',
              'buildNumber': 3,
              'schemaVersion': 1,
              'minCompatibleSchema': 1,
              'releaseNotes': 'New staking pool support and UI speedups',
            }),
            200,
          );
        }
        return http.Response('Not Found', 404);
      });

      final updateService = UpdateCheckService(client: mockClient);
      final info = await updateService.fetchLatestVersion();

      expect(info, isNotNull);
      expect(info!.version, equals('1.2.0'));
      expect(info.buildNumber, equals(3));
      expect(info.releaseNotes, contains('staking pool'));
    });
  });

  group('Hot Wallet State Migration & Snapshot Tests', () {
    test('HotAppState creates storage snapshot, preserves legacy data, and rolls back on failure', () async {
      final storage = InMemoryWebCryptoStorage();

      // Write legacy configuration without schemaVersion
      final legacyConfig = {
        'selectedNetwork': 'preprod',
        'locale': 'vi',
        'gapLimit': 25,
        'projectIds': {'preprod': 'preprod_secret_key_123'},
        'profiles': [
          {
            'id': 'prof_1',
            'name': 'Primary Vault',
            'network': 'preprod',
            'acctXvkBech32':
                'acct_xvk1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq52s22k',
            'accountIndex': 0,
            'createdAtMs': 1700000000000,
          }
        ],
        'activeProfileId': 'prof_1',
      };
      await storage.saveEncrypted('hot_wallet_config_v1', jsonEncode(legacyConfig));

      final state = HotAppState(storage: storage);
      await state.init();

      // Ensure data was completely loaded and not wiped
      expect(state.network, equals(CardanoNetwork.preprod));
      expect(state.gapLimit, equals(25));
      expect(state.projectIdFor(CardanoNetwork.preprod), equals('preprod_secret_key_123'));
      expect(state.allProfiles.length, equals(1));
      expect(state.allProfiles.first.name, equals('Primary Vault'));

      // Test snapshot creation
      expect(await state.hasStorageSnapshot(), isFalse);
      await state.createStorageSnapshot();
      expect(await state.hasStorageSnapshot(), isTrue);

      // Simulate corrupted state
      await storage.saveEncrypted('hot_wallet_config_v1', jsonEncode({'corrupted': true}));
      await state.init();
      expect(state.allProfiles, isEmpty);

      // Restore snapshot
      await state.restoreStorageSnapshot();
      expect(state.allProfiles.length, equals(1));
      expect(state.allProfiles.first.name, equals('Primary Vault'));
    });
  });

  group('Hot Wallet Update UI & Widget Tests', () {
    testWidgets('Dashboard displays update banner and opens update confirmation dialog', (tester) async {
      final storage = InMemoryWebCryptoStorage();
      final mockClient = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'version': '2.0.0',
            'buildNumber': 10,
            'schemaVersion': 1,
            'minCompatibleSchema': 1,
            'releaseNotes': 'Major security and performance improvements.',
          }),
          200,
        );
      });

      final state = HotAppState(
        storage: storage,
        updateService: UpdateCheckService(client: mockClient),
      );
      await state.init();

      // Check for updates
      await state.checkForUpdates();
      expect(state.hasUpdateAvailable, isTrue);

      // Add a dummy profile to show the dashboard ListView
      final ur = CardanoAccountUr(
        network: CardanoNetwork.preprod,
        acctXvk: Uint8List(64),
        label: 'Test Profile',
      );
      await state.addProfile(name: 'Test Profile', accountUr: ur);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DashboardScreen(
              appState: state,
              onOpenAccounts: () {},
              onOpenSettings: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Banner should be visible
      expect(find.byKey(const Key('update_available_banner')), findsOneWidget);
      expect(find.textContaining('v2.0.0'), findsWidgets);

      // Click update button in banner
      await tester.tap(find.byKey(const Key('banner_update_now_btn')));
      await tester.pumpAndSettle();

      // Dialog opens
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.textContaining('1.0.0 → 2.0.0'), findsOneWidget);
      expect(find.textContaining('Major security and performance improvements.'), findsOneWidget);
      expect(find.byKey(const Key('confirm_update_now_btn')), findsOneWidget);

      var reloadTriggered = false;
      await state.applyWebUpdate(onReload: () {
        reloadTriggered = true;
      });
      expect(reloadTriggered, isTrue);
      expect(await state.hasStorageSnapshot(), isTrue);
    });

    testWidgets('SettingsScreen allows manual check for updates and shows version info', (tester) async {
      tester.view.physicalSize = const Size(1000, 1800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final storage = InMemoryWebCryptoStorage();
      final mockClient = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'version': '1.0.0',
            'buildNumber': 1,
            'schemaVersion': 1,
            'minCompatibleSchema': 1,
            'releaseNotes': 'Already on latest.',
          }),
          200,
        );
      });

      final state = HotAppState(
        storage: storage,
        updateService: UpdateCheckService(client: mockClient),
      );
      await state.init();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsScreen(appState: state),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Scroll to check updates button
      final checkBtn = find.byKey(const Key('check_updates_btn'));
      await tester.scrollUntilVisible(
        checkBtn,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(checkBtn);
      await tester.pumpAndSettle();

      // Shows status message indicating it is already the latest version
      expect(find.byKey(const Key('update_status_msg')), findsOneWidget);
      expect(find.text(state.strings.alreadyLatestVersion), findsOneWidget);
    });
  });
}
