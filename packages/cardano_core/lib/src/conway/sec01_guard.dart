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

class AuditedOutput {
  final int outputIndex;
  final String bech32Address;
  final TxOutput output;
  final bool isVerifiedChange;
  final int? changeInternalIndex;

  const AuditedOutput({
    required this.outputIndex,
    required this.bech32Address,
    required this.output,
    required this.isVerifiedChange,
    this.changeInternalIndex,
  });
}

class Sec01AuditReport {
  final CardanoNetwork network;
  final Uint8List txBodyHash;
  final ConwayTxBody txBody;
  final List<AuditedOutput> externalOutputs;
  final List<AuditedOutput> verifiedChangeOutputs;
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
    required this.txBodyHash,
    required this.txBody,
    required this.externalOutputs,
    required this.verifiedChangeOutputs,
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

  /// Audits [request] against [accountPublicKey] (or [masterKey]) and [expectedNetwork].
  /// Throws [Sec01SecurityException] on any tampering or anomaly.
  static Sec01AuditReport audit({
    required CardanoSignRequestUr request,
    CardanoMasterKey? masterKey,
    CardanoAccountPublicKey? accountPublicKey,
    required CardanoNetwork expectedNetwork,
    int accountIndex = 0,
    BigInt? fallbackKeyDeposit,
  }) {
    if (accountPublicKey == null && masterKey == null) {
      throw ArgumentError(
        'Either accountPublicKey or masterKey must be provided to Sec01Guard.audit.',
      );
    }
    final acctPub = accountPublicKey ??
        masterKey!.exportAccountPublicKey(accountIndex: accountIndex);
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

    if (txBody.networkId != null &&
        txBody.networkId != expectedNetwork.networkTag) {
      throw Sec01SecurityException(
        Sec01ErrorCode.networkMismatch,
        'TxBody network_id (${txBody.networkId}) mismatches ${expectedNetwork.id} (${expectedNetwork.networkTag}).',
      );
    }

    // 2. UTXO Inputs Context & Ownership Guard
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

      if (ctx.derivationRole != 0 && ctx.derivationRole != 1) {
        throw Sec01SecurityException(
          Sec01ErrorCode.unauthorizedInputAddress,
          'Invalid input derivation role ${ctx.derivationRole} (expected 0 or 1)',
        );
      }
      if (ctx.derivationIndex < 0 || ctx.derivationIndex >= 0x80000000) {
        throw Sec01SecurityException(
          Sec01ErrorCode.unauthorizedInputAddress,
          'Invalid input derivation index ${ctx.derivationIndex} (expected 0 <= index < 2^31)',
        );
      }

      _assertAddressNetwork(ctx.addressBytes, expectedNetwork, 'input $id');

      // Re-derive Base & Enterprise address via public account key to prove ownership
      final expectedBase = acctPub.deriveBaseAddressBytes(
        role: ctx.derivationRole,
        index: ctx.derivationIndex,
        network: expectedNetwork,
      );
      final expectedEnterprise = acctPub.deriveEnterpriseAddressBytes(
        role: ctx.derivationRole,
        index: ctx.derivationIndex,
        network: expectedNetwork,
      );

      if (!constantTimeEquals(ctx.addressBytes, expectedBase) &&
          !constantTimeEquals(ctx.addressBytes, expectedEnterprise)) {
        throw Sec01SecurityException(
          Sec01ErrorCode.unauthorizedInputAddress,
          'UTXO input $id address does not match m/1852\'/1815\'/$accountIndex\'/${ctx.derivationRole}/${ctx.derivationIndex}',
        );
      }

      totalInputLovelace += ctx.lovelace;
      inputMultiAssets = inputMultiAssets.add(ctx.multiAssets);
    }

    if (contextMap.length != seenBodyInputs.length) {
      throw const Sec01SecurityException(
        Sec01ErrorCode.missingInputContext,
        'Extra unreferenced UTXO context entries detected.',
      );
    }

    // 3. Change Address Guard
    final changeIndexMap = <int, int>{};
    for (final chg in request.changeOutputs) {
      if (chg.txOutputIndex < 0 || chg.txOutputIndex >= txBody.outputs.length) {
        throw Sec01SecurityException(
          Sec01ErrorCode.invalidChangeIndex,
          'Change output index ${chg.txOutputIndex} out of bounds (${txBody.outputs.length} outputs).',
        );
      }
      if (chg.internalIndex < 0 || chg.internalIndex >= 0x80000000) {
        throw Sec01SecurityException(
          Sec01ErrorCode.invalidChangeIndex,
          'Change internalIndex must be in [0, 2^31 - 1]: ${chg.internalIndex}.',
        );
      }
      if (changeIndexMap.containsKey(chg.txOutputIndex)) {
        throw Sec01SecurityException(
          Sec01ErrorCode.invalidChangeIndex,
          'Duplicate change output index ${chg.txOutputIndex}.',
        );
      }
      changeIndexMap[chg.txOutputIndex] = chg.internalIndex;

      final expectedChangeBytes = acctPub.deriveBaseAddressBytes(
        role: 1,
        index: chg.internalIndex,
        network: expectedNetwork,
      );
      final actualBytes = txBody.outputs[chg.txOutputIndex].addressBytes;
      if (!constantTimeEquals(actualBytes, expectedChangeBytes)) {
        throw Sec01SecurityException(
          Sec01ErrorCode.changeAddressMismatch,
          'SECURITY ALERT: Change output #${chg.txOutputIndex} does not match derived internal address m/1852\'/1815\'/$accountIndex\'/1/${chg.internalIndex}!',
        );
      }
    }

