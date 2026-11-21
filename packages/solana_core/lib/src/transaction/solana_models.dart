import 'dart:typed_data';
import '../address/base58.dart';
import 'compact_u16.dart';

/// Account metadata for instruction creation.
class AccountMeta {
  final Uint8List pubkey;
  final bool isSigner;
  final bool isWritable;

  const AccountMeta({
    required this.pubkey,
    required this.isSigner,
    required this.isWritable,
  });

  String get address => Base58.encode(pubkey);
}

/// An instruction before account index compilation.
class SolanaInstruction {
  final Uint8List programId;
  final List<AccountMeta> accounts;
  final Uint8List data;

  const SolanaInstruction({
    required this.programId,
    required this.accounts,
    required this.data,
  });
}

/// Compiled instruction referencing indices in [SolanaMessage.accountKeys].
class CompiledInstruction {
  final int programIdIndex;
  final List<int> accountIndices;
  final Uint8List data;

  const CompiledInstruction({
    required this.programIdIndex,
    required this.accountIndices,
    required this.data,
  });

  Map<String, dynamic> toJson() => {
        'programIdIndex': programIdIndex,
        'accountIndices': accountIndices,
        'dataHex': data.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
      };
}

/// Header containing account privileges metadata.
class MessageHeader {
  final int numRequiredSignatures;
  final int numReadonlySignedAccounts;
  final int numReadonlyUnsignedAccounts;

  const MessageHeader({
    required this.numRequiredSignatures,
    required this.numReadonlySignedAccounts,
    required this.numReadonlyUnsignedAccounts,
  });

  Uint8List toBytes() {
    return Uint8List.fromList([
      numRequiredSignatures,
      numReadonlySignedAccounts,
      numReadonlyUnsignedAccounts,
    ]);
  }

  factory MessageHeader.fromBytes(Uint8List bytes, {int offset = 0}) {
    return MessageHeader(
      numRequiredSignatures: bytes[offset],
      numReadonlySignedAccounts: bytes[offset + 1],
      numReadonlyUnsignedAccounts: bytes[offset + 2],
    );
  }
}

/// Solana Transaction Message (Legacy format).
class SolanaMessage {
  final MessageHeader header;
  final List<Uint8List> accountKeys; // 32 bytes each
  final Uint8List recentBlockhash; // 32 bytes
  final List<CompiledInstruction> instructions;

  const SolanaMessage({
    required this.header,
    required this.accountKeys,
    required this.recentBlockhash,
    required this.instructions,
  });

  /// Compiles a [SolanaMessage] from fee payer, recent blockhash, and high-level [instructions].
  factory SolanaMessage.compile({
    required Uint8List feePayer,
    required Uint8List recentBlockhash,
    required List<SolanaInstruction> instructions,
  }) {
    final signedWritable = <Uint8List>[feePayer];
    final signedReadonly = <Uint8List>[];
    final unsignedWritable = <Uint8List>[];
    final unsignedReadonly = <Uint8List>[];

    void addAccount(AccountMeta meta) {
      final key = meta.pubkey;
      bool matches(Uint8List a) {
        if (a.length != key.length) return false;
        for (var i = 0; i < a.length; i++) {
          if (a[i] != key[i]) return false;
        }
        return true;
      }

      if (meta.isSigner) {
        if (meta.isWritable) {
          if (!signedWritable.any(matches)) signedWritable.add(key);
        } else {
          if (!signedReadonly.any(matches) && !signedWritable.any(matches)) {
            signedReadonly.add(key);
          }
        }
      } else {
        if (meta.isWritable) {
          if (!unsignedWritable.any(matches) &&
              !signedWritable.any(matches) &&
              !signedReadonly.any(matches)) {
            unsignedWritable.add(key);
          }
        } else {
          if (!unsignedReadonly.any(matches) &&
              !unsignedWritable.any(matches) &&
              !signedWritable.any(matches) &&
              !signedReadonly.any(matches)) {
            unsignedReadonly.add(key);
          }
        }
      }
    }

    for (final ix in instructions) {
      for (final acc in ix.accounts) {
        addAccount(acc);
      }
      // Add program id as unsigned readonly
      addAccount(AccountMeta(pubkey: ix.programId, isSigner: false, isWritable: false));
    }

    final allKeys = [
      ...signedWritable,
      ...signedReadonly,
      ...unsignedWritable,
      ...unsignedReadonly,
    ];

    int findKeyIndex(Uint8List key) {
      for (var i = 0; i < allKeys.length; i++) {
        final a = allKeys[i];
        var match = true;
        for (var j = 0; j < 32; j++) {
          if (a[j] != key[j]) {
            match = false;
            break;
          }
        }
        if (match) return i;
      }
      throw StateError('Key not found in accountKeys: ${Base58.encode(key)}');
    }

    final compiledIxs = <CompiledInstruction>[];
    for (final ix in instructions) {
      final pIndex = findKeyIndex(ix.programId);
      final accIndices = ix.accounts.map((a) => findKeyIndex(a.pubkey)).toList();
      compiledIxs.add(CompiledInstruction(
        programIdIndex: pIndex,
        accountIndices: accIndices,
        data: ix.data,
      ));
    }

    final header = MessageHeader(
      numRequiredSignatures: signedWritable.length + signedReadonly.length,
      numReadonlySignedAccounts: signedReadonly.length,
      numReadonlyUnsignedAccounts: unsignedReadonly.length,
    );

    return SolanaMessage(
      header: header,
      accountKeys: allKeys,
      recentBlockhash: recentBlockhash,
      instructions: compiledIxs,
    );
  }

