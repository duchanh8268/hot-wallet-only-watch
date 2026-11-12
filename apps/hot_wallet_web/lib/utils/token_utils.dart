import 'dart:convert';

import 'package:cardano_core/cardano_core.dart';

import '../services/blockfrost_service.dart';

/// Inserts `,` thousand separators into an unsigned integer digit string.
String _groupThousands(String digits) {
  if (digits.length <= 3) return digits;
  final buf = StringBuffer();
  final firstLen = digits.length % 3;
  var idx = firstLen == 0 ? 3 : firstLen;
  buf.write(digits.substring(0, idx));
  while (idx < digits.length) {
    buf.write(',');
    buf.write(digits.substring(idx, idx + 3));
    idx += 3;
  }
  return buf.toString();
}

/// Formats atomic token units into a decimal display string using [decimals].
/// When [includeGrouping] is true, adds `,` thousand separators to the integer part.
String formatTokenAmount(
  BigInt rawQty,
  int decimals, {
  bool includeGrouping = true,
}) {
  final negative = rawQty < BigInt.zero;
  final absVal = negative ? -rawQty : rawQty;
  final sign = negative ? '-' : '';
  if (decimals <= 0) {
    final intStr = absVal.toString();
    return '$sign${includeGrouping ? _groupThousands(intStr) : intStr}';
  }
  final scale = BigInt.from(10).pow(decimals);
  final whole = absVal ~/ scale;
  final wholeStr = includeGrouping ? _groupThousands(whole.toString()) : whole.toString();
  final frac = (absVal % scale).toString().padLeft(decimals, '0');
  final trimmed = frac.replaceFirst(RegExp(r'0+$'), '');
  return trimmed.isEmpty ? '$sign$wholeStr' : '$sign$wholeStr.$trimmed';
}

/// Parses a human-readable token amount string into atomic units using [decimals].
BigInt parseTokenAmount(String text, int decimals) {
  final clean = text.trim().replaceAll(',', '');
  if (clean.isEmpty) {
    throw const FormatException('Empty token quantity');
  }
  if (clean.startsWith('-')) {
    throw const FormatException('Token quantity cannot be negative');
  }

  final parts = clean.split('.');
  if (parts.length > 2) {
    throw const FormatException('Invalid token quantity format');
  }

  if (decimals <= 0) {
    if (parts.length == 2 && parts[1].replaceAll('0', '').isNotEmpty) {
      throw const FormatException('This token does not support decimal places');
    }
    final whole = BigInt.tryParse(parts[0]);
    if (whole == null) {
      throw const FormatException('Invalid integer token quantity');
    }
    return whole;
  }

  final wholePart = parts[0].isEmpty ? '0' : parts[0];
  final whole = BigInt.tryParse(wholePart);
  if (whole == null) {
    throw const FormatException('Invalid token quantity');
  }
  final fracPart = parts.length == 2 ? parts[1] : '';
  if (fracPart.length > decimals) {
    throw FormatException('Max $decimals decimal places for this token');
  }
  if (fracPart.isNotEmpty && !RegExp(r'^\d+$').hasMatch(fracPart)) {
    throw const FormatException('Invalid decimal digits');
  }

  final paddedFrac = fracPart.padRight(decimals, '0');
  final scale = BigInt.from(10).pow(decimals);
  return whole * scale + (paddedFrac.isEmpty ? BigInt.zero : BigInt.parse(paddedFrac));
}

/// Attempts to decode a CIP-67/CIP-68 prefixed asset name (4-byte header + UTF-8 name),
/// falling back to [AssetKey.displayName].
String resolveAssetDisplayName(AssetKey key, AssetMetadataInfo? meta) {
  final metaName = meta?.name?.trim();
  if (metaName != null && metaName.isNotEmpty) {
    return metaName;
  }
  // CIP-67 label prefixes: (100)=000643b0, (222)=000de140, (333)=0014df10, (444)=001bc280
  final hex = key.assetNameHex.toLowerCase();
  if (hex.length > 8 &&
      (hex.startsWith('000643b0') ||
          hex.startsWith('000de140') ||
          hex.startsWith('0014df10') ||
          hex.startsWith('001bc280'))) {
    final suffixBytes = hexDecode(hex.substring(8));
    try {
      final decoded = utf8.decode(suffixBytes, allowMalformed: false);
      final isPrintable = decoded.runes.every((r) => r >= 32 && r <= 126);
      if (isPrintable && decoded.isNotEmpty) {
        return decoded;
      }
    } catch (_) {}
  }
  return key.displayName;
}

/// Short ticker or display name for compact badges/UTXO summaries.
String resolveAssetSymbol(AssetKey key, AssetMetadataInfo? meta) {
  final ticker = meta?.ticker?.trim();
  if (ticker != null && ticker.isNotEmpty) {
    return ticker;
  }
  return resolveAssetDisplayName(key, meta);
}

/// Heuristic to distinguish NFTs from fungible tokens in the wallet UI.
bool isAssetNft(BigInt quantity, AssetMetadataInfo? meta) {
  return quantity == BigInt.one && (meta?.decimals ?? 0) == 0;
}
