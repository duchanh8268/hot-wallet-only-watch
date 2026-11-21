import 'dart:convert';
import 'dart:typed_data';
import 'package:chain_core_interface/chain_core_interface.dart'
    show hexEncode;
import '../bcs/bcs.dart';
import '../crypto/blake2b_256.dart';

/// ObjectRef in Sui: (objectId, version, digest).
class SuiObjectRef {
  final String objectId; // 32 bytes hex
  final BigInt version;
  final String digest; // 32 bytes base58 or hex (internally 32 bytes)

  const SuiObjectRef({
    required this.objectId,
    required this.version,
    required this.digest,
  });

  void writeBcs(BcsWriter writer) {
    writer.writeAddress(objectId);
    writer.writeU64(version);
    // Digest is 32 bytes
    final cleanDigest = digest.trim();
    if (cleanDigest.length == 64 || cleanDigest.startsWith('0x')) {
      writer.writeAddress(cleanDigest);
    } else {
      // Treat as raw bytes or base58 if needed, default 32 zeros if empty
      final bytes = Uint8List(32);
      final raw = utf8.encode(cleanDigest);
      for (int i = 0; i < 32 && i < raw.length; i++) {
        bytes[i] = raw[i];
      }
      writer.writeFixedBytes(bytes);
    }
  }

  factory SuiObjectRef.readBcs(BcsReader reader) {
    final objId = reader.readAddress();
    final ver = reader.readU64();
    final digBytes = reader.readFixedBytes(32);
    return SuiObjectRef(
      objectId: objId,
      version: ver,
      digest: hexEncode(digBytes, prefix0x: true),
    );
  }
}

/// Call argument to a Programmable Transaction.
abstract class SuiCallArg {
  void writeBcs(BcsWriter writer);

  static SuiCallArg readBcs(BcsReader reader) {
    final variant = reader.readUleb128();
    if (variant == 0) {
      final bytes = reader.readBytes();
      return SuiPureCallArg(bytes);
    } else if (variant == 1) {
      final objVariant = reader.readUleb128();
      if (objVariant == 0) {
        final ref = SuiObjectRef.readBcs(reader);
        return SuiObjectArg(ref);
      } else {
        throw UnsupportedError('SharedObject hoặc Receiving chưa hỗ trợ');
      }
    }
    throw FormatException('Loại CallArg không hợp lệ: $variant');
  }
}

class SuiPureCallArg extends SuiCallArg {
  final Uint8List bytes;
  SuiPureCallArg(this.bytes);

  factory SuiPureCallArg.u64(BigInt value) {
    final w = BcsWriter()..writeU64(value);
    return SuiPureCallArg(w.toBytes());
  }

  factory SuiPureCallArg.address(String address) {
    final w = BcsWriter()..writeAddress(address);
    return SuiPureCallArg(w.toBytes());
  }

  @override
  void writeBcs(BcsWriter writer) {
    writer.writeUleb128(0); // Pure variant = 0
    writer.writeBytes(bytes);
  }
}

class SuiObjectArg extends SuiCallArg {
  final SuiObjectRef objectRef;
  SuiObjectArg(this.objectRef);

  @override
  void writeBcs(BcsWriter writer) {
    writer.writeUleb128(1); // Object variant = 1
    writer.writeUleb128(0); // ImmOrOwnedObject = 0
    objectRef.writeBcs(writer);
  }
}

/// Argument referencing inputs or command outputs in a PTB.
abstract class SuiArgument {
  const SuiArgument();
  void writeBcs(BcsWriter writer);

  static SuiArgument readBcs(BcsReader reader) {
    final tag = reader.readUleb128();
    switch (tag) {
      case 0:
        return const SuiGasCoinArgument();
      case 1:
        return SuiInputArgument(reader.readU16());
      case 2:
        return SuiResultArgument(reader.readU16());
      case 3:
        return SuiNestedResultArgument(reader.readU16(), reader.readU16());
      default:
        throw FormatException('Argument tag không hợp lệ: $tag');
    }
  }
}

