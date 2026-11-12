import 'dart:math';
import 'dart:typed_data';

import 'package:cardano_core/cardano_core.dart';

import 'blockfrost_service.dart';
import 'hd_wallet_sync_service.dart';

class TxBuildResult {
  final CardanoSignRequestUr signRequest;
  final ConwayTxBody txBody;
  final BigInt fee;
  final BigInt? recipientMinAda;
  final BigInt? changeMinAda;

  const TxBuildResult({
    required this.signRequest,
    required this.txBody,
    required this.fee,
    this.recipientMinAda,
    this.changeMinAda,
  });
}

class ConwayTxBuilder {
  static final Random _rng = Random.secure();

  static Uint8List _randomRequestId() =>
      Uint8List.fromList(List<int>.generate(16, (_) => _rng.nextInt(256)));

  /// Estimates the Conway Min-ADA (`lovelace`) required for a recipient output
  /// carrying [tokensToSend]. If [recipientAddress] is empty or invalid, uses a
  /// representative 57-byte Shelley base address on the active network.
  static BigInt estimateRecipientMinAda({
    required WatchOnlyProfile profile,
    required WalletSyncState syncState,
    String? recipientAddress,
    MultiAsset? tokensToSend,
  }) {
    final network = profile.network;
    Uint8List addressBytes;
    final trimmed = recipientAddress?.trim() ?? '';
    if (trimmed.isNotEmpty) {
      try {
        final decoded = CardanoAddress.decode(trimmed);
        if (decoded.networkTag == network.networkTag) {
          addressBytes = decoded.rawBytes;
        } else {
          addressBytes = CardanoAccountPublicKey.fromBech32(profile.acctXvkBech32)
              .deriveBaseAddressBytes(role: 0, index: 0, network: network);
        }
      } catch (_) {
        addressBytes = CardanoAccountPublicKey.fromBech32(profile.acctXvkBech32)
            .deriveBaseAddressBytes(role: 0, index: 0, network: network);
      }
    } else {
      addressBytes = CardanoAccountPublicKey.fromBech32(profile.acctXvkBech32)
          .deriveBaseAddressBytes(role: 0, index: 0, network: network);
    }

    return calculateMinUtxo(
      TxOutput(
        addressBytes: addressBytes,
        lovelace: BigInt.from(2000000),
        multiAsset: tokensToSend ?? MultiAsset.empty,
      ),
      coinsPerUTxOByte: syncState.protocolParameters.coinsPerUTxOByte,
    );
  }

