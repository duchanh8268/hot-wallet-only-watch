import 'dart:typed_data';
import '../models/chain_id.dart';
import '../models/chain_network.dart';
import '../models/account_models.dart';
import '../models/audit_models.dart';

/// Base plugin interface shared by all blockchain implementations.
abstract class IChainPlugin {
  ChainId get chainId;
  String get displayName;
  List<ChainNetwork> get supportedNetworks;
  ChainNetwork get defaultNetwork;

  /// Returns true if this plugin handles the specified BC-UR type string.
  bool canHandleUr(String urType);

  /// Derives public account information (address, account UR, etc.) from unlocked entropy.
  Future<PublicAccountDetails> derivePublicAccount({
    required Uint8List entropy,
    String passphrase = '',
    required ChainNetwork network,
    required int accountIndex,
    required int addressIndex,
    String? label,
  });
}

/// Interface for Cold Wallet plugins (offline signing & SEC-01 audit).
abstract class IColdChainPlugin extends IChainPlugin {
  /// Parses an incoming BC-UR string into a typed sign request.
  Future<GenericSignRequest> parseSignRequestUr(String urString);

  /// Audits the sign request against strict SEC-01 security rules.
  Future<AuditVerdict> auditSignRequest({
    required Uint8List entropy,
    String passphrase = '',
    required GenericSignRequest request,
    required int accountIndex,
    required int addressIndex,
  });

  /// Signs the verified transaction and generates the sign response UR payload.
  Future<GenericSignResponse> signTransaction({
    required Uint8List entropy,
    String passphrase = '',
    required GenericSignRequest request,
    required int accountIndex,
    required int addressIndex,
  });

  /// Encodes a sign response into an Animated BC-UR string or single UR.
  String encodeSignResponseUr(GenericSignResponse response);
}

/// Interface for Hot Wallet plugins (Watch-Only online balance sync & tx building).
abstract class IHotChainPlugin extends IChainPlugin {
  /// Initializes or updates custom RPC / API key settings for this chain.
  Future<void> configureEndpoint({required ChainNetwork network, String? customUrl, String? apiKey});

  /// Fetches the account balance and asset details for a public address.
  Future<Map<String, dynamic>> fetchAccountBalance({
    required ChainNetwork network,
    required String address,
  });

  /// Submits (broadcasts) the final signed transaction to the blockchain.
  Future<String> broadcastTransaction({
    required ChainNetwork network,
    required Uint8List signedTxBytes,
  });
}