    // 4. Audit Outputs & Multi-Asset Conservation
    var totalOutputLovelace = BigInt.zero;
    var totalChangeLovelace = BigInt.zero;
    var totalExternalLovelace = BigInt.zero;
    var outputMultiAssets = MultiAsset.empty;
    final externalOutputs = <AuditedOutput>[];
    final verifiedChangeOutputs = <AuditedOutput>[];

    for (var i = 0; i < txBody.outputs.length; i++) {
      final out = txBody.outputs[i];
      _assertAddressNetwork(out.addressBytes, expectedNetwork, 'output #$i');
      final bech32Addr = CardanoAddress.encodeBytes(out.addressBytes);

      totalOutputLovelace += out.lovelace;
      outputMultiAssets = outputMultiAssets.add(out.multiAsset);

      final internalIdx = changeIndexMap[i];
      if (internalIdx != null) {
        totalChangeLovelace += out.lovelace;
        verifiedChangeOutputs.add(
          AuditedOutput(
            outputIndex: i,
            bech32Address: bech32Addr,
            output: out,
            isVerifiedChange: true,
            changeInternalIndex: internalIdx,
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
          ),
        );
      }
    }

    if (inputMultiAssets != outputMultiAssets) {
      throw const Sec01SecurityException(
        Sec01ErrorCode.nativeTokenImbalance,
        'SECURITY ALERT: Native Token balance mismatch between inputs and outputs!',
      );
    }

    // 5. Stake Credential & Governance Guard (m/1852'/1815'/accountIndex'/2/0)
    final expectedStakeHash = acctPub.deriveStakeKeyHash();
    final expectedRewardBytes = acctPub.deriveRewardAddressBytes(
      network: expectedNetwork,
    );

    var totalDeposits = BigInt.zero;
    var totalRefunds = BigInt.zero;

    for (final cert in txBody.certificates) {
      if (cert.stakeCredential.isScriptHash ||
          !constantTimeEquals(cert.stakeCredential.hash28, expectedStakeHash)) {
        throw const Sec01SecurityException(
          Sec01ErrorCode.unauthorizedStakeCredential,
          'SECURITY ALERT: Certificate targets a Stake Credential outside this wallet!',
        );
      }
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
      if (!constantTimeEquals(w.rewardAddressBytes, expectedRewardBytes)) {
        throw const Sec01SecurityException(
          Sec01ErrorCode.unauthorizedWithdrawalAddress,
          'SECURITY ALERT: Withdrawal reward address does not belong to this wallet!',
        );
      }
      totalWithdrawals += w.coin;
    }

    if ((txBody.certificates.isNotEmpty || txBody.withdrawals.isNotEmpty) &&
        !request.requireStakeWitness) {
      throw const Sec01SecurityException(
        Sec01ErrorCode.missingStakeWitnessFlag,
        'Transaction includes certificates/withdrawals but require_stake_witness is false.',
      );
    }

    // 6. Full Accounting Value Conservation
    final totalInSide = totalInputLovelace + totalWithdrawals + totalRefunds;
    final totalOutSide = totalOutputLovelace + txBody.fee + totalDeposits;
    if (totalInSide != totalOutSide) {
      throw Sec01SecurityException(
        Sec01ErrorCode.valueImbalance,
        'Accounting imbalance: (inputs=$totalInputLovelace + withdrawals=$totalWithdrawals + refunds=$totalRefunds) != (outputs=$totalOutputLovelace + fee=${txBody.fee} + deposits=$totalDeposits).',
      );
    }

    return Sec01AuditReport(
      network: expectedNetwork,
      txBodyHash: ConwayTxSerializer.computeTxBodyHash(request.txBodyCbor),
      txBody: txBody,
      externalOutputs: externalOutputs,
      verifiedChangeOutputs: verifiedChangeOutputs,
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
    BigInt? fallbackKeyDeposit,
  }) {
    final report = audit(
      request: request,
      masterKey: masterKey,
      expectedNetwork: expectedNetwork,
      accountIndex: accountIndex,
      fallbackKeyDeposit: fallbackKeyDeposit,
    );

    final witnesses = <VKeyWitness>[];
    final seenPaths = <String>{};

    for (final ctx in request.utxoInputs) {
      final pathKey = '${ctx.derivationRole}/${ctx.derivationIndex}';
      if (!seenPaths.add(pathKey)) continue;

      final key = masterKey.deriveAddressSigningKey(
        accountIndex: accountIndex,
        role: ctx.derivationRole,
        index: ctx.derivationIndex,
      );
      try {
        final sig = key.sign(report.txBodyHash);
        witnesses.add(VKeyWitness(vkey: key.publicKey, signature: sig));
      } finally {
        key.dispose();
      }
    }

    if (request.requireStakeWitness ||
        report.txBody.certificates.isNotEmpty ||
        report.txBody.withdrawals.isNotEmpty) {
      final stakeKey = masterKey.deriveAddressSigningKey(
        accountIndex: accountIndex,
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