  /// Builds an ADA and/or Multi-Asset transfer `ur:cardano-sign-request`.
  static TxBuildResult buildTransfer({
    required WatchOnlyProfile profile,
    required WalletSyncState syncState,
    required String recipientAddress,
    required BigInt lovelaceToSend,
    MultiAsset? tokensToSend,
    bool sendMax = false,
    bool keepRemainingTokens = false,
    bool autoMinAda = false,
  }) {
    final network = profile.network;
    final decodedRecipient = CardanoAddress.decode(recipientAddress);
    if (decodedRecipient.networkTag != network.networkTag) {
      throw ArgumentError(
        'Recipient address network does not match ${network.id}',
      );
    }

    if (syncState.utxos.isEmpty) {
      throw StateError('No UTXOs available in wallet');
    }

    final acctKey = CardanoAccountPublicKey.fromBech32(profile.acctXvkBech32);
    final pparams = syncState.protocolParameters;
    final sendTokens = tokensToSend ?? MultiAsset.empty;
    final ttl = syncState.latestSlot + 7200; // +2 hours

    if (sendMax) {
      if (keepRemainingTokens) {
        return _buildSendMaxAda(
          network: network,
          acctKey: acctKey,
          syncState: syncState,
          recipientBytes: decodedRecipient.rawBytes,
          sendTokens: sendTokens,
          pparams: pparams,
          ttl: ttl,
        );
      }
      return _buildSendMax(
        network: network,
        acctKey: acctKey,
        syncState: syncState,
        recipientBytes: decodedRecipient.rawBytes,
        pparams: pparams,
        ttl: ttl,
      );
    }

    // Validate recipient output meets Conway minUTxO
    final probeRecipientOut = TxOutput(
      addressBytes: decodedRecipient.rawBytes,
      lovelace: BigInt.from(2000000),
      multiAsset: sendTokens,
    );
    final recipientMinAda = calculateMinUtxo(
      probeRecipientOut,
      coinsPerUTxOByte: pparams.coinsPerUTxOByte,
    );
    final effectiveLovelaceToSend = (autoMinAda && lovelaceToSend < recipientMinAda)
        ? recipientMinAda
        : lovelaceToSend;

    if (effectiveLovelaceToSend < recipientMinAda) {
      throw ArgumentError(
        'Amount is below Min-ADA requirement (${recipientMinAda.toString()} lovelace)',
      );
    }

    final changeBytes = acctKey.deriveBaseAddressBytes(
      role: 1,
      index: syncState.nextUnusedInternalIndex,
      network: network,
    );

    // Coin selection:
    // 1. Cover required Native Tokens first
    // 2. Prefer clean ADA UTXOs for remaining ADA + fee + change minUTxO
    final selected = <DerivedUtxo>[];
    final remainingPool = List<DerivedUtxo>.from(syncState.utxos);

    if (sendTokens.isNotEmpty) {
      for (final entry in sendTokens.assets.entries) {
        var collected = BigInt.zero;
        for (final u in selected) {
          collected += u.utxo.multiAsset[entry.key];
        }
        if (collected >= entry.value) continue;

        final candidates = remainingPool
            .where((u) => u.utxo.multiAsset[entry.key] > BigInt.zero)
            .toList()
          ..sort(
            (a, b) => b.utxo.multiAsset[entry.key]
                .compareTo(a.utxo.multiAsset[entry.key]),
          );
        for (final c in candidates) {
          selected.add(c);
          remainingPool.remove(c);
          collected += c.utxo.multiAsset[entry.key];
          if (collected >= entry.value) break;
        }
        if (collected < entry.value) {
          throw StateError('Insufficient balance for token ${entry.key.displayName}');
        }
      }
    }

    // Sort remaining UTXOs: clean ADA first (largest-first), then token UTXOs
    remainingPool.sort((a, b) {
      final aClean = a.utxo.multiAsset.isEmpty ? 0 : 1;
      final bClean = b.utxo.multiAsset.isEmpty ? 0 : 1;
      if (aClean != bClean) return aClean.compareTo(bClean);
      return b.utxo.lovelace.compareTo(a.utxo.lovelace);
    });

    if (selected.isEmpty && remainingPool.isNotEmpty) {
      selected.add(remainingPool.removeAt(0));
    }

    var estimatedFee = BigInt.from(180000);
    BigInt? changeMinAda;

    for (var iter = 0; iter < 12; iter++) {
      var inLovelace = BigInt.zero;
      var inAssets = MultiAsset.empty;
      for (final s in selected) {
        inLovelace += s.utxo.lovelace;
        inAssets = inAssets.add(s.utxo.multiAsset);
      }

      final leftoverAssets = inAssets.subtract(sendTokens);
      var requiredOutLovelace = effectiveLovelaceToSend + estimatedFee;
      BigInt minAdaForChange = BigInt.zero;

      if (leftoverAssets.isNotEmpty) {
        minAdaForChange = calculateMinUtxo(
          TxOutput(
            addressBytes: changeBytes,
            lovelace: BigInt.from(2000000),
            multiAsset: leftoverAssets,
          ),
          coinsPerUTxOByte: pparams.coinsPerUTxOByte,
        );
        requiredOutLovelace += minAdaForChange;
      }

      while (inLovelace < requiredOutLovelace && remainingPool.isNotEmpty) {
        final next = remainingPool.removeAt(0);
        selected.add(next);
        inLovelace += next.utxo.lovelace;
        inAssets = inAssets.add(next.utxo.multiAsset);
        // Recompute leftover assets if new UTXO carries tokens
        if (next.utxo.multiAsset.isNotEmpty) {
          final updatedLeftover = inAssets.subtract(sendTokens);
          minAdaForChange = calculateMinUtxo(
            TxOutput(
              addressBytes: changeBytes,
              lovelace: BigInt.from(2000000),
              multiAsset: updatedLeftover,
            ),
            coinsPerUTxOByte: pparams.coinsPerUTxOByte,
          );
          requiredOutLovelace =
              effectiveLovelaceToSend + estimatedFee + minAdaForChange;
        }
      }

      if (inLovelace < requiredOutLovelace) {
        throw StateError('Insufficient ADA balance to cover transfer, Min-ADA, and fee');
      }

      final finalLeftoverAssets = inAssets.subtract(sendTokens);
      final surplus = inLovelace - effectiveLovelaceToSend - estimatedFee;
      final pureAdaMinUtxo = calculateMinUtxo(
        TxOutput(addressBytes: changeBytes, lovelace: BigInt.from(1500000)),
        coinsPerUTxOByte: pparams.coinsPerUTxOByte,
      );

      // Avoid burning recoverable ADA dust into fee if another UTXO is available
      if (finalLeftoverAssets.isEmpty &&
          surplus > BigInt.zero &&
          surplus < pureAdaMinUtxo &&
          remainingPool.isNotEmpty) {
        selected.add(remainingPool.removeAt(0));
        continue;
      }

      final outputs = <TxOutput>[
        TxOutput(
          addressBytes: decodedRecipient.rawBytes,
          lovelace: effectiveLovelaceToSend,
          multiAsset: sendTokens,
        ),
      ];
      final changeRefs = <UrChangeOutputRef>[];
      var actualFee = estimatedFee;
      var hasChange = false;

      if (finalLeftoverAssets.isNotEmpty || surplus >= pureAdaMinUtxo) {
        hasChange = true;
        outputs.add(
          TxOutput(
            addressBytes: changeBytes,
            lovelace: surplus,
            multiAsset: finalLeftoverAssets,
          ),
        );
        changeRefs.add(
          UrChangeOutputRef(
            txOutputIndex: 1,
            internalIndex: syncState.nextUnusedInternalIndex,
          ),
        );
        changeMinAda =
            finalLeftoverAssets.isNotEmpty ? minAdaForChange : pureAdaMinUtxo;
      } else {
        // Non-recoverable dust (< minUTxO with no extra UTXOs) absorbed into fee
        actualFee += surplus;
      }

      final txBody = ConwayTxBody(
        inputs: [
          for (final s in selected)
            TxInput(txHash: hexDecode(s.utxo.txHash), index: s.utxo.outputIndex),
        ],
        outputs: outputs,
        fee: actualFee,
        ttl: ttl,
        networkId: network.networkTag,
      );

      final exactFee = _computeExactFee(
        txBody: txBody,
        selectedInputs: selected,
        requireStakeWitness: false,
        pparams: pparams,
      );

      if (hasChange) {
        if (actualFee == exactFee ||
            (iter >= 8 &&
                actualFee >= exactFee &&
                (actualFee - exactFee) <= BigInt.from(200))) {
          return _finalizeResult(
            network: network,
            txBody: txBody,
            selectedInputs: selected,
            changeOutputs: changeRefs,
            requireStakeWitness: false,
            recipientMinAda: recipientMinAda,
            changeMinAda: changeMinAda,
          );
        }
      } else {
        if (actualFee >= exactFee &&
            (surplus == BigInt.zero ? actualFee == exactFee : true)) {
          return _finalizeResult(
            network: network,
            txBody: txBody,
            selectedInputs: selected,
            changeOutputs: changeRefs,
            requireStakeWitness: false,
            recipientMinAda: recipientMinAda,
            changeMinAda: changeMinAda,
          );
        }
      }

      estimatedFee = exactFee;
    }

    throw StateError('Failed to converge fee calculation');
  }

