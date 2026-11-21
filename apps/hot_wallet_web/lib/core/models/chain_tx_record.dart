/// Unified lightweight recent transaction record shared across multi-chain dashboards.
class ChainTxRecord {
  final String txHash;
  final int timestampMs;
  final String status; // 'confirmed', 'pending', 'failed'
  final String direction; // 'in', 'out', 'self', 'tx'
  final String summary;
  final String blockOrSlot;
  final String explorerUrl;

  const ChainTxRecord({
    required this.txHash,
    this.timestampMs = 0,
    this.status = 'confirmed',
    this.direction = 'tx',
    this.summary = '',
    this.blockOrSlot = '',
    this.explorerUrl = '',
  });

  ChainTxRecord copyWith({
    String? txHash,
    int? timestampMs,
    String? status,
    String? direction,
    String? summary,
    String? blockOrSlot,
    String? explorerUrl,
  }) {
    return ChainTxRecord(
      txHash: txHash ?? this.txHash,
      timestampMs: timestampMs ?? this.timestampMs,
      status: status ?? this.status,
      direction: direction ?? this.direction,
      summary: summary ?? this.summary,
      blockOrSlot: blockOrSlot ?? this.blockOrSlot,
      explorerUrl: explorerUrl ?? this.explorerUrl,
    );
  }

  Map<String, dynamic> toJson() => {
        'txHash': txHash,
        'timestampMs': timestampMs,
        'status': status,
        'direction': direction,
        'summary': summary,
        'blockOrSlot': blockOrSlot,
        'explorerUrl': explorerUrl,
      };

  factory ChainTxRecord.fromJson(Map<String, dynamic> json) => ChainTxRecord(
        txHash: json['txHash'] as String? ?? '',
        timestampMs: (json['timestampMs'] as num?)?.toInt() ?? 0,
        status: json['status'] as String? ?? 'confirmed',
        direction: json['direction'] as String? ?? 'tx',
        summary: json['summary'] as String? ?? '',
        blockOrSlot: json['blockOrSlot'] as String? ?? '',
        explorerUrl: json['explorerUrl'] as String? ?? '',
      );
}
