import 'dart:typed_data';

import '../bc_ur/cardano_ur_messages.dart';
import '../crypto/bytes.dart';
import '../crypto/cardano_keys.dart';
import 'models.dart';
import 'tx_serializer.dart';

enum Sec01ErrorCode {
  networkMismatch,
  malformedTxBody,
  missingInputContext,
  duplicateInput,
  unauthorizedInputAddress,
  invalidChangeIndex,
  changeAddressMismatch,
  valueImbalance,
  nativeTokenImbalance,
  unauthorizedStakeCredential,
  unauthorizedWithdrawalAddress,
  missingStakeWitnessFlag,
}

class Sec01SecurityException implements Exception {
  final Sec01ErrorCode code;
  final String message;

  const Sec01SecurityException(this.code, this.message);

  @override
  String toString() => 'Sec01SecurityException(${code.name}): $message';
}

class AuditedInput {
  final String txHashHex;
  final int outputIndex;
  final String bech32Address;
  final BigInt lovelace;
  final MultiAsset multiAssets;
  final int accountIndex;
  final int derivationRole;
  final int derivationIndex;
  final bool wasAutoDiscovered;

  const AuditedInput({
    required this.txHashHex,
    required this.outputIndex,
    required this.bech32Address,
    required this.lovelace,
    required this.multiAssets,
    required this.accountIndex,
    required this.derivationRole,
    required this.derivationIndex,
    required this.wasAutoDiscovered,
  });

  String get derivationPath => "m/1852'/1815'/$accountIndex'/$derivationRole/$derivationIndex";
}

class AuditedOutput {
  final int outputIndex;
  final String bech32Address;
  final TxOutput output;
  final bool isVerifiedChange;
  final int accountIndex;
  final int? changeInternalIndex;
  final bool wasAutoDiscovered;

  const AuditedOutput({
    required this.outputIndex,
    required this.bech32Address,
    required this.output,
    required this.isVerifiedChange,
    this.accountIndex = 0,
    this.changeInternalIndex,
    this.wasAutoDiscovered = false,
  });

  String? get changeDerivationPath => changeInternalIndex != null
      ? "m/1852'/1815'/$accountIndex'/1/$changeInternalIndex"
      : null;
}

/// Session-scoped public-key cache for CIP-1852 HD path auto-discovery (zero private keys).
class CardanoHdDiscoveryCache {
  final Map<int, CardanoAccountPublicKey> _accountPubs = {};
  final Map<String, Map<String, ({int role, int index})>> _addressIndexMaps = {};
  final Map<String, int> _scannedUpTo = {};

  void clear() {
    _accountPubs.clear();
    _addressIndexMaps.clear();
    _scannedUpTo.clear();
  }

  CardanoAccountPublicKey getAccountPublicKey(
    int accountIndex,
    CardanoAccountPublicKey Function() derive,
  ) {
    return _accountPubs[accountIndex] ??= derive();
  }

  ({int role, int index})? resolveAddress({
    required CardanoAccountPublicKey acctPub,
    required CardanoNetwork network,
    required int accountIndex,
    required Uint8List addressBytes,
    List<int> roles = const [0, 1, 2, 3],
    int maxScanIndex = 200,
  }) {
    final netAcctKey = '${network.id}/$accountIndex';
    final addrMap = _addressIndexMaps.putIfAbsent(netAcctKey, () => {});
    final targetHex = hexEncode(addressBytes);
    final cached = addrMap[targetHex];
    if (cached != null && roles.contains(cached.role)) {
      return cached;
    }

    for (final role in roles) {
      final roleKey = '$netAcctKey/$role';
      final roleLimit = (role == 2 || role == 3)
          ? (maxScanIndex < 20 ? maxScanIndex : 20)
          : maxScanIndex;
      var nextIdx = (_scannedUpTo[roleKey] ?? -1) + 1;
      while (nextIdx <= roleLimit) {
        final baseHex = hexEncode(
          acctPub.deriveBaseAddressBytes(role: role, index: nextIdx, network: network),
        );
        addrMap.putIfAbsent(baseHex, () => (role: role, index: nextIdx));

        final entHex = hexEncode(
          acctPub.deriveEnterpriseAddressBytes(role: role, index: nextIdx, network: network),
        );
        addrMap.putIfAbsent(entHex, () => (role: role, index: nextIdx));

        if (role == 2 && nextIdx == 0) {
          final rewHex = hexEncode(
            acctPub.deriveRewardAddressBytes(network: network),
          );
          addrMap.putIfAbsent(rewHex, () => (role: role, index: nextIdx));
        }

        _scannedUpTo[roleKey] = nextIdx;
        if (baseHex == targetHex || entHex == targetHex) {
          return (role: role, index: nextIdx);
        }
        if (role == 2 && nextIdx == 0) {
          final rewHex = hexEncode(acctPub.deriveRewardAddressBytes(network: network));
          if (rewHex == targetHex) {
            return (role: role, index: nextIdx);
          }
        }
        nextIdx++;
      }
    }

    final postCached = addrMap[targetHex];
    if (postCached != null && roles.contains(postCached.role)) {
      return postCached;
    }
    return null;
  }

