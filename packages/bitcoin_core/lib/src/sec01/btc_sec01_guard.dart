import 'dart:typed_data';
import 'package:chain_core_interface/chain_core_interface.dart';
import '../address/bech32_segwit.dart';
import '../bc_ur/btc_ur_messages.dart';
import '../crypto/btc_account_pub.dart';
import '../crypto/btc_hd_key.dart';
import '../crypto/secp256k1_btc.dart';
import '../transaction/btc_models.dart';
import '../transaction/btc_serializer.dart';
import '../transaction/sighash_bip143.dart';

/// Session-scoped public-key cache for BIP-84 HD path auto-discovery (zero private keys).
class BtcHdDiscoveryCache {
  final Map<String, BtcAccountPublicKey> _accountPubs = {};
  final Map<String, Map<String, ({int change, int addressIndex})>> _pkhIndexMaps = {};
  final Map<String, int> _scannedUpTo = {};

  void clear() {
    _accountPubs.clear();
    _pkhIndexMaps.clear();
    _scannedUpTo.clear();
  }

  BtcAccountPublicKey getAccountPublicKey({
    required bool isTestnet,
    required int accountIndex,
    required BtcAccountPublicKey Function() derive,
  }) {
    final key = '${isTestnet ? 't' : 'm'}/$accountIndex';
    return _accountPubs[key] ??= derive();
  }

  ({int change, int addressIndex})? resolvePubKeyHash({
    required BtcAccountPublicKey acctPub,
    required bool isTestnet,
    required int accountIndex,
    required Uint8List pubKeyHash20,
    List<int> changes = const [0, 1],
    int maxScanIndex = 200,
  }) {
    final acctKey = '${isTestnet ? 't' : 'm'}/$accountIndex';
    final map = _pkhIndexMaps.putIfAbsent(acctKey, () => {});
    final targetHex = hexEncode(pubKeyHash20);
    final cached = map[targetHex];
    if (cached != null && changes.contains(cached.change)) {
      return cached;
    }

    for (final change in changes) {
      final branchKey = '$acctKey/$change';
      var nextIdx = (_scannedUpTo[branchKey] ?? -1) + 1;
      while (nextIdx <= maxScanIndex) {
        final pkhHex = acctPub.derivePubKeyHashHex(change, nextIdx);
        map.putIfAbsent(pkhHex, () => (change: change, addressIndex: nextIdx));
        _scannedUpTo[branchKey] = nextIdx;
        if (pkhHex == targetHex) {
          return (change: change, addressIndex: nextIdx);
        }
        nextIdx++;
      }
    }

    final postCached = map[targetHex];
    if (postCached != null && changes.contains(postCached.change)) {
      return postCached;
    }
    return null;
  }
}

class BtcResolvedInputPath {
  final int accountIndex;
  final int change;
  final int addressIndex;
  final BigInt verifiedSat;
  final bool wasAutoDiscovered;

  const BtcResolvedInputPath({
    required this.accountIndex,
    required this.change,
    required this.addressIndex,
    required this.verifiedSat,
    required this.wasAutoDiscovered,
  });

  String path(bool isTestnet) =>
      "m/84'/${isTestnet ? 1 : 0}'/$accountIndex'/$change/$addressIndex";
}

class BtcSec01AuditResult {
  final AuditVerdict verdict;
  final int resolvedAccountIndex;
  final List<BtcResolvedInputPath> resolvedInputs;
  final Map<int, int> resolvedChangeIndices;

  const BtcSec01AuditResult({
    required this.verdict,
    required this.resolvedAccountIndex,
    this.resolvedInputs = const [],
    this.resolvedChangeIndices = const {},
  });
}

/// Offline SEC-01 Security Audit Guard & Signer for Bitcoin Native SegWit transactions.
class BtcSec01Guard {
  const BtcSec01Guard._();

  static const int defaultMaxAddressScanIndex = 200;
  static final BigInt _maxMoneySat = BigInt.from(21000000) * BigInt.from(100000000);