  static TxBuildResult _buildSendMaxAda({
    required CardanoNetwork network,
    required CardanoAccountPublicKey acctKey,
    required WalletSyncState syncState,
    required Uint8List recipientBytes,
    required MultiAsset sendTokens,
    required ProtocolParameters pparams,
    required int ttl,
  }) {
    final changeBytes = acctKey.deriveBaseAddressBytes(
      role: 1,
      index: syncState.nextUnusedInternalIndex,
      network: network,
    );

    // Candidate A: UTXOs covering sendTokens + all clean ADA UTXOs
    final candidateA = <DerivedUtxo>[];
    final poolA = List<DerivedUtxo>.from(syncState.utxos);
    if (sendTokens.isNotEmpty) {
      for (final entry in sendTokens.assets.entries) {
        var collected = BigInt.zero;
        for (final u in candidateA) {
          collected += u.utxo.multiAsset[entry.key];
        }
        if (collected >= entry.value) continue;
        final matches = poolA
            .where((u) => u.utxo.multiAsset[entry.key] > BigInt.zero)
            .toList()
          ..sort(
            (a, b) => b.utxo.multiAsset[entry.key]
                .compareTo(a.utxo.multiAsset[entry.key]),
          );
        for (final m in matches) {
          candidateA.add(m);
          poolA.remove(m);
          collected += m.utxo.multiAsset[entry.key];
          if (collected >= entry.value) break;
        }
        if (collected < entry.value) {
          throw StateError('Insufficient balance for token ${entry.key.displayName}');
        }
      }
    }
    for (final u in poolA) {
      if (u.utxo.multiAsset.isEmpty) {
        candidateA.add(u);
      }
    }

    // Candidate B: All UTXOs in the wallet (consolidates leftover tokens to free locked ADA)
    final candidateB = List<DerivedUtxo>.from(syncState.utxos);

    TxBuildResult? tryBuild(List<DerivedUtxo> selected) {
      if (selected.isEmpty) return null;
      var inLovelace = BigInt.zero;
      var inAssets = MultiAsset.empty;
      for (final s in selected) {
        inLovelace += s.utxo.lovelace;
        inAssets = inAssets.add(s.utxo.multiAsset);
      }
      final leftoverAssets = inAssets.subtract(sendTokens);
      final recipientMinAda = calculateMinUtxo(
        TxOutput(
          addressBytes: recipientBytes,
          lovelace: BigInt.from(2000000),
          multiAsset: sendTokens,
        ),
        coinsPerUTxOByte: pparams.coinsPerUTxOByte,
      );
      final changeMinAda = leftoverAssets.isNotEmpty
          ? calculateMinUtxo(
              TxOutput(
                addressBytes: changeBytes,
                lovelace: BigInt.from(2000000),
                multiAsset: leftoverAssets,
              ),
              coinsPerUTxOByte: pparams.coinsPerUTxOByte,
            )
          : BigInt.zero;

      var fee = BigInt.from(180000);
      for (var iter = 0; iter < 8; iter++) {
        final sendAmount = inLovelace - fee - changeMinAda;
        if (sendAmount < recipientMinAda) {
          return null;
        }
        final outputs = <TxOutput>[
          TxOutput(
            addressBytes: recipientBytes,
            lovelace: sendAmount,
            multiAsset: sendTokens,
          ),
          if (leftoverAssets.isNotEmpty)
            TxOutput(
              addressBytes: changeBytes,
              lovelace: changeMinAda,
              multiAsset: leftoverAssets,
            ),
        ];
        final changeRefs = leftoverAssets.isNotEmpty
            ? [
                UrChangeOutputRef(
                  txOutputIndex: 1,
                  internalIndex: syncState.nextUnusedInternalIndex,
                ),
              ]
            : const <UrChangeOutputRef>[];

        final txBody = ConwayTxBody(
          inputs: [
            for (final s in selected)
              TxInput(txHash: hexDecode(s.utxo.txHash), index: s.utxo.outputIndex),
          ],
          outputs: outputs,
          fee: fee,
          ttl: ttl,
          networkId: network.networkTag,
        );
        final exactFee = _computeExactFee(
          txBody: txBody,
          selectedInputs: selected,
          requireStakeWitness: false,
          pparams: pparams,
        );
        if (fee == exactFee) {
          return _finalizeResult(
            network: network,
            txBody: txBody,
            selectedInputs: selected,
            changeOutputs: changeRefs,
            requireStakeWitness: false,
            recipientMinAda: recipientMinAda,
            changeMinAda: leftoverAssets.isNotEmpty ? changeMinAda : null,
          );
        }
        fee = exactFee;
      }
      return null;
    }

    final resA = tryBuild(candidateA);
    final resB = tryBuild(candidateB);
    if (resA != null && resB != null) {
      return resB.txBody.outputs[0].lovelace >= resA.txBody.outputs[0].lovelace
          ? resB
          : resA;
    }
    if (resB != null) return resB;
    if (resA != null) return resA;

    throw StateError(
      'Insufficient ADA to cover Send Max ADA (fee + Min-ADA for remaining tokens)',
    );
  }

