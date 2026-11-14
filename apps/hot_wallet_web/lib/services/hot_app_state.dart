import 'dart:convert';

import 'package:cardano_core/cardano_core.dart';
import 'package:flutter/foundation.dart';

import '../l10n/app_strings.dart';
import 'blockfrost_service.dart';
import 'conway_tx_builder.dart';
import 'hd_wallet_sync_service.dart';
import 'update_service.dart';
import 'web_crypto_storage.dart';
import 'web_reload_helper.dart';

class HotAppState extends ChangeNotifier {
  static const String currentVersion = '1.0.0';
  static const int currentBuildNumber = 1;
  static const int currentSchemaVersion = 1;
  static const String _storageKey = 'hot_wallet_config_v1';
  static const String _backupStorageKey = 'hot_wallet_config_backup';

  final WebCryptoStorage storage;
  final BlockfrostService blockfrost;
  final UpdateCheckService updateService;
  final SchemaMigrationRunner migrationRunner = SchemaMigrationRunner();
  late final HdWalletSyncService syncService;

  CardanoNetwork _network = CardanoNetwork.preprod; // Default: Preprod
  HotLocale _locale = HotLocale.vi; // Default: Vietnamese
  int _gapLimit = 20;

  final Map<CardanoNetwork, String> _projectIds = {
    CardanoNetwork.preprod: '',
    CardanoNetwork.preview: '',
    CardanoNetwork.mainnet: '',
  };

  final List<WatchOnlyProfile> _profiles = [];
  final Map<String, WalletSyncState> _syncCache = {};
  final Map<String, int> _customTokenDecimals = {};
  String? _activeProfileId;

  bool _loaded = false;
  bool _syncing = false;
  int _syncSeq = 0;
  String? _syncError;
  WalletSyncState? _syncState;
  TxBuildResult? _lastBuiltTx;

  AppVersionInfo? _latestVersion;
  bool _checkingUpdate = false;
  String? _updateStatusMessage;

  HotAppState({
    WebCryptoStorage? storage,
    BlockfrostService? blockfrost,
    UpdateCheckService? updateService,
  })  : storage = storage ?? WebCryptoStorage(),
        blockfrost = blockfrost ?? BlockfrostService(),
        updateService = updateService ?? UpdateCheckService() {
    syncService = HdWalletSyncService(this.blockfrost);
  }

  CardanoNetwork get network => _network;
  HotLocale get locale => _locale;
  HotStrings get strings => HotStrings(_locale);
  int get gapLimit => _gapLimit;
  bool get loaded => _loaded;
  bool get syncing => _syncing;
  String? get syncError => _syncError;
  WalletSyncState? get syncState => _syncState;
  TxBuildResult? get lastBuiltTx => _lastBuiltTx;
  bool get isWebCryptoActive => storage.isWebCryptoActive;

  AppVersionInfo? get latestVersion => _latestVersion;
  bool get checkingUpdate => _checkingUpdate;
  String? get updateStatusMessage => _updateStatusMessage;
  bool get hasUpdateAvailable =>
      _latestVersion != null &&
      _latestVersion!.isNewerThan(
        currentVersion: currentVersion,
        currentBuildNumber: currentBuildNumber,
      );

  void setLastBuiltTx(TxBuildResult? tx) {
    _lastBuiltTx = tx;
    notifyListeners();
  }

  String projectIdFor(CardanoNetwork net) => _projectIds[net] ?? '';
  String get activeProjectId => projectIdFor(_network);

  List<WatchOnlyProfile> get allProfiles => List.unmodifiable(_profiles);
  List<WatchOnlyProfile> get networkProfiles =>
      _profiles.where((p) => p.network == _network).toList();

  WatchOnlyProfile? get activeProfile {
    final matching = networkProfiles;
    if (matching.isEmpty) return null;
    for (final p in matching) {
      if (p.id == _activeProfileId) return p;
    }
    return matching.first;
  }

  Future<void> createStorageSnapshot() async {
    final raw = await storage.loadEncrypted(_storageKey);
    if (raw != null && raw.isNotEmpty) {
      await storage.saveEncrypted(_backupStorageKey, raw);
    }
  }

  Future<bool> hasStorageSnapshot() async {
    final raw = await storage.loadEncrypted(_backupStorageKey);
    return raw != null && raw.isNotEmpty;
  }

