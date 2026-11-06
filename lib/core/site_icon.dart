import 'dart:typed_data';

import 'package:http/http.dart' as http;

const _maxIconBytes = 2 * 1024 * 1024;

Map<String, String> _attributes(String tag) => {
  for (final match in RegExp(r'''([\w-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))''').allMatches(tag))
    match[1]!.toLowerCase(): (match[2] ?? match[3] ?? match[4]!).replaceAll('&amp;', '&'),
};

/// Refresh from the site's current HTML, including embedded icons on API-domain
/// landing pages. Requests deliberately carry no provider keys or auth headers.
Future<Uint8List?> loadSiteIcon(Uri site, {http.Client? client}) async {
  final httpClient = client ?? http.Client();
  try {
    final page = await httpClient.get(site, headers: {'Cache-Control': 'no-cache'}).timeout(const Duration(seconds: 6));
    if (page.bodyBytes.length > _maxIconBytes) return null;
    // An API domain may serve its branded landing page with HTTP 403.
    final html = page.body;
    final candidates = <String>[];
    for (final link in RegExp(r'<link\b[^>]*>', caseSensitive: false).allMatches(html)) {
      final attrs = _attributes(link[0]!);
      final rel = (attrs['rel'] ?? '').toLowerCase().split(RegExp(r'\s+'));
      if (rel.any((r) => r == 'icon' || r.startsWith('apple-touch-icon'))) {
        final href = attrs['href'];
        if (href != null && href.isNotEmpty && attrs['type'] != 'image/svg+xml') candidates.add(href);
      }
    }
    // The API's access notice embeds the same site logo instead of a <link>.
    for (final img in RegExp(r'<img\b[^>]*>', caseSensitive: false).allMatches(html)) {
      final src = _attributes(img[0]!)['src'];
      if (src != null && src.startsWith('data:image/')) candidates.add(src);
    }
    candidates.add('/favicon.ico');
    for (final candidate in candidates.take(5)) {
      try {
        final uri = site.resolve(candidate);
        Uint8List bytes;
        if (uri.scheme == 'data') {
          if (!uri.data!.mimeType.startsWith('image/')) continue;
          bytes = uri.data!.contentAsBytes();
        } else {
          if (uri.scheme != 'https') continue;
          final response = await httpClient.get(uri).timeout(const Duration(seconds: 6));
          if (response.statusCode != 200) continue;
          bytes = response.bodyBytes;
        }
        if (bytes.isEmpty || bytes.length > _maxIconBytes) continue;
        // ICOs can contain a PNG. Flutter can decode that PNG directly.
        if (bytes.length >= 6 && bytes[0] == 0 && bytes[1] == 0 && bytes[2] == 1 && bytes[3] == 0) {
          final data = ByteData.sublistView(bytes);
          final count = data.getUint16(4, Endian.little);
          Uint8List? png;
          for (var i = 0; i < count && 6 + (i + 1) * 16 <= bytes.length; i++) {
            final length = data.getUint32(6 + i * 16 + 8, Endian.little);
            final offset = data.getUint32(6 + i * 16 + 12, Endian.little);
            if (offset + length <= bytes.length && length > 4 && bytes[offset] == 137 && bytes[offset + 1] == 80) {
              if (png == null || length > png.length) png = Uint8List.sublistView(bytes, offset, offset + length);
            }
          }
          if (png != null) return png;
          continue;
        }
        if (bytes.length < 4) continue;
        final png = bytes[0] == 137 && bytes[1] == 80 && bytes[2] == 78 && bytes[3] == 71;
        final jpeg = bytes[0] == 255 && bytes[1] == 216;
        final gif = bytes[0] == 71 && bytes[1] == 73 && bytes[2] == 70;
        final webp = bytes.length >= 12 && bytes[0] == 82 && bytes[8] == 87 && bytes[9] == 69;
        if (png || jpeg || gif || webp) return bytes;
      } catch (_) {
        // Try another declared icon, then let the widget use its bundled asset.
      }
    }
  } catch (_) {
    // Offline, timeout or an invalid page: keep showing the bundled icon.
  } finally {
    if (client == null) httpClient.close();
  }
  return null;
}
