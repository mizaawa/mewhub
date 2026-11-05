import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

/// Extracts plain text from user-attached documents, entirely on-device.
class DocumentExtractor {
  static const maxChars = 200000;

  static const textExtensions = {
    'txt',
    'md',
    'markdown',
    'csv',
    'tsv',
    'json',
    'jsonl',
    'xml',
    'yaml',
    'yml',
    'toml',
    'ini',
    'log',
    'html',
    'htm',
    'css',
    'js',
    'mjs',
    'ts',
    'tsx',
    'jsx',
    'dart',
    'py',
    'java',
    'kt',
    'kts',
    'swift',
    'go',
    'rs',
    'c',
    'h',
    'cpp',
    'hpp',
    'cc',
    'cs',
    'php',
    'rb',
    'sh',
    'bash',
    'zsh',
    'ps1',
    'sql',
    'lua',
    'r',
    'scala',
    'vue',
    'svelte',
    'tex',
    'srt',
    'vtt',
    'gradle',
    'properties',
    'env',
    'conf',
    'cfg',
  };

  static bool isSupported(String name) {
    final ext = name.split('.').last.toLowerCase();
    return textExtensions.contains(ext) ||
        ext == 'pdf' ||
        ext == 'docx' ||
        ext == 'pptx' ||
        ext == 'xlsx' ||
        ext == 'epub';
  }

  static Future<String> extract(File f) async {
    final name = f.path.toLowerCase();
    final bytes = await f.readAsBytes();
    String text;
    if (name.endsWith('.pdf')) {
      text = PdfText.extract(bytes);
    } else if (name.endsWith('.docx')) {
      text = _ooxml(bytes, (n) => n == 'word/document.xml', paragraphTag: 'w:p', textTag: 'w:t');
    } else if (name.endsWith('.pptx')) {
      text = _ooxml(
        bytes,
        (n) => n.startsWith('ppt/slides/slide') && n.endsWith('.xml'),
        paragraphTag: 'a:p',
        textTag: 'a:t',
      );
    } else if (name.endsWith('.xlsx')) {
      text = _xlsx(bytes);
    } else if (name.endsWith('.epub')) {
      text = _epub(bytes);
    } else {
      text = utf8.decode(bytes, allowMalformed: true);
    }
    text = text.replaceAll('\r\n', '\n').replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
    if (text.length > maxChars) text = '${text.substring(0, maxChars)}\n…(truncated)';
    return text;
  }

  static String _ooxml(
    Uint8List bytes,
    bool Function(String) pick, {
    required String paragraphTag,
    required String textTag,
  }) {
    final archive = ZipDecoder().decodeBytes(bytes);
    final files = archive.files.where((f) => f.isFile && pick(f.name)).toList()
      ..sort((a, b) => _natural(a.name).compareTo(_natural(b.name)));
    final buf = StringBuffer();
    for (final file in files) {
      final doc = XmlDocument.parse(utf8.decode(file.content, allowMalformed: true));
      for (final p in doc.findAllElements(paragraphTag)) {
        final line = p.findAllElements(textTag).map((e) => e.innerText).join();
        if (line.trim().isNotEmpty) buf.writeln(line);
      }
      buf.writeln();
    }
    return buf.toString();
  }

  static String _natural(String s) => s.replaceAllMapped(RegExp(r'\d+'), (m) => m.group(0)!.padLeft(6, '0'));