  int? resolveChangeIndex({
    required CardanoAccountPublicKey acctPub,
    required CardanoNetwork network,
    required int accountIndex,
    required Uint8List addressBytes,
    int maxScanIndex = 200,
  }) {
    final netAcctKey = '${network.id}/$accountIndex';
    final roleKey = '$netAcctKey/1';
    final addrMap = _addressIndexMaps.putIfAbsent(netAcctKey, () => {});
    final targetHex = hexEncode(addressBytes);
    final cached = addrMap[targetHex];
    if (cached != null && cached.role == 1) {
      // Ensure it is a Base Address (not Enterprise) for change verification
      final expectedBase = acctPub.deriveBaseAddressBytes(
        role: 1,
        index: cached.index,
        network: network,
      );
      if (constantTimeEquals(addressBytes, expectedBase)) {
        return cached.index;
      }
    }

    var nextIdx = (_scannedUpTo[roleKey] ?? -1) + 1;
    while (nextIdx <= maxScanIndex) {
      final baseBytes = acctPub.deriveBaseAddressBytes(
        role: 1,
        index: nextIdx,
        network: network,
      );
      final baseHex = hexEncode(baseBytes);
      addrMap.putIfAbsent(baseHex, () => (role: 1, index: nextIdx));
      final entHex = hexEncode(
        acctPub.deriveEnterpriseAddressBytes(role: 1, index: nextIdx, network: network),
      );
      addrMap.putIfAbsent(entHex, () => (role: 1, index: nextIdx));
      _scannedUpTo[roleKey] = nextIdx;
      if (constantTimeEquals(addressBytes, baseBytes)) {
        return nextIdx;
      }
      nextIdx++;
    }
    return null;
  }
}

class Sec01AuditReport {
  final CardanoNetwork network;
  final int resolvedAccountIndex;
  final Uint8List txBodyHash;
  final ConwayTxBody txBody;
  final List<AuditedInput> auditedInputs;
  final List<AuditedOutput> externalOutputs;
  final List<AuditedOutput> verifiedChangeOutputs;
  final List<String> resolvedSignerPaths;
  final BigInt totalInputLovelace;
  final BigInt totalOutputLovelace;
  final BigInt totalChangeLovelace;
  final BigInt totalExternalLovelace;
  final BigInt totalWithdrawals;
  final BigInt totalDeposits;
  final BigInt totalRefunds;
  final BigInt fee;

  const Sec01AuditReport({
    required this.network,
    required this.resolvedAccountIndex,
    required this.txBodyHash,
    required this.txBody,
    required this.auditedInputs,
    required this.externalOutputs,
    required this.verifiedChangeOutputs,
    required this.resolvedSignerPaths,
    required this.totalInputLovelace,
    required this.totalOutputLovelace,
    required this.totalChangeLovelace,
    required this.totalExternalLovelace,
    required this.totalWithdrawals,
    required this.totalDeposits,
    required this.totalRefunds,
    required this.fee,
  });

  /// Net lovelace leaving the wallet (external outputs + fee + deposits - refunds).
  BigInt get netAdaSpent =>
      totalExternalLovelace + fee + totalDeposits - totalRefunds;
}

