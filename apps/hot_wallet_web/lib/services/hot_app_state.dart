import 'dart:convert';

import 'package:cardano_core/cardano_core.dart';
import 'package:chain_core_interface/chain_core_interface.dart';
import 'package:flutter/foundation.dart';

import '../chains/cardano/cardano_hot_plugin.dart';
import '../chains/bitcoin/bitcoin_hot_plugin.dart';
import '../chains/bitcoin/models/btc_profile.dart';
import '../chains/bitcoin/services/btc_hd_sync_service.dart';
import '../chains/bitcoin/services/mempool_service.dart';
import '../chains/evm/evm_hot_plugin.dart';
import '../chains/evm/models/evm_profile.dart';
import '../chains/solana/solana_hot_plugin.dart';
import '../chains/solana/models/sol_profile.dart';
import '../chains/sui/sui_hot_plugin.dart';
import '../chains/sui/models/sui_profile.dart';
import '../core/models/chain_tx_record.dart';
import '../core/services/hot_chain_registry.dart';
import '../l10n/app_strings.dart';
import 'cardano_rpc_service.dart';
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
  final CardanoRpcService cardanoRpc;
  final UpdateCheckService updateService;
  final SchemaMigrationRunner migrationRunner = SchemaMigrationRunner();
  late final HdWalletSyncService syncService;
  final HotChainRegistry chainRegistry = HotChainRegistry();
  ChainId _activeChainId = ChainId.cardano;

  CardanoNetwork _network = CardanoNetwork.preprod; // Default: Preprod
  HotLocale _locale = HotLocale.vi; // Default: Vietnamese
  int _gapLimit = 20;

  final Map<ChainId, ChainNetwork> _chainNetworks = {};
  final Map<String, String> _customRpcEndpoints = {};

  final List<WatchOnlyProfile> _profiles = [];
  final Map<String, WalletSyncState> _syncCache = {};
  final Map<String, int> _customTokenDecimals = {};
  String? _activeProfileId;

  final List<EvmWatchOnlyProfile> _evmProfiles = [];
  String? _activeEvmProfileId;
  Map<String, dynamic>? _evmAccountState;
  bool _evmLoading = false;
  String? _evmError;

  final List<BtcWatchOnlyProfile> _btcProfiles = [];
  String? _activeBtcProfileId;
  Map<String, dynamic>? _btcAccountState;
  BtcWalletSyncState? _btcSyncState;
  bool _btcLoading = false;
  String? _btcError;

  final List<SolWatchOnlyProfile> _solProfiles = [];
  String? _activeSolProfileId;
  Map<String, dynamic>? _solAccountState;
  bool _solLoading = false;
  String? _solError;

  final List<SuiWatchOnlyProfile> _suiProfiles = [];
  String? _activeSuiProfileId;
  Map<String, dynamic>? _suiAccountState;
  bool _suiLoading = false;
  String? _suiError;

  final Map<String, List<ChainTxRecord>> _localBroadcastTxs = {};

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
    CardanoRpcService? cardanoRpc,
    UpdateCheckService? updateService,
  })  : storage = storage ?? WebCryptoStorage(),
        cardanoRpc = cardanoRpc ?? CardanoRpcService(),
        updateService = updateService ?? UpdateCheckService() {
    syncService = HdWalletSyncService(this.cardanoRpc);
    _chainNetworks[ChainId.cardano] = CardanoHotPlugin.instance.defaultNetwork;
    _chainNetworks[ChainId.bitcoin] = BitcoinHotPlugin.instance.defaultNetwork;
    _chainNetworks[ChainId.ethereum] = EvmHotPlugin.ethereum.defaultNetwork;
    _chainNetworks[ChainId.hyperliquid] = EvmHotPlugin.hyperliquid.defaultNetwork;
    _chainNetworks[ChainId.solana] = SolanaHotPlugin.instance.defaultNetwork;
    _chainNetworks[ChainId.sui] = SuiHotPlugin.instance.defaultNetwork;
  }

  CardanoNetwork get network => _network;
  ChainId get activeChainId => _activeChainId;
  IHotChainPlugin get activeChainPlugin => chainRegistry.getPlugin(_activeChainId);
  ChainNetwork get activeChainNetwork =>
      _chainNetworks[_activeChainId] ?? activeChainPlugin.defaultNetwork;
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

  Map<String, String> get customRpcEndpoints => Map.unmodifiable(_customRpcEndpoints);
  String getCustomRpcEndpoint(String key, String defaultUrl) => _customRpcEndpoints[key] ?? defaultUrl;

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

        final chainIdStr = json['activeChainId'] as String?;
        if (chainIdStr != null) {
          _activeChainId = ChainId.values.firstWhere(
            (c) => c.id == chainIdStr,
            orElse: () => ChainId.cardano,
          );
        }

        final evmProfList = json['evmProfiles'] as List<dynamic>? ?? [];
        _evmProfiles
          ..clear()
          ..addAll(
            evmProfList.map(
              (e) => EvmWatchOnlyProfile.fromJson(e as Map<String, dynamic>),
            ),
          );
        _activeEvmProfileId = json['activeEvmProfileId'] as String?;

        final btcProfList = json['btcProfiles'] as List<dynamic>? ?? [];
        _btcProfiles
          ..clear()
          ..addAll(
            btcProfList.map(
              (e) => BtcWatchOnlyProfile.fromJson(e as Map<String, dynamic>),
            ),
          );
        _activeBtcProfileId = json['activeBtcProfileId'] as String?;

        final solProfList = json['solProfiles'] as List<dynamic>? ?? [];
        _solProfiles
          ..clear()
          ..addAll(
            solProfList.map(
              (e) => SolWatchOnlyProfile.fromJson(e as Map<String, dynamic>),
            ),
          );
        _activeSolProfileId = json['activeSolProfileId'] as String?;

        final suiProfList = json['suiProfiles'] as List<dynamic>? ?? [];
        _suiProfiles
          ..clear()
          ..addAll(
            suiProfList.map(
              (e) => SuiWatchOnlyProfile.fromJson(e as Map<String, dynamic>),
            ),
          );
        _activeSuiProfileId = json['activeSuiProfileId'] as String?;

        final netId = json['selectedNetwork'] as String?;
        if (netId != null) {
          _network = CardanoNetwork.fromId(netId);
        }
        final loc = json['locale'] as String?;
        if (loc == 'en') _locale = HotLocale.en;
        _gapLimit = (json['gapLimit'] as num?)?.toInt() ?? 20;

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

        final rpcMap = json['customRpcEndpoints'] as Map<String, dynamic>? ?? {};
        _customRpcEndpoints
          ..clear()
          ..addAll({
            for (final e in rpcMap.entries)
              if (e.value is String && (e.value as String).isNotEmpty)
                e.key: e.value as String,
          });
        final upgradedRpcDefaults = _upgradeObsoleteDefaultRpcEndpoints();
        _applyCustomEndpoints();

        final txMap = json['localBroadcastTxs'] as Map<String, dynamic>? ?? {};
        _localBroadcastTxs.clear();
        for (final entry in txMap.entries) {
          if (entry.value is List) {
            _localBroadcastTxs[entry.key] = (entry.value as List<dynamic>)
                .whereType<Map<String, dynamic>>()
                .map(ChainTxRecord.fromJson)
                .toList();
          }
        }
        if (upgradedRpcDefaults) {
          await _persist();
        }
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
      'profiles': [for (final p in _profiles) p.toJson()],
      'activeProfileId': _activeProfileId,
      'customTokenDecimals': _customTokenDecimals,
      'activeChainId': _activeChainId.id,
      'evmProfiles': [for (final p in _evmProfiles) p.toJson()],
      'activeEvmProfileId': _activeEvmProfileId,
      'btcProfiles': [for (final p in _btcProfiles) p.toJson()],
      'activeBtcProfileId': _activeBtcProfileId,
      'solProfiles': [for (final p in _solProfiles) p.toJson()],
      'activeSolProfileId': _activeSolProfileId,
      'suiProfiles': [for (final p in _suiProfiles) p.toJson()],
      'activeSuiProfileId': _activeSuiProfileId,
      'customRpcEndpoints': _customRpcEndpoints,
      'localBroadcastTxs': {
        for (final e in _localBroadcastTxs.entries)
          e.key: [for (final tx in e.value) tx.toJson()],
      },
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

  List<EvmWatchOnlyProfile> get allEvmProfiles => List.unmodifiable(_evmProfiles);

  List<EvmWatchOnlyProfile> get currentChainEvmProfiles =>
      _evmProfiles.where((p) => p.chainId == _activeChainId).toList();

  EvmWatchOnlyProfile? get activeEvmProfile {
    final matching = currentChainEvmProfiles;
    if (matching.isEmpty) return null;
    for (final p in matching) {
      if (p.id == _activeEvmProfileId) return p;
    }
    return matching.first;
  }

  Map<String, dynamic>? get evmAccountState => _evmAccountState;
  bool get evmLoading => _evmLoading;
  String? get evmError => _evmError;

  void setActiveChain(ChainId next) {
    if (_activeChainId == next) return;
    _activeChainId = next;
    _persist();
    notifyListeners();
    if (_activeChainId == ChainId.cardano) {
      if (activeProfile != null) {
        syncActiveWallet();
      }
    } else if (_activeChainId == ChainId.bitcoin) {
      if (activeBtcProfile != null) {
        refreshBtcState();
      }
    } else if (_activeChainId == ChainId.solana) {
      if (activeSolProfile != null) {
        refreshSolState();
      }
    } else if (_activeChainId == ChainId.sui) {
      if (activeSuiProfile != null) {
        refreshSuiState();
      }
    } else {
      if (activeEvmProfile != null) {
        refreshEvmState();
      }
    }
  }

  void setActiveChainNetwork(ChainNetwork network) {
    _chainNetworks[_activeChainId] = network;
    if (_activeChainId == ChainId.cardano) {
      _network = CardanoNetwork.fromId(network.id);
      final p = activeProfile;
      _syncState = p == null ? null : _syncCache['${p.id}:${_network.id}'];
      _syncError = null;
    }
    _persist();
    notifyListeners();
    if (_activeChainId == ChainId.cardano) {
      if (activeProfile != null) {
        syncActiveWallet();
      }
    } else if (_activeChainId == ChainId.bitcoin) {
      if (activeBtcProfile != null) {
        refreshBtcState();
      }
    } else if (_activeChainId == ChainId.solana) {
      if (activeSolProfile != null) {
        refreshSolState();
      }
    } else if (_activeChainId == ChainId.sui) {
      if (activeSuiProfile != null) {
        refreshSuiState();
      }
    } else {
      if (activeEvmProfile != null) {
        refreshEvmState();
      }
    }
  }

  Future<EvmWatchOnlyProfile> addEvmProfile({
    required String name,
    required ChainId chainId,
    required String address,
    String networkId = 'mainnet',
    int accountIndex = 0,
  }) async {
    final id = '${chainId.id}_${DateTime.now().microsecondsSinceEpoch}';
    final profile = EvmWatchOnlyProfile(
      id: id,
      name: name.trim().isEmpty ? '${chainId.name.toUpperCase()} Account' : name.trim(),
      chainId: chainId,
      networkId: networkId,
      address: address.trim(),
      accountIndex: accountIndex,
    );
    _evmProfiles.add(profile);
    _activeEvmProfileId = profile.id;
    await _persist();
    notifyListeners();
    await refreshEvmState();
    return profile;
  }

  Future<void> selectEvmProfile(String id) async {
    _activeEvmProfileId = id;
    await _persist();
    notifyListeners();
    await refreshEvmState();
  }

  Future<void> renameEvmProfile(String id, String newName) async {
    final idx = _evmProfiles.indexWhere((p) => p.id == id);
    if (idx == -1 || newName.trim().isEmpty) return;
    _evmProfiles[idx] = _evmProfiles[idx].copyWith(name: newName.trim());
    await _persist();
    notifyListeners();
  }

  Future<void> deleteEvmProfile(String id) async {
    _evmProfiles.removeWhere((p) => p.id == id);
    if (_activeEvmProfileId == id) {
      _activeEvmProfileId =
          currentChainEvmProfiles.isNotEmpty ? currentChainEvmProfiles.first.id : null;
    }
    await _persist();
    notifyListeners();
    if (activeEvmProfile != null) {
      await refreshEvmState();
    } else {
      _evmAccountState = null;
      notifyListeners();
    }
  }

  Future<void> refreshEvmState() async {
    final profile = activeEvmProfile;
    if (profile == null) {
      _evmAccountState = null;
      notifyListeners();
      return;
    }
    _evmLoading = true;
    _evmError = null;
    notifyListeners();
    try {
      final plugin = activeChainPlugin;
      final state = await plugin.fetchAccountBalance(
        network: activeChainNetwork,
        address: profile.address,
      );
      _evmAccountState = state;
    } catch (e) {
      _evmError = e.toString();
    } finally {
      _evmLoading = false;
      notifyListeners();
    }
  }

  List<BtcWatchOnlyProfile> get allBtcProfiles => List.unmodifiable(_btcProfiles);

  List<BtcWatchOnlyProfile> get currentChainBtcProfiles =>
      _btcProfiles.where((p) => p.networkId == activeChainNetwork.id).toList();

  BtcWatchOnlyProfile? get activeBtcProfile {
    final matching = currentChainBtcProfiles;
    if (matching.isEmpty) {
      if (_btcProfiles.isNotEmpty) return _btcProfiles.first;
      return null;
    }
    for (final p in matching) {
      if (p.id == _activeBtcProfileId) return p;
    }
    return matching.first;
  }

  Map<String, dynamic>? get btcAccountState => _btcAccountState;
  BtcWalletSyncState? get btcSyncState => _btcSyncState;
  bool get btcLoading => _btcLoading;
  String? get btcError => _btcError;

  Future<BtcWatchOnlyProfile> addBtcProfile({
    required String name,
    required String receiveAddress,
    String networkId = 'testnet4',
    int accountIndex = 0,
    int masterFingerprint = 0,
    String? accountXpub,
  }) async {
    final id = 'btc_${DateTime.now().microsecondsSinceEpoch}';
    final profile = BtcWatchOnlyProfile(
      id: id,
      name: name.trim().isEmpty ? 'Bitcoin Account' : name.trim(),
      networkId: networkId,
      receiveAddress: receiveAddress.trim(),
      accountIndex: accountIndex,
      masterFingerprint: masterFingerprint,
      accountXpub: accountXpub,
    );
    _btcProfiles.add(profile);
    _activeBtcProfileId = profile.id;
    await _persist();
    notifyListeners();
    await refreshBtcState();
    return profile;
  }

  Future<void> selectBtcProfile(String id) async {
    _activeBtcProfileId = id;
    await _persist();
    notifyListeners();
    await refreshBtcState();
  }

  Future<void> renameBtcProfile(String id, String newName) async {
    final idx = _btcProfiles.indexWhere((p) => p.id == id);
    if (idx == -1 || newName.trim().isEmpty) return;
    _btcProfiles[idx] = _btcProfiles[idx].copyWith(name: newName.trim());
    await _persist();
    notifyListeners();
  }

  Future<void> deleteBtcProfile(String id) async {
    _btcProfiles.removeWhere((p) => p.id == id);
    if (_activeBtcProfileId == id) {
      _activeBtcProfileId =
          currentChainBtcProfiles.isNotEmpty ? currentChainBtcProfiles.first.id : null;
    }
    await _persist();
    notifyListeners();
    if (activeBtcProfile != null) {
      await refreshBtcState();
    } else {
      _btcAccountState = null;
      _btcSyncState = null;
      notifyListeners();
    }
  }

  Future<void> refreshBtcState() async {
    final profile = activeBtcProfile;
    if (profile == null) {
      _btcAccountState = null;
      _btcSyncState = null;
      notifyListeners();
      return;
    }
    _btcLoading = true;
    _btcError = null;
    notifyListeners();
    try {
      final hdSync = BtcHdWalletSyncService(BitcoinHotPlugin.instance.mempoolService);
      final synced = await hdSync.syncProfile(
        profile: profile,
        networkId: activeChainNetwork.id,
        gapLimit: _gapLimit,
      );
      _btcSyncState = synced;
      _btcAccountState = {
        'address': synced.nextUnusedExternalAddress,
        'primaryReceiveAddress': synced.primaryReceiveAddress,
        'nextUnusedChangeAddress': synced.nextUnusedChangeAddress,
        'nextUnusedChangeIndex': synced.nextUnusedChangeIndex,
        'isHdSynced': synced.isHdSynced,
        'network': activeChainNetwork.id,
        'balanceSat': synced.totalSat.toString(),
        'utxos': [for (final u in synced.utxos) u.utxo],
        'derivedUtxos': synced.utxos,
        'utxoCount': synced.utxos.length,
        'recentTxs': synced.recentTxs,
        'historyError': ?synced.historyError,
      };
    } catch (e) {
      _btcError = e.toString();
    } finally {
      _btcLoading = false;
      notifyListeners();
    }
  }

  void loadDemoBtcData() {
    if (activeBtcProfile == null) {
      addBtcProfile(
        name: 'Bitcoin Demo Account',
        receiveAddress: 'tb1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu',
        networkId: activeChainNetwork.id,
      );
    }
    final profile = activeBtcProfile;
    final address = profile?.receiveAddress ?? 'tb1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu';
    final demoUtxo0 = MempoolUtxo(
      txid: '1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b',
      vout: 0,
      valueSat: BigInt.from(1000000), // 0.01 BTC
      confirmed: true,
      blockHeight: 850123,
    );
    final demoUtxo1 = MempoolUtxo(
      txid: '9f8e7d6c5b4a3f2e1d0c9b8a7f6e5d4c3b2a1f0e9d8c7b6a5f4e3d2c1b0a9f8e',
      vout: 1,
      valueSat: BigInt.from(500000), // 0.005 BTC
      confirmed: true,
      blockHeight: 850130,
    );
    final demoDerived = [
      BtcDerivedUtxo(
        utxo: demoUtxo0,
        accountIndex: profile?.accountIndex ?? 0,
        change: 0,
        addressIndex: 0,
        address: address,
      ),
      BtcDerivedUtxo(
        utxo: demoUtxo1,
        accountIndex: profile?.accountIndex ?? 0,
        change: 1,
        addressIndex: 0,
        address: address,
      ),
    ];
    final demoRecent = [
      ChainTxRecord(
        txHash: '9f8e7d6c5b4a3f2e1d0c9b8a7f6e5d4c3b2a1f0e9d8c7b6a5f4e3d2c1b0a9f8e',
        timestampMs: 1730005000000,
        status: 'confirmed',
        direction: 'in',
        summary: '+0.00500000 BTC',
        blockOrSlot: 'Block #850130',
        explorerUrl: MempoolService.explorerTxUrl(
          activeChainNetwork.id,
          '9f8e7d6c5b4a3f2e1d0c9b8a7f6e5d4c3b2a1f0e9d8c7b6a5f4e3d2c1b0a9f8e',
        ),
      ),
    ];
    _btcSyncState = BtcWalletSyncState(
      totalSat: BigInt.from(1500000),
      utxos: demoDerived,
      primaryReceiveAddress: address,
      nextUnusedExternalAddress: address,
      nextUnusedExternalIndex: 0,
      nextUnusedChangeAddress: address,
      nextUnusedChangeIndex: 1,
      recentTxs: demoRecent,
      isHdSynced: profile?.hasAccountXpub ?? false,
    );
    _btcError = null;
    _btcAccountState = {
      'address': address,
      'network': activeChainNetwork.id,
      'balanceSat': '1500000', // 0.015 BTC
      'utxoCount': 2,
      'utxos': [demoUtxo0, demoUtxo1],
      'derivedUtxos': demoDerived,
      'recentTxs': demoRecent,
    };
    notifyListeners();
  }

  // Solana Profile & State Management
  List<SolWatchOnlyProfile> get allSolProfiles => List.unmodifiable(_solProfiles);

  List<SolWatchOnlyProfile> get currentChainSolProfiles =>
      _solProfiles.where((p) => p.networkId == activeChainNetwork.id).toList();

  SolWatchOnlyProfile? get activeSolProfile {
    final matching = currentChainSolProfiles;
    if (matching.isEmpty) {
      if (_solProfiles.isNotEmpty) return _solProfiles.first;
      return null;
    }
    for (final p in matching) {
      if (p.id == _activeSolProfileId) return p;
    }
    return matching.first;
  }

  Map<String, dynamic>? get solAccountState => _solAccountState;
  bool get solLoading => _solLoading;
  String? get solError => _solError;

  Future<SolWatchOnlyProfile> addSolProfile({
    required String name,
    required String address,
    String networkId = 'devnet',
    int accountIndex = 0,
  }) async {
    final id = 'sol_${DateTime.now().microsecondsSinceEpoch}';
    final profile = SolWatchOnlyProfile(
      id: id,
      name: name.trim().isEmpty ? 'Solana Account' : name.trim(),
      networkId: networkId,
      address: address.trim(),
      accountIndex: accountIndex,
    );
    _solProfiles.add(profile);
    _activeSolProfileId = profile.id;
    await _persist();
    notifyListeners();
    await refreshSolState();
    return profile;
  }

  Future<void> selectSolProfile(String id) async {
    _activeSolProfileId = id;
    await _persist();
    notifyListeners();
    await refreshSolState();
  }

  Future<void> renameSolProfile(String id, String newName) async {
    final idx = _solProfiles.indexWhere((p) => p.id == id);
    if (idx == -1 || newName.trim().isEmpty) return;
    _solProfiles[idx] = _solProfiles[idx].copyWith(name: newName.trim());
    await _persist();
    notifyListeners();
  }

  Future<void> deleteSolProfile(String id) async {
    _solProfiles.removeWhere((p) => p.id == id);
    if (_activeSolProfileId == id) {
      _activeSolProfileId =
          currentChainSolProfiles.isNotEmpty ? currentChainSolProfiles.first.id : null;
    }
    await _persist();
    notifyListeners();
    if (activeSolProfile != null) {
      await refreshSolState();
    } else {
      _solAccountState = null;
      notifyListeners();
    }
  }

  Future<void> refreshSolState() async {
    final profile = activeSolProfile;
    if (profile == null) {
      _solAccountState = null;
      notifyListeners();
      return;
    }
    _solLoading = true;
    _solError = null;
    notifyListeners();
    try {
      final plugin = SolanaHotPlugin.instance;
      final state = await plugin.fetchAccountBalance(
        network: activeChainNetwork,
        address: profile.address,
      );
      _solAccountState = state;
    } catch (e) {
      _solError = e.toString();
    } finally {
      _solLoading = false;
      notifyListeners();
    }
  }

  void loadDemoSolData() {
    if (activeSolProfile == null) {
      addSolProfile(
        name: 'Solana Demo Account',
        address: 'Ab6JNNGNQJbj1EPZ4Fa6wCitFxzuAh1YG23kBxxYFKib',
        networkId: activeChainNetwork.id,
      );
    }
    final profile = activeSolProfile;
    final address = profile?.address ?? 'Ab6JNNGNQJbj1EPZ4Fa6wCitFxzuAh1YG23kBxxYFKib';
    _solError = null;
    _solAccountState = {
      'address': address,
      'network': activeChainNetwork.id,
      'lamports': '3500000000',
      'sol': '3.5000',
      'recentTxs': [
        ChainTxRecord(
          txHash: '5VERv8NMvzbJMEkV8xnrLkEaWRtSz9CosKDYjCJjBRnbJLgp8uirBgmQpjKhoR4tjF3ZpRzrFmBV6UjKdiSZkQUW',
          timestampMs: 1730005000000,
          status: 'confirmed',
          direction: 'in',
          blockOrSlot: 'Slot #312456789',
          explorerUrl:
              'https://explorer.solana.com/tx/5VERv8NMvzbJMEkV8xnrLkEaWRtSz9CosKDYjCJjBRnbJLgp8uirBgmQpjKhoR4tjF3ZpRzrFmBV6UjKdiSZkQUW?cluster=${activeChainNetwork.id}',
        ),
      ],
    };
    notifyListeners();
  }

  // Sui Profile & State Management
  List<SuiWatchOnlyProfile> get allSuiProfiles => List.unmodifiable(_suiProfiles);

  List<SuiWatchOnlyProfile> get currentChainSuiProfiles =>
      _suiProfiles.where((p) => p.networkId == activeChainNetwork.id).toList();

  SuiWatchOnlyProfile? get activeSuiProfile {
    final matching = currentChainSuiProfiles;
    if (matching.isEmpty) {
      if (_suiProfiles.isNotEmpty) return _suiProfiles.first;
      return null;
    }
    for (final p in matching) {
      if (p.id == _activeSuiProfileId) return p;
    }
    return matching.first;
  }

  Map<String, dynamic>? get suiAccountState => _suiAccountState;
  bool get suiLoading => _suiLoading;
  String? get suiError => _suiError;

  Future<SuiWatchOnlyProfile> addSuiProfile({
    required String name,
    required String address,
    String networkId = 'testnet',
    int accountIndex = 0,
    int addressIndex = 0,
  }) async {
    final id = 'sui_${DateTime.now().microsecondsSinceEpoch}';
    final profile = SuiWatchOnlyProfile(
      id: id,
      name: name.trim().isEmpty ? 'Sui Account' : name.trim(),
      networkId: networkId,
      address: address.trim(),
      accountIndex: accountIndex,
      addressIndex: addressIndex,
    );
    _suiProfiles.add(profile);
    _activeSuiProfileId = profile.id;
    await _persist();
    notifyListeners();
    await refreshSuiState();
    return profile;
  }

  Future<void> selectSuiProfile(String id) async {
    _activeSuiProfileId = id;
    await _persist();
    notifyListeners();
    await refreshSuiState();
  }

  Future<void> renameSuiProfile(String id, String newName) async {
    final idx = _suiProfiles.indexWhere((p) => p.id == id);
    if (idx == -1 || newName.trim().isEmpty) return;
    _suiProfiles[idx] = _suiProfiles[idx].copyWith(name: newName.trim());
    await _persist();
    notifyListeners();
  }

  String _txCacheKey(ChainId chainId, String networkId, String address) =>
      '${chainId.id}:${networkId.toLowerCase()}:${address.toLowerCase()}';

  Future<void> recordRecentBroadcastTx({
    required ChainId chainId,
    required String networkId,
    required String address,
    required String txHash,
    String summary = '',
    String explorerUrl = '',
    String blockOrSlot = 'Broadcasted',
  }) async {
    if (txHash.trim().isEmpty) return;
    final key = _txCacheKey(chainId, networkId, address);
    final list = List<ChainTxRecord>.from(_localBroadcastTxs[key] ?? const []);
    list.removeWhere((t) => t.txHash.toLowerCase() == txHash.toLowerCase());
    list.insert(
      0,
      ChainTxRecord(
        txHash: txHash.trim(),
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        status: 'pending',
        direction: 'out',
        summary: summary,
        blockOrSlot: blockOrSlot,
        explorerUrl: explorerUrl,
      ),
    );
    if (list.length > 20) {
      list.removeRange(20, list.length);
    }
    _localBroadcastTxs[key] = list;
    await _persist();
    notifyListeners();
  }

  List<ChainTxRecord> recentTxsFor({
    required ChainId chainId,
    required String networkId,
    required String address,
    List<ChainTxRecord> remoteTxs = const [],
  }) {
    final key = _txCacheKey(chainId, networkId, address);
    final local = _localBroadcastTxs[key] ?? const [];
    final mergedByHash = <String, ChainTxRecord>{};

    for (final tx in remoteTxs) {
      mergedByHash[tx.txHash.toLowerCase()] = tx;
    }
    for (final tx in local) {
      final hashKey = tx.txHash.toLowerCase();
      final remote = mergedByHash[hashKey];
      if (remote == null) {
        mergedByHash[hashKey] = tx;
      } else if (remote.summary.isEmpty && tx.summary.isNotEmpty) {
        mergedByHash[hashKey] = remote.copyWith(summary: tx.summary);
      }
    }

    final sorted = mergedByHash.values.toList()
      ..sort((a, b) => b.timestampMs.compareTo(a.timestampMs));
    return sorted;
  }

  Future<void> deleteSuiProfile(String id) async {
    _suiProfiles.removeWhere((p) => p.id == id);
    if (_activeSuiProfileId == id) {
      _activeSuiProfileId =
          currentChainSuiProfiles.isNotEmpty ? currentChainSuiProfiles.first.id : null;
    }
    await _persist();
    notifyListeners();
    if (activeSuiProfile != null) {
      await refreshSuiState();
    } else {
      _suiAccountState = null;
      notifyListeners();
    }
  }

  Future<void> refreshSuiState() async {
    final profile = activeSuiProfile;
    if (profile == null) {
      _suiAccountState = null;
      notifyListeners();
      return;
    }
    _suiLoading = true;
    _suiError = null;
    notifyListeners();
    try {
      final plugin = SuiHotPlugin.instance;
      final state = await plugin.fetchAccountBalance(
        network: activeChainNetwork,
        address: profile.address,
      );
      _suiAccountState = state;
    } catch (e) {
      _suiError = e.toString();
    } finally {
      _suiLoading = false;
      notifyListeners();
    }
  }

  void loadDemoSuiData() {
    if (activeSuiProfile == null) {
      addSuiProfile(
        name: 'Sui Demo Account',
        address: '0xd404e60fc990df26ad7355c607f61c93162b5ed3e778015757f5b44d5bfe7f07',
        networkId: activeChainNetwork.id,
      );
    }
    final profile = activeSuiProfile;
    final address = profile?.address ?? '0xd404e60fc990df26ad7355c607f61c93162b5ed3e778015757f5b44d5bfe7f07';
    _suiError = null;
    _suiAccountState = {
      'address': address,
      'network': activeChainNetwork.id,
      'mist': '7250000000',
      'sui': '7.2500',
      'recentTxs': [
        ChainTxRecord(
          txHash: 'Byw8L2tV7P5vH1mQ9r4sK6fN3xJ8zA2cD5eG7hM9pQ1rT',
          timestampMs: 1730005000000,
          status: 'confirmed',
          direction: 'in',
          blockOrSlot: 'Checkpoint #102488',
          explorerUrl:
              'https://suiscan.xyz/${activeChainNetwork.id}/tx/Byw8L2tV7P5vH1mQ9r4sK6fN3xJ8zA2cD5eG7hM9pQ1rT',
        ),
      ],
    };
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
    if (p != null) {
      await syncActiveWallet();
    }
  }

  static void validateCustomRpcUrl(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.hasAuthority || uri.host.isEmpty) {
      throw ArgumentError('Invalid Custom RPC URL format: $url');
    }
    final scheme = uri.scheme.toLowerCase();
    final host = uri.host.toLowerCase();
    final isLocalhost = host == 'localhost' || host == '127.0.0.1' || host == '::1';
    if (scheme == 'https') return;
    if (scheme == 'http' && isLocalhost) return;
    throw ArgumentError(
      'Custom RPC URL must use https:// (http:// is allowed only for localhost/127.0.0.1)',
    );
  }

  Future<void> saveSettings({
    required int gapLimit,
    Map<String, String>? customRpcEndpoints,
  }) async {
    _gapLimit = gapLimit.clamp(5, 100);
    if (customRpcEndpoints != null) {
      final validated = <String, String>{};
      for (final e in customRpcEndpoints.entries) {
        final v = e.value.trim();
        if (v.isEmpty) continue;
        validateCustomRpcUrl(v);
        validated[e.key] = v;
      }
      _customRpcEndpoints
        ..clear()
        ..addAll(validated);
      _applyCustomEndpoints();
    }
    await _persist();
    notifyListeners();
  }

  static const Map<String, Set<String>> _obsoleteDefaultRpcUrls = {
    'eth_mainnet': {'https://cloudflare-eth.com'},
    'sol_mainnet-beta': {'https://api.mainnet-beta.solana.com'},
  };

  /// Drops persisted entries that still point to retired/blocked default RPCs
  /// so existing users automatically pick up the updated working defaults.
  bool _upgradeObsoleteDefaultRpcEndpoints() {
    var changed = false;
    for (final entry in _obsoleteDefaultRpcUrls.entries) {
      final current = _customRpcEndpoints[entry.key];
      if (current == null) continue;
      final normalized = current.trim().replaceFirst(RegExp(r'/+$'), '').toLowerCase();
      if (entry.value.contains(normalized)) {
        _customRpcEndpoints.remove(entry.key);
        changed = true;
      }
    }
    return changed;
  }

  void _applyCustomEndpoints() {
    cardanoRpc
      ..resetToDefaultRpcUrl('preprod')
      ..resetToDefaultRpcUrl('preview')
      ..resetToDefaultRpcUrl('mainnet');
    EvmHotPlugin.ethereum.rpcService
      ..resetToDefaultRpcUrl('mainnet')
      ..resetToDefaultRpcUrl('sepolia')
      ..resetToDefaultRpcUrl('holesky');
    SolanaHotPlugin.instance.rpcService
      ..resetToDefaultRpcUrl('mainnet-beta')
      ..resetToDefaultRpcUrl('devnet')
      ..resetToDefaultRpcUrl('testnet');

    for (final e in _customRpcEndpoints.entries) {
      final key = e.key.toLowerCase();
      final url = e.value;
      try {
        validateCustomRpcUrl(url);
      } catch (_) {
        continue;
      }
      if (key.startsWith('cardano_')) {
        final net = key.replaceFirst('cardano_', '');
        cardanoRpc.setCustomRpcUrl(net, url);
      } else if (key.startsWith('btc_')) {
        final net = key.replaceFirst('btc_', '');
        BitcoinHotPlugin.instance.mempoolService.setCustomApiUrl(net, url);
      } else if (key.startsWith('eth_')) {
        final net = key.replaceFirst('eth_', '');
        EvmHotPlugin.ethereum.rpcService.setCustomRpcUrl(net, url);
      } else if (key.startsWith('hl_')) {
        final net = key.replaceFirst('hl_', '');
        EvmHotPlugin.hyperliquid.hlService.setCustomApiUrl(net, url);
      } else if (key.startsWith('sol_')) {
        final net = key.replaceFirst('sol_', '');
        SolanaHotPlugin.instance.rpcService.setCustomRpcUrl(net, url);
      } else if (key.startsWith('sui_')) {
        final net = key.replaceFirst('sui_', '');
        SuiHotPlugin.instance.rpcService.setCustomRpcUrl(net, url);
      }
    }
  }

  Future<String> testEndpointConnection(String chainKey, String netId, String endpointOrKey) async {
    final ep = endpointOrKey.trim();
    if (ep.isEmpty) throw Exception('Endpoint URL / Key không được để trống');
    validateCustomRpcUrl(ep);
    final chain = chainKey.toLowerCase();
    if (chain == 'cardano') {
      cardanoRpc.setCustomRpcUrl(netId, ep);
      final slot = await cardanoRpc.getLatestSlot(CardanoNetwork.fromId(netId));
      return 'OK • Latest slot: $slot';
    } else if (chain == 'btc') {
      BitcoinHotPlugin.instance.mempoolService.setCustomApiUrl(netId, ep);
      final rates = await BitcoinHotPlugin.instance.mempoolService.getRecommendedFees(netId);
      return 'OK • Phí đề xuất: ${rates.fastestFee} sat/vB';
    } else if (chain == 'eth') {
      EvmHotPlugin.ethereum.rpcService.setCustomRpcUrl(netId, ep);
      final blockNum = await EvmHotPlugin.ethereum.rpcService.callRpc(netId, 'eth_blockNumber', []);
      final parsed = BigInt.tryParse(blockNum.toString()) ?? BigInt.zero;
      return 'OK • EVM Block: $parsed';
    } else if (chain == 'hl') {
      return 'OK • Hyperliquid API cấu hình: $ep';
    } else if (chain == 'sol') {
      SolanaHotPlugin.instance.rpcService.setCustomRpcUrl(netId, ep);
      final blockhash = await SolanaHotPlugin.instance.rpcService.getLatestBlockhash(networkId: netId);
      return 'OK • Solana Blockhash: ${blockhash.length} bytes';
    } else if (chain == 'sui') {
      SuiHotPlugin.instance.rpcService.setCustomRpcUrl(netId, ep);
      return 'OK • Sui Fullnode RPC cấu hình: $ep';
    }
    throw Exception('Chuỗi không hỗ trợ: $chainKey');
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
    if (profile.network == _network) {
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
    await syncActiveWallet();
  }

  Future<void> syncActiveWallet() async {
    final profile = activeProfile;
    if (profile == null) return;

    final mySeq = ++_syncSeq;
    _syncing = true;
    _syncError = null;
    notifyListeners();

    try {
      final result = await syncService.syncProfile(
        profile: profile,
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
          utxo: CardanoUtxo(
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
          utxo: CardanoUtxo(
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
          utxo: CardanoUtxo(
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
