import 'dart:typed_data';
import '../crypto/bytes_utils.dart';
import '../crypto/keccak256.dart';
import '../rlp/rlp_codec.dart';
import 'evm_tx_models.dart';

/// Serializer for EVM transactions and signature injection.
class EvmTxSerializer {
  const EvmTxSerializer._();

  /// Serializes an unsigned EIP-1559 transaction for hashing:
  /// 0x02 || RLP([chainId, nonce, maxPriorityFeePerGas, maxFeePerGas, gasLimit, to, value, data, accessList])
  static Uint8List serializeEip1559Unsigned(Eip1559Transaction tx) {
    final toBytes = hexDecode(tx.to);
    final accessListRlp = tx.accessList.map((a) => a.toRlpItem()).toList();

    final rlpList = [
      tx.chainId,
      tx.nonce,
      tx.maxPriorityFeePerGas,
      tx.maxFeePerGas,
      tx.gasLimit,
      toBytes,
      tx.value,
      tx.data,
      accessListRlp,
    ];

    final encodedRlp = Rlp.encodeList(rlpList);
    return concatBytes([
      Uint8List.fromList([0x02]),
      encodedRlp,
    ]);
  }

  /// Injects signature into an EIP-1559 transaction:
  /// 0x02 || RLP([chainId, nonce, maxPriorityFeePerGas, maxFeePerGas, gasLimit, to, value, data, accessList, yParity, r, s])
  static Uint8List serializeEip1559Signed(Eip1559Transaction tx, EvmSignature sig) {
    final toBytes = hexDecode(tx.to);
    final accessListRlp = tx.accessList.map((a) => a.toRlpItem()).toList();

    // In EIP-1559, yParity is 0 or 1
    final yParity = sig.v >= 27 ? (sig.v - 27) : sig.v;

    final rlpList = [
      tx.chainId,
      tx.nonce,
      tx.maxPriorityFeePerGas,
      tx.maxFeePerGas,
      tx.gasLimit,
      toBytes,
      tx.value,
      tx.data,
      accessListRlp,
      yParity,
      _stripLeadingZeros(sig.r),
      _stripLeadingZeros(sig.s),
    ];

    final encodedRlp = Rlp.encodeList(rlpList);
    return concatBytes([
      Uint8List.fromList([0x02]),
      encodedRlp,
    ]);
  }

  /// Serializes an unsigned Legacy transaction with EIP-155 replay protection:
  /// RLP([nonce, gasPrice, gasLimit, to, value, data, chainId, 0, 0])
  static Uint8List serializeLegacyUnsigned(LegacyTransaction tx) {
    final toBytes = hexDecode(tx.to);
    final rlpList = [
      tx.nonce,
      tx.gasPrice,
      tx.gasLimit,
      toBytes,
      tx.value,
      tx.data,
      tx.chainId,
      BigInt.zero,
      BigInt.zero,
    ];
    return Rlp.encodeList(rlpList);
  }

  /// Injects signature into a Legacy transaction:
  /// RLP([nonce, gasPrice, gasLimit, to, value, data, v, r, s])
  static Uint8List serializeLegacySigned(LegacyTransaction tx, EvmSignature sig) {
    final toBytes = hexDecode(tx.to);
    // EIP-155: v = chainId * 2 + 35 + recId
    var vVal = sig.v;
    if (vVal < 27) {
      vVal = tx.chainId * 2 + 35 + vVal;
    }

    final rlpList = [
      tx.nonce,
      tx.gasPrice,
      tx.gasLimit,
      toBytes,
      tx.value,
      tx.data,
      vVal,
      _stripLeadingZeros(sig.r),
      _stripLeadingZeros(sig.s),
    ];
    return Rlp.encodeList(rlpList);
  }

  /// Computes 32-byte signing hash for any supported EVM transaction.
  static Uint8List hashForSigning(EvmTransaction tx) {
    return Keccak256.hash(tx.unsignedSigningBytes);
  }

  static Uint8List _stripLeadingZeros(Uint8List bytes) {
    var start = 0;
    while (start < bytes.length && bytes[start] == 0) {
      start++;
    }
    if (start == bytes.length) return Uint8List(0);
    return bytes.sublist(start);
  }
}
