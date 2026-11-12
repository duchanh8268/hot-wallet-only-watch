import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'bip39_wordlist.dart';

export 'bip39_wordlist.dart' show bip39EnglishWordlist;

/// BIP-39 mnemonic & entropy codec supporting 12, 15, 18, 21, and 24 words.
class Bip39 {
  static final Map<String, int> _wordToIndex = {
    for (var i = 0; i < bip39EnglishWordlist.length; i++)
      bip39EnglishWordlist[i]: i,
  };

  /// Valid entropy byte lengths: 16 (12w), 20 (15w), 24 (18w), 28 (21w), 32 (24w).
  static const Set<int> validEntropyLengths = {16, 20, 24, 28, 32};

  /// Valid mnemonic word counts.
  static const Set<int> validWordCounts = {12, 15, 18, 21, 24};

  /// Converts [entropy] bytes into a space-separated BIP-39 mnemonic.
  static String entropyToMnemonic(Uint8List entropy) {
    if (!validEntropyLengths.contains(entropy.length)) {
      throw ArgumentError(
        'Invalid BIP-39 entropy length: ${entropy.length} bytes',
      );
    }

    final entBits = entropy.length * 8;
    final csBits = entBits ~/ 32;
    final hash = sha256.convert(entropy).bytes;
    final checksumByte = hash[0];

    final totalBits = entBits + csBits;
    final wordCount = totalBits ~/ 11;
    final words = <String>[];

    for (var w = 0; w < wordCount; w++) {
      var index = 0;
      for (var b = 0; b < 11; b++) {
        final bitPos = w * 11 + b;
        final bit = _readBit(entropy, checksumByte, entBits, bitPos);
        index = (index << 1) | bit;
      }
      words.add(bip39EnglishWordlist[index]);
    }

    return words.join(' ');
  }

  /// Validates and converts a BIP-39 [mnemonic] back into raw entropy bytes.
  /// Throws [FormatException] if words or checksum are invalid.
  static Uint8List mnemonicToEntropy(String mnemonic) {
    final words = splitWords(mnemonic);
    if (!validWordCounts.contains(words.length)) {
      throw FormatException(
        'Invalid BIP-39 word count: ${words.length}. Expected 12, 15, 18, 21, or 24.',
      );
    }

    final indices = List<int>.filled(words.length, 0);
    for (var i = 0; i < words.length; i++) {
      final idx = _wordToIndex[words[i]];
      if (idx == null) {
        throw FormatException('Unknown BIP-39 word at position ${i + 1}: "${words[i]}"');
      }
      indices[i] = idx;
    }

    final totalBits = words.length * 11;
    final csBits = totalBits ~/ 33;
    final entBits = totalBits - csBits;
    final entBytesLen = entBits ~/ 8;
    final entropy = Uint8List(entBytesLen);
    var extractedChecksum = 0;

    for (var w = 0; w < indices.length; w++) {
      final wordVal = indices[w];
      for (var b = 0; b < 11; b++) {
        final bitPos = w * 11 + b;
        final bit = (wordVal >> (10 - b)) & 1;
        if (bitPos < entBits) {
          if (bit == 1) {
            entropy[bitPos >> 3] |= 1 << (7 - (bitPos & 7));
          }
        } else {
          extractedChecksum = (extractedChecksum << 1) | bit;
        }
      }
    }

    final hash = sha256.convert(entropy).bytes;
    final expectedChecksum = hash[0] >> (8 - csBits);
    if (extractedChecksum != expectedChecksum) {
      entropy.fillRange(0, entropy.length, 0);
      throw const FormatException('Invalid BIP-39 mnemonic checksum');
    }

    return entropy;
  }

  /// Returns true if [mnemonic] has valid BIP-39 words, length, and checksum.
  static bool validateMnemonic(String mnemonic) {
    Uint8List? entropy;
    try {
      entropy = mnemonicToEntropy(mnemonic);
      return true;
    } catch (_) {
      return false;
    } finally {
      entropy?.fillRange(0, entropy.length, 0);
    }
  }

  /// Normalizes whitespace and lowercases a mnemonic into a list of words.
  static List<String> splitWords(String mnemonic) {
    final trimmed = mnemonic.trim().toLowerCase();
    if (trimmed.isEmpty) return const [];
    return trimmed.split(RegExp(r'\s+'));
  }

  /// Checks whether a single word exists in the BIP-39 English wordlist.
  static bool isValidWord(String word) =>
      _wordToIndex.containsKey(word.trim().toLowerCase());

  /// Returns matching BIP-39 wordlist suggestions for a prefix.
  static List<String> suggestions(String prefix, {int limit = 6}) {
    final p = prefix.trim().toLowerCase();
    if (p.isEmpty) return const [];
    final out = <String>[];
    for (final w in bip39EnglishWordlist) {
      if (w.startsWith(p)) {
        out.add(w);
        if (out.length >= limit) break;
      }
    }
    return out;
  }

  static int _readBit(
    Uint8List entropy,
    int checksumByte,
    int entBits,
    int bitPos,
  ) {
    if (bitPos < entBits) {
      return (entropy[bitPos >> 3] >> (7 - (bitPos & 7))) & 1;
    }
    final csPos = bitPos - entBits;
    return (checksumByte >> (7 - csPos)) & 1;
  }
}
