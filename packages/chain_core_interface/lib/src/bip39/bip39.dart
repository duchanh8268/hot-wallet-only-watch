import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart' as pc;
import 'bip39_wordlist.dart';

export 'bip39_wordlist.dart' show bip39EnglishWordlist;

/// Universal BIP-39 mnemonic, entropy, and seed generator.
class Bip39 {
  static final Map<String, int> _wordToIndex = {
    for (var i = 0; i < bip39EnglishWordlist.length; i++)
      bip39EnglishWordlist[i]: i,
  };

  static const Set<int> validEntropyLengths = {16, 20, 24, 28, 32};
  static const Set<int> validWordCounts = {12, 15, 18, 21, 24};

  /// Converts [entropy] bytes into a space-separated BIP-39 mnemonic.
  static String entropyToMnemonic(Uint8List entropy) {
    if (!validEntropyLengths.contains(entropy.length)) {
      throw ArgumentError('Invalid BIP-39 entropy length: ${entropy.length} bytes');
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

  /// Converts a space-separated [mnemonic] into raw entropy bytes.
  static Uint8List mnemonicToEntropy(String mnemonic) {
    final words = mnemonic.trim().split(RegExp(r'\s+'));
    if (!validWordCounts.contains(words.length)) {
      throw ArgumentError('Invalid BIP-39 word count: ${words.length}');
    }

    final totalBits = words.length * 11;
    final csBits = totalBits % 32 == 0 ? totalBits ~/ 33 : totalBits ~/ 32;
    final entBits = totalBits - csBits;
    final entBytes = entBits ~/ 8;

    final bitBuffer = <int>[];
    for (final word in words) {
      final index = _wordToIndex[word.toLowerCase()];
      if (index == null) {
        throw ArgumentError('Invalid BIP-39 word: $word');
      }
      for (var b = 10; b >= 0; b--) {
        bitBuffer.add((index >> b) & 1);
      }
    }

    final entropy = Uint8List(entBytes);
    for (var i = 0; i < entBits; i++) {
      if (bitBuffer[i] == 1) {
        entropy[i ~/ 8] |= 1 << (7 - (i % 8));
      }
    }

    final expectedHash = sha256.convert(entropy).bytes;
    final expectedCsByte = expectedHash[0];
    for (var i = 0; i < csBits; i++) {
      final actualBit = bitBuffer[entBits + i];
      final expectedBit = (expectedCsByte >> (7 - i)) & 1;
      if (actualBit != expectedBit) {
        throw const FormatException('BIP-39 checksum verification failed');
      }
    }

    return entropy;
  }

  /// Standard BIP-39: derives 64-byte (512-bit) seed via PBKDF2-HMAC-SHA512 (2048 iterations).
  static Uint8List mnemonicToSeed(String mnemonic, {String passphrase = ''}) {
    final passBytes = Uint8List.fromList(utf8.encode(mnemonic.trim()));
    final saltBytes = Uint8List.fromList(utf8.encode('mnemonic$passphrase'));
    final derivator = pc.PBKDF2KeyDerivator(pc.HMac(pc.SHA512Digest(), 128));
    derivator.init(pc.Pbkdf2Parameters(saltBytes, 2048, 64));
    return derivator.process(passBytes);
  }

  /// Derives 64-byte seed directly from [entropy] and optional [passphrase].
  static Uint8List entropyToSeed(Uint8List entropy, {String passphrase = ''}) {
    final mnemonic = entropyToMnemonic(entropy);
    return mnemonicToSeed(mnemonic, passphrase: passphrase);
  }

  static int _readBit(Uint8List entropy, int checksumByte, int entBits, int bitPos) {
    if (bitPos < entBits) {
      final byte = entropy[bitPos ~/ 8];
      final offset = 7 - (bitPos % 8);
      return (byte >> offset) & 1;
    } else {
      final csOffset = 7 - (bitPos - entBits);
      return (checksumByte >> csOffset) & 1;
    }
  }
}
