enum HotLocale { vi, en }

class HotStrings {
  final HotLocale locale;
  const HotStrings(this.locale);
  bool get isVi => locale == HotLocale.vi;

  String get appTitle => isVi ? 'Ví Nóng Cardano Watch-Only' : 'Cardano Watch-Only Hot Wallet';
  String get subtitle => isVi ? 'Air-Gapped Conway Era • Không chứa Private Key' : 'Air-Gapped Conway Era • Zero Private Keys';

  // Nav tabs
  String get tabDashboard => isVi ? 'Tổng quan' : 'Dashboard';
  String get tabSend => isVi ? 'Gửi tài sản' : 'Send Assets';
  String get tabStaking => isVi ? 'Staking & DRep' : 'Staking & DRep';
  String get tabAccounts => isVi ? 'Hồ sơ Ví' : 'Wallet Profiles';
  String get tabSettings => isVi ? 'Cài đặt API' : 'API Settings';

  // Top bar
  String get networkLabel => isVi ? 'Mạng' : 'Network';
  String get syncBtn => isVi ? 'Đồng bộ' : 'Sync';
  String get syncing => isVi ? 'Đang đồng bộ...' : 'Syncing...';
  String get noWalletSelected => isVi ? 'Chưa có hồ sơ Watch-Only' : 'No Watch-Only Profile';

  // Accounts
  String get accountsTitle => isVi ? 'Quản lý Đa hồ sơ Watch-Only' : 'Multi-Profile Watch-Only Manager';
  String get addAccountQrBtn => isVi ? 'Quét QR Ví Lạnh (ur:cardano-account)' : 'Scan Cold Wallet QR (ur:cardano-account)';
  String get walletNameLabel => isVi ? 'Tên hồ sơ ví' : 'Profile Name';
  String get networkMismatchTitle => isVi ? 'Cảnh báo lệch mạng!' : 'Network Mismatch!';
  String networkMismatchBody(String qrNet, String appNet) => isVi
      ? 'Mã QR từ Ví Lạnh thuộc mạng "$qrNet" nhưng Web App đang chọn "$appNet". Hãy chuyển mạng hoặc xuất lại QR đúng mạng.'
      : 'Cold Wallet QR is for "$qrNet", while Web App is set to "$appNet". Switch network or re-export QR.';
  String get rename => isVi ? 'Đổi tên' : 'Rename';
  String get delete => isVi ? 'Xóa' : 'Delete';
  String get active => isVi ? 'Đang chọn' : 'Active';
  String get pasteUrOptional => isVi
      ? 'Hoặc dán chuỗi UR thủ công (nếu thiết bị không có Webcam)'
      : 'Or paste UR string manually (if no webcam available)';
  String get parseUrBtn => isVi ? 'Nạp chuỗi UR' : 'Load UR String';

  // Settings
  String get settingsTitle => isVi ? 'Cấu hình Blockfrost API theo từng mạng' : 'Per-Network Blockfrost API Settings';
  String get webCryptoBadge => isVi
      ? 'Mã hóa bằng Web Crypto API (SubtleCrypto AES-256-GCM • Non-Extractable Key trong IndexedDB)'
      : 'Encrypted via Web Crypto API (SubtleCrypto AES-256-GCM • Non-Extractable Key in IndexedDB)';
  String projectIdLabel(String net) => 'Blockfrost Project ID ($net)';
  String get saveSettingsBtn => isVi ? 'Lưu cấu hình mã hóa' : 'Save Encrypted Settings';
  String get testConnectionBtn => isVi ? 'Kiểm tra kết nối' : 'Test Connection';
  String get gapLimitLabel => isVi ? 'Giới hạn quét HD (Gap Limit)' : 'HD Discovery Gap Limit';
  String get settingsSaved => isVi ? 'Đã lưu và mã hóa trong IndexedDB!' : 'Saved and encrypted in IndexedDB!';
  String get missingApiKey => isVi
      ? 'Chưa nhập Blockfrost Project ID cho mạng hiện tại. Vào tab Cài đặt API để thiết lập.'
      : 'Blockfrost Project ID not configured for the active network. Open API Settings tab.';