  static TxBuildResult _buildSendMax({
    required CardanoNetwork network,
    required CardanoAccountPublicKey acctKey,
    required WalletSyncState syncState,
    required Uint8List recipientBytes,
    required ProtocolParameters pparams,
    required int ttl,
  }) {
    final selected = List<DerivedUtxo>.from(syncState.utxos);
    var totalLovelace = BigInt.zero;
    var totalAssets = MultiAsset.empty;
    for (final s in selected) {
      totalLovelace += s.utxo.lovelace;
      totalAssets = totalAssets.add(s.utxo.multiAsset);
    }

    var fee = BigInt.from(200000);
    for (var i = 0; i < 6; i++) {
      final sendAmount = totalLovelace - fee;
      if (sendAmount <= BigInt.zero) {
        throw StateError('Insufficient balance to cover transaction fee');
      }
      final out = TxOutput(
        addressBytes: recipientBytes,
        lovelace: sendAmount,
        multiAsset: totalAssets,
      );
      final minAda = calculateMinUtxo(
        out,
        coinsPerUTxOByte: pparams.coinsPerUTxOByte,
      );
      if (sendAmount < minAda) {
        throw StateError('Remaining balance is below Min-ADA ($minAda lovelace)');
      }

      final txBody = ConwayTxBody(
        inputs: [
          for (final s in selected)
            TxInput(txHash: hexDecode(s.utxo.txHash), index: s.utxo.outputIndex),
        ],
        outputs: [out],
        fee: fee,
        ttl: ttl,
        networkId: network.networkTag,
      );
      final exactFee = _computeExactFee(
        txBody: txBody,
        selectedInputs: selected,
        requireStakeWitness: false,
        pparams: pparams,
      );
      if (fee == exactFee) {
        return _finalizeResult(
          network: network,
          txBody: txBody,
          selectedInputs: selected,
          changeOutputs: const [],
          requireStakeWitness: false,
          recipientMinAda: minAda,
        );
      }
      fee = exactFee;
    }

    throw StateError('Failed to converge Send Max fee');
  }

