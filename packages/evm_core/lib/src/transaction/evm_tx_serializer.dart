import 'dart:typed_data';
import '../address/eip55.dart';
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
    final toBytes = tx.to.isEmpty ? Uint8List(0) : hexDecode(tx.to);
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
    final toBytes = tx.to.isEmpty ? Uint8List(0) : hexDecode(tx.to);
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
    final toBytes = tx.to.isEmpty ? Uint8List(0) : hexDecode(tx.to);
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
    final toBytes = tx.to.isEmpty ? Uint8List(0) : hexDecode(tx.to);
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

  /// Strictly deserializes an unsigned EIP-1559 transaction from [bytes]:
  /// `0x02 || RLP([chainId, nonce, maxPriorityFeePerGas, maxFeePerGas, gasLimit, to, value, data, accessList])`.
  static Eip1559Transaction deserializeEip1559Unsigned(Uint8List bytes) {
    if (bytes.length < 2 || bytes[0] != 0x02) {
      throw const FormatException('Invalid EIP-1559 transaction prefix (expected 0x02)');
    }
    final decoded = Rlp.decode(Uint8List.sublistView(bytes, 1));
    if (decoded is! List || decoded.length != 9) {
      throw FormatException(
        'EIP-1559 unsigned transaction must be a 9-element RLP list, got ${decoded is List ? decoded.length : decoded.runtimeType}',
      );
    }

    final chainIdBig = _expectBigInt(decoded[0], 'chainId');
    if (chainIdBig <= BigInt.zero || !chainIdBig.isValidInt) {
      throw FormatException('Invalid EIP-1559 chainId: $chainIdBig');
    }
    final nonce = _expectBigInt(decoded[1], 'nonce');
    final maxPriorityFee = _expectBigInt(decoded[2], 'maxPriorityFeePerGas');
    final maxFee = _expectBigInt(decoded[3], 'maxFeePerGas');
    final gasLimit = _expectBigInt(decoded[4], 'gasLimit');
    final toBytes = _expectBytes(decoded[5], 'to');
    final toAddr = _decodeAddressOrEmpty(toBytes);
    final value = _expectBigInt(decoded[6], 'value');
    final data = _expectBytes(decoded[7], 'data');
    final accessList = _decodeAccessList(decoded[8]);

    return Eip1559Transaction(
      chainId: chainIdBig.toInt(),
      nonce: nonce,
      maxPriorityFeePerGas: maxPriorityFee,
      maxFeePerGas: maxFee,
      gasLimit: gasLimit,
      to: toAddr,
      value: value,
      data: data,
      accessList: accessList,
    );
  }

  /// Strictly deserializes an unsigned Legacy transaction from RLP [bytes]:
  /// EIP-155: `RLP([nonce, gasPrice, gasLimit, to, value, data, chainId, 0, 0])`, or
  /// Pre-EIP-155: `RLP([nonce, gasPrice, gasLimit, to, value, data])`.
  static LegacyTransaction deserializeLegacyUnsigned(Uint8List bytes) {
    if (bytes.isEmpty || bytes[0] < 0xc0) {
      throw const FormatException('Invalid Legacy RLP transaction (expected RLP list)');
    }
    final decoded = Rlp.decode(bytes);
    if (decoded is! List || (decoded.length != 6 && decoded.length != 9)) {
      throw FormatException(
        'Legacy unsigned transaction must have 6 or 9 RLP items, got ${decoded is List ? decoded.length : decoded.runtimeType}',
      );
    }

    final nonce = _expectBigInt(decoded[0], 'nonce');
    final gasPrice = _expectBigInt(decoded[1], 'gasPrice');
    final gasLimit = _expectBigInt(decoded[2], 'gasLimit');
    final toBytes = _expectBytes(decoded[3], 'to');
    final toAddr = _decodeAddressOrEmpty(toBytes);
    final value = _expectBigInt(decoded[4], 'value');
    final data = _expectBytes(decoded[5], 'data');

    var chainId = 0;
    if (decoded.length == 9) {
      final chainIdBig = _expectBigInt(decoded[6], 'chainId');
      final rPlaceholder = _expectBigInt(decoded[7], 'eip155_r');
      final sPlaceholder = _expectBigInt(decoded[8], 'eip155_s');
      if (chainIdBig <= BigInt.zero ||
          !chainIdBig.isValidInt ||
          rPlaceholder != BigInt.zero ||
          sPlaceholder != BigInt.zero) {
        throw const FormatException('Invalid EIP-155 unsigned legacy transaction fields');
      }
      chainId = chainIdBig.toInt();
    }

    return LegacyTransaction(
      chainId: chainId,
      nonce: nonce,
      gasPrice: gasPrice,
      gasLimit: gasLimit,
      to: toAddr,
      value: value,
      data: data,
    );
  }

  static Uint8List _expectBytes(dynamic item, String field) {
    if (item is! Uint8List) {
      throw FormatException('Expected RLP byte string for $field');
    }
    return item;
  }

  static BigInt _expectBigInt(dynamic item, String field) {
    return Rlp.decodeBigInt(_expectBytes(item, field));
  }

  static String _decodeAddressOrEmpty(Uint8List toBytes) {
    if (toBytes.isEmpty) return '';
    if (toBytes.length != 20) {
      throw FormatException('Invalid EVM "to" address byte length: ${toBytes.length}');
    }
    return Eip55.formatChecksumAddress(toBytes);
  }

  static List<AccessListEntry> _decodeAccessList(dynamic rawList) {
    if (rawList is! List) {
      throw const FormatException('accessList must be an RLP list');
    }
    final result = <AccessListEntry>[];
    for (final entry in rawList) {
      if (entry is! List || entry.length != 2) {
        throw const FormatException('Each accessList entry must have 2 elements');
      }
      final addrBytes = _expectBytes(entry[0], 'accessList.address');
      if (addrBytes.length != 20) {
        throw FormatException('Invalid accessList address length: ${addrBytes.length}');
      }
      final rawKeys = entry[1];
      if (rawKeys is! List) {
        throw const FormatException('accessList storageKeys must be an RLP list');
      }
      final keys = <Uint8List>[];
      for (final k in rawKeys) {
        final kb = _expectBytes(k, 'accessList.storageKey');
        if (kb.length != 32) {
          throw FormatException('Invalid accessList storageKey length: ${kb.length}');
        }
        keys.add(kb);
      }
      result.add(AccessListEntry(
        address: Eip55.formatChecksumAddress(addrBytes),
        storageKeys: keys,
      ));
    }
    return result;
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
