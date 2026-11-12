import 'models.dart';
import 'tx_serializer.dart';

/// Calculates Babbage/Conway minimum ADA (`lovelace`) required for a UTXO output:
/// `minUTxO = (160 + cborByteLength(txOutput)) * coinsPerUTxOByte`.
///
/// Uses fixed-point iteration so CBOR integer length changes for `lovelace`
/// are accounted for accurately.
BigInt calculateMinUtxo(
  TxOutput output, {
  int coinsPerUTxOByte = 4310,
}) {
  var estimate = BigInt.from(1000000);
  var requiredAda = estimate;
  for (var i = 0; i < 6; i++) {
    final probeOutput = TxOutput(
      addressBytes: output.addressBytes,
      lovelace: estimate,
      multiAsset: output.multiAsset,
    );
    final cborBytes = ConwayTxSerializer.encodeTxOutput(probeOutput).encode();
    requiredAda =
        BigInt.from(160 + cborBytes.length) * BigInt.from(coinsPerUTxOByte);
    if (requiredAda == estimate) {
      return requiredAda;
    }
    estimate = requiredAda;
  }
  return requiredAda;
}
