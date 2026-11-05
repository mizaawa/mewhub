import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mime/mime.dart';

import '../core/net.dart';
import '../core/paths.dart';

class EncodedImage {
  const EncodedImage(this.mime, this.base64);
  final String mime;
  final String base64;

  String get dataUri => 'data:$mime;base64,$base64';
}

/// Resolves an [ImagePart] url (sandbox path / http url / data uri) into base64.
class MediaEncoder {
  static final Map<String, EncodedImage> _cache = {};

  static Future<EncodedImage?> encodeImage(String url) async {
    final cached = _cache[url];
    if (cached != null) return cached;
    EncodedImage? out;
    try {
      if (url.startsWith('data:')) {
        final comma = url.indexOf(',');
        final header = url.substring(5, comma);
        final mime = header.split(';').first;
        out = EncodedImage(mime.isEmpty ? 'image/png' : mime, url.substring(comma + 1));
      } else if (url.startsWith('http://') || url.startsWith('https://')) {
        final r = await Net.bytesWithType(Uri.parse(url));
        final mime = r.mime?.split(';').first ?? lookupMimeType(url) ?? 'image/png';
        out = EncodedImage(mime, base64Encode(r.bytes));
      } else {
        final f = File(AppPaths.resolve(url));
        if (!await f.exists()) return null;
        final bytes = await f.readAsBytes();
        final mime = lookupMimeType(f.path, headerBytes: bytes.take(16).toList()) ?? 'image/png';
        out = EncodedImage(mime, base64Encode(bytes));
      }
    } catch (_) {
      return null;
    }
    if (_cache.length > 40) _cache.remove(_cache.keys.first);
    _cache[url] = out;
    return out;
  }

  static Uint8List? decodeDataUri(String uri) {
    final comma = uri.indexOf(',');
    if (!uri.startsWith('data:') || comma < 0) return null;
    try {
      return base64Decode(uri.substring(comma + 1));
    } catch (_) {
      return null;
    }
  }

  static String extFromMime(String mime) => switch (mime) {
    'image/jpeg' => 'jpg',
    'image/webp' => 'webp',
    'image/gif' => 'gif',
    'image/heic' => 'heic',
    _ => 'png',
  };
}