  /// Builds a Conway Staking / Vote Delegation / Reward Withdrawal / Deregistration Tx.
  static TxBuildResult buildStakingAction({
    required WatchOnlyProfile profile,
    required WalletSyncState syncState,
    String? poolId,
    DRep? drep,
    bool withdrawRewards = false,
    bool deregisterStake = false,
  }) {
    final network = profile.network;
    final acctKey = CardanoAccountPublicKey.fromBech32(profile.acctXvkBech32);
    final pparams = syncState.protocolParameters;
    final stakeHash = acctKey.deriveStakeKeyHash();
    final stakeCred = StakeCredential(hash28: stakeHash);
    final rewardAddrBytes = acctKey.deriveRewardAddressBytes(network: network);
    final changeBytes = acctKey.deriveBaseAddressBytes(
      role: 1,
      index: syncState.nextUnusedInternalIndex,
      network: network,
    );
    final ttl = syncState.latestSlot + 7200;

    final certs = <CardanoCertificate>[];
    final withdrawals = <Withdrawal>[];
    var deposits = BigInt.zero;
    var refunds = BigInt.zero;

    if (deregisterStake) {
      if (!syncState.stakeInfo.registered) {
        throw StateError('Stake key is not currently registered');
      }
      if (syncState.stakeInfo.withdrawableAmount > BigInt.zero) {
        withdrawals.add(
          Withdrawal(
            rewardAddressBytes: rewardAddrBytes,
            coin: syncState.stakeInfo.withdrawableAmount,
          ),
        );
      }
      certs.add(StakeDeregistrationCert(stakeCred, coin: pparams.keyDeposit));
      refunds += pparams.keyDeposit;
    } else {
      if (poolId != null && poolId.trim().isNotEmpty) {
        final poolHash = CardanoAddress.decodePoolId(poolId.trim());
        if (!syncState.stakeInfo.registered) {
          certs.add(StakeRegistrationCert(stakeCred, coin: pparams.keyDeposit));
          deposits += pparams.keyDeposit;
        }
        certs.add(StakeDelegationCert(stakeCred, poolHash));
      }

      if (drep != null) {
        if (!syncState.stakeInfo.registered && certs.isEmpty) {
          certs.add(StakeRegistrationCert(stakeCred, coin: pparams.keyDeposit));
          deposits += pparams.keyDeposit;
        }
        certs.add(VoteDelegationCert(stakeCred, drep));
      }

      if (withdrawRewards) {
        final reward = syncState.stakeInfo.withdrawableAmount;
        if (reward <= BigInt.zero) {
          throw StateError('No withdrawable staking rewards available');
        }
        // Conway rule: if user has never set a DRep yet, auto-attach AlwaysAbstain
        if ((syncState.stakeInfo.drepId == null ||
                syncState.stakeInfo.drepId!.isEmpty) &&
            drep == null) {
          certs.add(VoteDelegationCert(stakeCred, const DRepAlwaysAbstain()));
        }
        withdrawals.add(
          Withdrawal(rewardAddressBytes: rewardAddrBytes, coin: reward),
        );
      }
    }

    if (certs.isEmpty && withdrawals.isEmpty) {
      throw ArgumentError('No staking or governance action specified');
    }

    final totalWithdrawals = withdrawals.fold<BigInt>(
      BigInt.zero,
      (sum, w) => sum + w.coin,
    );

    if (syncState.utxos.isEmpty) {
      throw StateError('At least one ADA UTXO is required to pay fees/collateral');
    }

    final pool = List<DerivedUtxo>.from(syncState.utxos)
      ..sort((a, b) {
        final aClean = a.utxo.multiAsset.isEmpty ? 0 : 1;
        final bClean = b.utxo.multiAsset.isEmpty ? 0 : 1;
        if (aClean != bClean) return aClean.compareTo(bClean);
        return b.utxo.lovelace.compareTo(a.utxo.lovelace);
      });

    final selected = <DerivedUtxo>[pool.removeAt(0)];
    var fee = BigInt.from(200000);

    for (var iter = 0; iter < 8; iter++) {
      var inLovelace = BigInt.zero;
      var inAssets = MultiAsset.empty;
      for (final s in selected) {
        inLovelace += s.utxo.lovelace;
        inAssets = inAssets.add(s.utxo.multiAsset);
      }

      final minChangeAda = calculateMinUtxo(
        TxOutput(
          addressBytes: changeBytes,
          lovelace: BigInt.from(2000000),
          multiAsset: inAssets,
        ),
        coinsPerUTxOByte: pparams.coinsPerUTxOByte,
      );

      var changeLovelace =
          inLovelace + totalWithdrawals + refunds - deposits - fee;

      while (changeLovelace < minChangeAda && pool.isNotEmpty) {
        final next = pool.removeAt(0);
        selected.add(next);
        inLovelace += next.utxo.lovelace;
        inAssets = inAssets.add(next.utxo.multiAsset);
        changeLovelace =
            inLovelace + totalWithdrawals + refunds - deposits - fee;
      }

      if (changeLovelace < minChangeAda) {
        throw StateError('Insufficient ADA for staking deposit, fee, and minUTxO');
      }

      final txBody = ConwayTxBody(
        inputs: [
          for (final s in selected)
            TxInput(txHash: hexDecode(s.utxo.txHash), index: s.utxo.outputIndex),
        ],
        outputs: [
          TxOutput(
            addressBytes: changeBytes,
            lovelace: changeLovelace,
            multiAsset: inAssets,
          ),
        ],
        fee: fee,
        ttl: ttl,
        certificates: certs,
        withdrawals: withdrawals,
        networkId: network.networkTag,
      );

      final exactFee = _computeExactFee(
        txBody: txBody,
        selectedInputs: selected,
        requireStakeWitness: true,
        pparams: pparams,
      );

      if (fee == exactFee) {
        return _finalizeResult(
          network: network,
          txBody: txBody,
          selectedInputs: selected,
          changeOutputs: [
            UrChangeOutputRef(
              txOutputIndex: 0,
              internalIndex: syncState.nextUnusedInternalIndex,
            ),
          ],
          requireStakeWitness: true,
          changeMinAda: minChangeAda,
        );
      }
      fee = exactFee;
    }

    throw StateError('Failed to converge staking fee');
  }

