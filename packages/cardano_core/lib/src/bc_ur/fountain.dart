import 'dart:math' as math;
import 'dart:typed_data';

import '../conway/cbor.dart';
import 'crc32.dart';
import 'xoshiro256.dart';

/// Single BC-UR Fountain Code packet `[seqNum, seqLen, messageLen, checksum, data]`.
class FountainPart {
  final int seqNum;
  final int seqLen;
  final int messageLen;
  final int checksum;
  final Uint8List data;

  FountainPart({
    required this.seqNum,
    required this.seqLen,
    required this.messageLen,
    required this.checksum,
    required Uint8List data,
  }) : data = Uint8List.fromList(data);

  Uint8List toCborBytes() {
    return CborArray([
      CborInt.fromInt(seqNum),
      CborInt.fromInt(seqLen),
      CborInt.fromInt(messageLen),
      CborInt.fromInt(checksum),
      CborBytes(data),
    ]).encode();
  }

  factory FountainPart.fromCborBytes(Uint8List bytes) {
    final decoded = CborValue.decode(bytes);
    if (decoded is! CborArray || decoded.items.length != 5) {
      throw const FormatException('Invalid BC-UR FountainPart CBOR');
    }
    final seqNum = decoded.items[0];
    final seqLen = decoded.items[1];
    final msgLen = decoded.items[2];
    final checksum = decoded.items[3];
    final data = decoded.items[4];
    if (seqNum is! CborInt ||
        seqLen is! CborInt ||
        msgLen is! CborInt ||
        checksum is! CborInt ||
        data is! CborBytes) {
      throw const FormatException('Invalid BC-UR FountainPart field types');
    }
    return FountainPart(
      seqNum: seqNum.toInt(),
      seqLen: seqLen.toInt(),
      messageLen: msgLen.toInt(),
      checksum: checksum.toInt(),
      data: data.bytes,
    );
  }
}

/// BC-UR Luby Transform fragment selection (BCR-2020-005).
class FountainUtils {
  static Set<int> chooseFragments(int seqNum, int seqLen, int checksum) {
    if (seqNum <= seqLen) {
      return {seqNum - 1};
    }
    final rng = Xoshiro256StarStar.forFountain(seqNum, checksum);
    final degree = _chooseDegree(seqLen, rng);
    final indexes = List<int>.generate(seqLen, (i) => i);
    final shuffled = _shuffle(indexes, rng);
    return shuffled.take(degree).toSet();
  }

  /// Robust Soliton / BC-UR inverse-degree sampler (`1/k` harmonic distribution).
  static int _chooseDegree(int seqLen, Xoshiro256StarStar rng) {
    final weights = List<double>.generate(seqLen, (i) => 1.0 / (i + 1));
    final total = weights.reduce((a, b) => a + b);
    final probs = [for (final w in weights) w / total];

    // Vose Alias Method (matches Blockchain Commons RandomSampler)
    final n = seqLen;
    final p = List<double>.filled(n, 0);
    final a = List<int>.filled(n, 0);
    final small = <int>[];
    final large = <int>[];
    final scaled = [for (final pr in probs) pr * n];

    for (var i = n - 1; i >= 0; i--) {
      if (scaled[i] < 1.0) {
        small.add(i);
      } else {
        large.add(i);
      }
    }

    while (small.isNotEmpty && large.isNotEmpty) {
      final s = small.removeLast();
      final l = large.removeLast();
      p[s] = scaled[s];
      a[s] = l;
      scaled[l] = (scaled[l] + scaled[s]) - 1.0;
      if (scaled[l] < 1.0) {
        small.add(l);
      } else {
        large.add(l);
      }
    }

    while (large.isNotEmpty) {
      p[large.removeLast()] = 1.0;
    }
    while (small.isNotEmpty) {
      p[small.removeLast()] = 1.0;
    }

    final r1 = rng.nextDouble();
    final r2 = rng.nextDouble();
    final i = (n * r1).floor().clamp(0, n - 1);
    final chosenZeroBased = r2 < p[i] ? i : a[i];
    return chosenZeroBased + 1;
  }

  static List<int> _shuffle(List<int> items, Xoshiro256StarStar rng) {
    final remaining = List<int>.from(items);
    final result = <int>[];
    while (remaining.isNotEmpty) {
      final idx = rng.nextIntRange(0, remaining.length - 1);
      result.add(remaining.removeAt(idx));
    }
    return result;
  }

  static Uint8List xorBytes(Uint8List a, Uint8List b) {
    final len = math.min(a.length, b.length);
    final out = Uint8List(len);
    for (var i = 0; i < len; i++) {
      out[i] = a[i] ^ b[i];
    }
    return out;
  }
}

