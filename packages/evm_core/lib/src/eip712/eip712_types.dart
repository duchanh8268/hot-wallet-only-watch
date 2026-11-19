import 'dart:convert';

/// Represents a single field definition in an EIP-712 struct.
class Eip712TypeProperty {
  final String name;
  final String type;

  const Eip712TypeProperty({required this.name, required this.type});

  Map<String, String> toJson() => {'name': name, 'type': type};

  factory Eip712TypeProperty.fromJson(Map<String, dynamic> json) =>
      Eip712TypeProperty(
        name: json['name'] as String,
        type: json['type'] as String,
      );
}

/// Domain separator definition for EIP-712.
class Eip712Domain {
  final String? name;
  final String? version;
  final int? chainId;
  final String? verifyingContract;
  final String? salt;

  const Eip712Domain({
    this.name,
    this.version,
    this.chainId,
    this.verifyingContract,
    this.salt,
  });

  Map<String, dynamic> toMap() {
    final m = <String, dynamic>{};
    if (name != null) m['name'] = name;
    if (version != null) m['version'] = version;
    if (chainId != null) m['chainId'] = chainId;
    if (verifyingContract != null) m['verifyingContract'] = verifyingContract;
    if (salt != null) m['salt'] = salt;
    return m;
  }

  Map<String, dynamic> toJson() => toMap();

  factory Eip712Domain.fromJson(Map<String, dynamic> json) {
    int? parsedChainId;
    if (json['chainId'] != null) {
      if (json['chainId'] is int) {
        parsedChainId = json['chainId'] as int;
      } else if (json['chainId'] is String) {
        parsedChainId = int.tryParse(json['chainId'] as String);
      }
    }
    return Eip712Domain(
      name: json['name'] as String?,
      version: json['version'] as String?,
      chainId: parsedChainId,
      verifyingContract: json['verifyingContract'] as String?,
      salt: json['salt'] as String?,
    );
  }
}

/// Full EIP-712 Typed Data container.
class Eip712TypedData {
  final Map<String, List<Eip712TypeProperty>> types;
  final String primaryType;
  final Eip712Domain domain;
  final Map<String, dynamic> message;

  const Eip712TypedData({
    required this.types,
    required this.primaryType,
    required this.domain,
    required this.message,
  });

  Map<String, dynamic> toJson() => {
        'types': types.map(
          (k, v) => MapEntry(k, v.map((p) => p.toJson()).toList()),
        ),
        'primaryType': primaryType,
        'domain': domain.toJson(),
        'message': message,
      };

  factory Eip712TypedData.fromJson(Map<String, dynamic> json) {
    final rawTypes = json['types'] as Map<String, dynamic>;
    final parsedTypes = <String, List<Eip712TypeProperty>>{};

    rawTypes.forEach((key, val) {
      if (val is List) {
        parsedTypes[key] = val
            .map((item) => Eip712TypeProperty.fromJson(item as Map<String, dynamic>))
            .toList();
      }
    });

    final rawDomain = json['domain'] as Map<String, dynamic>? ?? {};
    final parsedDomain = Eip712Domain.fromJson(rawDomain);

    return Eip712TypedData(
      types: parsedTypes,
      primaryType: json['primaryType'] as String? ?? '',
      domain: parsedDomain,
      message: (json['message'] as Map<String, dynamic>?) ?? {},
    );
  }

  factory Eip712TypedData.fromJsonString(String jsonStr) =>
      Eip712TypedData.fromJson(jsonDecode(jsonStr) as Map<String, dynamic>);
}