  static String _xlsx(Uint8List bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);
    final shared = <String>[];
    final ss = archive.findFile('xl/sharedStrings.xml');
    if (ss != null) {
      final doc = XmlDocument.parse(utf8.decode(ss.content, allowMalformed: true));
      for (final si in doc.findAllElements('si')) {
        shared.add(si.findAllElements('t').map((e) => e.innerText).join());
      }
    }
    final buf = StringBuffer();
    final sheets =
        archive.files.where((f) => f.name.startsWith('xl/worksheets/sheet') && f.name.endsWith('.xml')).toList()
          ..sort((a, b) => _natural(a.name).compareTo(_natural(b.name)));
    for (final sheet in sheets) {
      buf.writeln('## ${sheet.name.split('/').last.replaceAll('.xml', '')}');
      final doc = XmlDocument.parse(utf8.decode(sheet.content, allowMalformed: true));
      for (final row in doc.findAllElements('row')) {
        final cells = <String>[];
        for (final c in row.findElements('c')) {
          final v = c.getElement('v')?.innerText ?? c.findAllElements('t').map((e) => e.innerText).join();
          if (c.getAttribute('t') == 's') {
            final i = int.tryParse(v);
            cells.add(i != null && i < shared.length ? shared[i] : v);
          } else {
            cells.add(v);
          }
        }
        if (cells.any((e) => e.isNotEmpty)) buf.writeln(cells.join('\t'));
      }
      buf.writeln();
    }
    return buf.toString();
  }

  static String _epub(Uint8List bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);
    final pages =
        archive.files.where((f) => f.isFile && RegExp(r'\.(x?html?)$').hasMatch(f.name.toLowerCase())).toList()
          ..sort((a, b) => _natural(a.name).compareTo(_natural(b.name)));
    final buf = StringBuffer();
    for (final p in pages) {
      final html = utf8.decode(p.content, allowMalformed: true);
      buf.writeln(
        html
            .replaceAll(RegExp(r'<(script|style)[\s\S]*?</\1>', caseSensitive: false), '')
            .replaceAll(RegExp(r'<br\s*/?>|</p>|</h[1-6]>|</div>', caseSensitive: false), '\n')
            .replaceAll(RegExp(r'<[^>]+>'), '')
            .replaceAll('&nbsp;', ' ')
            .replaceAll('&amp;', '&')
            .replaceAll('&lt;', '<')
            .replaceAll('&gt;', '>'),
      );
    }
    return buf.toString();
  }
}

/// Best-effort pure-Dart PDF text extraction (no native code).
///
/// Handles FlateDecode content streams, `Tj` / `TJ` / `'` / `"` operators,
/// literal and hex strings, and simple ToUnicode CMaps (bfchar / bfrange).
/// Scanned (image-only) PDFs yield little text; use OCR for those.
class PdfText {
  static String extract(Uint8List data) {
    final latin = latin1.decode(data, allowInvalid: true);
    final streams = <String>[];
    final cmaps = <Map<int, String>>[];
    final re = RegExp(r'<<([\s\S]*?)>>\s*stream\r?\n');
    for (final m in re.allMatches(latin)) {
      final dict = m.group(1)!;
      final start = m.end;
      final end = latin.indexOf('endstream', start);
      if (end < 0) continue;
      var raw = data.sublist(start, end);
      if (dict.contains('/FlateDecode')) {
        try {
          raw = Uint8List.fromList(const ZLibDecoder().decodeBytes(raw));
        } catch (_) {
          continue;
        }
      } else if (dict.contains('/Filter')) {
        continue; // images (DCT, JPX ...) and unsupported filters
      }
      final s = latin1.decode(raw, allowInvalid: true);
      if (s.contains('begincmap')) {
        cmaps.add(_parseCmap(s));
      } else if (s.contains('BT') && (s.contains('Tj') || s.contains('TJ'))) {
        streams.add(s);
      }
    }
    final cmap = <int, String>{};
    for (final c in cmaps) {
      cmap.addAll(c);
    }
    final buf = StringBuffer();
    for (final s in streams) {
      buf.write(_textFromContent(s, cmap));
      buf.writeln();
    }
    return buf.toString();
  }

  static Map<int, String> _parseCmap(String s) {
    final out = <int, String>{};
    for (final block in RegExp(r'beginbfchar([\s\S]*?)endbfchar').allMatches(s)) {
      for (final m in RegExp(r'<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>').allMatches(block.group(1)!)) {
        out[int.parse(m.group(1)!, radix: 16)] = _utf16Hex(m.group(2)!);
      }
    }
    for (final block in RegExp(r'beginbfrange([\s\S]*?)endbfrange').allMatches(s)) {
      for (final m in RegExp(r'<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>').allMatches(block.group(1)!)) {
        final lo = int.parse(m.group(1)!, radix: 16);
        final hi = int.parse(m.group(2)!, radix: 16);
        final dst = int.parse(m.group(3)!, radix: 16);
        if (hi - lo > 10000) continue;
        for (var i = lo; i <= hi; i++) {
          out[i] = String.fromCharCode(dst + (i - lo));
        }
      }
    }
    return out;
  }

