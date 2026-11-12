import 'dart:typed_data';

import 'bech32.dart';
import 'blake2b.dart';
import 'ed25519_bip32.dart';

/// Supported Cardano networks. Default across both apps is [CardanoNetwork.preprod].
enum CardanoNetwork {
  preprod(
    urCode: 0,
    networkTag: 0,
    id: 'preprod',
    addressPrefix: 'addr_test',
    stakePrefix: 'stake_test',
    blockfrostBaseUrl: 'https://cardano-preprod.blockfrost.io/api/v0',
    explorerBaseUrl: 'https://preprod.cardanoscan.io',
  ),
  preview(
    urCode: 1,
    networkTag: 0,
    id: 'preview',
    addressPrefix: 'addr_test',
    stakePrefix: 'stake_test',
    blockfrostBaseUrl: 'https://cardano-preview.blockfrost.io/api/v0',
    explorerBaseUrl: 'https://preview.cardanoscan.io',
  ),
  mainnet(
    urCode: 2,
    networkTag: 1,
    id: 'mainnet',
    addressPrefix: 'addr',
    stakePrefix: 'stake',
    blockfrostBaseUrl: 'https://cardano-mainnet.blockfrost.io/api/v0',
    explorerBaseUrl: 'https://cardanoscan.io',
  );

  final int urCode;
  final int networkTag;
  final String id;
  final String addressPrefix;
  final String stakePrefix;
  final String blockfrostBaseUrl;
  final String explorerBaseUrl;

  const CardanoNetwork({
    required this.urCode,
    required this.networkTag,
    required this.id,
    required this.addressPrefix,
    required this.stakePrefix,
    required this.blockfrostBaseUrl,
    required this.explorerBaseUrl,
  });

  bool get isTestnet => networkTag == 0;

  String explorerTxUrl(String txHash) => '$explorerBaseUrl/transaction/$txHash';

  static CardanoNetwork fromUrCode(int code) {
    for (final n in values) {
      if (n.urCode == code) return n;
    }
    throw FormatException('Unsupported Cardano UR network code: $code');
  }

  static CardanoNetwork fromId(String id) {
    for (final n in values) {
      if (n.id == id.toLowerCase()) return n;
    }
    throw FormatException('Unsupported Cardano network id: $id');
  }
}

/// Decoded components of a Shelley/Conway address.
class DecodedAddress {
  final String hrp;
  final Uint8List rawBytes;
  final int headerByte;
  final int addressType;
  final int networkTag;
  final Uint8List paymentHash;
  final Uint8List? stakeHash;

  const DecodedAddress({
    required this.hrp,
    required this.rawBytes,
    required this.headerByte,
    required this.addressType,
    required this.networkTag,
    required this.paymentHash,
    this.stakeHash,
  });

  bool get isRewardAddress => addressType == 0x0e || addressType == 0x0f;
}

/// Decoded DRep credential from Bech32 `drep1...` (CIP-105 28B or CIP-129 29B).
class DecodedDRepId {
  final bool isScriptHash;
  final Uint8List hash28;

  const DecodedDRepId({required this.isScriptHash, required this.hash28});
}

/// CIP-1852 Cardano Key Manager holding the Icarus V2 root key in memory.
class CardanoMasterKey {
  final ExtendedPrivateKey rootKey;

  CardanoMasterKey._(this.rootKey);

  /// Derives a Cardano master key from BIP-39 [entropy] and optional [passphrase].
  factory CardanoMasterKey.fromEntropy(
    Uint8List entropy, {
    String passphrase = '',
  }) {
    return CardanoMasterKey._(
      ExtendedPrivateKey.fromIcarusEntropy(entropy, passphrase: passphrase),
    );
  }

  /// Constructs a Cardano master key from a pre-derived 96-byte Icarus PBKDF2 seed.
  factory CardanoMasterKey.fromIcarusSeed(Uint8List seed96) {
    return CardanoMasterKey._(ExtendedPrivateKey.fromIcarusSeed(seed96));
  }

  /// Derives the CIP-1852 account private key `m/1852'/1815'/accountIndex'`.
  ExtendedPrivateKey deriveAccountPrivateKey({int accountIndex = 0}) {
    final purpose = rootKey.deriveHardened(1852);
    final coinType = purpose.deriveHardened(1815);
    final account = coinType.deriveHardened(accountIndex);
    purpose.dispose();
    coinType.dispose();
    return account;
  }

  /// Exports the 64-byte Extended Account Public Key (`acct_xvk`) at `m/1852'/1815'/accountIndex'`.
  CardanoAccountPublicKey exportAccountPublicKey({int accountIndex = 0}) {
    final acctPrv = deriveAccountPrivateKey(accountIndex: accountIndex);
    try {
      return CardanoAccountPublicKey(acctPrv.toExtendedPublicKey());
    } finally {
      acctPrv.dispose();
    }
  }

