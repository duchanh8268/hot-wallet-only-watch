import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import '../crypto/bytes.dart';

/// 64-bit Xoshiro256** PRNG using BigInt for identical behavior across Dart VM, Android, and Web JS/WASM.
class Xoshiro256StarStar {
  static final BigInt _mask64 = (BigInt.one << 64) - BigInt.one;
  final List<BigInt> _s;

  Xoshiro256StarStar(List<BigInt> seed) : _s = List<BigInt>.from(seed) {
    if (_s.length != 4) {
      throw ArgumentError('Xoshiro256** requires 4 64-bit state words');
    }
  }

  /// Initializes state from an arbitrary byte [seed] (32 bytes used directly; otherwise hashed via SHA-256).
  factory Xoshiro256StarStar.fromBytes(Uint8List seed) {
    final digest = seed.length == 32 ? seed : Uint8List.fromList(sha256.convert(seed).bytes);
    final words = <BigInt>[];
    for (var i = 0; i < 4; i++) {
      var w = BigInt.zero;
      for (var b = 0; b < 8; b++) {
        w = (w << 8) | BigInt.from(digest[i * 8 + b]);
      }
      words.add(w);
    }
    return Xoshiro256StarStar(words);
  }

  /// Seeds per BC-UR fountain spec: `SHA256(uint32_be(seqNum) || uint32_be(checksum))`.
  factory Xoshiro256StarStar.forFountain(int seqNum, int checksum) {
    final seedInput = concatBytes([uint32ToBe(seqNum), uint32ToBe(checksum)]);
    return Xoshiro256StarStar.fromBytes(seedInput);
  }

  static BigInt _rotl(BigInt x, int k) {
    return ((x << k) | (x >> (64 - k))) & _mask64;
  }

  /// Generates the next unsigned 64-bit integer as [BigInt].
  BigInt nextUint64() {
    final result = (_rotl((_s[1] * BigInt.from(5)) & _mask64, 7) * BigInt.from(9)) & _mask64;
    final t = (_s[1] << 17) & _mask64;

    _s[2] ^= _s[0];
    _s[3] ^= _s[1];
    _s[1] ^= _s[2];
    _s[0] ^= _s[3];

    _s[2] ^= t;
    _s[3] = _rotl(_s[3], 45);

    return result;
  }

  /// Generates a uniform floating-point number in `[0.0, 1.0)`.
  double nextDouble() {
    // Use top 53 bits for IEEE-754 double precision
    final top53 = (nextUint64() >> 11).toInt();
    return top53 / 9007199254740992.0; // 2^53
  }

  /// Generates a uniform integer in `[low, high]`.
  int nextIntRange(int low, int high) {
    final span = high - low + 1;
    return low + (nextDouble() * span).floor();
  }
}