  static String _utf16Hex(String hex) {
    final units = <int>[];
    for (var i = 0; i + 4 <= hex.length; i += 4) {
      units.add(int.parse(hex.substring(i, i + 4), radix: 16));
    }
    if (units.isEmpty && hex.isNotEmpty) units.add(int.parse(hex, radix: 16));
    return String.fromCharCodes(units);
  }

  static String _textFromContent(String s, Map<int, String> cmap) {
    final buf = StringBuffer();
    final tokens = RegExp(
      r'\((?:\x5C.|[^\x5C)])*\)|<[0-9A-Fa-f\s]*>|\[|\]|T\*|Tj|TJ|Td|TD|ET|BT|'
      "'"
      r'|"|-?\d+\.?\d*',
    );
    var inArray = false;
    final arr = StringBuffer();
    for (final m in tokens.allMatches(s)) {
      final tok = m.group(0)!;
      if (tok.startsWith('(')) {
        final str = _literal(tok.substring(1, tok.length - 1));
        (inArray ? arr : buf).write(cmap.isEmpty ? str : _mapBytes(str.codeUnits, cmap));
      } else if (tok.startsWith('<')) {
        final hex = tok.substring(1, tok.length - 1).replaceAll(RegExp(r'\s'), '');
        (inArray ? arr : buf).write(_hexString(hex, cmap));
      } else if (tok == '[') {
        inArray = true;
        arr.clear();
      } else if (tok == ']') {
        inArray = false;
      } else if (tok == 'TJ') {
        buf.write(arr);
        arr.clear();
      } else if (inArray && RegExp(r'^-?\d').hasMatch(tok)) {
        final n = double.tryParse(tok) ?? 0;
        final cur = arr.toString();
        if (n < -200 && cur.isNotEmpty && !cur.endsWith(' ')) arr.write(' ');
      } else if (tok == 'T*' || tok == "'" || tok == '"' || tok == 'Td' || tok == 'TD') {
        buf.write('\n');
      } else if (tok == 'ET') {
        buf.write('\n');
      }
    }
    return buf.toString().replaceAll(RegExp(r'[ \t]+\n'), '\n');
  }

  static String _hexString(String hex, Map<int, String> cmap) {
    if (hex.length.isOdd) hex = '${hex}0';
    if (cmap.isNotEmpty) {
      final width = hex.length % 4 == 0 && cmap.keys.any((k) => k > 255) ? 4 : 2;
      final out = StringBuffer();
      for (var i = 0; i + width <= hex.length; i += width) {
        final code = int.parse(hex.substring(i, i + width), radix: 16);
        out.write(cmap[code] ?? '');
      }
      return out.toString();
    }
    final bytes = <int>[for (var i = 0; i + 2 <= hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)];
    if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
      return String.fromCharCodes([for (var i = 2; i + 1 < bytes.length; i += 2) (bytes[i] << 8) | bytes[i + 1]]);
    }
    return latin1.decode(bytes, allowInvalid: true);
  }

  static String _mapBytes(List<int> bytes, Map<int, String> cmap) {
    final twoByte = cmap.keys.any((k) => k > 255);
    final out = StringBuffer();
    if (twoByte) {
      for (var i = 0; i + 1 < bytes.length; i += 2) {
        out.write(cmap[(bytes[i] << 8) | bytes[i + 1]] ?? '');
      }
    } else {
      for (final b in bytes) {
        out.write(cmap[b] ?? String.fromCharCode(b));
      }
    }
    return out.toString();
  }

  static String _literal(String s) {
    final out = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      final c = s[i];
      if (c != r'\' || i + 1 >= s.length) {
        out.write(c);
        continue;
      }
      final n = s[++i];
      switch (n) {
        case 'n':
          out.write('\n');
        case 'r':
          out.write('\r');
        case 't':
          out.write('\t');
        case 'b' || 'f':
          break;
        case '(' || ')' || r'\':
          out.write(n);
        default:
          final oct = RegExp(r'[0-7]{1,3}').matchAsPrefix(s, i);
          if (oct != null) {
            out.writeCharCode(int.parse(oct.group(0)!, radix: 8));
            i = oct.end - 1;
          } else {
            out.write(n);
          }
      }
    }
    return out.toString();
  }
}