  /// Derives a signing key at `m/1852'/1815'/accountIndex'/role/index`.
  ExtendedPrivateKey deriveAddressSigningKey({
    int accountIndex = 0,
    required int role,
    required int index,
  }) {
    final acctPrv = deriveAccountPrivateKey(accountIndex: accountIndex);
    final rolePrv = acctPrv.deriveChild(role);
    final addrPrv = rolePrv.deriveChild(index);
    acctPrv.dispose();
    rolePrv.dispose();
    return addrPrv;
  }

  /// Derives the 28-byte stake key hash at `m/1852'/1815'/accountIndex'/2/0`.
  Uint8List deriveStakeKeyHash({int accountIndex = 0}) {
    final stakePrv = deriveAddressSigningKey(
      accountIndex: accountIndex,
      role: 2,
      index: 0,
    );
    try {
      return blake2b224(stakePrv.publicKey);
    } finally {
      stakePrv.dispose();
    }
  }

  /// Derives raw Base Address bytes (57 bytes) for `role/index` combined with stake `2/0`.
  Uint8List deriveBaseAddressBytes({
    int accountIndex = 0,
    required int role,
    required int index,
    required CardanoNetwork network,
  }) {
    final payPrv = deriveAddressSigningKey(
      accountIndex: accountIndex,
      role: role,
      index: index,
    );
    final stakePrv = deriveAddressSigningKey(
      accountIndex: accountIndex,
      role: 2,
      index: 0,
    );
    try {
      final payHash = blake2b224(payPrv.publicKey);
      final stakeHash = blake2b224(stakePrv.publicKey);
      return CardanoAddress.buildBaseAddressBytes(
        paymentKeyHash: payHash,
        stakeKeyHash: stakeHash,
        network: network,
      );
    } finally {
      payPrv.dispose();
      stakePrv.dispose();
    }
  }

  /// Derives Bech32 Base Address (`addr1...` or `addr_test1...`).
  String deriveBaseAddress({
    int accountIndex = 0,
    required int role,
    required int index,
    required CardanoNetwork network,
  }) {
    final raw = deriveBaseAddressBytes(
      accountIndex: accountIndex,
      role: role,
      index: index,
      network: network,
    );
    return Bech32.encode(network.addressPrefix, raw);
  }

  /// Derives raw Reward/Stake Address bytes (29 bytes) at `2/0`.
  Uint8List deriveRewardAddressBytes({
    int accountIndex = 0,
    required CardanoNetwork network,
  }) {
    final stakeHash = deriveStakeKeyHash(accountIndex: accountIndex);
    return CardanoAddress.buildRewardAddressBytes(
      stakeKeyHash: stakeHash,
      network: network,
    );
  }

  /// Derives Bech32 Reward/Stake Address (`stake1...` or `stake_test1...`).
  String deriveRewardAddress({
    int accountIndex = 0,
    required CardanoNetwork network,
  }) {
    final raw = deriveRewardAddressBytes(
      accountIndex: accountIndex,
      network: network,
    );
    return Bech32.encode(network.stakePrefix, raw);
  }

  /// Overwrites master key bytes in RAM.
  void dispose() => rootKey.dispose();
}

/// CIP-1852 Account Public Key (`acct_xvk`) for Watch-Only Hot Wallet derivation.
class CardanoAccountPublicKey {
  final ExtendedPublicKey accountXpub;
  final Map<int, ExtendedPublicKey> _roleCache = {};
  final Map<String, Uint8List> _keyHashCache = {};
  final Map<String, Uint8List> _baseAddressBytesCache = {};
  final Map<String, String> _baseAddressCache = {};
  Uint8List? _stakeKeyHashCache;

  CardanoAccountPublicKey(this.accountXpub);

  factory CardanoAccountPublicKey.fromBytes(Uint8List bytes) {
    return CardanoAccountPublicKey(ExtendedPublicKey(bytes));
  }

  factory CardanoAccountPublicKey.fromBech32(String bech32Str) {
    final decoded = Bech32.decode(bech32Str);
    if (decoded.hrp != 'acct_xvk') {
      throw FormatException('Expected HRP "acct_xvk", got "${decoded.hrp}"');
    }
    return CardanoAccountPublicKey.fromBytes(decoded.data);
  }

  Uint8List get bytes => accountXpub.bytes;

  String toBech32() => Bech32.encode('acct_xvk', accountXpub.bytes);

  ExtendedPublicKey deriveRole(int role) =>
      _roleCache[role] ??= accountXpub.deriveChild(role);

  ExtendedPublicKey deriveKey(int role, int index) =>
      deriveRole(role).deriveChild(index);

  Uint8List deriveKeyHash(int role, int index) =>
      _keyHashCache['$role/$index'] ??= blake2b224(deriveKey(role, index).publicKey);

