/// Opens an external HTTP(S) URL in a new browser tab.
/// On non-web platforms (such as VM tests), records the last requested URL and returns `true` for valid HTTP(S) URLs.
String? lastOpenedExternalUrlForTest;

bool openExternalUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
    return false;
  }
  lastOpenedExternalUrlForTest = url;
  return true;
}