/// Comprehensive offline security auditor (SEC-01) and signer for Cold Wallet.
class Sec01Guard {
  static final BigInt defaultProtocolKeyDeposit = BigInt.from(2000000);
  static const int defaultMaxAddressScanIndex = 200;
  static const Set<int> supportedRoles = {0, 1, 2, 3};

  /// Audits [request] against [accountPublicKey] (or [masterKey]) and [expectedNetwork].
  /// Throws [Sec01SecurityException] on any tampering or anomaly.
  static Sec01AuditReport audit({
    required CardanoSignRequestUr request,
    CardanoMasterKey? masterKey,
    CardanoAccountPublicKey? accountPublicKey,
    required CardanoNetwork expectedNetwork,
    int accountIndex = 0,
    List<int>? candidateAccountIndices,
    int maxAddressScanIndex = defaultMaxAddressScanIndex,
    CardanoHdDiscoveryCache? discoveryCache,
    BigInt? fallbackKeyDeposit,
  }) {
    if (accountPublicKey == null && masterKey == null) {
      throw ArgumentError(
        'Either accountPublicKey or masterKey must be provided to Sec01Guard.audit.',
      );
    }
    final keyDeposit = fallbackKeyDeposit ?? defaultProtocolKeyDeposit;

    // 1. Network Guard
    if (request.network != expectedNetwork) {
      throw Sec01SecurityException(
        Sec01ErrorCode.networkMismatch,
        'Request network (${request.network.id}) does not match active Cold Wallet network (${expectedNetwork.id}).',
      );
    }

    final ConwayTxBody txBody;
    try {
      txBody = ConwayTxSerializer.decodeTxBody(request.txBodyCbor);
    } catch (e) {
      throw Sec01SecurityException(
        Sec01ErrorCode.malformedTxBody,
        'Failed to parse Conway TxBody CBOR: $e',
      );
    }

    // Enforce canonical round-trip equality so non-canonical CBOR or unparsed fields are rejected
    final canonicalCbor = ConwayTxSerializer.encodeTxBody(txBody);
    if (!constantTimeEquals(canonicalCbor, request.txBodyCbor)) {
      throw const Sec01SecurityException(
        Sec01ErrorCode.malformedTxBody,
        'TxBody CBOR is non-canonical or contains unparsed fields.',
      );
    }

    if (txBody.fee < BigInt.zero) {
      throw const Sec01SecurityException(
        Sec01ErrorCode.malformedTxBody,
        'Transaction fee cannot be negative.',
      );
    }

    if (txBody.networkId != null &&
        txBody.networkId != expectedNetwork.networkTag) {
      throw Sec01SecurityException(
        Sec01ErrorCode.networkMismatch,
        'TxBody network_id (${txBody.networkId}) mismatches ${expectedNetwork.id} (${expectedNetwork.networkTag}).',
      );
    }

    // 2. UTXO Inputs Context Structural Checks
    if (txBody.inputs.isEmpty) {
      throw const Sec01SecurityException(
        Sec01ErrorCode.missingInputContext,
        'Transaction must contain at least one input.',
      );
    }

    final contextMap = <String, UrUtxoInputContext>{};
    for (final ctx in request.utxoInputs) {
      final id = '${hexEncode(ctx.txHash)}#${ctx.outputIndex}';
      if (contextMap.containsKey(id)) {
        throw Sec01SecurityException(
          Sec01ErrorCode.duplicateInput,
          'Duplicate UTXO context entry: $id',
        );
      }
      contextMap[id] = ctx;
    }

    final seenBodyInputs = <String>{};
    final orderedContexts = <UrUtxoInputContext>[];
    var totalInputLovelace = BigInt.zero;
    var inputMultiAssets = MultiAsset.empty;

    for (final txIn in txBody.inputs) {
      final id = txIn.id;
      if (!seenBodyInputs.add(id)) {
        throw Sec01SecurityException(
          Sec01ErrorCode.duplicateInput,
          'Duplicate input in TxBody: $id',
        );
      }
      final ctx = contextMap[id];
      if (ctx == null) {
        throw Sec01SecurityException(
          Sec01ErrorCode.missingInputContext,
          'Missing UTXO input context for $id',
        );
      }

      if (ctx.derivationRole != null && !supportedRoles.contains(ctx.derivationRole)) {
        throw Sec01SecurityException(
          Sec01ErrorCode.unauthorizedInputAddress,
          'Invalid input derivation role ${ctx.derivationRole} (expected 0, 1, 2, or 3)',
        );
      }
      if (ctx.derivationIndex != null &&
          (ctx.derivationIndex! < 0 || ctx.derivationIndex! >= 0x80000000)) {
        throw Sec01SecurityException(
          Sec01ErrorCode.unauthorizedInputAddress,
          'Invalid input derivation index ${ctx.derivationIndex} (expected 0 <= index < 2^31)',
        );
      }

      _assertAddressNetwork(ctx.addressBytes, expectedNetwork, 'input $id');

      if (ctx.lovelace < BigInt.zero) {
        throw const Sec01SecurityException(
          Sec01ErrorCode.malformedTxBody,
          'UTXO input lovelace cannot be negative.',
        );
      }

      orderedContexts.add(ctx);
      totalInputLovelace += ctx.lovelace;
      inputMultiAssets = inputMultiAssets.add(ctx.multiAssets);
    }

    if (contextMap.length != seenBodyInputs.length) {
      throw const Sec01SecurityException(
        Sec01ErrorCode.missingInputContext,
        'Extra unreferenced UTXO context entries detected.',
      );
    }

    // 3. Change Output Structural Checks
    final changeRefMap = <int, UrChangeOutputRef>{};
    for (final chg in request.changeOutputs) {
      if (chg.txOutputIndex < 0 || chg.txOutputIndex >= txBody.outputs.length) {
        throw Sec01SecurityException(
          Sec01ErrorCode.invalidChangeIndex,
          'Change output index ${chg.txOutputIndex} out of bounds (${txBody.outputs.length} outputs).',
        );
      }
      if (chg.internalIndex != null &&
          (chg.internalIndex! < 0 || chg.internalIndex! >= 0x80000000)) {
        throw Sec01SecurityException(
          Sec01ErrorCode.invalidChangeIndex,
          'Change internalIndex must be in [0, 2^31 - 1]: ${chg.internalIndex}.',
        );
      }
      if (changeRefMap.containsKey(chg.txOutputIndex)) {
        throw Sec01SecurityException(
          Sec01ErrorCode.invalidChangeIndex,
          'Duplicate change output index ${chg.txOutputIndex}.',
        );
      }
      changeRefMap[chg.txOutputIndex] = chg;
    }

    // 4. Audit Outputs Structure & Multi-Asset Conservation
    var totalOutputLovelace = BigInt.zero;
    var outputMultiAssets = MultiAsset.empty;
    for (var i = 0; i < txBody.outputs.length; i++) {
      final out = txBody.outputs[i];
      _assertAddressNetwork(out.addressBytes, expectedNetwork, 'output #$i');
      final addrType = (out.addressBytes[0] >> 4) & 0x0f;
      if (addrType == 0x0e || addrType == 0x0f) {
        throw Sec01SecurityException(
          Sec01ErrorCode.malformedTxBody,
          'SECURITY ALERT: Output #$i uses a Reward/Stake address which cannot be spent cleanly in UTXO outputs.',
        );
      }
      totalOutputLovelace += out.lovelace;
      outputMultiAssets = outputMultiAssets.add(out.multiAsset);
    }

    if (inputMultiAssets != outputMultiAssets) {
      throw const Sec01SecurityException(
        Sec01ErrorCode.nativeTokenImbalance,
        'SECURITY ALERT: Native Token balance mismatch between inputs and outputs!',
      );
    }

    // 5. Structural Certificate/Withdrawal & Full Accounting Conservation
    var totalDeposits = BigInt.zero;
    var totalRefunds = BigInt.zero;
    for (final cert in txBody.certificates) {
      switch (cert) {
        case StakeRegistrationCert(:final coin):
          totalDeposits += coin ?? keyDeposit;
        case StakeDeregistrationCert(:final coin):
          totalRefunds += coin ?? keyDeposit;
        case StakeRegDelegCert(:final coin):
        case VoteRegDelegCert(:final coin):
        case StakeVoteRegDelegCert(:final coin):
          totalDeposits += coin;
        case StakeDelegationCert():
        case VoteDelegationCert():
        case StakeVoteDelegationCert():
          break;
      }
    }

    var totalWithdrawals = BigInt.zero;
    for (final w in txBody.withdrawals) {
      _assertAddressNetwork(
        w.rewardAddressBytes,
        expectedNetwork,
        'withdrawal',
      );
      totalWithdrawals += w.coin;
    }

    if ((txBody.certificates.isNotEmpty || txBody.withdrawals.isNotEmpty) &&
        !request.requireStakeWitness) {
      throw const Sec01SecurityException(
        Sec01ErrorCode.missingStakeWitnessFlag,
        'Transaction includes certificates/withdrawals but require_stake_witness is false.',
      );
    }

    final totalInSide = totalInputLovelace + totalWithdrawals + totalRefunds;
    final totalOutSide = totalOutputLovelace + txBody.fee + totalDeposits;
    if (totalInSide != totalOutSide) {
      throw Sec01SecurityException(
        Sec01ErrorCode.valueImbalance,
        'Accounting imbalance: (inputs=$totalInputLovelace + withdrawals=$totalWithdrawals + refunds=$totalRefunds) != (outputs=$totalOutputLovelace + fee=${txBody.fee} + deposits=$totalDeposits).',
      );
    }

    // 6. Account & Multi-Role Ownership Resolution (Hybrid: Hinted or Auto-Discovered)
    final candidates = _buildCandidateAccounts(
      masterKey: masterKey,
      accountPublicKey: accountPublicKey,
      preferredAccountIndex: accountIndex,
      requestAccountIndex: request.accountIndex,
      candidateAccountIndices: candidateAccountIndices,
    );

    final cache = discoveryCache ?? CardanoHdDiscoveryCache();
    Sec01SecurityException? firstError;

    for (final candidateAcct in candidates) {
      final acctPub = (masterKey == null && accountPublicKey != null && candidateAcct == accountIndex)
          ? accountPublicKey
          : cache.getAccountPublicKey(
              candidateAcct,
              () => masterKey!.exportAccountPublicKey(accountIndex: candidateAcct),
            );

      try {
        return _verifyAccountOwnership(
          request: request,
          txBody: txBody,
          orderedContexts: orderedContexts,
          changeRefMap: changeRefMap,
          acctPub: acctPub,
          candidateAccountIndex: candidateAcct,
          expectedNetwork: expectedNetwork,
          maxAddressScanIndex: maxAddressScanIndex,
          cache: cache,
          totalInputLovelace: totalInputLovelace,
          totalOutputLovelace: totalOutputLovelace,
          totalWithdrawals: totalWithdrawals,
          totalDeposits: totalDeposits,
          totalRefunds: totalRefunds,
        );
      } on Sec01SecurityException catch (e) {
        firstError ??= e;
      }
    }

    throw firstError!;
  }

