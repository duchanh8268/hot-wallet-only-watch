import 'dart:typed_data';

import 'package:bitcoin_core/bitcoin_core.dart';
import 'package:chain_core_interface/chain_core_interface.dart';
import '../../core/models/chain_tx_record.dart';
import 'services/mempool_service.dart';

/// Hot Wallet plugin supporting Bitcoin (BIP-84 Native SegWit P2WPKH).
class BitcoinHotPlugin implements IHotChainPlugin {
  static final BitcoinHotPlugin instance = BitcoinHotPlugin._();

  @override
  final ChainId chainId = ChainId.bitcoin;

  final MempoolService mempoolService;

  BitcoinHotPlugin._({MempoolService? mempool})
      : mempoolService = mempool ?? MempoolService();

  @override
  String get displayName => 'Bitcoin';

  @override
  List<ChainNetwork> get supportedNetworks => const [
        ChainNetwork(
          id: 'testnet4',
          name: 'Bitcoin Testnet4',
          isTestnet: true,
          networkCode: 1,
        ),
        ChainNetwork(
          id: 'mainnet',
          name: 'Bitcoin Mainnet',
          isTestnet: false,
          networkCode: 0,
        ),
        ChainNetwork(
          id: 'signet',
          name: 'Bitcoin Signet',
          isTestnet: true,
          networkCode: 2,
        ),
      ];

  @override
  ChainNetwork get defaultNetwork => supportedNetworks.first;

  @override
  bool canHandleUr(String urType) {
    final lower = urType.toLowerCase();
    return lower == BtcAccountUr.urType ||
        lower == BtcSignRequestUr.urType ||
        lower == BtcSignResponseUr.urType;
  }

  @override
  Future<PublicAccountDetails> derivePublicAccount({
    required Uint8List entropy,
    String passphrase = '',
    required ChainNetwork network,
    required int accountIndex,
    required int addressIndex,
    String? label,
  }) async {
    final isTestnet = network.isTestnet;
    final hrp = isTestnet ? 'tb' : 'bc';
    final seed = Bip39.entropyToSeed(entropy, passphrase: passphrase);
    final masterHd = BtcHdKey.fromSeed(seed);
    final childKey = masterHd.deriveBip84Address(
      accountIndex: accountIndex,
      change: 0,
      addressIndex: addressIndex,
      isTestnet: isTestnet,
    );

    try {
      final address = Bech32Segwit.encodeP2wpkh(
        hrp: hrp,
        program20: childKey.pubKeyHash,
      );

      final accountUr = BtcAccountUr(
        chain: chainId.id,
        network: network.id,
        accountIndex: accountIndex,
        receiveAddress: address,
        masterFingerprint: masterHd.fingerprint,
        label: label,
      ).toUr();

      return PublicAccountDetails(
        primaryAddress: address,
        secondaryAddress: null,
        publicIdentifier: address,
        accountUr: accountUr,
        rawPublicKey: childKey.publicKeyCompressed,
      );
    } finally {
      masterHd.dispose();
      childKey.dispose();
      zeroize(seed);
    }
  }

  @override
  Future<void> configureEndpoint({
    required ChainNetwork network,
    String? customUrl,
    String? apiKey,
  }) async {
    if (customUrl != null && customUrl.isNotEmpty) {
      mempoolService.setCustomApiUrl(network.id, customUrl);
    }
  }

  @override
  Future<Map<String, dynamic>> fetchAccountBalance({
    required ChainNetwork network,
    required String address,
  }) async {
    try {
      final utxos = await mempoolService.getUtxos(network.id, address);
      var totalSat = BigInt.zero;
      for (final u in utxos) {
        totalSat += u.valueSat;
      }
      List<ChainTxRecord> recentTxs = const [];
      String? historyError;
      try {
        recentTxs = await mempoolService.getRecentTxs(network.id, address);
      } catch (e) {
        historyError = e.toString();
      }
      return {
        'address': address,
        'network': network.id,
        'balanceSat': totalSat.toString(),
        'utxos': utxos,
        'utxoCount': utxos.length,
        'recentTxs': recentTxs,
        'historyError': ?historyError,
      };
    } catch (e) {
      return {
        'address': address,
        'network': network.id,
        'balanceSat': '0',
        'utxos': <MempoolUtxo>[],
        'utxoCount': 0,
        'error': e.toString(),
      };
    }
  }

  @override
  Future<String> broadcastTransaction({
    required ChainNetwork network,
    required Uint8List signedTxBytes,
  }) async {
    final rawHex = hexEncode(signedTxBytes);
    return await mempoolService.broadcastRawTx(network.id, rawHex);
  }

  /// Injects signatures from a `BtcSignResponseUr` into the original `BtcTransaction`
  /// and returns the fully assembled `BtcTransaction` with witness data.
  BtcTransaction assembleSignedTx({
    required BtcTransaction originalTx,
    required BtcSignResponseUr response,
  }) {
    if (response.witnesses.length != originalTx.inputs.length) {
      throw ArgumentError(
        'Số lượng witness (${response.witnesses.length}) không khớp với số inputs (${originalTx.inputs.length})',
      );
    }

    final updatedInputs = <BtcTxIn>[];
    for (var i = 0; i < originalTx.inputs.length; i++) {
      final oldIn = originalTx.inputs[i];
      final wit = response.witnesses[i];
      updatedInputs.add(BtcTxIn(
        previousOutput: oldIn.previousOutput,
        scriptSig: oldIn.scriptSig,
        sequence: oldIn.sequence,
        amountSat: oldIn.amountSat,
        accountIndex: oldIn.accountIndex,
        change: oldIn.change,
        addressIndex: oldIn.addressIndex,
        nonWitnessUtxo: oldIn.nonWitnessUtxo,
        witness: wit,
      ));
    }

    return BtcTransaction(
      version: originalTx.version,
      inputs: updatedInputs,
      outputs: originalTx.outputs,
      lockTime: originalTx.lockTime,
    );
  }
}