  /// Audits an incoming [BtcSignRequestUr] against the unlocked [entropy],
  /// returning a full [BtcSec01AuditResult] with resolved HD paths.
  static BtcSec01AuditResult auditDetailed({
    required Uint8List entropy,
    String passphrase = '',
    required BtcSignRequestUr request,
    required int expectedAccountIndex,
    String? expectedNetwork,
    List<int>? candidateAccountIndices,
    int maxAddressScanIndex = defaultMaxAddressScanIndex,
    BtcHdDiscoveryCache? discoveryCache,
  }) {
    if (candidateAccountIndices == null && request.accountIndex != expectedAccountIndex) {
      return BtcSec01AuditResult(
        verdict: AuditVerdict.rejected(
          'AccountIndex trong yêu cầu (${request.accountIndex}) không khớp với ví đang mở ($expectedAccountIndex)',
        ),
        resolvedAccountIndex: expectedAccountIndex,
      );
    }

    if (expectedNetwork != null &&
        request.network.trim().toLowerCase() != expectedNetwork.trim().toLowerCase()) {
      return BtcSec01AuditResult(
        verdict: AuditVerdict.rejected(
          'Xung đột mạng lưới (Network Mismatch): Yêu cầu ký thuộc mạng "${request.network}" '
          'nhưng Ví Lạnh đang đặt ở mạng "$expectedNetwork".',
        ),
        resolvedAccountIndex: expectedAccountIndex,
      );
    }

    final isTestnet = request.network.toLowerCase().contains('test') ||
        request.network.toLowerCase().contains('signet');
    final hrp = isTestnet ? 'tb' : 'bc';

    final seed = Bip39.entropyToSeed(entropy, passphrase: passphrase);
    final master = BtcHdKey.fromSeed(seed);
    final cache = discoveryCache ?? BtcHdDiscoveryCache();

    try {
      final tx = request.transaction;
      if (tx.inputs.isEmpty) {
        return BtcSec01AuditResult(
          verdict: AuditVerdict.rejected('Giao dịch không có UTXO đầu vào (inputs empty)'),
          resolvedAccountIndex: expectedAccountIndex,
        );
      }
      if (tx.outputs.isEmpty) {
        return BtcSec01AuditResult(
          verdict: AuditVerdict.rejected('Giao dịch không có đầu ra (outputs empty)'),
          resolvedAccountIndex: expectedAccountIndex,
        );
      }

      // 1. Structural Input & BIP-143 nonWitnessUtxo verification
      var totalInputSat = BigInt.zero;
      final seenOutpoints = <String>{};
      final parsedInputs = <({BtcTxIn inp, Uint8List scriptPubKey, BigInt verifiedSat})>[];

      for (var i = 0; i < tx.inputs.length; i++) {
        final inp = tx.inputs[i];
        final Uint8List outpointBytes;
        try {
          outpointBytes = inp.previousOutput.toBytes();
        } catch (e) {
          return BtcSec01AuditResult(
            verdict: AuditVerdict.rejected('UTXO đầu vào #$i có OutPoint không hợp lệ: $e'),
            resolvedAccountIndex: expectedAccountIndex,
          );
        }
        final canonicalOutpoint = OutPoint.fromBytes(outpointBytes);
        final outpointKey = '${canonicalOutpoint.txid.toLowerCase()}:${canonicalOutpoint.vout}';
        if (!seenOutpoints.add(outpointKey)) {
          return BtcSec01AuditResult(
            verdict: AuditVerdict.rejected('Phát hiện UTXO đầu vào bị trùng lặp tại Input #$i ($outpointKey)'),
            resolvedAccountIndex: expectedAccountIndex,
          );
        }
        if (inp.scriptSig.isNotEmpty) {
          return BtcSec01AuditResult(
            verdict: AuditVerdict.rejected('Native SegWit Input #$i không được chứa scriptSig khác rỗng'),
            resolvedAccountIndex: expectedAccountIndex,
          );
        }

        final prevRaw = inp.nonWitnessUtxo;
        if (prevRaw == null || prevRaw.isEmpty) {
          return BtcSec01AuditResult(
            verdict: AuditVerdict.rejected(
              'UTXO đầu vào #$i thiếu dữ liệu giao dịch trước (nonWitnessUtxo) để xác thực giá trị BIP-143',
            ),
            resolvedAccountIndex: expectedAccountIndex,
          );
        }
        final ({int version, List<BtcTxOut> outputs, int lockTime, String txid}) prevTx;
        try {
          prevTx = BtcSerializer.parseRawTransaction(prevRaw);
        } catch (e) {
          return BtcSec01AuditResult(
            verdict: AuditVerdict.rejected('UTXO đầu vào #$i có nonWitnessUtxo không hợp lệ: $e'),
            resolvedAccountIndex: expectedAccountIndex,
          );
        }
        if (prevTx.txid.toLowerCase() != canonicalOutpoint.txid.toLowerCase()) {
          return BtcSec01AuditResult(
            verdict: AuditVerdict.rejected(
              'CẢNH BÁO AN NINH: Hash của nonWitnessUtxo (${prevTx.txid}) không khớp với TxID đầu vào #$i (${canonicalOutpoint.txid})',
            ),
            resolvedAccountIndex: expectedAccountIndex,
          );
        }
        if (canonicalOutpoint.vout < 0 || canonicalOutpoint.vout >= prevTx.outputs.length) {
          return BtcSec01AuditResult(
            verdict: AuditVerdict.rejected(
              'UTXO đầu vào #$i có vout=${canonicalOutpoint.vout} vượt quá số đầu ra của nonWitnessUtxo (${prevTx.outputs.length})',
            ),
            resolvedAccountIndex: expectedAccountIndex,
          );
        }

        final verifiedPrevOut = prevTx.outputs[canonicalOutpoint.vout];
        final verifiedSat = verifiedPrevOut.valueSat;
        if (verifiedSat <= BigInt.zero || verifiedSat > _maxMoneySat) {
          return BtcSec01AuditResult(
            verdict: AuditVerdict.rejected('UTXO đầu vào #$i có giá trị satoshi thực tế không hợp lệ ($verifiedSat)'),
            resolvedAccountIndex: expectedAccountIndex,
          );
        }
        if (inp.amountSat != null && inp.amountSat! != verifiedSat) {
          return BtcSec01AuditResult(
            verdict: AuditVerdict.rejected(
              'CẢNH BÁO AN NINH BIP-143: Giá trị khai báo (${inp.amountSat} sats) ở UTXO #$i '
              'không khớp với giao dịch gốc ($verifiedSat sats)!',
            ),
            resolvedAccountIndex: expectedAccountIndex,
          );
        }

        if (verifiedPrevOut.scriptPubKey.length != 22 ||
            verifiedPrevOut.scriptPubKey[0] != 0x00 ||
            verifiedPrevOut.scriptPubKey[1] != 0x14) {
          return BtcSec01AuditResult(
            verdict: AuditVerdict.rejected(
              'UTXO đầu vào #$i không phải chuẩn P2WPKH Native SegWit',
            ),
            resolvedAccountIndex: expectedAccountIndex,
          );
        }

        if (inp.change != null && inp.change != 0 && inp.change != 1) {
          return BtcSec01AuditResult(
            verdict: AuditVerdict.rejected('UTXO #$i có giá trị chain (change=${inp.change}) không hợp lệ (chỉ nhận 0 hoặc 1)'),
            resolvedAccountIndex: expectedAccountIndex,
          );
        }
        if (inp.addressIndex != null && (inp.addressIndex! < 0 || inp.addressIndex! >= 0x80000000)) {
          return BtcSec01AuditResult(
            verdict: AuditVerdict.rejected('UTXO #$i có addressIndex (${inp.addressIndex}) không hợp lệ'),
            resolvedAccountIndex: expectedAccountIndex,
          );
        }

        totalInputSat += verifiedSat;
        parsedInputs.add((
          inp: inp,
          scriptPubKey: verifiedPrevOut.scriptPubKey,
          verifiedSat: verifiedSat,
        ));
      }

      // 2. Output structural & Fee sanity checks (account-independent)
      var totalOutputSat = BigInt.zero;
      for (var i = 0; i < tx.outputs.length; i++) {
        final out = tx.outputs[i];
        if (out.valueSat <= BigInt.zero || out.valueSat > _maxMoneySat) {
          return BtcSec01AuditResult(
            verdict: AuditVerdict.rejected(
              'Output #$i có giá trị satoshi không hợp lệ (${out.valueSat} sats). Chặn 0-satoshi / số âm.',
            ),
            resolvedAccountIndex: expectedAccountIndex,
          );
        }
        if (out.isChange &&
            out.changeIndex != null &&
            (out.changeIndex! < 0 || out.changeIndex! >= 0x80000000)) {
          return BtcSec01AuditResult(
            verdict: AuditVerdict.rejected('Change Output #$i sai changeIndex (${out.changeIndex})'),
            resolvedAccountIndex: expectedAccountIndex,
          );
        }
        totalOutputSat += out.valueSat;
      }

      final feeSat = totalInputSat - totalOutputSat;
      if (feeSat < BigInt.zero) {
        return BtcSec01AuditResult(
          verdict: AuditVerdict.rejected('Tổng giá trị đầu ra vượt quá đầu vào (âm phí)'),
          resolvedAccountIndex: expectedAccountIndex,
        );
      }
      if (feeSat != request.feeSat) {
        return BtcSec01AuditResult(
          verdict: AuditVerdict.rejected(
            'Phí giao dịch tính toán ($feeSat sats) không khớp với phí khai báo trong UR (${request.feeSat} sats)',
          ),
          resolvedAccountIndex: expectedAccountIndex,
        );
      }

      // 3. Resolve Account & HD Paths (Hybrid: Hinted or Auto-Discovered across change 0 & 1)
      final candidates = _buildCandidateAccounts(
        expectedAccountIndex: expectedAccountIndex,
        requestAccountIndex: request.accountIndex,
        candidateAccountIndices: candidateAccountIndices,
      );

      BtcSec01AuditResult? firstRejection;
      for (final acctIdx in candidates) {
        final acctPub = cache.getAccountPublicKey(
          isTestnet: isTestnet,
          accountIndex: acctIdx,
          derive: () => master.exportBip84AccountPublicKey(
            accountIndex: acctIdx,
            isTestnet: isTestnet,
          ),
        );

        final attempt = _verifyForAccount(
          request: request,
          tx: tx,
          parsedInputs: parsedInputs,
          acctPub: acctPub,
          acctIdx: acctIdx,
          expectedAccountIndex: expectedAccountIndex,
          strictInputAccount: candidateAccountIndices == null,
          isTestnet: isTestnet,
          hrp: hrp,
          totalInputSat: totalInputSat,
          feeSat: feeSat,
          maxAddressScanIndex: maxAddressScanIndex,
          cache: cache,
        );
        if (attempt.verdict.isApproved) {
          return attempt;
        }
        firstRejection ??= attempt;
      }

      return firstRejection!;
    } finally {
      master.dispose();
      zeroize(seed);
    }
  }

