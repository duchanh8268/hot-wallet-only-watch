import 'dart:typed_data';
import 'package:chain_core_interface/chain_core_interface.dart' show hexDecode, hexEncode;
import '../address/bech32_segwit.dart';

/// Represents a Bitcoin UTXO OutPoint (32-byte transaction ID and output index).
class OutPoint {
  final String txid; // 64-hex character string (display order, big-endian)
  final int vout;

  const OutPoint({
    required this.txid,
    required this.vout,
  });

  /// Serializes OutPoint to 36 bytes wire format: 32 bytes little-endian txid + 4 bytes uint32 little-endian vout.
  Uint8List toBytes() {
    final rawTxid = hexDecode(txid);
    if (rawTxid.length != 32) {
      throw ArgumentError('OutPoint txid must be 32 bytes (64 hex chars), got ${rawTxid.length}');
    }
    if (vout < 0 || vout > 0xffffffff) {
      throw ArgumentError('OutPoint vout out of uint32 range: $vout');
    }
    final bytes = Uint8List(36);
    // Bitcoin wire format stores txid in reverse (little-endian) byte order
    for (var i = 0; i < 32; i++) {
      bytes[i] = rawTxid[31 - i];
    }
    bytes[32] = vout & 0xff;
    bytes[33] = (vout >> 8) & 0xff;
    bytes[34] = (vout >> 16) & 0xff;
    bytes[35] = (vout >> 24) & 0xff;
    return bytes;
  }

  factory OutPoint.fromBytes(Uint8List bytes, {int offset = 0}) {
    if (bytes.length - offset < 36) {
      throw const FormatException('OutPoint requires 36 bytes');
    }
    final rawReversed = bytes.sublist(offset, offset + 32);
    final txidBytes = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      txidBytes[i] = rawReversed[31 - i];
    }
    final vout = bytes[offset + 32] |
        (bytes[offset + 33] << 8) |
        (bytes[offset + 34] << 16) |
        (bytes[offset + 35] << 24);

    return OutPoint(
      txid: hexEncode(txidBytes),
      vout: vout,
    );
  }

  Map<String, dynamic> toJson() => {'txid': txid, 'vout': vout};

  factory OutPoint.fromJson(Map<String, dynamic> json) => OutPoint(
        txid: json['txid'] as String,
        vout: (json['vout'] as num).toInt(),
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OutPoint && other.txid == txid && other.vout == vout;

  @override
  int get hashCode => Object.hash(txid, vout);
}

/// Witness stack for an input.
class BtcWitness {
  final List<Uint8List> items;

  const BtcWitness([this.items = const []]);

  bool get isEmpty => items.isEmpty;
  bool get isNotEmpty => items.isNotEmpty;

  Map<String, dynamic> toJson() => {
        'items': items.map((e) => hexEncode(e)).toList(),
      };

  factory BtcWitness.fromJson(Map<String, dynamic> json) {
    final list = json['items'] as List<dynamic>? ?? [];
    return BtcWitness(list.map((e) => hexDecode(e as String)).toList());
  }
}

/// A Bitcoin transaction input.
class BtcTxIn {
  final OutPoint previousOutput;
  final Uint8List scriptSig;
  final int sequence;
  BtcWitness witness;

  // Optional contextual metadata used for SegWit signing & Cold Wallet verification
  final BigInt? amountSat;
  final int? accountIndex;
  final int? change; // 0 for external receive, 1 for internal change
  final int? addressIndex;
  final Uint8List? nonWitnessUtxo;

  BtcTxIn({
    required this.previousOutput,
    Uint8List? scriptSig,
    this.sequence = 0xfffffffd, // Default RBF enabled
    this.witness = const BtcWitness(),
    this.amountSat,
    this.accountIndex,
    this.change,
    this.addressIndex,
    Uint8List? nonWitnessUtxo,
  })  : scriptSig = scriptSig ?? Uint8List(0),
        nonWitnessUtxo =
            nonWitnessUtxo != null ? Uint8List.fromList(nonWitnessUtxo) : null;

  Map<String, dynamic> toJson() => {
        'previousOutput': previousOutput.toJson(),
        'scriptSig': hexEncode(scriptSig),
        'sequence': sequence,
        'witness': witness.toJson(),
        if (amountSat != null) 'amountSat': amountSat.toString(),
        if (accountIndex != null) 'accountIndex': accountIndex,
        if (change != null) 'change': change,
        if (addressIndex != null) 'addressIndex': addressIndex,
        if (nonWitnessUtxo != null) 'nonWitnessUtxo': hexEncode(nonWitnessUtxo!),
      };

