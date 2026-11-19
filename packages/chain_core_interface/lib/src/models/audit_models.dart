import 'dart:typed_data';
import 'chain_id.dart';
import 'chain_network.dart';

/// Generic payload for an Air-Gap transaction signing request.
class GenericSignRequest {
  final String urType;
  final Uint8List requestId; // 16 bytes UUID
  final ChainId chainId;
  final ChainNetwork network;
  final Uint8List rawPayload;
  final Map<String, dynamic> metadata;

  const GenericSignRequest({
    required this.urType,
    required this.requestId,
    required this.chainId,
    required this.network,
    required this.rawPayload,
    this.metadata = const {},
  });
}

/// Generic payload for an Air-Gap transaction signing response.
class GenericSignResponse {
  final String urType;
  final Uint8List requestId;
  final ChainId chainId;
  final Uint8List rawSignatureData;

  const GenericSignResponse({
    required this.urType,
    required this.requestId,
    required this.chainId,
    required this.rawSignatureData,
  });
}

/// Verdict returned by SEC-01 audit inspection on Cold Wallet.
class AuditVerdict {
  final bool isApproved;
  final String? rejectReason;
  final List<String> warnings;
  final String recipientAddress;
  final String amountDisplay;
  final String feeDisplay;
  final String networkDisplay;
  final bool isHighRiskContractCall;
  final Map<String, String> extraDetails;

  const AuditVerdict({
    required this.isApproved,
    this.rejectReason,
    this.warnings = const [],
    required this.recipientAddress,
    required this.amountDisplay,
    required this.feeDisplay,
    required this.networkDisplay,
    this.isHighRiskContractCall = false,
    this.extraDetails = const {},
  });

  factory AuditVerdict.rejected(String reason) => AuditVerdict(
        isApproved: false,
        rejectReason: reason,
        recipientAddress: 'N/A',
        amountDisplay: '0',
        feeDisplay: '0',
        networkDisplay: 'Unknown',
      );
}
