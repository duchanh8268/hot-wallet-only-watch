import 'dart:typed_data';
import '../address/eip55.dart';
import '../crypto/bytes_utils.dart';
import 'evm_tx_serializer.dart';

/// Supported EVM transaction envelope types.
enum EvmTxType {
  legacy(0),
  eip2930(1),
  eip1559(2);

  final int typeCode;
  const EvmTxType(this.typeCode);
}

/// Access list entry for EIP-2930 and EIP-1559.
class AccessListEntry {
  final String address;
  final List<Uint8List> storageKeys;

  const AccessListEntry({
    required this.address,
    this.storageKeys = const [],
  });

  List<dynamic> toRlpItem() => [
        hexDecode(address),
        storageKeys,
      ];
}

/// Abstract base class for EVM transactions.
abstract class EvmTransaction {
  int get chainId;
  BigInt get nonce;
  BigInt get gasLimit;
  String get to; // 0x... hex address or empty for contract creation
  BigInt get value; // in wei
  Uint8List get data; // calldata
  EvmTxType get txType;

  /// Serialization of unsigned transaction payload (the bytes to hash with Keccak-256 for signing).
  Uint8List get unsignedSigningBytes;

  /// 32-byte Keccak-256 hash to be signed by secp256k1.
  Uint8List get signingHash;
}

/// EIP-1559 Dynamic Fee Transaction (Type 2).
class Eip1559Transaction implements EvmTransaction {
  @override
  final int chainId;
  @override
  final BigInt nonce;
  final BigInt maxPriorityFeePerGas; // in wei
  final BigInt maxFeePerGas;         // in wei
  @override
  final BigInt gasLimit;
  @override
  final String to;
  @override
  final BigInt value;
  @override
  final Uint8List data;
  final List<AccessListEntry> accessList;

  @override
  EvmTxType get txType => EvmTxType.eip1559;

  Eip1559Transaction({
    required this.chainId,
    required this.nonce,
    required this.maxPriorityFeePerGas,
    required this.maxFeePerGas,
    required this.gasLimit,
    required String to,
    required this.value,
    Uint8List? data,
    this.accessList = const [],
  })  : to = to.trim().isEmpty ? '' : Eip55.toChecksumAddress(to),
        data = data ?? Uint8List(0);

  @override
  Uint8List get unsignedSigningBytes => EvmTxSerializer.serializeEip1559Unsigned(this);

  @override
  Uint8List get signingHash => EvmTxSerializer.hashForSigning(this);
}

/// Legacy Transaction (Type 0).
class LegacyTransaction implements EvmTransaction {
  @override
  final int chainId;
  @override
  final BigInt nonce;
  final BigInt gasPrice; // in wei
  @override
  final BigInt gasLimit;
  @override
  final String to;
  @override
  final BigInt value;
  @override
  final Uint8List data;

  @override
  EvmTxType get txType => EvmTxType.legacy;

  LegacyTransaction({
    required this.chainId,
    required this.nonce,
    required this.gasPrice,
    required this.gasLimit,
    required String to,
    required this.value,
    Uint8List? data,
  })  : to = to.trim().isEmpty ? '' : Eip55.toChecksumAddress(to),
        data = data ?? Uint8List(0);

  @override
  Uint8List get unsignedSigningBytes => EvmTxSerializer.serializeLegacyUnsigned(this);

  @override
  Uint8List get signingHash => EvmTxSerializer.hashForSigning(this);
}

/// EVM transaction signature container.
class EvmSignature {
  final Uint8List r; // 32 bytes
  final Uint8List s; // 32 bytes
  final int v;       // yParity (0/1) for EIP-1559, or (chainId*2 + 35 + recId) for Legacy

  const EvmSignature({
    required this.r,
    required this.s,
    required this.v,
  });
}