  // Dashboard
  String get totalAda => isVi ? 'Số Dư Khả Dụng' : 'Available Balance';
  String availableUtxosCount(int count) =>
      isVi ? '$count UTXOs khả dụng' : '$count UTXOs available';
  String get rewardsAda => isVi ? 'Phần Thưởng Staking Khả Dụng' : 'Available Staking Rewards';
  String get withdrawRewardShortBtn => isVi ? 'Rút Thưởng' : 'Withdraw';
  String get step1BuildTxBtn => isVi
      ? 'BƯỚC 1: TẠO GIAO DỊCH CHUYỂN ADA (BUILD TX)'
      : 'STEP 1: BUILD ADA TRANSFER TX';
  String get stakeAndDrepBtn => isVi
      ? 'ỦY THÁC STAKE POOL & DREP (CONWAY)'
      : 'DELEGATE STAKE POOL & DREP (CONWAY)';
  String get step2ScanSubmitBtn => isVi
      ? 'BƯỚC 2: QUÉT & SUBMIT GIAO DỊCH ĐÃ KÝ'
      : 'STEP 2: SCAN & SUBMIT SIGNED TX';
  String get addWalletToListBtn => isVi
      ? 'Thêm Ví Này Vào Danh Sách Quản Lý'
      : 'Manage Watch-Only Wallet List';
  String get walletListSectionTitle => isVi
      ? 'Danh Sách Ví & Nhóm Tài Khoản:'
      : 'Wallets & Account Profiles:';
  String get addWalletShortBtn => isVi ? 'Thêm Ví' : 'Add Wallet';
  String get needStep1Title => isVi
      ? 'Chưa có giao dịch chờ ký'
      : 'No Pending Unsigned Transaction';
  String get needStep1Desc => isVi
      ? 'Hãy thực hiện Bước 1 (Tạo giao dịch hoặc Ủy thác Stake/DRep) trước để tạo mã QR gửi sang Ví Lạnh ký, sau đó quay lại Bước 2 để quét chữ ký và phát sóng.'
      : 'Complete Step 1 (Build Transfer or Staking/DRep Tx) first to generate a sign request QR for your Cold Wallet, then return to Step 2 to scan and broadcast.';
  String get receiveAddress => isVi ? 'Địa chỉ Nhận hiện tại' : 'Next Receiving Address';
  String receiveAddressWithPath(int accountIndex, int addressIndex) => isVi
      ? "Địa chỉ Nhận (m/1852'/1815'/$accountIndex'/0/$addressIndex)"
      : "Receiving Address (m/1852'/1815'/$accountIndex'/0/$addressIndex)";
  String showPrimaryAddrBtn(int accountIndex) => isVi
      ? "Xem địa chỉ gốc ($accountIndex'/0/0)"
      : "View Base Address ($accountIndex'/0/0)";
  String showNextAddrBtn(int accountIndex, int nextIndex) => isVi
      ? "Địa chỉ mới ($accountIndex'/0/$nextIndex)"
      : "Next Unused ($accountIndex'/0/$nextIndex)";
  String get copiedAddressMsg => isVi ? 'Đã sao chép địa chỉ' : 'Address copied';
  String get nativeTokens => isVi ? 'Tài sản Native Tokens' : 'Native Tokens';
  String get noTokens => isVi ? 'Chưa có Native Token nào.' : 'No Native Tokens found.';
  String get searchTokensHint => isVi ? 'Tìm token theo tên, ticker hoặc Policy ID...' : 'Search tokens by name, ticker, or Policy ID...';
  String get filterAll => isVi ? 'Tất cả' : 'All';
  String get filterFt => isVi ? 'Token (FT)' : 'Tokens (FT)';
  String get filterNft => 'NFT';
  String get utxosTitle => isVi ? 'Danh sách UTXO khả dụng' : 'Available UTXOs';
  String get txHistoryTitle => isVi ? 'Lịch sử giao dịch gần đây' : 'Recent Transactions';

  // Send
  String get sendTitle => isVi ? 'Soạn Giao dịch Chuyển Tài sản (Conway Era)' : 'Build Asset Transfer (Conway Era)';
  String get recipientAddrLabel => isVi ? 'Địa chỉ người nhận (addr1... / addr_test1...)' : 'Recipient Address (addr1... / addr_test1...)';
  String get scanRecipientQr => isVi ? 'Quét QR địa chỉ' : 'Scan Address QR';
  String get adaAmountLabel => isVi ? 'Số lượng ADA' : 'ADA Amount';
  String get extraAdaLabel => isVi ? 'ADA gửi thêm (tùy chọn, cộng thêm vào Min-ADA)' : 'Extra ADA (optional, added on top of Min-ADA)';
  String get autoMinAdaLabel => isVi ? 'Tự động đính kèm Min-ADA chuẩn Conway' : 'Auto-attach Conway Min-ADA';
  String get sendMaxBtn => isVi ? 'Gửi tối đa ADA' : 'Send Max ADA';
  String get sweepAllBtn => isVi ? 'Quét sạch ví (ADA + toàn bộ Token)' : 'Sweep All (ADA + all Tokens)';
  String get selectTokensLabel => isVi ? 'Native Tokens gửi kèm (Chỉ hiện token có trong ví)' : 'Native Tokens to Send (Wallet tokens only)';
  String get addTokenBtn => isVi ? '+ Thêm Native Token từ ví' : '+ Add Wallet Native Token';
  String get noMoreTokensToAdd => isVi ? 'Đã chọn tất cả token khả dụng trong ví' : 'All available wallet tokens added';
  String get txPreviewTitle => isVi ? 'Xem trước Phí & Min-ADA (Conway Standard)' : 'Fee & Min-ADA Live Preview (Conway Standard)';
  String get attachedMinAdaLabel => isVi ? 'Min-ADA đính kèm cho Output nhận' : 'Attached Recipient Min-ADA';
  String get estimatedFeeLabel => isVi ? 'Phí mạng ước tính chính xác' : 'Estimated Network Fee';
  String get changeMinAdaLabel => isVi ? 'Min-ADA tiền thối (token còn lại)' : 'Change Min-ADA (remaining tokens)';
  String get totalAdaDeductedLabel => isVi ? 'Tổng ADA trừ khỏi ví' : 'Total ADA Deducted';
  String get buildSignQrBtn => isVi ? 'Tạo Animated QR Ký Giao dịch' : 'Generate Sign Request QR';