  Uint8List deriveStakeKeyHash({int index = 0}) {
    if (index == 0) {
      return _stakeKeyHashCache ??= deriveKeyHash(2, 0);
    }
    return deriveKeyHash(2, index);
  }

  Uint8List deriveBaseAddressBytes({
    required int role,
    required int index,
    required CardanoNetwork network,
  }) {
    final key = '${network.id}/$role/$index';
    return _baseAddressBytesCache[key] ??= CardanoAddress.buildBaseAddressBytes(
      paymentKeyHash: deriveKeyHash(role, index),
      stakeKeyHash: deriveStakeKeyHash(),
      network: network,
    );
  }

  String deriveBaseAddress({
    required int role,
    required int index,
    required CardanoNetwork network,
  }) {
    final key = '${network.id}/$role/$index';
    return _baseAddressCache[key] ??= Bech32.encode(
      network.addressPrefix,
      deriveBaseAddressBytes(role: role, index: index, network: network),
    );
  }

  Uint8List deriveEnterpriseAddressBytes({
    required int role,
    required int index,
    required CardanoNetwork network,
  }) {
    final payHash = deriveKeyHash(role, index);
    return CardanoAddress.buildEnterpriseAddressBytes(
      paymentKeyHash: payHash,
      network: network,
    );
  }

  String deriveEnterpriseAddress({
    required int role,
    required int index,
    required CardanoNetwork network,
  }) {
    final raw = deriveEnterpriseAddressBytes(
      role: role,
      index: index,
      network: network,
    );
    return Bech32.encode(network.addressPrefix, raw);
  }

  Uint8List deriveRewardAddressBytes({required CardanoNetwork network}) {
    final stakeHash = deriveStakeKeyHash();
    return CardanoAddress.buildRewardAddressBytes(
      stakeKeyHash: stakeHash,
      network: network,
    );
  }

  String deriveRewardAddress({required CardanoNetwork network}) {
    final raw = deriveRewardAddressBytes(network: network);
    return Bech32.encode(network.stakePrefix, raw);
  }
}

/// Helper utilities for constructing and inspecting Cardano addresses & IDs.
class CardanoAddress {
  static Uint8List buildBaseAddressBytes({
    required Uint8List paymentKeyHash,
    required Uint8List stakeKeyHash,
    required CardanoNetwork network,
  }) {
    if (paymentKeyHash.length != 28 || stakeKeyHash.length != 28) {
      throw ArgumentError('Key hashes must be 28 bytes');
    }
    final header = network.isTestnet ? 0x00 : 0x01;
    final out = Uint8List(57);
    out[0] = header;
    out.setRange(1, 29, paymentKeyHash);
    out.setRange(29, 57, stakeKeyHash);
    return out;
  }

  static Uint8List buildEnterpriseAddressBytes({
    required Uint8List paymentKeyHash,
    required CardanoNetwork network,
  }) {
    if (paymentKeyHash.length != 28) {
      throw ArgumentError('Payment key hash must be 28 bytes');
    }
    final header = network.isTestnet ? 0x60 : 0x61;
    final out = Uint8List(29);
    out[0] = header;
    out.setRange(1, 29, paymentKeyHash);
    return out;
  }

  static Uint8List buildRewardAddressBytes({
    required Uint8List stakeKeyHash,
    required CardanoNetwork network,
  }) {
    if (stakeKeyHash.length != 28) {
      throw ArgumentError('Stake key hash must be 28 bytes');
    }
    final header = network.isTestnet ? 0xe0 : 0xe1;
    final out = Uint8List(29);
    out[0] = header;
    out.setRange(1, 29, stakeKeyHash);
    return out;
  }

  /// Encodes raw Shelley/Conway address bytes into Bech32 according to header type & network.
  static String encodeBytes(Uint8List rawBytes) {
    if (rawBytes.isEmpty) {
      throw const FormatException('Empty Cardano address bytes');
    }
    final header = rawBytes[0];
    final addrType = (header >> 4) & 0x0f;
    final netTag = header & 0x0f;
    final isReward = addrType == 0x0e || addrType == 0x0f;
    final hrp = isReward
        ? (netTag == 1 ? 'stake' : 'stake_test')
        : (netTag == 1 ? 'addr' : 'addr_test');
    return Bech32.encode(hrp, rawBytes);
  }

