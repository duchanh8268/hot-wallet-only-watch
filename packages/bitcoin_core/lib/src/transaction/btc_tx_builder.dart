import 'dart:typed_data';
import '../address/bech32_segwit.dart';
import 'btc_models.dart';

/// Unspent Transaction Output with key derivation metadata.
class BtcUtxo {
  final OutPoint outpoint;
  final BigInt valueSat;
  final int accountIndex;
  final int change; // 0 for external receive, 1 for internal change
  final int addressIndex;
  final Uint8List? pubKeyHash;

  const BtcUtxo({
    required this.outpoint,
    required this.valueSat,
    required this.accountIndex,
    required this.change,
    required this.addressIndex,
    this.pubKeyHash,
  });

  Map<String, dynamic> toJson() => {
        'outpoint': outpoint.toJson(),
        'valueSat': valueSat.toString(),
        'accountIndex': accountIndex,
        'change': change,
        'addressIndex': addressIndex,
      };

  factory BtcUtxo.fromJson(Map<String, dynamic> json) => BtcUtxo(
        outpoint: OutPoint.fromJson(json['outpoint'] as Map<String, dynamic>),
        valueSat: BigInt.parse(json['valueSat'] as String),
        accountIndex: (json['accountIndex'] as num).toInt(),
        change: (json['change'] as num).toInt(),
        addressIndex: (json['addressIndex'] as num).toInt(),
      );
}

/// Transaction build result with details on inputs, outputs, fee and change.
class BtcTxBuildResult {
  final BtcTransaction transaction;
  final BigInt totalInputSat;
  final BigInt sendAmountSat;
  final BigInt feeSat;
  final BigInt? changeSat;
  final int estimatedVSize;

  const BtcTxBuildResult({
    required this.transaction,
    required this.totalInputSat,
    required this.sendAmountSat,
    required this.feeSat,
    required this.changeSat,
    required this.estimatedVSize,
  });
}

/// Helper to select UTXOs and build valid Native SegWit (P2WPKH) Bitcoin transactions.
class BtcTxBuilder {
  static const int dustLimitSat = 546;

  const BtcTxBuilder._();

  /// Estimates the virtual size (vB) for a P2WPKH transaction.
  static int estimateVSize({required int inputCount, required int outputCount}) {
    // 10.5 overhead + (68 * inputs) + (31 * outputs)
    return 11 + (inputCount * 68) + (outputCount * 31);
  }

  /// Builds a P2WPKH transaction spending from [availableUtxos].
  static BtcTxBuildResult buildP2wpkhTx({
    required List<BtcUtxo> availableUtxos,
    required String recipientAddress,
    required BigInt amountSat,
    required String changeAddress,
    required int changeIndex,
    int feeRateSatPerVb = 5,
    bool sendMax = false,
  }) {
    if (availableUtxos.isEmpty) {
      throw StateError('No available UTXOs');
    }
    if (!Bech32Segwit.isValid(address: recipientAddress)) {
      throw ArgumentError('Invalid recipient Bech32 address: $recipientAddress');
    }
    if (!sendMax && amountSat <= BigInt.zero) {
      throw ArgumentError('Amount must be positive');
    }

    final sortedUtxos = List<BtcUtxo>.from(availableUtxos)
      ..sort((a, b) => b.valueSat.compareTo(a.valueSat)); // Largest first

    final selectedUtxos = <BtcUtxo>[];
    var totalInput = BigInt.zero;

    if (sendMax) {
      // Sweep all available UTXOs
      selectedUtxos.addAll(sortedUtxos);
      for (final u in selectedUtxos) {
        totalInput += u.valueSat;
      }
      final vSize = estimateVSize(inputCount: selectedUtxos.length, outputCount: 1);
      final fee = BigInt.from(vSize * feeRateSatPerVb);
      final netSend = totalInput - fee;

      if (netSend < BigInt.from(dustLimitSat)) {
        throw StateError('Insufficient funds to cover dust threshold and fee');
      }

      final inputs = selectedUtxos
          .map(
            (u) => BtcTxIn(
              previousOutput: u.outpoint,
              amountSat: u.valueSat,
              accountIndex: u.accountIndex,
              change: u.change,
              addressIndex: u.addressIndex,
            ),
          )
          .toList();

      final outputs = [
        BtcTxOut.fromAddress(
          valueSat: netSend,
          address: recipientAddress,
          isChange: false,
        ),
      ];

      return BtcTxBuildResult(
        transaction: BtcTransaction(version: 2, inputs: inputs, outputs: outputs),
        totalInputSat: totalInput,
        sendAmountSat: netSend,
        feeSat: fee,
        changeSat: null,
        estimatedVSize: vSize,
      );
    }

    // Normal payment: accumulate UTXOs until amount + estimated fee with change is covered
    var estimatedVSize = estimateVSize(inputCount: 1, outputCount: 2);
    var estimatedFee = BigInt.from(estimatedVSize * feeRateSatPerVb);

    for (final u in sortedUtxos) {
      selectedUtxos.add(u);
      totalInput += u.valueSat;

      estimatedVSize = estimateVSize(inputCount: selectedUtxos.length, outputCount: 2);
      estimatedFee = BigInt.from(estimatedVSize * feeRateSatPerVb);

      if (totalInput >= amountSat + estimatedFee) {
        break;
      }
    }

    if (totalInput < amountSat + estimatedFee) {
      throw StateError('Insufficient funds: have $totalInput sats, need ${amountSat + estimatedFee} sats');
    }

    var changeSat = totalInput - amountSat - estimatedFee;
    var finalVSize = estimatedVSize;
    var finalFee = estimatedFee;
    final outputs = <BtcTxOut>[
      BtcTxOut.fromAddress(valueSat: amountSat, address: recipientAddress, isChange: false),
    ];

    if (changeSat >= BigInt.from(dustLimitSat)) {
      outputs.add(
        BtcTxOut.fromAddress(
          valueSat: changeSat,
          address: changeAddress,
          isChange: true,
          changeIndex: changeIndex,
        ),
      );
    } else {
      // Below dust limit, absorb change into fee
      finalFee += changeSat;
      changeSat = BigInt.zero;
      finalVSize = estimateVSize(inputCount: selectedUtxos.length, outputCount: 1);
    }

    final inputs = selectedUtxos
        .map(
          (u) => BtcTxIn(
            previousOutput: u.outpoint,
            amountSat: u.valueSat,
            accountIndex: u.accountIndex,
            change: u.change,
            addressIndex: u.addressIndex,
          ),
        )
        .toList();

    return BtcTxBuildResult(
      transaction: BtcTransaction(version: 2, inputs: inputs, outputs: outputs),
      totalInputSat: totalInput,
      sendAmountSat: amountSat,
      feeSat: finalFee,
      changeSat: changeSat > BigInt.zero ? changeSat : null,
      estimatedVSize: finalVSize,
    );
  }
}