  static List<int> _buildCandidateAccounts({
    required CardanoMasterKey? masterKey,
    required CardanoAccountPublicKey? accountPublicKey,
    required int preferredAccountIndex,
    required int? requestAccountIndex,
    required List<int>? candidateAccountIndices,
  }) {
    if (masterKey == null && accountPublicKey != null) {
      if (requestAccountIndex != null && requestAccountIndex != preferredAccountIndex) {
        throw Sec01SecurityException(
          Sec01ErrorCode.unauthorizedInputAddress,
          'Request accountIndex ($requestAccountIndex) does not match active account ($preferredAccountIndex).',
        );
      }
      return [preferredAccountIndex];
    }

    if (requestAccountIndex != null) {
      if (requestAccountIndex < 0 || requestAccountIndex >= 0x80000000) {
        throw Sec01SecurityException(
          Sec01ErrorCode.unauthorizedInputAddress,
          'Invalid request accountIndex: $requestAccountIndex',
        );
      }
      return [requestAccountIndex];
    }

    if (candidateAccountIndices == null) {
      return [preferredAccountIndex];
    }

    final seen = <int>{};
    final out = <int>[];
    void addIfValid(int idx) {
      if (idx >= 0 && idx < 0x80000000 && seen.add(idx)) {
        out.add(idx);
      }
    }

    addIfValid(preferredAccountIndex);
    for (final idx in candidateAccountIndices) {
      addIfValid(idx);
    }
    for (var i = 0; i <= 4; i++) {
      addIfValid(i);
    }
    return out;
  }

