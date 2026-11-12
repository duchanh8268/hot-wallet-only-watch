/// In-memory storage adapter used for non-web unit/widget tests.
class WebCryptoStorage {
  final Map<String, String> _memory = {};

  bool get isWebCryptoActive => false;

  Future<void> saveEncrypted(String key, String plaintext) async {
    _memory[key] = plaintext;
  }

  Future<String?> loadEncrypted(String key) async {
    return _memory[key];
  }

  Future<void> deleteEncrypted(String key) async {
    _memory.remove(key);
  }
}