  /// Serializes message to raw bytes for signing and network transport.
  Uint8List serialize() {
    final bb = BytesBuilder();
    // 1. Header (3 bytes)
    bb.add(header.toBytes());

    // 2. Account keys (CompactU16 length + 32-byte keys)
    bb.add(CompactU16.encode(accountKeys.length));
    for (final k in accountKeys) {
      bb.add(k);
    }

    // 3. Recent blockhash (32 bytes)
    bb.add(recentBlockhash);

    // 4. Instructions (CompactU16 length + compiled instructions)
    bb.add(CompactU16.encode(instructions.length));
    for (final ix in instructions) {
      bb.addByte(ix.programIdIndex);
      bb.add(CompactU16.encode(ix.accountIndices.length));
      for (final idx in ix.accountIndices) {
        bb.addByte(idx);
      }
      bb.add(CompactU16.encode(ix.data.length));
      bb.add(ix.data);
    }

    return bb.toBytes();
  }

  /// Deserializes a message from wire [bytes].
  factory SolanaMessage.deserialize(Uint8List bytes) {
    if (bytes.length < 3) {
      throw const FormatException('Solana message too short for header');
    }
    if ((bytes[0] & 0x80) != 0) {
      throw UnsupportedError(
        'Solana Versioned Message (v${bytes[0] & 0x7f}) is not supported for SEC-01 verification',
      );
    }

    var offset = 0;
    // Header
    final header = MessageHeader.fromBytes(bytes, offset: offset);
    offset += 3;

    // Account keys
    final (numAccounts, accSize) = CompactU16.decode(bytes, offset: offset);
    offset += accSize;
    if (bytes.length - offset < numAccounts * 32) {
      throw const FormatException('Solana message truncated in accountKeys');
    }
    final keys = <Uint8List>[];
    for (var i = 0; i < numAccounts; i++) {
      keys.add(Uint8List.fromList(bytes.sublist(offset, offset + 32)));
      offset += 32;
    }

    if (header.numRequiredSignatures <= 0 ||
        header.numRequiredSignatures > keys.length ||
        header.numReadonlySignedAccounts > header.numRequiredSignatures ||
        header.numRequiredSignatures + header.numReadonlyUnsignedAccounts > keys.length) {
      throw const FormatException('Invalid Solana MessageHeader account counts');
    }

    // Recent blockhash
    if (bytes.length - offset < 32) {
      throw const FormatException('Solana message truncated in recentBlockhash');
    }
    final blockhash = Uint8List.fromList(bytes.sublist(offset, offset + 32));
    offset += 32;

    // Instructions
    final (numIxs, ixSize) = CompactU16.decode(bytes, offset: offset);
    offset += ixSize;
    final ixs = <CompiledInstruction>[];
    for (var i = 0; i < numIxs; i++) {
      if (offset >= bytes.length) {
        throw const FormatException('Solana message truncated in instruction programIdIndex');
      }
      final progIdx = bytes[offset++];
      final (numAccIdxs, accIdxSize) = CompactU16.decode(bytes, offset: offset);
      offset += accIdxSize;
      if (bytes.length - offset < numAccIdxs) {
        throw const FormatException('Solana message truncated in instruction accountIndices');
      }
      final accIndices = <int>[];
      for (var j = 0; j < numAccIdxs; j++) {
        accIndices.add(bytes[offset++]);
      }
      final (dataLen, dataLenSize) = CompactU16.decode(bytes, offset: offset);
      offset += dataLenSize;
      if (bytes.length - offset < dataLen) {
        throw const FormatException('Solana message truncated in instruction data');
      }
      final data = Uint8List.fromList(bytes.sublist(offset, offset + dataLen));
      offset += dataLen;

      ixs.add(CompiledInstruction(
        programIdIndex: progIdx,
        accountIndices: accIndices,
        data: data,
      ));
    }

    if (offset != bytes.length) {
      throw FormatException(
        'Trailing bytes in SolanaMessage: consumed $offset of ${bytes.length}',
      );
    }

    return SolanaMessage(
      header: header,
      accountKeys: keys,
      recentBlockhash: blockhash,
      instructions: ixs,
    );
  }
}

