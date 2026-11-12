import 'dart:convert';
import 'dart:typed_data';
import 'package:cardano_core/cardano_core.dart';
import 'package:test/test.dart';

void main() {
  const walletMnemonic =
      'eight country switch draw meat scout mystery blade tip drift useless good keep usage title';
  const attackerMnemonic =
      'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';

  late CardanoMasterKey walletKey;
  late CardanoMasterKey attackerKey;

  setUp(() {
    final wEnt = Bip39.mnemonicToEntropy(walletMnemonic);
    final aEnt = Bip39.mnemonicToEntropy(attackerMnemonic);
    walletKey = CardanoMasterKey.fromEntropy(wEnt);
    attackerKey = CardanoMasterKey.fromEntropy(aEnt);
    zeroizeAll([wEnt, aEnt]);
  });

  tearDown(() {
    walletKey.dispose();
    attackerKey.dispose();
  });

  CardanoSignRequestUr buildValidTransfer({
    CardanoNetwork network = CardanoNetwork.preprod,
    bool includeTokens = false,
  }) {
    final inAddr = walletKey.deriveBaseAddressBytes(
      role: 0,
      index: 0,
      network: network,
    );
    final recipientAddr = attackerKey.deriveBaseAddressBytes(
      role: 0,
      index: 0,
      network: network,
    );
    final changeAddr = walletKey.deriveBaseAddressBytes(
      role: 1,
      index: 3,
      network: network,
    );

    final tokenKey = AssetKey.fromBytes(
      Uint8List.fromList(List<int>.filled(28, 0xaa)),
      Uint8List.fromList(utf8.encode('GOLD')),
    );
    final inputMa = includeTokens ? MultiAsset({tokenKey: BigInt.from(100)}) : MultiAsset.empty;
    final outMa = includeTokens ? MultiAsset({tokenKey: BigInt.from(40)}) : MultiAsset.empty;
    final chgMa = includeTokens ? MultiAsset({tokenKey: BigInt.from(60)}) : MultiAsset.empty;

    final txHash = Uint8List.fromList(List<int>.filled(32, 0x55));
    final fee = BigInt.from(180000);
    final txBody = ConwayTxBody(
      inputs: [TxInput(txHash: txHash, index: 0)],
      outputs: [
        TxOutput(addressBytes: recipientAddr, lovelace: BigInt.from(3000000), multiAsset: outMa),
        TxOutput(addressBytes: changeAddr, lovelace: BigInt.from(6820000), multiAsset: chgMa),
      ],
      fee: fee,
      ttl: 90000000,
      networkId: network.networkTag,
    );

    return CardanoSignRequestUr(
      requestId: Uint8List.fromList(List<int>.generate(16, (i) => i)),
      network: network,
      txBodyCbor: ConwayTxSerializer.encodeTxBody(txBody),
      utxoInputs: [
        UrUtxoInputContext(
          txHash: txHash,
          outputIndex: 0,
          addressBytes: inAddr,
          lovelace: BigInt.from(10000000),
          multiAssets: inputMa,
          derivationRole: 0,
          derivationIndex: 0,
        ),
      ],
      changeOutputs: const [
        UrChangeOutputRef(txOutputIndex: 1, internalIndex: 3),
      ],
      requireStakeWitness: false,
    );
  }

  group('SEC-01 Guard Valid Transactions', () {
    test('Passes valid ADA + MultiAsset transfer and signs', () {
      final req = buildValidTransfer(includeTokens: true);
      final report = Sec01Guard.audit(
        request: req,
        masterKey: walletKey,
        expectedNetwork: CardanoNetwork.preprod,
      );
      expect(report.externalOutputs.length, 1);
      expect(report.verifiedChangeOutputs.length, 1);
      expect(report.verifiedChangeOutputs.first.changeInternalIndex, 3);
      expect(report.netAdaSpent, BigInt.from(3180000));

      final res = Sec01Guard.auditAndSign(
        request: req,
        masterKey: walletKey,
        expectedNetwork: CardanoNetwork.preprod,
      );
      expect(res.vkeyWitnesses.length, 1);
      final txHash = ConwayTxSerializer.computeTxBodyHash(req.txBodyCbor);
      expect(
        Ed25519.verify(
          res.vkeyWitnesses.first.vkey,
          txHash,
          res.vkeyWitnesses.first.signature,
        ),
        isTrue,
      );
    });

    test('Passes valid Conway Staking + VoteDelegation + Reward Withdrawal', () {
      final inAddr = walletKey.deriveBaseAddressBytes(
        role: 0,
        index: 0,
        network: CardanoNetwork.preprod,
      );
      final changeAddr = walletKey.deriveBaseAddressBytes(
        role: 1,
        index: 0,
        network: CardanoNetwork.preprod,
      );
      final stakeCred = StakeCredential(hash28: walletKey.deriveStakeKeyHash());
      final rewardAddr = walletKey.deriveRewardAddressBytes(
        network: CardanoNetwork.preprod,
      );
      final poolHash = Uint8List.fromList(List<int>.filled(28, 0x77));
      final txHash = Uint8List.fromList(List<int>.filled(32, 0x33));

      // Input: 10 ADA, Withdrawal: 5 ADA, Deposit: 2 ADA, Fee: 0.2 ADA => Change: 12.8 ADA
      final txBody = ConwayTxBody(
        inputs: [TxInput(txHash: txHash, index: 1)],
        outputs: [
          TxOutput(addressBytes: changeAddr, lovelace: BigInt.from(12800000)),
        ],
        fee: BigInt.from(200000),
        ttl: 90000000,
        certificates: [
          StakeRegistrationCert(stakeCred, coin: BigInt.from(2000000)),
          StakeDelegationCert(stakeCred, poolHash),
          VoteDelegationCert(stakeCred, const DRepAlwaysAbstain()),
        ],
        withdrawals: [
          Withdrawal(
            rewardAddressBytes: rewardAddr,
            coin: BigInt.from(5000000),
          ),
        ],
        networkId: 0,
      );

      final req = CardanoSignRequestUr(
        requestId: Uint8List.fromList(List<int>.filled(16, 9)),
        network: CardanoNetwork.preprod,
        txBodyCbor: ConwayTxSerializer.encodeTxBody(txBody),
        utxoInputs: [
          UrUtxoInputContext(
            txHash: txHash,
            outputIndex: 1,
            addressBytes: inAddr,
            lovelace: BigInt.from(10000000),
            derivationRole: 0,
            derivationIndex: 0,
          ),
        ],
        changeOutputs: const [
          UrChangeOutputRef(txOutputIndex: 0, internalIndex: 0),
        ],
        requireStakeWitness: true,
      );

      final res = Sec01Guard.auditAndSign(
        request: req,
        masterKey: walletKey,
        expectedNetwork: CardanoNetwork.preprod,
      );
      // Payment key + Stake key = 2 witnesses
      expect(res.vkeyWitnesses.length, 2);
    });
  });

  group('SEC-01 Attack & Tampering Detection', () {
    test('Blocks Change Address Substitution Attack', () {
      final inAddr = walletKey.deriveBaseAddressBytes(
        role: 0,
        index: 0,
        network: CardanoNetwork.preprod,
      );
      final recipientAddr = attackerKey.deriveBaseAddressBytes(
        role: 0,
        index: 0,
        network: CardanoNetwork.preprod,
      );
      // Attacker swaps Change output to their own address!
      final hijackedChangeAddr = attackerKey.deriveBaseAddressBytes(
        role: 1,
        index: 0,
        network: CardanoNetwork.preprod,
      );
      final txHash = Uint8List.fromList(List<int>.filled(32, 0x55));

      final txBody = ConwayTxBody(
        inputs: [TxInput(txHash: txHash, index: 0)],
        outputs: [
          TxOutput(addressBytes: recipientAddr, lovelace: BigInt.from(2000000)),
          TxOutput(addressBytes: hijackedChangeAddr, lovelace: BigInt.from(7820000)),
        ],
        fee: BigInt.from(180000),
        networkId: 0,
      );

      final req = CardanoSignRequestUr(
        requestId: Uint8List.fromList(List<int>.filled(16, 1)),
        network: CardanoNetwork.preprod,
        txBodyCbor: ConwayTxSerializer.encodeTxBody(txBody),
        utxoInputs: [
          UrUtxoInputContext(
            txHash: txHash,
            outputIndex: 0,
            addressBytes: inAddr,
            lovelace: BigInt.from(10000000),
            derivationRole: 0,
            derivationIndex: 0,
          ),
        ],
        changeOutputs: const [
          UrChangeOutputRef(txOutputIndex: 1, internalIndex: 0),
        ],
        requireStakeWitness: false,
      );

      expect(
        () => Sec01Guard.audit(
          request: req,
          masterKey: walletKey,
          expectedNetwork: CardanoNetwork.preprod,
        ),
        throwsA(
          isA<Sec01SecurityException>().having(
            (e) => e.code,
            'code',
            Sec01ErrorCode.changeAddressMismatch,
          ),
        ),
      );
    });

    test('Blocks UTXO Input balance inflation / hidden fee', () {
      final valid = buildValidTransfer();
      // Lie about input lovelace (+5 ADA)
      final tampered = CardanoSignRequestUr(
        requestId: valid.requestId,
        network: valid.network,
        txBodyCbor: valid.txBodyCbor,
        utxoInputs: [
          UrUtxoInputContext(
            txHash: valid.utxoInputs.first.txHash,
            outputIndex: 0,
            addressBytes: valid.utxoInputs.first.addressBytes,
            lovelace: BigInt.from(15000000),
            derivationRole: 0,
            derivationIndex: 0,
          ),
        ],
        changeOutputs: valid.changeOutputs,
        requireStakeWitness: false,
      );

      expect(
        () => Sec01Guard.audit(
          request: tampered,
          masterKey: walletKey,
          expectedNetwork: CardanoNetwork.preprod,
        ),
        throwsA(
          isA<Sec01SecurityException>().having(
            (e) => e.code,
            'code',
            Sec01ErrorCode.valueImbalance,
          ),
        ),
      );
    });

    test('Blocks Native Token loss / theft', () {
      final inAddr = walletKey.deriveBaseAddressBytes(
        role: 0,
        index: 0,
        network: CardanoNetwork.preprod,
      );
      final changeAddr = walletKey.deriveBaseAddressBytes(
        role: 1,
        index: 0,
        network: CardanoNetwork.preprod,
      );
      final tokenKey = AssetKey.fromBytes(
        Uint8List.fromList(List<int>.filled(28, 0xaa)),
        Uint8List.fromList(utf8.encode('GOLD')),
      );
      final txHash = Uint8List.fromList(List<int>.filled(32, 0x55));

      final txBody = ConwayTxBody(
        inputs: [TxInput(txHash: txHash, index: 0)],
        outputs: [
          // Forgot to return 50 GOLD tokens!
          TxOutput(addressBytes: changeAddr, lovelace: BigInt.from(9820000)),
        ],
        fee: BigInt.from(180000),
        networkId: 0,
      );

      final req = CardanoSignRequestUr(
        requestId: Uint8List.fromList(List<int>.filled(16, 1)),
        network: CardanoNetwork.preprod,
        txBodyCbor: ConwayTxSerializer.encodeTxBody(txBody),
        utxoInputs: [
          UrUtxoInputContext(
            txHash: txHash,
            outputIndex: 0,
            addressBytes: inAddr,
            lovelace: BigInt.from(10000000),
            multiAssets: MultiAsset({tokenKey: BigInt.from(50)}),
            derivationRole: 0,
            derivationIndex: 0,
          ),
        ],
        changeOutputs: const [
          UrChangeOutputRef(txOutputIndex: 0, internalIndex: 0),
        ],
        requireStakeWitness: false,
      );

      expect(
        () => Sec01Guard.audit(
          request: req,
          masterKey: walletKey,
          expectedNetwork: CardanoNetwork.preprod,
        ),
        throwsA(
          isA<Sec01SecurityException>().having(
            (e) => e.code,
            'code',
            Sec01ErrorCode.nativeTokenImbalance,
          ),
        ),
      );
    });

    test('Blocks foreign Stake Credential in Certificate', () {
      final inAddr = walletKey.deriveBaseAddressBytes(
        role: 0,
        index: 0,
        network: CardanoNetwork.preprod,
      );
      final changeAddr = walletKey.deriveBaseAddressBytes(
        role: 1,
        index: 0,
        network: CardanoNetwork.preprod,
      );
      final foreignStakeCred = StakeCredential(
        hash28: attackerKey.deriveStakeKeyHash(),
      );
      final poolHash = Uint8List.fromList(List<int>.filled(28, 0x77));
      final txHash = Uint8List.fromList(List<int>.filled(32, 0x33));

      final txBody = ConwayTxBody(
        inputs: [TxInput(txHash: txHash, index: 0)],
        outputs: [
          TxOutput(addressBytes: changeAddr, lovelace: BigInt.from(9800000)),
        ],
        fee: BigInt.from(200000),
        certificates: [StakeDelegationCert(foreignStakeCred, poolHash)],
        networkId: 0,
      );

      final req = CardanoSignRequestUr(
        requestId: Uint8List.fromList(List<int>.filled(16, 3)),
        network: CardanoNetwork.preprod,
        txBodyCbor: ConwayTxSerializer.encodeTxBody(txBody),
        utxoInputs: [
          UrUtxoInputContext(
            txHash: txHash,
            outputIndex: 0,
            addressBytes: inAddr,
            lovelace: BigInt.from(10000000),
            derivationRole: 0,
            derivationIndex: 0,
          ),
        ],
        changeOutputs: const [
          UrChangeOutputRef(txOutputIndex: 0, internalIndex: 0),
        ],
        requireStakeWitness: true,
      );

      expect(
        () => Sec01Guard.audit(
          request: req,
          masterKey: walletKey,
          expectedNetwork: CardanoNetwork.preprod,
        ),
        throwsA(
          isA<Sec01SecurityException>().having(
            (e) => e.code,
            'code',
            Sec01ErrorCode.unauthorizedStakeCredential,
          ),
        ),
      );
    });

    test('Blocks Network mismatch between Cold Wallet and Sign Request', () {
      final req = buildValidTransfer(network: CardanoNetwork.preprod);
      expect(
        () => Sec01Guard.audit(
          request: req,
          masterKey: walletKey,
          expectedNetwork: CardanoNetwork.mainnet,
        ),
        throwsA(
          isA<Sec01SecurityException>().having(
            (e) => e.code,
            'code',
            Sec01ErrorCode.networkMismatch,
          ),
        ),
      );
    });
  });
}