  Future<void> restoreStorageSnapshot() async {
    final raw = await storage.loadEncrypted(_backupStorageKey);
    if (raw != null && raw.isNotEmpty) {
      await storage.saveEncrypted(_storageKey, raw);
      await init();
    }
  }

  Future<void> checkForUpdates({String? url}) async {
    _checkingUpdate = true;
    _updateStatusMessage = null;
    notifyListeners();
    try {
      final info = await updateService.fetchLatestVersion(url: url ?? 'version.json');
      _latestVersion = info;
      if (hasUpdateAvailable) {
        _updateStatusMessage = strings.updateAvailableNotice(info!.version);
      } else {
        _updateStatusMessage = strings.alreadyLatestVersion;
      }
    } catch (e) {
      _updateStatusMessage = e.toString();
    } finally {
      _checkingUpdate = false;
      notifyListeners();
    }
  }

  Future<void> applyWebUpdate({void Function()? onReload}) async {
    await createStorageSnapshot();
    if (onReload != null) {
      onReload();
    } else {
      reloadWebApp();
    }
  }

  Future<void> init() async {
    try {
      final raw = await storage.loadEncrypted(_storageKey);
      if (raw != null && raw.isNotEmpty) {
        var json = jsonDecode(raw) as Map<String, dynamic>;
        final existingSchema = (json['schemaVersion'] as num?)?.toInt() ?? 1;
        if (existingSchema < currentSchemaVersion) {
          await createStorageSnapshot();
          try {
            json = migrationRunner.migrate(
              data: json,
              targetVersion: currentSchemaVersion,
            );
            await storage.saveEncrypted(_storageKey, jsonEncode(json));
          } catch (_) {
            await restoreStorageSnapshot();
            rethrow;
          }
        }

        final netId = json['selectedNetwork'] as String?;
        if (netId != null) {
          _network = CardanoNetwork.fromId(netId);
        }
        final loc = json['locale'] as String?;
        if (loc == 'en') _locale = HotLocale.en;
        _gapLimit = (json['gapLimit'] as num?)?.toInt() ?? 20;

        final apiMap = json['projectIds'] as Map<String, dynamic>? ?? {};
        for (final net in CardanoNetwork.values) {
          _projectIds[net] = (apiMap[net.id] as String?) ?? '';
        }

        final profList = json['profiles'] as List<dynamic>? ?? [];
        _profiles
          ..clear()
          ..addAll(
            profList.map(
              (e) => WatchOnlyProfile.fromJson(e as Map<String, dynamic>),
            ),
          );
        _activeProfileId = json['activeProfileId'] as String?;
        final decMap = json['customTokenDecimals'] as Map<String, dynamic>? ?? {};
        _customTokenDecimals
          ..clear()
          ..addAll({
            for (final e in decMap.entries)
              if (e.value is num) e.key: (e.value as num).toInt().clamp(0, 18),
          });
      }
    } catch (_) {
      // Ignore corrupt storage on init and start clean
    } finally {
      _loaded = true;
      notifyListeners();
    }
  }

  Future<void> _persist() async {
    final payload = jsonEncode({
      'schemaVersion': currentSchemaVersion,
      'selectedNetwork': _network.id,
      'locale': _locale.name,
      'gapLimit': _gapLimit,
      'projectIds': {for (final n in CardanoNetwork.values) n.id: _projectIds[n] ?? ''},
      'profiles': [for (final p in _profiles) p.toJson()],
      'activeProfileId': _activeProfileId,
      'customTokenDecimals': _customTokenDecimals,
    });
    await storage.saveEncrypted(_storageKey, payload);
  }

  int tokenDecimalsFor(String unit, AssetMetadataInfo? meta) {
    return _customTokenDecimals[unit] ?? meta?.decimals ?? 0;
  }

  Future<void> setCustomTokenDecimals(String unit, int decimals) async {
    _customTokenDecimals[unit] = decimals.clamp(0, 18);
    await _persist();
    notifyListeners();
  }

  Future<void> toggleLocale() async {
    _locale = _locale == HotLocale.vi ? HotLocale.en : HotLocale.vi;
    await _persist();
    notifyListeners();
  }