class SuiGasCoinArgument extends SuiArgument {
  const SuiGasCoinArgument();
  @override
  void writeBcs(BcsWriter writer) {
    writer.writeUleb128(0); // GasCoin = 0
  }
}

class SuiInputArgument extends SuiArgument {
  final int index;
  const SuiInputArgument(this.index);
  @override
  void writeBcs(BcsWriter writer) {
    writer.writeUleb128(1); // Input = 1
    writer.writeU16(index);
  }
}

class SuiResultArgument extends SuiArgument {
  final int index;
  const SuiResultArgument(this.index);
  @override
  void writeBcs(BcsWriter writer) {
    writer.writeUleb128(2); // Result = 2
    writer.writeU16(index);
  }
}

class SuiNestedResultArgument extends SuiArgument {
  final int commandIndex;
  final int resultIndex;
  const SuiNestedResultArgument(this.commandIndex, this.resultIndex);
  @override
  void writeBcs(BcsWriter writer) {
    writer.writeUleb128(3); // NestedResult = 3
    writer.writeU16(commandIndex);
    writer.writeU16(resultIndex);
  }
}

/// Commands executed within a Programmable Transaction.
abstract class SuiCommand {
  void writeBcs(BcsWriter writer);

  static SuiCommand readBcs(BcsReader reader) {
    final variant = reader.readUleb128();
    switch (variant) {
      case 1: // TransferObjects
        final count = reader.readUleb128();
        final objects = <SuiArgument>[];
        for (int i = 0; i < count; i++) {
          objects.add(SuiArgument.readBcs(reader));
        }
        final recipient = SuiArgument.readBcs(reader);
        return SuiTransferObjectsCommand(objects: objects, recipient: recipient);
      case 2: // SplitCoins
        final coin = SuiArgument.readBcs(reader);
        final amtCount = reader.readUleb128();
        final amounts = <SuiArgument>[];
        for (int i = 0; i < amtCount; i++) {
          amounts.add(SuiArgument.readBcs(reader));
        }
        return SuiSplitCoinsCommand(coin: coin, amounts: amounts);
      case 3: // MergeCoins
        final destination = SuiArgument.readBcs(reader);
        final srcCount = reader.readUleb128();
        final sources = <SuiArgument>[];
        for (int i = 0; i < srcCount; i++) {
          sources.add(SuiArgument.readBcs(reader));
        }
        return SuiMergeCoinsCommand(destination: destination, sources: sources);
      default:
        throw UnsupportedError(
          'Lệnh Sui PTB tag $variant không được hỗ trợ để đảm bảo kiểm toán BCS chính xác (Fail-Closed)',
        );
    }
  }
}

class SuiSplitCoinsCommand extends SuiCommand {
  final SuiArgument coin;
  final List<SuiArgument> amounts;

  SuiSplitCoinsCommand({required this.coin, required this.amounts});

  @override
  void writeBcs(BcsWriter writer) {
    writer.writeUleb128(2); // SplitCoins = 2
    coin.writeBcs(writer);
    writer.writeUleb128(amounts.length);
    for (final amt in amounts) {
      amt.writeBcs(writer);
    }
  }
}

class SuiTransferObjectsCommand extends SuiCommand {
  final List<SuiArgument> objects;
  final SuiArgument recipient;

  SuiTransferObjectsCommand({required this.objects, required this.recipient});

  @override
  void writeBcs(BcsWriter writer) {
    writer.writeUleb128(1); // TransferObjects = 1
    writer.writeUleb128(objects.length);
    for (final obj in objects) {
      obj.writeBcs(writer);
    }
    recipient.writeBcs(writer);
  }
}

class SuiMergeCoinsCommand extends SuiCommand {
  final SuiArgument destination;
  final List<SuiArgument> sources;

