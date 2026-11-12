import 'dart:js_interop';

@JS('CardanoWebCryptoStorage')
external _JsCryptoStorage? get _jsStorage;

extension type _JsCryptoStorage(JSObject _) implements JSObject {
  external bool isSupported();
  external JSPromise<JSBoolean> saveEncrypted(String key, String plaintext);
  external JSPromise<JSString?> loadEncrypted(String key);
  external JSPromise<JSBoolean> deleteEncrypted(String key);
}

/// Production Web Crypto API (`SubtleCrypto` AES-256-GCM) + IndexedDB storage.
class WebCryptoStorage {
  final Map<String, String> _fallback = {};

  bool get isWebCryptoActive => _jsStorage?.isSupported() ?? false;

  Future<void> saveEncrypted(String key, String plaintext) async {
    final js = _jsStorage;
    if (js != null && js.isSupported()) {
      await js.saveEncrypted(key, plaintext).toDart;
      return;
    }
    _fallback[key] = plaintext;
  }

  Future<String?> loadEncrypted(String key) async {
    final js = _jsStorage;
    if (js != null && js.isSupported()) {
      final res = await js.loadEncrypted(key).toDart;
      return res?.toDart;
    }
    return _fallback[key];
  }

  Future<void> deleteEncrypted(String key) async {
    final js = _jsStorage;
    if (js != null && js.isSupported()) {
      await js.deleteEncrypted(key).toDart;
      return;
    }
    _fallback.remove(key);
  }
}