  Future<void> setNetwork(CardanoNetwork next) async {
    if (_network == next) return;
    _network = next;
    final p = activeProfile;
    _syncState = p == null ? null : _syncCache['${p.id}:${next.id}'];
    _syncError = null;
    await _persist();
    notifyListeners();
    if (p != null && activeProjectId.trim().isNotEmpty) {
      await syncActiveWallet();
    }
  }

  Future<void> saveSettings({
    required Map<CardanoNetwork, String> projectIds,
    required int gapLimit,
  }) async {
    for (final e in projectIds.entries) {
      _projectIds[e.key] = e.value.trim();
    }
    _gapLimit = gapLimit.clamp(5, 100);
    await _persist();
    notifyListeners();
  }

  Future<int> testBlockfrostConnection(
    CardanoNetwork net,
    String projectId,
  ) {
    return blockfrost.getLatestSlot(net, projectId);
  }

  Future<WatchOnlyProfile> addProfile({
    required String name,
    required CardanoAccountUr accountUr,
  }) async {
    final xvkBech32 = CardanoAccountPublicKey.fromBytes(accountUr.acctXvk).toBech32();
    final id = '${accountUr.network.id}_${DateTime.now().microsecondsSinceEpoch}';
    final profile = WatchOnlyProfile(
      id: id,
      name: name.trim().isEmpty ? (accountUr.label ?? 'Cardano Wallet') : name.trim(),
      network: accountUr.network,
      acctXvkBech32: xvkBech32,
      accountIndex: accountUr.accountIndex,
      createdAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    _profiles.add(profile);
    _activeProfileId = profile.id;
    _syncState = null;
    await _persist();
    notifyListeners();
    if (profile.network == _network && activeProjectId.isNotEmpty) {
      await syncActiveWallet();
    }
    return profile;
  }

  Future<void> renameProfile(String id, String newName) async {
    final idx = _profiles.indexWhere((p) => p.id == id);
    if (idx == -1 || newName.trim().isEmpty) return;
    _profiles[idx] = _profiles[idx].copyWith(name: newName.trim());
    await _persist();
    notifyListeners();
  }

  Future<void> deleteProfile(String id) async {
    _profiles.removeWhere((p) => p.id == id);
    _syncCache.removeWhere((k, _) => k.startsWith('$id:'));
    if (_activeProfileId == id) {
      _activeProfileId = networkProfiles.isNotEmpty ? networkProfiles.first.id : null;
      final nextP = activeProfile;
      _syncState = nextP == null ? null : _syncCache['${nextP.id}:${_network.id}'];
    }
    await _persist();
    notifyListeners();
  }

  Future<void> selectProfile(String id) async {
    _activeProfileId = id;
    final p = activeProfile;
    _syncState = p == null ? null : _syncCache['${p.id}:${_network.id}'];
    _syncError = null;
    await _persist();
    notifyListeners();
    if (activeProjectId.isNotEmpty) {
      await syncActiveWallet();
    }
  }

  Future<void> syncActiveWallet() async {
    final profile = activeProfile;
    if (profile == null) return;
    final key = projectIdFor(profile.network);
    if (key.trim().isEmpty) {
      _syncError = strings.missingApiKey;
      notifyListeners();
      return;
    }

    final mySeq = ++_syncSeq;
    _syncing = true;
    _syncError = null;
    notifyListeners();

    try {
      final result = await syncService.syncProfile(
        profile: profile,
        projectId: key,
        gapLimit: _gapLimit,
      );
      if (mySeq == _syncSeq) {
        _syncState = result;
        _syncCache['${profile.id}:${profile.network.id}'] = result;
      }
    } catch (e) {
      if (mySeq == _syncSeq) {
        _syncError = e.toString();
      }
    } finally {
      if (mySeq == _syncSeq) {
        _syncing = false;
        notifyListeners();
      }
    }
  }

  /// Populates realistic local Preprod UTXOs & Native Token for offline browser testing
  /// using real addresses derived from the active watch-only `acct_xvk`.
  void loadDemoPreprodData() {
    final profile = activeProfile;
    if (profile == null) return;
    final acctKey = CardanoAccountPublicKey.fromBech32(profile.acctXvkBech32);
    final extAddr0 = acctKey.deriveBaseAddress(role: 0, index: 0, network: profile.network);
    final extAddr1 = acctKey.deriveBaseAddress(role: 0, index: 1, network: profile.network);
    final stakeAddr = acctKey.deriveRewardAddress(network: profile.network);

    const demoPolicy = 'a0028f350aaabe0545fdcb56b039bfb08e4bb4d8c4d7c3c7d481c235';
    const demoPolicy2 = '29d222ce763455e3d7a09a665ce554f00ac89d2e99a1a83d267170c6';
    const demoAssetHex = '74484f534b59'; // "tHOSKY"
    const demoMinHex = '744d494e'; // "tMIN"
    const demoNftHex = '436f6c6444656d6f4e4654'; // "ColdDemoNFT"

    final hoskyKey = AssetKey(demoPolicy, demoAssetHex);
    final minKey = AssetKey(demoPolicy2, demoMinHex);
    final nftKey = AssetKey(demoPolicy2, demoNftHex);

    final utxo1Assets = MultiAsset({
      hoskyKey: BigInt.from(250000),
      minKey: BigInt.from(125500000), // 125.5 tMIN (6 decimals)
    });
    final utxo2Assets = MultiAsset({
      nftKey: BigInt.one,
    });
    final totalAssets = utxo1Assets.add(utxo2Assets);

    _syncError = null;
    _syncState = WalletSyncState(
      totalLovelace: BigInt.from(1255500000),
      totalMultiAsset: totalAssets,
      utxos: [
        DerivedUtxo(
          utxo: BlockfrostUtxo(
            txHash: '1111111111111111111111111111111111111111111111111111111111111111',
            outputIndex: 0,
            address: extAddr0,
            lovelace: BigInt.from(1000000000),
            multiAsset: MultiAsset.empty,
          ),
          derivationRole: 0,
          derivationIndex: 0,
        ),
        DerivedUtxo(
          utxo: BlockfrostUtxo(
            txHash: '2222222222222222222222222222222222222222222222222222222222222222',
            outputIndex: 1,
            address: extAddr1,
            lovelace: BigInt.from(250500000),
            multiAsset: utxo1Assets,
          ),
          derivationRole: 0,
          derivationIndex: 1,
        ),
        DerivedUtxo(
          utxo: BlockfrostUtxo(
            txHash: '3333333333333333333333333333333333333333333333333333333333333333',
            outputIndex: 0,
            address: extAddr1,
            lovelace: BigInt.from(5000000),
            multiAsset: utxo2Assets,
          ),
          derivationRole: 0,
          derivationIndex: 1,
        ),
      ],
      primaryReceiveAddress: extAddr0,
      nextUnusedExternalAddress: extAddr1,
      nextUnusedInternalIndex: 0,
      stakeAddress: stakeAddr,
      stakeInfo: StakeAccountInfo(
        registered: true,
        controlledAmount: BigInt.from(1255500000),
        withdrawableAmount: BigInt.from(15000000),
        poolId: 'pool1pu5jlj4q9w9jlxeu370a3c9myx47md5j5m2str0naunn2q3lkdy',
      ),
      poolName: 'Demo Cardano Pool',
      assetMetadata: const {
        '$demoPolicy$demoAssetHex': AssetMetadataInfo(
          unit: '$demoPolicy$demoAssetHex',
          fingerprint: 'asset1demo0hosky00000000000000000000000000',
          ticker: 'tHOSKY',
          name: 'Test HOSKY Token',
          decimals: 0,
        ),
        '$demoPolicy2$demoMinHex': AssetMetadataInfo(
          unit: '$demoPolicy2$demoMinHex',
          fingerprint: 'asset1demo0tmin000000000000000000000000000',
          ticker: 'tMIN',
          name: 'Test Minswap Token',
          decimals: 6,
        ),
        '$demoPolicy2$demoNftHex': AssetMetadataInfo(
          unit: '$demoPolicy2$demoNftHex',
          fingerprint: 'asset1demo0nft0000000000000000000000000000',
          name: 'Cold Wallet Demo NFT',
          decimals: 0,
          onchainStandard: 'CIP25v1',
        ),
      },
      recentTxs: const [
        AddressTxSummary(
          txHash: '1111111111111111111111111111111111111111111111111111111111111111',
          blockHeight: 2845100,
          blockTime: 1730000000,
        ),
      ],
      protocolParameters: ProtocolParameters.cardanoDefaults,
      latestSlot: 75000000,
    );
    notifyListeners();
  }
}
