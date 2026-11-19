import 'dart:convert';
import 'dart:typed_data';
import '../crypto/bytes_utils.dart';
import '../crypto/keccak256.dart';

/// EIP-55 Mixed-case checksum address encoder & validator.
class Eip55 {
  const Eip55._();

  /// Derives checksummed Ethereum address from 64-byte uncompressed public key.
  static String addressFromPublicKey64(Uint8List publicKey64) {
    if (publicKey64.length != 64) {
      throw ArgumentError('publicKey64 must be 64 bytes, got ${publicKey64.length}');
    }
    final hash = Keccak256.hash(publicKey64);
    final rawAddress = hash.sublist(12, 32);
    return formatChecksumAddress(rawAddress);
  }

  /// Formats 20-byte raw address into EIP-55 mixed-case checksummed string with '0x' prefix.
  static String formatChecksumAddress(List<int> addressBytes) {
    if (addressBytes.length != 20) {
      throw ArgumentError('Address must be 20 bytes, got ${addressBytes.length}');
    }
    final lowerHex = hexEncode(addressBytes, prefix0x: false).toLowerCase();
    return toChecksumAddress(lowerHex);
  }

  /// Converts a 40-character hex string (with or without 0x) into an EIP-55 checksummed string.
  static String toChecksumAddress(String hexAddress) {
    var clean = hexAddress.trim();
    if (clean.startsWith('0x') || clean.startsWith('0X')) {
      clean = clean.substring(2);
    }
    if (clean.length != 40) {
      throw ArgumentError('Address hex must be exactly 40 characters, got ${clean.length}');
    }
    final lower = clean.toLowerCase();
    final hash = Keccak256.hash(utf8.encode(lower));

    final sb = StringBuffer('0x');
    for (var i = 0; i < 40; i++) {
      final char = lower[i];
      final hashByte = hash[i >> 1];
      final hashNibble = (i & 1) == 0 ? (hashByte >> 4) & 0x0f : hashByte & 0x0f;

      if (hashNibble >= 8) {
        sb.write(char.toUpperCase());
      } else {
        sb.write(char);
      }
    }

    return sb.toString();
  }

  /// Validates whether [address] is a valid 40-hex string, and if mixed-case, checks EIP-55 checksum.
  static bool isValidAddress(String address) {
    final clean = address.trim();
    if (!RegExp(r'^(0x|0X)?[0-9a-fA-F]{40}$').hasMatch(clean)) {
      return false;
    }
    final stripped = clean.startsWith('0x') || clean.startsWith('0X')
        ? clean.substring(2)
        : clean;

    // All lowercase or all uppercase is technically allowed in raw form
    if (stripped == stripped.toLowerCase() || stripped == stripped.toUpperCase()) {
      return true;
    }

    // Mixed case must match EIP-55 checksum
    try {
      return toChecksumAddress(stripped) == '0x$stripped';
    } catch (_) {
      return false;
    }
  }
}