  /// Decodes and validates a Bech32 Shelley/Conway address (`addr1...`, `addr_test1...`, `stake1...`, `stake_test1...`).
  static DecodedAddress decode(String address) {
    final decoded = Bech32.decode(address);
    final raw = decoded.data;
    if (raw.isEmpty) {
      throw const FormatException('Empty address payload');
    }
    final header = raw[0];
    final addrType = (header >> 4) & 0x0f;
    final netTag = header & 0x0f;

    if (decoded.hrp == 'addr' && netTag != 1) {
      throw const FormatException('Mainnet addr1 prefix has testnet header');
    }
    if (decoded.hrp == 'addr_test' && netTag != 0) {
      throw const FormatException('Testnet addr_test1 prefix has mainnet header');
    }
    if (decoded.hrp == 'stake' && netTag != 1) {
      throw const FormatException('Mainnet stake1 prefix has testnet header');
    }
    if (decoded.hrp == 'stake_test' && netTag != 0) {
      throw const FormatException('Testnet stake_test1 prefix has mainnet header');
    }
    if (!const {'addr', 'addr_test', 'stake', 'stake_test'}.contains(decoded.hrp)) {
      throw FormatException('Unsupported Cardano address HRP: ${decoded.hrp}');
    }

    if (addrType <= 0x03) {
      // Base addresses (57 bytes)
      if (raw.length != 57) {
        throw FormatException('Base address must be 57 bytes, got ${raw.length}');
      }
      return DecodedAddress(
        hrp: decoded.hrp,
        rawBytes: raw,
        headerByte: header,
        addressType: addrType,
        networkTag: netTag,
        paymentHash: Uint8List.sublistView(raw, 1, 29),
        stakeHash: Uint8List.sublistView(raw, 29, 57),
      );
    } else if (addrType == 0x06 || addrType == 0x07 || addrType == 0x0e || addrType == 0x0f) {
      // Enterprise or Reward addresses (29 bytes)
      if (raw.length != 29) {
        throw FormatException('Address type $addrType must be 29 bytes, got ${raw.length}');
      }
      return DecodedAddress(
        hrp: decoded.hrp,
        rawBytes: raw,
        headerByte: header,
        addressType: addrType,
        networkTag: netTag,
        paymentHash: Uint8List.sublistView(raw, 1, 29),
      );
    } else if (addrType == 0x04 || addrType == 0x05) {
      // Pointer address (>= 32 bytes)
      if (raw.length < 32) {
        throw FormatException('Pointer address too short: ${raw.length}');
      }
      return DecodedAddress(
        hrp: decoded.hrp,
        rawBytes: raw,
        headerByte: header,
        addressType: addrType,
        networkTag: netTag,
        paymentHash: Uint8List.sublistView(raw, 1, 29),
      );
    }

    throw FormatException('Unsupported Shelley/Conway address type: $addrType');
  }

  /// Decodes a `pool1...` Bech32 Pool ID into its 28-byte pool key hash.
  static Uint8List decodePoolId(String poolId) {
    final decoded = Bech32.decode(poolId);
    if (decoded.hrp != 'pool') {
      throw FormatException('Expected HRP "pool", got "${decoded.hrp}"');
    }
    if (decoded.data.length != 28) {
      throw FormatException('Pool hash must be 28 bytes, got ${decoded.data.length}');
    }
    return decoded.data;
  }

  /// Encodes a 28-byte pool key hash into `pool1...`.
  static String encodePoolId(Uint8List poolHash28) {
    if (poolHash28.length != 28) {
      throw ArgumentError('Pool hash must be 28 bytes');
    }
    return Bech32.encode('pool', poolHash28);
  }

  /// Decodes a `drep1...` Bech32 DRep ID (supports both CIP-105 28B and CIP-129 29B).
  static DecodedDRepId decodeDRepId(String drepId) {
    final decoded = Bech32.decode(drepId);
    if (decoded.hrp != 'drep' && decoded.hrp != 'drep_script') {
      throw FormatException('Expected HRP "drep", got "${decoded.hrp}"');
    }
    if (decoded.data.length == 28) {
      return DecodedDRepId(
        isScriptHash: decoded.hrp == 'drep_script',
        hash28: decoded.data,
      );
    }
    if (decoded.data.length == 29) {
      final header = decoded.data[0];
      final credType = header & 0x0f;
      if (credType != 2 && credType != 3) {
        throw FormatException('Invalid CIP-129 DRep header byte: 0x${header.toRadixString(16)}');
      }
      return DecodedDRepId(
        isScriptHash: credType == 3,
        hash28: Uint8List.sublistView(decoded.data, 1, 29),
      );
    }
    throw FormatException('DRep payload must be 28 or 29 bytes, got ${decoded.data.length}');
  }

  /// Encodes a 28-byte DRep key/script hash in CIP-129 `drep1...` format.
  static String encodeDRepId(Uint8List hash28, {bool isScriptHash = false}) {
    if (hash28.length != 28) {
      throw ArgumentError('DRep hash must be 28 bytes');
    }
    final out = Uint8List(29);
    out[0] = isScriptHash ? 0x23 : 0x22;
    out.setRange(1, 29, hash28);
    return Bech32.encode('drep', out);
  }
}