/// Rateless Fountain Encoder producing infinite sequence parts.
class FountainEncoder {
  final int messageLen;
  final int checksum;
  final int fragmentLen;
  final List<Uint8List> _fragments;
  int _seqNum = 0;

  FountainEncoder(
    Uint8List message, {
    int maxFragmentLen = 90,
    int minFragmentLen = 10,
  })  : messageLen = message.length,
        checksum = Crc32.compute(message),
        fragmentLen = _findNominalFragmentLength(
          message.length,
          minFragmentLen,
          maxFragmentLen,
        ),
        _fragments = [] {
    final count = (message.length / fragmentLen).ceil().clamp(1, 1 << 30);
    for (var i = 0; i < count; i++) {
      final start = i * fragmentLen;
      final end = math.min(start + fragmentLen, message.length);
      final chunk = Uint8List(fragmentLen);
      if (start < end) {
        chunk.setRange(0, end - start, message, start);
      }
      _fragments.add(chunk);
    }
  }

  int get seqLen => _fragments.length;
  int get seqNum => _seqNum;
  bool get isSinglePart => seqLen == 1;
  bool get isComplete => _seqNum >= seqLen;

  static int _findNominalFragmentLength(
    int messageLen,
    int minFragmentLen,
    int maxFragmentLen,
  ) {
    if (messageLen <= maxFragmentLen) {
      return math.max(1, messageLen);
    }
    final maxCount = (messageLen / minFragmentLen).ceil();
    var fragmentCount = 1;
    var fragmentLen = maxFragmentLen;
    while (fragmentCount <= maxCount) {
      final candidate = (messageLen / fragmentCount).ceil();
      if (candidate <= maxFragmentLen) {
        fragmentLen = math.max(minFragmentLen, candidate);
        break;
      }
      fragmentCount++;
    }
    return fragmentLen;
  }

  FountainPart nextPart() {
    _seqNum++;
    final indexes = FountainUtils.chooseFragments(_seqNum, seqLen, checksum);
    var combined = Uint8List(fragmentLen);
    for (final idx in indexes) {
      combined = FountainUtils.xorBytes(combined, _fragments[idx]);
    }
    return FountainPart(
      seqNum: _seqNum,
      seqLen: seqLen,
      messageLen: messageLen,
      checksum: checksum,
      data: combined,
    );
  }
}

class _MixedPart {
  final Set<int> indexes;
  Uint8List data;

  _MixedPart(this.indexes, this.data);
}

/// Fountain Decoder supporting out-of-order, partial, and lossy packet streams.
class FountainDecoder {
  static const int maxAllowedSeqLen = 2048;
  static const int maxAllowedMessageLen = 262144; // 256 KB
  static const int maxAllowedFragmentLen = 4096;
  static const int maxMixedParts = 512;

  int? _expectedSeqLen;
  int? _expectedMessageLen;
  int? _expectedChecksum;
  int? _expectedFragmentLen;

  final Map<int, Uint8List> _simpleParts = {};
  final List<_MixedPart> _mixedParts = [];
  final Set<int> _processedPartSeqs = {};
  Uint8List? _result;

  bool get isComplete => _result != null;
  Uint8List? get result => _result;
  int? get expectedPartCount => _expectedSeqLen;
  int get receivedPartCount => _processedPartSeqs.length;
  Set<int> get receivedIndexes => Set.unmodifiable(_simpleParts.keys);

  double get estimatedProgress {
    if (_result != null) return 1.0;
    final total = _expectedSeqLen;
    if (total == null || total == 0) return 0.0;
    // Blend solved chunks + mixed knowledge
    final solved = _simpleParts.length;
    final mixedBonus = math.min(
      (total - solved) * 0.7,
      _mixedParts.length * 0.5,
    );
    return ((solved + mixedBonus) / total).clamp(0.0, 0.99);
  }

  /// Processes an incoming [part]. Returns true if valid and accepted.
  bool receivePart(FountainPart part) {
    if (_result != null) return true;

    if (part.seqLen <= 0 ||
        part.seqLen > maxAllowedSeqLen ||
        part.messageLen < 0 ||
        part.messageLen > maxAllowedMessageLen ||
        part.data.isEmpty ||
        part.data.length > maxAllowedFragmentLen) {
      return false;
    }

    if (_expectedSeqLen == null) {
      _expectedSeqLen = part.seqLen;
      _expectedMessageLen = part.messageLen;
      _expectedChecksum = part.checksum;
      _expectedFragmentLen = part.data.length;
    } else {
      if (part.seqLen != _expectedSeqLen ||
          part.messageLen != _expectedMessageLen ||
          part.checksum != _expectedChecksum ||
          part.data.length != _expectedFragmentLen) {
        return false;
      }
    }

    if (!_processedPartSeqs.add(part.seqNum)) {
      return true; // Already seen this sequence number
    }

    final indexes = FountainUtils.chooseFragments(
      part.seqNum,
      part.seqLen,
      part.checksum,
    );

    final reduced = _reducePart(_MixedPart(indexes, Uint8List.fromList(part.data)));
    if (reduced.indexes.isEmpty) {
      return true; // Redundant
    }

    if (reduced.indexes.length == 1) {
      final idx = reduced.indexes.first;
      _enqueueSolved(idx, reduced.data);
    } else if (_mixedParts.length < maxMixedParts) {
      _mixedParts.add(reduced);
      _tryGaussianSolve();
    } else {
      return false;
    }

    _checkCompletion();
    return true;
  }