  /// Audits an incoming [BtcSignRequestUr] against the unlocked [entropy].
  static AuditVerdict audit({
    required Uint8List entropy,
    String passphrase = '',
    required BtcSignRequestUr request,
    required int expectedAccountIndex,
    String? expectedNetwork,
    List<int>? candidateAccountIndices,
    int maxAddressScanIndex = defaultMaxAddressScanIndex,
    BtcHdDiscoveryCache? discoveryCache,
  }) {
    return auditDetailed(
      entropy: entropy,
      passphrase: passphrase,
      request: request,
      expectedAccountIndex: expectedAccountIndex,
      expectedNetwork: expectedNetwork,
      candidateAccountIndices: candidateAccountIndices,
      maxAddressScanIndex: maxAddressScanIndex,
      discoveryCache: discoveryCache,
    ).verdict;
  }

  static List<int> _buildCandidateAccounts({
    required int expectedAccountIndex,
    required int requestAccountIndex,
    required List<int>? candidateAccountIndices,
  }) {
    if (candidateAccountIndices == null) {
      return [expectedAccountIndex];
    }
    final seen = <int>{};
    final out = <int>[];
    void addIfValid(int idx) {
      if (idx >= 0 && idx < 0x80000000 && seen.add(idx)) {
        out.add(idx);
      }
    }

    addIfValid(requestAccountIndex);
    addIfValid(expectedAccountIndex);
    for (final idx in candidateAccountIndices) {
      addIfValid(idx);
    }
    for (var i = 0; i <= 4; i++) {
      addIfValid(i);
    }
    return out;
  }