  factory BtcTxIn.fromJson(Map<String, dynamic> json) => BtcTxIn(
        previousOutput: OutPoint.fromJson(json['previousOutput'] as Map<String, dynamic>),
        scriptSig: hexDecode(json['scriptSig'] as String? ?? ''),
        sequence: (json['sequence'] as num?)?.toInt() ?? 0xfffffffd,
        witness: json['witness'] != null
            ? BtcWitness.fromJson(json['witness'] as Map<String, dynamic>)
            : const BtcWitness(),
        amountSat: json['amountSat'] != null ? BigInt.parse(json['amountSat'] as String) : null,
        accountIndex: (json['accountIndex'] as num?)?.toInt(),
        change: (json['change'] as num?)?.toInt(),
        addressIndex: (json['addressIndex'] as num?)?.toInt(),
        nonWitnessUtxo: json['nonWitnessUtxo'] != null
            ? hexDecode(json['nonWitnessUtxo'] as String)
            : null,
      );
}

/// A Bitcoin transaction output.
class BtcTxOut {
  final BigInt valueSat;
  final Uint8List scriptPubKey;

  // Optional metadata to mark change output for Cold Wallet verification
  final bool isChange;
  final int? changeIndex;

  const BtcTxOut({
    required this.valueSat,
    required this.scriptPubKey,
    this.isChange = false,
    this.changeIndex,
  });

  /// Constructs a P2WPKH output: OP_0 (0x00) OP_PUSHBYTES_20 (0x14) <20-byte program>.
  factory BtcTxOut.p2wpkh({
    required BigInt valueSat,
    required Uint8List program20,
    bool isChange = false,
    int? changeIndex,
  }) {
    if (program20.length != 20) {
      throw ArgumentError('P2WPKH program must be 20 bytes');
    }
    final script = Uint8List(22);
    script[0] = 0x00; // OP_0
    script[1] = 0x14; // Push 20 bytes
    script.setRange(2, 22, program20);
    return BtcTxOut(
      valueSat: valueSat,
      scriptPubKey: script,
      isChange: isChange,
      changeIndex: changeIndex,
    );
  }

  /// Constructs a SegWit output from a Bech32 Native SegWit address.
  factory BtcTxOut.fromAddress({
    required BigInt valueSat,
    required String address,
    bool isChange = false,
    int? changeIndex,
  }) {
    final decoded = Bech32Segwit.decode(address);
    if (decoded.witnessVersion == 0 && decoded.program.length == 20) {
      return BtcTxOut.p2wpkh(
        valueSat: valueSat,
        program20: decoded.program,
        isChange: isChange,
        changeIndex: changeIndex,
      );
    }
    // Generic SegWit output script: OP_n (0x00 or 0x50+n) <push_len> <program>
    final vOp = decoded.witnessVersion == 0 ? 0x00 : (0x50 + decoded.witnessVersion);
    final script = Uint8List(2 + decoded.program.length);
    script[0] = vOp;
    script[1] = decoded.program.length;
    script.setRange(2, 2 + decoded.program.length, decoded.program);
    return BtcTxOut(
      valueSat: valueSat,
      scriptPubKey: script,
      isChange: isChange,
      changeIndex: changeIndex,
    );
  }

  Map<String, dynamic> toJson() => {
        'valueSat': valueSat.toString(),
        'scriptPubKey': hexEncode(scriptPubKey),
        'isChange': isChange,
        if (changeIndex != null) 'changeIndex': changeIndex,
      };

  factory BtcTxOut.fromJson(Map<String, dynamic> json) => BtcTxOut(
        valueSat: BigInt.parse(json['valueSat'] as String),
        scriptPubKey: hexDecode(json['scriptPubKey'] as String),
        isChange: json['isChange'] as bool? ?? false,
        changeIndex: (json['changeIndex'] as num?)?.toInt(),
      );
}

/// A Bitcoin transaction.
class BtcTransaction {
  final int version;
  final List<BtcTxIn> inputs;
  final List<BtcTxOut> outputs;
  final int lockTime;

  BtcTransaction({
    this.version = 2,
    required this.inputs,
    required this.outputs,
    this.lockTime = 0,
  });

  bool get hasWitness => inputs.any((i) => i.witness.isNotEmpty);

  Map<String, dynamic> toJson() => {
        'version': version,
        'inputs': inputs.map((e) => e.toJson()).toList(),
        'outputs': outputs.map((e) => e.toJson()).toList(),
        'lockTime': lockTime,
      };

  factory BtcTransaction.fromJson(Map<String, dynamic> json) => BtcTransaction(
        version: (json['version'] as num?)?.toInt() ?? 2,
        inputs: (json['inputs'] as List<dynamic>)
            .map((e) => BtcTxIn.fromJson(e as Map<String, dynamic>))
            .toList(),
        outputs: (json['outputs'] as List<dynamic>)
            .map((e) => BtcTxOut.fromJson(e as Map<String, dynamic>))
            .toList(),
        lockTime: (json['lockTime'] as num?)?.toInt() ?? 0,
      );
}