/// Solana full Transaction with signatures.
class SolanaTransaction {
  final List<Uint8List> signatures; // 64 bytes each
  final SolanaMessage message;

  const SolanaTransaction({
    required this.signatures,
    required this.message,
  });

  /// Serializes transaction to standard wire format.
  Uint8List serialize() {
    final bb = BytesBuilder();
    bb.add(CompactU16.encode(signatures.length));
    for (final sig in signatures) {
      bb.add(sig);
    }
    bb.add(message.serialize());
    return bb.toBytes();
  }

  /// Deserializes a transaction from standard wire [bytes].
  factory SolanaTransaction.deserialize(Uint8List bytes) {
    var offset = 0;
    final (numSigs, sigSize) = CompactU16.decode(bytes, offset: offset);
    offset += sigSize;

    final signatures = <Uint8List>[];
    for (var i = 0; i < numSigs; i++) {
      signatures.add(Uint8List.fromList(bytes.sublist(offset, offset + 64)));
      offset += 64;
    }

    final messageBytes = Uint8List.sublistView(bytes, offset);
    final message = SolanaMessage.deserialize(messageBytes);

    return SolanaTransaction(
      signatures: signatures,
      message: message,
    );
  }
}

/// Standard System Program instructions builder.
class SystemProgram {
  static final Uint8List programId = Uint8List(32); // All zeros = 11111111111111111111111111111111
  static const String programIdBase58 = '11111111111111111111111111111111';

  const SystemProgram._();

  /// Creates a SOL transfer instruction.
  static SolanaInstruction transfer({
    required Uint8List fromPubkey,
    required Uint8List toPubkey,
    required BigInt lamports,
  }) {
    // Instruction 2 = Transfer (4 bytes u32 LE: 0x02, 0x00, 0x00, 0x00) + (8 bytes u64 LE lamports)
    final data = Uint8List(12);
    data[0] = 0x02;
    data[1] = 0x00;
    data[2] = 0x00;
    data[3] = 0x00;

    var val = lamports;
    for (var i = 0; i < 8; i++) {
      data[4 + i] = (val & BigInt.from(0xff)).toInt();
      val >>= 8;
    }

    return SolanaInstruction(
      programId: programId,
      accounts: [
        AccountMeta(pubkey: fromPubkey, isSigner: true, isWritable: true),
        AccountMeta(pubkey: toPubkey, isSigner: false, isWritable: true),
      ],
      data: data,
    );
  }
}
