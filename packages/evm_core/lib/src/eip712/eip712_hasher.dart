import 'dart:convert';
import 'dart:typed_data';
import '../crypto/bytes_utils.dart';
import '../crypto/keccak256.dart';
import 'eip712_types.dart';

/// Implements standard EIP-712 hashing (v4).
class Eip712Hasher {
  const Eip712Hasher._();

  /// Computes final 32-byte signing hash:
  /// keccak256("\x19\x01" || domainSeparator || hashStruct(primaryType, message))
  static Uint8List hashTypedData(Eip712TypedData typedData) {
    final domainSep = hashDomain(typedData);
    final structHash = hashStruct(
      primaryType: typedData.primaryType,
      data: typedData.message,
      types: typedData.types,
    );

    final payload = concatBytes([
      Uint8List.fromList([0x19, 0x01]),
      domainSep,
      structHash,
    ]);

    return Keccak256.hash(payload);
  }

  /// Computes domain separator hash for [typedData].
  static Uint8List hashDomain(Eip712TypedData typedData) {
    const domainTypeName = 'EIP712Domain';
    final domainTypes = typedData.types[domainTypeName] ?? _inferDomainTypes(typedData.domain);
    final domainData = typedData.domain.toMap();

    final allTypes = Map<String, List<Eip712TypeProperty>>.from(typedData.types);
    allTypes[domainTypeName] = domainTypes;

    return hashStruct(
      primaryType: domainTypeName,
      data: domainData,
      types: allTypes,
    );
  }

  /// Computes hashStruct: keccak256(typeHash || encodeData(primaryType, data))
  static Uint8List hashStruct({
    required String primaryType,
    required Map<String, dynamic> data,
    required Map<String, List<Eip712TypeProperty>> types,
  }) {
    final typeHashBytes = hashType(primaryType, types);
    final encodedData = encodeData(primaryType, data, types);
    return Keccak256.hash(concatBytes([typeHashBytes, encodedData]));
  }

  /// Computes typeHash: keccak256(encodeType(primaryType))
  static Uint8List hashType(
    String primaryType,
    Map<String, List<Eip712TypeProperty>> types,
  ) {
    final encodedType = encodeType(primaryType, types);
    return Keccak256.hash(utf8.encode(encodedType));
  }

  /// Formats type representation with referenced types sorted alphabetically.
  static String encodeType(
    String primaryType,
    Map<String, List<Eip712TypeProperty>> types,
  ) {
    final props = types[primaryType];
    if (props == null) {
      throw ArgumentError('Type not defined in EIP-712 types: $primaryType');
    }

    final deps = _findDependencies(primaryType, types)..remove(primaryType);
    final sortedDeps = deps.toList()..sort();

    final sb = StringBuffer();
    sb.write('$primaryType(${props.map((p) => '${p.type} ${p.name}').join(',')})');
    for (final dep in sortedDeps) {
      final depProps = types[dep]!;
      sb.write('$dep(${depProps.map((p) => '${p.type} ${p.name}').join(',')})');
    }

    return sb.toString();
  }

  /// Encodes data fields into concatenated 32-byte words.
  static Uint8List encodeData(
    String primaryType,
    Map<String, dynamic> data,
    Map<String, List<Eip712TypeProperty>> types,
  ) {
    final props = types[primaryType];
    if (props == null) {
      throw ArgumentError('Type not defined: $primaryType');
    }

    final chunks = <Uint8List>[];
    for (final prop in props) {
      final val = data[prop.name];
      chunks.add(_encodeField(prop.type, val, types));
    }

    return concatBytes(chunks);
  }

  static Uint8List _encodeField(
    String type,
    dynamic val,
    Map<String, List<Eip712TypeProperty>> types,
  ) {
    if (types.containsKey(type)) {
      // Sub-struct
      if (val is! Map<String, dynamic>) {
        throw ArgumentError('Expected Map for struct type $type, got ${val.runtimeType}');
      }
      return hashStruct(primaryType: type, data: val, types: types);
    }

    if (type.endsWith(']')) {
      // Array type
      final itemType = type.substring(0, type.lastIndexOf('['));
      final list = val as List;
      final encodedItems = list.map((item) => _encodeField(itemType, item, types)).toList();
      return Keccak256.hash(concatBytes(encodedItems));
    }

    if (type == 'string') {
      final str = val as String? ?? '';
      return Keccak256.hash(utf8.encode(str));
    }

    if (type == 'bytes') {
      final bytes = val is List<int>
          ? Uint8List.fromList(val)
          : hexDecode(val as String? ?? '');
      return Keccak256.hash(bytes);
    }

    if (type == 'bool') {
      final b = val == true;
      return _bigIntTo32(b ? BigInt.one : BigInt.zero);
    }

    if (type == 'address') {
      final addrHex = val as String? ?? '';
      final rawBytes = hexDecode(addrHex);
      final padded = Uint8List(32);
      padded.setRange(32 - rawBytes.length, 32, rawBytes);
      return padded;
    }

    if (type.startsWith('uint') || type.startsWith('int')) {
      BigInt numVal;
      if (val is BigInt) {
        numVal = val;
      } else if (val is int) {
        numVal = BigInt.from(val);
      } else if (val is String) {
        if (val.startsWith('0x') || val.startsWith('0X')) {
          numVal = BigInt.parse(val.substring(2), radix: 16);
        } else {
          numVal = BigInt.parse(val);
        }
      } else {
        numVal = BigInt.zero;
      }
      return _bigIntTo32(numVal);
    }

    if (type.startsWith('bytes')) {
      // Fixed-length bytes (bytes1..bytes32)
      final bytes = val is List<int>
          ? Uint8List.fromList(val)
          : hexDecode(val as String? ?? '');
      final padded = Uint8List(32);
      padded.setRange(0, bytes.length, bytes);
      return padded;
    }

    throw ArgumentError('Unsupported EIP-712 type: $type');
  }

  static Set<String> _findDependencies(
    String primaryType,
    Map<String, List<Eip712TypeProperty>> types, [
    Set<String>? visited,
  ]) {
    final result = visited ?? <String>{};
    if (result.contains(primaryType)) return result;
    result.add(primaryType);

    final props = types[primaryType];
    if (props != null) {
      for (final p in props) {
        var baseType = p.type;
        while (baseType.endsWith(']')) {
          baseType = baseType.substring(0, baseType.lastIndexOf('['));
        }
        if (types.containsKey(baseType)) {
          _findDependencies(baseType, types, result);
        }
      }
    }
    return result;
  }

  static List<Eip712TypeProperty> _inferDomainTypes(Eip712Domain domain) {
    final list = <Eip712TypeProperty>[];
    if (domain.name != null) list.add(const Eip712TypeProperty(name: 'name', type: 'string'));
    if (domain.version != null) list.add(const Eip712TypeProperty(name: 'version', type: 'string'));
    if (domain.chainId != null) list.add(const Eip712TypeProperty(name: 'chainId', type: 'uint256'));
    if (domain.verifyingContract != null) {
      list.add(const Eip712TypeProperty(name: 'verifyingContract', type: 'address'));
    }
    if (domain.salt != null) list.add(const Eip712TypeProperty(name: 'salt', type: 'bytes32'));
    return list;
  }

  static Uint8List _bigIntTo32(BigInt val) {
    final out = Uint8List(32);
    var v = val;
    for (var i = 31; i >= 0; i--) {
      out[i] = (v & BigInt.from(0xff)).toInt();
      v = v >> 8;
    }
    return out;
  }
}
