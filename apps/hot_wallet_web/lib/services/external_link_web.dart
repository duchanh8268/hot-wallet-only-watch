import 'package:web/web.dart' as web;

/// Opens an external HTTP(S) URL safely in a new browser tab (`noopener,noreferrer`).
bool openExternalUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
    return false;
  }
  web.window.open(url, '_blank', 'noopener,noreferrer');
  return true;
}