  static Sec01AuditReport _verifyAccountOwnership({
    required CardanoSignRequestUr request,
    required ConwayTxBody txBody,
    required List<UrUtxoInputContext> orderedContexts,
    required Map<int, UrChangeOutputRef> changeRefMap,
    required CardanoAccountPublicKey acctPub,
    required int candidateAccountIndex,
    required CardanoNetwork expectedNetwork,
    required int maxAddressScanIndex,
    required CardanoHdDiscoveryCache cache,
    required BigInt totalInputLovelace,
    required BigInt totalOutputLovelace,
    required BigInt totalWithdrawals,
    required BigInt totalDeposits,
    required BigInt totalRefunds,
  }) {
    final auditedInputs = <AuditedInput>[];
    final signerPaths = <String>{};

    for (final ctx in orderedContexts) {
      final id = '${hexEncode(ctx.txHash)}#${ctx.outputIndex}';
      final int resolvedRole;
      final int resolvedIndex;
      final bool wasAutoDiscovered;

      if (ctx.hasDerivationHint) {
        resolvedRole = ctx.derivationRole!;
        resolvedIndex = ctx.derivationIndex!;
        wasAutoDiscovered = false;

        final expectedBase = acctPub.deriveBaseAddressBytes(
          role: resolvedRole,
          index: resolvedIndex,
          network: expectedNetwork,
        );
        final expectedEnterprise = acctPub.deriveEnterpriseAddressBytes(
          role: resolvedRole,
          index: resolvedIndex,
          network: expectedNetwork,
        );
        final matchesReward = resolvedRole == 2 &&
            resolvedIndex == 0 &&
            constantTimeEquals(
              ctx.addressBytes,
              acctPub.deriveRewardAddressBytes(network: expectedNetwork),
            );

        if (!constantTimeEquals(ctx.addressBytes, expectedBase) &&
            !constantTimeEquals(ctx.addressBytes, expectedEnterprise) &&
            !matchesReward) {
          throw Sec01SecurityException(
            Sec01ErrorCode.unauthorizedInputAddress,
            'UTXO input $id address does not match m/1852\'/1815\'/$candidateAccountIndex\'/$resolvedRole/$resolvedIndex',
          );
        }
      } else {
        final rolesToSearch = ctx.derivationRole != null
            ? <int>[ctx.derivationRole!]
            : const <int>[0, 1, 2, 3];
        final match = cache.resolveAddress(
          acctPub: acctPub,
          network: expectedNetwork,
          accountIndex: candidateAccountIndex,
          addressBytes: ctx.addressBytes,
          roles: rolesToSearch,
          maxScanIndex: maxAddressScanIndex,
        );
        if (match == null) {
          throw Sec01SecurityException(
            Sec01ErrorCode.unauthorizedInputAddress,
            'UTXO input $id could not be matched to any CIP-1852 role (0..3, index 0..$maxAddressScanIndex) of account #$candidateAccountIndex',
          );
        }
        resolvedRole = match.role;
        resolvedIndex = match.index;
        wasAutoDiscovered = true;
      }

      final inputRecord = AuditedInput(
        txHashHex: hexEncode(ctx.txHash),
        outputIndex: ctx.outputIndex,
        bech32Address: CardanoAddress.encodeBytes(ctx.addressBytes),
        lovelace: ctx.lovelace,
        multiAssets: ctx.multiAssets,
        accountIndex: candidateAccountIndex,
        derivationRole: resolvedRole,
        derivationIndex: resolvedIndex,
        wasAutoDiscovered: wasAutoDiscovered,
      );
      auditedInputs.add(inputRecord);
      signerPaths.add(inputRecord.derivationPath);
    }

    // Verify change outputs against role=1
    var totalChangeLovelace = BigInt.zero;
    var totalExternalLovelace = BigInt.zero;
    final externalOutputs = <AuditedOutput>[];
    final verifiedChangeOutputs = <AuditedOutput>[];

    for (var i = 0; i < txBody.outputs.length; i++) {
      final out = txBody.outputs[i];
      final bech32Addr = CardanoAddress.encodeBytes(out.addressBytes);
      final chgRef = changeRefMap[i];

      if (chgRef != null) {
        final int resolvedInternalIdx;
        final bool changeAutoDiscovered;

        if (chgRef.internalIndex != null) {
          resolvedInternalIdx = chgRef.internalIndex!;
          changeAutoDiscovered = false;
          final expectedChangeBytes = acctPub.deriveBaseAddressBytes(
            role: 1,
            index: resolvedInternalIdx,
            network: expectedNetwork,
          );
          if (!constantTimeEquals(out.addressBytes, expectedChangeBytes)) {
            throw Sec01SecurityException(
              Sec01ErrorCode.changeAddressMismatch,
              'SECURITY ALERT: Change output #${chgRef.txOutputIndex} does not match derived internal address m/1852\'/1815\'/$candidateAccountIndex\'/1/$resolvedInternalIdx!',
            );
          }
        } else {
          final discoveredIdx = cache.resolveChangeIndex(
            acctPub: acctPub,
            network: expectedNetwork,
            accountIndex: candidateAccountIndex,
            addressBytes: out.addressBytes,
            maxScanIndex: maxAddressScanIndex,
          );
          if (discoveredIdx == null) {
            throw Sec01SecurityException(
              Sec01ErrorCode.changeAddressMismatch,
              'SECURITY ALERT: Change output #${chgRef.txOutputIndex} could not be matched to internal chain m/1852\'/1815\'/$candidateAccountIndex\'/1/0..$maxAddressScanIndex!',
            );
          }
          resolvedInternalIdx = discoveredIdx;
          changeAutoDiscovered = true;
        }

        totalChangeLovelace += out.lovelace;
        verifiedChangeOutputs.add(
          AuditedOutput(
            outputIndex: i,
            bech32Address: bech32Addr,
            output: out,
            isVerifiedChange: true,
            accountIndex: candidateAccountIndex,
            changeInternalIndex: resolvedInternalIdx,
            wasAutoDiscovered: changeAutoDiscovered,
          ),
        );
      } else {
        totalExternalLovelace += out.lovelace;
        externalOutputs.add(
          AuditedOutput(
            outputIndex: i,
            bech32Address: bech32Addr,
            output: out,
            isVerifiedChange: false,
            accountIndex: candidateAccountIndex,
          ),
        );
      }
    }

    // Verify Stake Credential & Governance Guard (m/1852'/1815'/accountIndex'/2/0)
    final expectedStakeHash = acctPub.deriveStakeKeyHash();
    final expectedRewardBytes = acctPub.deriveRewardAddressBytes(
      network: expectedNetwork,
    );

    for (final cert in txBody.certificates) {
      if (cert.stakeCredential.isScriptHash ||
          !constantTimeEquals(cert.stakeCredential.hash28, expectedStakeHash)) {
        throw const Sec01SecurityException(
          Sec01ErrorCode.unauthorizedStakeCredential,
          'SECURITY ALERT: Certificate targets a Stake Credential outside this wallet!',
        );
      }
    }

    for (final w in txBody.withdrawals) {
      if (!constantTimeEquals(w.rewardAddressBytes, expectedRewardBytes)) {
        throw const Sec01SecurityException(
          Sec01ErrorCode.unauthorizedWithdrawalAddress,
          'SECURITY ALERT: Withdrawal reward address does not belong to this wallet!',
        );
      }
    }

    if (request.requireStakeWitness ||
        txBody.certificates.isNotEmpty ||
        txBody.withdrawals.isNotEmpty) {
      signerPaths.add("m/1852'/1815'/$candidateAccountIndex'/2/0");
    }

    return Sec01AuditReport(
      network: expectedNetwork,
      resolvedAccountIndex: candidateAccountIndex,
      txBodyHash: ConwayTxSerializer.computeTxBodyHash(request.txBodyCbor),
      txBody: txBody,
      auditedInputs: auditedInputs,
      externalOutputs: externalOutputs,
      verifiedChangeOutputs: verifiedChangeOutputs,
      resolvedSignerPaths: signerPaths.toList(),
      totalInputLovelace: totalInputLovelace,
      totalOutputLovelace: totalOutputLovelace,
      totalChangeLovelace: totalChangeLovelace,
      totalExternalLovelace: totalExternalLovelace,
      totalWithdrawals: totalWithdrawals,
      totalDeposits: totalDeposits,
      totalRefunds: totalRefunds,
      fee: txBody.fee,
    );
  }