  SuiMergeCoinsCommand({required this.destination, required this.sources});

  @override
  void writeBcs(BcsWriter writer) {
    writer.writeUleb128(3); // MergeCoins = 3
    destination.writeBcs(writer);
    writer.writeUleb128(sources.length);
    for (final src in sources) {
      src.writeBcs(writer);
    }
  }
}

class SuiUnknownCommand extends SuiCommand {
  final int tag;
  SuiUnknownCommand(this.tag);
  @override
  void writeBcs(BcsWriter writer) {
    throw UnsupportedError('Không thể serialize UnknownCommand tag $tag');
  }
}

/// Gas Data in Sui Transaction.
class SuiGasData {
  final List<SuiObjectRef> payment;
  final String owner;
  final BigInt price;
  final BigInt budget;

  const SuiGasData({
    required this.payment,
    required this.owner,
    required this.price,
    required this.budget,
  });

  void writeBcs(BcsWriter writer) {
    writer.writeUleb128(payment.length);
    for (final ref in payment) {
      ref.writeBcs(writer);
    }
    writer.writeAddress(owner);
    writer.writeU64(price);
    writer.writeU64(budget);
  }

  factory SuiGasData.readBcs(BcsReader reader) {
    final count = reader.readUleb128();
    final payment = <SuiObjectRef>[];
    for (int i = 0; i < count; i++) {
      payment.add(SuiObjectRef.readBcs(reader));
    }
    final owner = reader.readAddress();
    final price = reader.readU64();
    final budget = reader.readU64();
    return SuiGasData(
      payment: payment,
      owner: owner,
      price: price,
      budget: budget,
    );
  }
}

/// Programmable Transaction payload.
class SuiProgrammableTransaction {
  final List<SuiCallArg> inputs;
  final List<SuiCommand> commands;

  const SuiProgrammableTransaction({
    required this.inputs,
    required this.commands,
  });

  void writeBcs(BcsWriter writer) {
    writer.writeUleb128(inputs.length);
    for (final inp in inputs) {
      inp.writeBcs(writer);
    }
    writer.writeUleb128(commands.length);
    for (final cmd in commands) {
      cmd.writeBcs(writer);
    }
  }

  factory SuiProgrammableTransaction.readBcs(BcsReader reader) {
    final inCount = reader.readUleb128();
    final inputs = <SuiCallArg>[];
    for (int i = 0; i < inCount; i++) {
      inputs.add(SuiCallArg.readBcs(reader));
    }
    final cmdCount = reader.readUleb128();
    final commands = <SuiCommand>[];
    for (int i = 0; i < cmdCount; i++) {
      commands.add(SuiCommand.readBcs(reader));
    }
    return SuiProgrammableTransaction(inputs: inputs, commands: commands);
  }
}

/// TransactionDataV1 for modern Sui transactions.
class SuiTransactionDataV1 {
  final SuiProgrammableTransaction ptb;
  final String sender;
  final SuiGasData gasData;
  /// Expiration: 0 = None, 1 = Epoch
  final int expirationTag;
  final BigInt? expirationEpoch;

  const SuiTransactionDataV1({
    required this.ptb,
    required this.sender,
    required this.gasData,
    this.expirationTag = 0,
    this.expirationEpoch,
  });

  void writeBcs(BcsWriter writer) {
    // Kind variant 0 = ProgrammableTransaction
    writer.writeUleb128(0);
    ptb.writeBcs(writer);

    writer.writeAddress(sender);
    gasData.writeBcs(writer);

    writer.writeUleb128(expirationTag);
    if (expirationTag == 1 && expirationEpoch != null) {
      writer.writeU64(expirationEpoch!);
    }
  }