  static BtcSec01AuditResult _verifyForAccount({
    required BtcSignRequestUr request,
    required BtcTransaction tx,
    required List<({BtcTxIn inp, Uint8List scriptPubKey, BigInt verifiedSat})> parsedInputs,
    required BtcAccountPublicKey acctPub,
    required int acctIdx,
    required int expectedAccountIndex,
    required bool strictInputAccount,
    required bool isTestnet,
    required String hrp,
    required BigInt totalInputSat,
    required BigInt feeSat,
    required int maxAddressScanIndex,
    required BtcHdDiscoveryCache cache,
  }) {
    final resolvedInputs = <BtcResolvedInputPath>[];
    final extraDetails = <String, String>{
      'Resolved Account': 'Account #$acctIdx',
      'Inputs Count': '${tx.inputs.length} UTXOs',
      'Outputs Count': '${tx.outputs.length}',
      'Total Inputs': '${_formatSats(totalInputSat)} sats',
    };

    for (var i = 0; i < parsedInputs.length; i++) {
      final item = parsedInputs[i];
      final inp = item.inp;
      final inputPkh = item.scriptPubKey.sublist(2, 22);

      if (strictInputAccount && inp.accountIndex != null && inp.accountIndex != expectedAccountIndex) {
        return BtcSec01AuditResult(
          verdict: AuditVerdict.rejected(
            'UTXO #$i thuộc accountIndex #${inp.accountIndex} khác với ví đang mở (#$expectedAccountIndex)',
          ),
          resolvedAccountIndex: acctIdx,
        );
      }

      final int resolvedChange;
      final int resolvedAddrIdx;
      final bool wasAutoDiscovered;

      if (inp.change != null && inp.addressIndex != null) {
        resolvedChange = inp.change!;
        resolvedAddrIdx = inp.addressIndex!;
        wasAutoDiscovered = false;

        final expectedPkh = acctPub.derivePubKeyHash(resolvedChange, resolvedAddrIdx);
        if (!constantTimeEquals(inputPkh, expectedPkh)) {
          return BtcSec01AuditResult(
            verdict: AuditVerdict.rejected(
              'CẢNH BÁO AN NINH: ScriptPubKey của UTXO #$i không thuộc địa chỉ '
              'm/84\'/${isTestnet ? 1 : 0}\'/$acctIdx\'/$resolvedChange/$resolvedAddrIdx của ví này!',
            ),
            resolvedAccountIndex: acctIdx,
          );
        }
      } else {
        final branches = inp.change != null ? <int>[inp.change!] : const <int>[0, 1];
        final match = cache.resolvePubKeyHash(
          acctPub: acctPub,
          isTestnet: isTestnet,
          accountIndex: acctIdx,
          pubKeyHash20: inputPkh,
          changes: branches,
          maxScanIndex: maxAddressScanIndex,
        );
        if (match == null) {
          return BtcSec01AuditResult(
            verdict: AuditVerdict.rejected(
              'CẢNH BÁO AN NINH: Không tìm thấy khóa sở hữu cho UTXO #$i trên Account #$acctIdx (change 0/1, index 0..$maxAddressScanIndex)!',
            ),
            resolvedAccountIndex: acctIdx,
          );
        }
        resolvedChange = match.change;
        resolvedAddrIdx = match.addressIndex;
        wasAutoDiscovered = true;
      }

      final resolved = BtcResolvedInputPath(
        accountIndex: acctIdx,
        change: resolvedChange,
        addressIndex: resolvedAddrIdx,
        verifiedSat: item.verifiedSat,
        wasAutoDiscovered: wasAutoDiscovered,
      );
      resolvedInputs.add(resolved);
      extraDetails['Input #$i'] =
          '${resolved.path(isTestnet)} (${_formatSats(item.verifiedSat)} sats)${wasAutoDiscovered ? ' [auto]' : ''}';
    }

    // Verify Outputs & Strict Change Address (change=1)
    final externalRecipients = <({String address, BigInt valueSat})>[];
    final resolvedChangeIndices = <int, int>{};
    var sendAmountSat = BigInt.zero;
    var isHighRisk = false;
    final warnings = <String>[];

    for (var i = 0; i < tx.outputs.length; i++) {
      final out = tx.outputs[i];
      if (out.isChange) {
        final int resolvedChangeIdx;
        final bool changeAuto;

        if (out.scriptPubKey.length != 22 ||
            out.scriptPubKey[0] != 0x00 ||
            out.scriptPubKey[1] != 0x14) {
          return BtcSec01AuditResult(
            verdict: AuditVerdict.rejected(
              'CẢNH BÁO AN NINH CỰC KỲ NGUY HIỂM: Địa chỉ thối (Change Output #$i) không phải chuẩn P2WPKH!',
            ),
            resolvedAccountIndex: acctIdx,
          );
        }

        final outPkh = out.scriptPubKey.sublist(2, 22);
        if (out.changeIndex != null) {
          resolvedChangeIdx = out.changeIndex!;
          changeAuto = false;
          final expectedPkh = acctPub.derivePubKeyHash(1, resolvedChangeIdx);
          if (!constantTimeEquals(outPkh, expectedPkh)) {
            return BtcSec01AuditResult(
              verdict: AuditVerdict.rejected(
                'CẢNH BÁO AN NINH CỰC KỲ NGUY HIỂM: Địa chỉ thối (Change Address) bị đánh tráo! '
                'ScriptPubKey không khớp với địa chỉ nội bộ m/84\'/${isTestnet ? 1 : 0}\'/$acctIdx\'/1/$resolvedChangeIdx.',
              ),
              resolvedAccountIndex: acctIdx,
            );
          }
        } else {
          final match = cache.resolvePubKeyHash(
            acctPub: acctPub,
            isTestnet: isTestnet,
            accountIndex: acctIdx,
            pubKeyHash20: outPkh,
            changes: const [1],
            maxScanIndex: maxAddressScanIndex,
          );
          if (match == null) {
            return BtcSec01AuditResult(
              verdict: AuditVerdict.rejected(
                'CẢNH BÁO AN NINH CỰC KỲ NGUY HIỂM: Không xác thực được địa chỉ thối (Change Output #$i) thuộc nhánh nội bộ /1/* của Account #$acctIdx!',
              ),
              resolvedAccountIndex: acctIdx,
            );
          }
          resolvedChangeIdx = match.addressIndex;
          changeAuto = true;
        }

        resolvedChangeIndices[i] = resolvedChangeIdx;
        extraDetails['Change Output #$i'] =
            "Verified internal m/84'/${isTestnet ? 1 : 0}'/$acctIdx'/1/$resolvedChangeIdx: ${_formatBtc(out.valueSat)} BTC${changeAuto ? ' [auto]' : ''}";
      } else {
        sendAmountSat += out.valueSat;
        String addrDisplay;
        if (out.scriptPubKey.length == 22 &&
            out.scriptPubKey[0] == 0x00 &&
            out.scriptPubKey[1] == 0x14) {
          addrDisplay = Bech32Segwit.encodeP2wpkh(
            hrp: hrp,
            program20: out.scriptPubKey.sublist(2, 22),
          );
        } else {
          isHighRisk = true;
          addrDisplay = 'Script:${hexEncode(out.scriptPubKey, prefix0x: true)}';
          warnings.add('Đầu ra #$i không phải chuẩn P2WPKH Bech32');
        }
        externalRecipients.add((address: addrDisplay, valueSat: out.valueSat));
        extraDetails['Recipient Output #$i'] = '$addrDisplay (${_formatBtc(out.valueSat)} BTC)';
      }
    }

    if (externalRecipients.isEmpty) {
      warnings.add('Giao dịch tự chuyển nội bộ (không có đầu ra bên ngoài)');
    } else if (externalRecipients.length > 1) {
      isHighRisk = true;
      warnings.add(
        'CẢNH BÁO ĐA ĐẦU RA: Giao dịch gửi đến ${externalRecipients.length} địa chỉ nhận khác nhau. '
        'Vui lòng đối chiếu từng địa chỉ và số tiền bên dưới!',
      );
    }

    final recipientAddress = externalRecipients.isEmpty
        ? 'Self-Transfer (Nội bộ)'
        : externalRecipients.length == 1
            ? externalRecipients.first.address
            : externalRecipients
                .map((r) => '${r.address} (${_formatBtc(r.valueSat)} BTC)')
                .join('\n');

    if (feeSat == BigInt.zero) {
      warnings.add('Cảnh báo: Phí mạng bằng 0 satoshi, giao dịch có thể bị từ chối');
    }
    if (feeSat > BigInt.from(1000000)) {
      isHighRisk = true;
      warnings.add('CẢNH BÁO PHÍ CAO: Phí mạng là ${_formatBtc(feeSat)} BTC');
    }

    return BtcSec01AuditResult(
      verdict: AuditVerdict(
        isApproved: true,
        recipientAddress: recipientAddress,
        amountDisplay: '${_formatBtc(sendAmountSat)} BTC (${_formatSats(sendAmountSat)} sats)',
        feeDisplay: '${_formatBtc(feeSat)} BTC (${_formatSats(feeSat)} sats)',
        networkDisplay: '${request.chain.toUpperCase()} (${request.network.toUpperCase()})',
        isHighRiskContractCall: isHighRisk,
        warnings: warnings,
        extraDetails: extraDetails,
      ),
      resolvedAccountIndex: acctIdx,
      resolvedInputs: resolvedInputs,
      resolvedChangeIndices: resolvedChangeIndices,
    );
  }