  static BigInt _computeExactFee({
    required ConwayTxBody txBody,
    required List<DerivedUtxo> selectedInputs,
    required bool requireStakeWitness,
    required ProtocolParameters pparams,
  }) {
    final bodyBytes = ConwayTxSerializer.encodeTxBody(txBody);
    final uniquePaths = <String>{
      for (final u in selectedInputs) '${u.derivationRole}/${u.derivationIndex}',
    };
    final witnessCount = uniquePaths.length + (requireStakeWitness ? 1 : 0);
    final dummyWitnesses = [
      for (var i = 0; i < witnessCount; i++)
        VKeyWitness(
          vkey: Uint8List.fromList([i & 0xff, ...List<int>.filled(31, 0xaa)]),
          signature: Uint8List(64),
        ),
    ];
    final dummySigned = ConwayTxSerializer.assembleSignedTransaction(
      txBodyCbor: bodyBytes,
      witnesses: dummyWitnesses,
      verifySignatures: false,
    );
    final exactBytes = dummySigned.length;
    return BigInt.from(pparams.minFeeA * exactBytes + pparams.minFeeB);
  }

  static TxBuildResult _finalizeResult({
    required CardanoNetwork network,
    required ConwayTxBody txBody,
    required List<DerivedUtxo> selectedInputs,
    required List<UrChangeOutputRef> changeOutputs,
    required bool requireStakeWitness,
    BigInt? recipientMinAda,
    BigInt? changeMinAda,
  }) {
    final bodyBytes = ConwayTxSerializer.encodeTxBody(txBody);
    final req = CardanoSignRequestUr(
      requestId: _randomRequestId(),
      network: network,
      txBodyCbor: bodyBytes,
      utxoInputs: [
        for (final u in selectedInputs)
          UrUtxoInputContext(
            txHash: hexDecode(u.utxo.txHash),
            outputIndex: u.utxo.outputIndex,
            addressBytes: CardanoAddress.decode(u.utxo.address).rawBytes,
            lovelace: u.utxo.lovelace,
            multiAssets: u.utxo.multiAsset,
            derivationRole: u.derivationRole,
            derivationIndex: u.derivationIndex,
          ),
      ],
      changeOutputs: changeOutputs,
      requireStakeWitness: requireStakeWitness,
    );

    return TxBuildResult(
      signRequest: req,
      txBody: txBody,
      fee: txBody.fee,
      recipientMinAda: recipientMinAda,
      changeMinAda: changeMinAda,
    );
  }
}