  // Staking
  String get stakingTitle => isVi ? 'Staking Pool & Quản trị Conway (DRep)' : 'Staking Pool & Conway Governance (DRep)';
  String get stakeStatusRegistered => isVi ? 'Trạng thái Stake Key: Đã đăng ký' : 'Stake Key Status: Registered';
  String get stakeStatusUnregistered => isVi ? 'Trạng thái Stake Key: Chưa đăng ký (sẽ tự đính kèm Key Deposit)' : 'Stake Key Status: Unregistered (auto-adds Key Deposit)';
  String get controlledStakeLabel => isVi
      ? 'Tổng số ADA đang được Stake (Controlled Stake)'
      : 'Total Staked ADA (Controlled Stake)';
  String get stakingMechanismNote => isVi
      ? 'Lưu ý cơ chế Cardano: Staking tính trên toàn bộ Stake Address (stake...) nên 100% số dư ví tự động được stake. Giao dịch ủy thác chỉ chi tiêu 1 UTXO đủ trả cọc 2 ADA + phí (~0.18 ADA) rồi trả tiền thối về ví — con số Total Output trên Explorer chỉ là tiền thối của UTXO đó, không phải tổng số ADA đang stake.'
      : 'Cardano Staking Note: Delegation applies to your Stake Key (stake...), automatically staking 100% of all wallet UTXOs. The delegation tx only spends 1 UTXO to pay the 2 ADA deposit + fee (~0.18 ADA) and returns change — Explorer "Total Output" shows that UTXO change, not your total staked balance.';
  String get poolIdLabel => isVi ? 'Pool ID (pool1...)' : 'Pool ID (pool1...)';
  String get drepModeLabel => isVi ? 'Ủy quyền Bỏ phiếu Conway (DRep)' : 'Conway Vote Delegation (DRep)';
  String get drepAlwaysAbstain => isVi ? 'AlwaysAbstain (Mặc định - Đủ điều kiện rút thưởng)' : 'AlwaysAbstain (Default - Unlocks Reward Withdrawals)';
  String get drepAlwaysNoConf => 'AlwaysNoConfidence';
  String get drepCustom => isVi ? 'Nhập DRep ID cụ thể (drep1...)' : 'Custom DRep ID (drep1...)';
  String get delegateBtn => isVi ? 'Tạo QR Ủy quyền Pool & DRep' : 'Build Pool & DRep Delegation QR';
  String get withdrawBtn => isVi ? 'Rút toàn bộ Thưởng Staking' : 'Withdraw All Staking Rewards';
  String get deregisterBtn => isVi ? 'Hủy đăng ký Stake Key (Nhận lại Deposit)' : 'Deregister Stake Key (Reclaim Deposit)';

  // Broadcast flow
  String get signReqStepTitle => isVi ? 'Bước 1: Đưa Ví Lạnh quét Animated QR' : 'Step 1: Scan Animated QR with Cold Wallet';
  String get scanRespStepBtn => isVi ? 'Đã ký xong → Quét QR Chữ ký từ Ví Lạnh' : 'Signed → Scan Sign Response QR';
  String get scanRespStepTitle => isVi ? 'Bước 2: Quét Animated QR Chữ ký (ur:cardano-sign-response)' : 'Step 2: Scan Signed Response QR';
  String get broadcastReadyTitle => isVi ? 'Bước 3: Chữ ký hợp lệ — Sẵn sàng Phát sóng' : 'Step 3: Signatures Verified — Ready to Broadcast';
  String get broadcastBtn => isVi ? 'Phát sóng Giao dịch (Submit Tx)' : 'Broadcast Transaction (Submit Tx)';
  String get txSubmittedTitle => isVi ? 'Đã phát sóng giao dịch lên mạng Cardano!' : 'Transaction Broadcasted to Cardano!';
  String get viewOnExplorer => isVi ? 'Xem trên Cardanoscan Explorer' : 'View on Cardanoscan Explorer';
  String get confirmStatusWaiting => isVi ? 'Đang chờ xác nhận trên block...' : 'Waiting for on-chain confirmation...';
  String get confirmStatusConfirmed => isVi ? 'Giao dịch đã được xác nhận trên chain!' : 'Transaction confirmed on-chain!';

  String get close => isVi ? 'Đóng' : 'Close';
  String get cancel => isVi ? 'Hủy' : 'Cancel';
  String get save => isVi ? 'Lưu' : 'Save';
}
