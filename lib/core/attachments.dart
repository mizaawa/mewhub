import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;

import '../ai/message.dart';
import 'documents.dart';
import 'paths.dart';
import 'util.dart';

/// Copies picked media into the app sandbox and returns message parts.
/// All files stay under Application Support; nothing touches shared storage.
class Attachments {
  static final _picker = ImagePicker();

  static Future<String> _store(Uint8List bytes, String ext) async {
    final name = '${DateTime.now().millisecondsSinceEpoch}_${randomHex(4)}.$ext';
    final f = File(p.join(AppPaths.files.path, name));
    await f.writeAsBytes(bytes, flush: true);
    return AppPaths.toRelative(f.path);
  }

  static Future<List<ImagePart>> pickImages() async {
    final files = await _picker.pickMultiImage(maxWidth: 2048, maxHeight: 2048, imageQuality: 88, limit: 9);
    return [for (final f in files) ImagePart(await _store(await f.readAsBytes(), _ext(f.path, 'jpg')))];
  }

  static Future<ImagePart?> takePhoto() async {
    final f = await _picker.pickImage(source: ImageSource.camera, maxWidth: 2048, maxHeight: 2048, imageQuality: 88);
    if (f == null) return null;
    return ImagePart(await _store(await f.readAsBytes(), _ext(f.path, 'jpg')));
  }

  /// Picks documents; images picked through the file picker become [ImagePart]s.
  static Future<List<Part>> pickFiles() async {
    final files = await FilePicker.pickFiles(type: FileType.any);
    final out = <Part>[];
    for (final f in files) {
      final bytes = await f.readAsBytes();
      final mime = lookupMimeType(f.name, headerBytes: bytes.take(16).toList()) ?? 'application/octet-stream';
      final ext = _ext(f.name, 'bin');
      if (mime.startsWith('image/')) {
        out.add(ImagePart(await _store(bytes, ext)));
        continue;
      }
      final rel = await _store(bytes, ext);
      String text;
      try {
        text = DocumentExtractor.isSupported(f.name)
            ? await DocumentExtractor.extract(File(AppPaths.resolve(rel)))
            : '(binary file, ${formatBytes(bytes.length)}, content not extracted)';
      } catch (e) {
        text = '(failed to read file: $e)';
      }
      out.add(DocumentPart(path: rel, fileName: f.name, mime: mime, extractedText: text));
    }
    return out;
  }

  static Future<DocumentPart> textAsFile(String text) async {
    final rel = await _store(Uint8List.fromList(utf8.encode(text)), 'txt');
    return DocumentPart(
      path: rel,
      fileName: 'pasted_${formatTime(DateTime.now()).replaceAll(':', '')}.txt',
      mime: 'text/plain',
      extractedText: text,
    );
  }

  static Future<String> storeBytes(Uint8List bytes, String ext) => _store(bytes, ext);

  static Future<String?> pickAvatar() async {
    final f = await _picker.pickImage(source: ImageSource.gallery, maxWidth: 512, maxHeight: 512, imageQuality: 90);
    if (f == null) return null;
    final name = 'avatar_${DateTime.now().millisecondsSinceEpoch}.${_ext(f.path, 'jpg')}';
    final dest = File(p.join(AppPaths.avatars.path, name));
    await dest.writeAsBytes(await f.readAsBytes());
    return AppPaths.toRelative(dest.path);
  }

  static Future<String?> pickBackground() async {
    final f = await _picker.pickImage(source: ImageSource.gallery, maxWidth: 2400, maxHeight: 2400, imageQuality: 85);
    if (f == null) return null;
    final name = 'bg_${DateTime.now().millisecondsSinceEpoch}.${_ext(f.path, 'jpg')}';
    final dest = File(p.join(AppPaths.backgrounds.path, name));
    await dest.writeAsBytes(await f.readAsBytes());
    return AppPaths.toRelative(dest.path);
  }

  static String _ext(String path, String def) {
    final e = p.extension(path).replaceFirst('.', '').toLowerCase();
    return e.isEmpty || e.length > 8 ? def : e;
  }
}