  /// Audits [request] via SEC-01, signs `blake2b_256(tx_body_cbor)` with all required keys,
  /// zeroizes derived signing keys, and returns [CardanoSignResponseUr].
  static CardanoSignResponseUr auditAndSign({
    required CardanoSignRequestUr request,
    required CardanoMasterKey masterKey,
    required CardanoNetwork expectedNetwork,
    int accountIndex = 0,
    List<int>? candidateAccountIndices,
    int maxAddressScanIndex = defaultMaxAddressScanIndex,
    CardanoHdDiscoveryCache? discoveryCache,
    BigInt? fallbackKeyDeposit,
  }) {
    final report = audit(
      request: request,
      masterKey: masterKey,
      expectedNetwork: expectedNetwork,
      accountIndex: accountIndex,
      candidateAccountIndices: candidateAccountIndices,
      maxAddressScanIndex: maxAddressScanIndex,
      discoveryCache: discoveryCache,
      fallbackKeyDeposit: fallbackKeyDeposit,
    );

    final witnesses = <VKeyWitness>[];
    final seenPaths = <String>{};

    for (final inp in report.auditedInputs) {
      final pathKey = '${inp.derivationRole}/${inp.derivationIndex}';
      if (!seenPaths.add(pathKey)) continue;

      final key = masterKey.deriveAddressSigningKey(
        accountIndex: report.resolvedAccountIndex,
        role: inp.derivationRole,
        index: inp.derivationIndex,
      );
      try {
        final sig = key.sign(report.txBodyHash);
        witnesses.add(VKeyWitness(vkey: key.publicKey, signature: sig));
      } finally {
        key.dispose();
      }
    }

    if ((request.requireStakeWitness ||
            report.txBody.certificates.isNotEmpty ||
            report.txBody.withdrawals.isNotEmpty) &&
        seenPaths.add('2/0')) {
      final stakeKey = masterKey.deriveAddressSigningKey(
        accountIndex: report.resolvedAccountIndex,
        role: 2,
        index: 0,
      );
      try {
        final sig = stakeKey.sign(report.txBodyHash);
        witnesses.add(VKeyWitness(vkey: stakeKey.publicKey, signature: sig));
      } finally {
        stakeKey.dispose();
      }
    }

    return CardanoSignResponseUr(
      requestId: request.requestId,
      vkeyWitnesses: witnesses,
    );
  }

  static void _assertAddressNetwork(
    Uint8List rawAddress,
    CardanoNetwork expectedNetwork,
    String label,
  ) {
    if (rawAddress.isEmpty) {
      throw Sec01SecurityException(
        Sec01ErrorCode.malformedTxBody,
        'Empty address in $label',
      );
    }
    final netTag = rawAddress[0] & 0x0f;
    if (netTag != expectedNetwork.networkTag) {
      throw Sec01SecurityException(
        Sec01ErrorCode.networkMismatch,
        'Address network tag ($netTag) in $label mismatches ${expectedNetwork.id} (${expectedNetwork.networkTag}).',
      );
    }
    // Validate Bech32/structural integrity
    try {
      final encoded = CardanoAddress.encodeBytes(rawAddress);
      CardanoAddress.decode(encoded);
    } catch (e) {
      throw Sec01SecurityException(
        Sec01ErrorCode.malformedTxBody,
        'Malformed address bytes in $label: $e',
      );
    }
  }
}