  factory SuiTransactionDataV1.readBcs(BcsReader reader) {
    final kindVariant = reader.readUleb128();
    if (kindVariant != 0) {
      throw UnsupportedError('Chỉ hỗ trợ ProgrammableTransaction (kind 0)');
    }
    final ptb = SuiProgrammableTransaction.readBcs(reader);
    final sender = reader.readAddress();
    final gasData = SuiGasData.readBcs(reader);
    final expTag = reader.readUleb128();
    BigInt? epoch;
    if (expTag == 1) {
      epoch = reader.readU64();
    } else if (expTag != 0) {
      throw FormatException('TransactionExpiration tag không hợp lệ: $expTag');
    }
    return SuiTransactionDataV1(
      ptb: ptb,
      sender: sender,
      gasData: gasData,
      expirationTag: expTag,
      expirationEpoch: epoch,
    );
  }
}

/// Complete TransactionData envelope with V1 variant (tag 0).
class SuiTransactionData {
  final SuiTransactionDataV1 v1;

  const SuiTransactionData({required this.v1});

  Uint8List toBcs() {
    final writer = BcsWriter();
    writer.writeUleb128(0); // V1 variant = 0
    v1.writeBcs(writer);
    return writer.toBytes();
  }

  factory SuiTransactionData.fromBcs(Uint8List bytes) {
    final reader = BcsReader(bytes);
    final variant = reader.readUleb128();
    if (variant != 0) {
      throw UnsupportedError('Chỉ hỗ trợ Sui TransactionData V1 (variant 0)');
    }
    final v1 = SuiTransactionDataV1.readBcs(reader);
    if (reader.remaining != 0) {
      throw FormatException(
        'Phát hiện ${reader.remaining} trailing bytes không hợp lệ trong SuiTransactionData BCS',
      );
    }
    return SuiTransactionData(v1: v1);
  }

  /// Creates an Intent message for this transaction data:
  /// `[0, 0, 0]` (TransactionData, V0, Sui) || BCS(TransactionData).
  Uint8List toIntentMessage() {
    final bcsBytes = toBcs();
    final intent = Uint8List(3 + bcsBytes.length);
    intent[0] = 0; // IntentScope::TransactionData
    intent[1] = 0; // IntentVersion::V0
    intent[2] = 0; // AppId::Sui
    intent.setRange(3, intent.length, bcsBytes);
    return intent;
  }

  /// Calculates the Blake2b-256 digest of the intent message.
  Uint8List getDigest() {
    return blake2b256(toIntentMessage());
  }

  /// Helper to build a standard SUI Coin transfer PTB.
  static SuiTransactionData createTransfer({
    required String sender,
    required String recipient,
    required BigInt amountMIST,
    required List<SuiObjectRef> gasPayment,
    required BigInt gasBudget,
    BigInt? gasPrice,
  }) {
    // Inputs:
    // 0: Pure(amountMIST)
    // 1: Pure(recipient)
    final inputs = <SuiCallArg>[
      SuiPureCallArg.u64(amountMIST),
      SuiPureCallArg.address(recipient),
    ];

    // Commands:
    // Command 0: SplitCoins(GasCoin, [Input(0)])
    // Command 1: TransferObjects([Result(0)], Input(1))
    final commands = <SuiCommand>[
      SuiSplitCoinsCommand(
        coin: const SuiGasCoinArgument(),
        amounts: [const SuiInputArgument(0)],
      ),
      SuiTransferObjectsCommand(
        objects: [const SuiResultArgument(0)],
        recipient: const SuiInputArgument(1),
      ),
    ];

    final ptb = SuiProgrammableTransaction(
      inputs: inputs,
      commands: commands,
    );

    final gasData = SuiGasData(
      payment: gasPayment,
      owner: sender,
      price: gasPrice ?? BigInt.from(1000),
      budget: gasBudget,
    );

    final v1 = SuiTransactionDataV1(
      ptb: ptb,
      sender: sender,
      gasData: gasData,
    );

    return SuiTransactionData(v1: v1);
  }
}