  _MixedPart _reducePart(_MixedPart part) {
    final remainingIndexes = Set<int>.from(part.indexes);
    var data = Uint8List.fromList(part.data);
    for (final idx in part.indexes) {
      final known = _simpleParts[idx];
      if (known != null) {
        remainingIndexes.remove(idx);
        data = FountainUtils.xorBytes(data, known);
      }
    }
    return _MixedPart(remainingIndexes, data);
  }

  void _enqueueSolved(int firstIdx, Uint8List firstData) {
    final queue = <(int, Uint8List)>[(firstIdx, firstData)];
    while (queue.isNotEmpty) {
      final (idx, data) = queue.removeAt(0);
      if (_simpleParts.containsKey(idx)) continue;
      _simpleParts[idx] = data;

      var i = 0;
      while (i < _mixedParts.length) {
        final mp = _mixedParts[i];
        if (mp.indexes.remove(idx)) {
          mp.data = FountainUtils.xorBytes(mp.data, data);
          if (mp.indexes.isEmpty) {
            _mixedParts.removeAt(i);
            continue;
          }
          if (mp.indexes.length == 1) {
            final solvedIdx = mp.indexes.first;
            final solvedData = mp.data;
            _mixedParts.removeAt(i);
            queue.add((solvedIdx, solvedData));
            continue;
          }
        }
        i++;
      }
    }
  }

  /// GF(2) Gaussian elimination fallback when enough mixed equations accumulate.
  void _tryGaussianSolve() {
    final seqLen = _expectedSeqLen!;
    final missing = <int>[
      for (var i = 0; i < seqLen; i++)
        if (!_simpleParts.containsKey(i)) i,
    ];
    if (missing.isEmpty || _mixedParts.length < missing.length) {
      return;
    }

    final colMap = {for (var c = 0; c < missing.length; c++) missing[c]: c};
    final rows = <_MixedPart>[
      for (final mp in _mixedParts)
        _MixedPart(Set<int>.from(mp.indexes), Uint8List.fromList(mp.data)),
    ];

    var pivotRow = 0;
    for (final colIdx in missing) {
      var found = -1;
      for (var r = pivotRow; r < rows.length; r++) {
        if (rows[r].indexes.contains(colIdx)) {
          found = r;
          break;
        }
      }
      if (found == -1) continue;

      final tmp = rows[pivotRow];
      rows[pivotRow] = rows[found];
      rows[found] = tmp;

      final pivot = rows[pivotRow];
      for (var r = 0; r < rows.length; r++) {
        if (r == pivotRow) continue;
        if (rows[r].indexes.contains(colIdx)) {
          for (final pIdx in pivot.indexes) {
            if (!rows[r].indexes.add(pIdx)) {
              rows[r].indexes.remove(pIdx);
            }
          }
          rows[r].data = FountainUtils.xorBytes(rows[r].data, pivot.data);
        }
      }
      pivotRow++;
      if (pivotRow == colMap.length) break;
    }

    for (final row in rows) {
      if (row.indexes.length == 1) {
        _enqueueSolved(row.indexes.first, row.data);
      }
    }
  }

  void _checkCompletion() {
    final seqLen = _expectedSeqLen;
    final msgLen = _expectedMessageLen;
    final expectedCrc = _expectedChecksum;
    if (seqLen == null || msgLen == null || expectedCrc == null) return;
    if (_simpleParts.length < seqLen) return;

    final builder = BytesBuilder(copy: false);
    for (var i = 0; i < seqLen; i++) {
      builder.add(_simpleParts[i]!);
    }
    final padded = builder.toBytes();
    if (padded.length < msgLen) {
      throw const FormatException('Reconstructed fountain payload shorter than expected');
    }
    final assembled = Uint8List.sublistView(padded, 0, msgLen);
    if (Crc32.compute(assembled) != expectedCrc) {
      throw const FormatException('Fountain reconstructed message CRC-32 mismatch');
    }
    _result = Uint8List.fromList(assembled);
  }
}