  /// Audits and signs all inputs of [request], returning a [BtcSignResponseUr].
  static BtcSignResponseUr auditAndSign({
    required Uint8List entropy,
    String passphrase = '',
    required BtcSignRequestUr request,
    required int expectedAccountIndex,
    String? expectedNetwork,
    List<int>? candidateAccountIndices,
    int maxAddressScanIndex = defaultMaxAddressScanIndex,
    BtcHdDiscoveryCache? discoveryCache,
  }) {
    final auditResult = auditDetailed(
      entropy: entropy,
      passphrase: passphrase,
      request: request,
      expectedAccountIndex: expectedAccountIndex,
      expectedNetwork: expectedNetwork,
      candidateAccountIndices: candidateAccountIndices,
      maxAddressScanIndex: maxAddressScanIndex,
      discoveryCache: discoveryCache,
    );

    if (!auditResult.verdict.isApproved) {
      throw StateError(
        auditResult.verdict.rejectReason ?? 'SEC-01 audit rejected Bitcoin transaction',
      );
    }

    final isTestnet = request.network.toLowerCase().contains('test') ||
        request.network.toLowerCase().contains('signet');
    final seed = Bip39.entropyToSeed(entropy, passphrase: passphrase);
    final master = BtcHdKey.fromSeed(seed);

    try {
      final witnesses = <BtcWitness>[];
      final tx = request.transaction;

      for (var i = 0; i < tx.inputs.length; i++) {
        final path = auditResult.resolvedInputs[i];

        final key = master.deriveBip84Address(
          accountIndex: path.accountIndex,
          change: path.change,
          addressIndex: path.addressIndex,
          isTestnet: isTestnet,
        );
        try {
          final pubKeyCompressed = key.publicKeyCompressed;
          final pubKeyHash = key.pubKeyHash;

          final sighash = Bip143Sighash.computeP2wpkhSighash(
            tx: tx,
            inputIndex: i,
            pubKeyHash20: pubKeyHash,
            amountSat: path.verifiedSat,
            sighashType: Bip143Sighash.sighashAll,
          );

          final sigDer = Secp256k1Btc.signDer(
            sighash,
            key.privateKey,
            sighashType: Bip143Sighash.sighashAll,
          );

          witnesses.add(BtcWitness([sigDer, pubKeyCompressed]));
        } finally {
          key.dispose();
        }
      }

      return BtcSignResponseUr(
        requestId: request.requestId,
        witnesses: witnesses,
      );
    } finally {
      master.dispose();
      zeroize(seed);
    }
  }

  static String _formatBtc(BigInt sats) {
    final whole = sats ~/ BigInt.from(10).pow(8);
    final remainder = (sats % BigInt.from(10).pow(8)).toString().padLeft(8, '0');
    return '$whole.$remainder';
  }

  static String _formatSats(BigInt sats) {
    return sats.toString().replaceAllMapped(
          RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
          (m) => '${m[1]},',
        );
  }
}
