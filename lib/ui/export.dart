import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import '../ai/message.dart';
import '../core/paths.dart';
import '../core/util.dart';
import '../data/conversation.dart';

class ConversationExport {
  static String fileName(Conversation c) {
    final base = c.title.isEmpty ? 'chat_${formatDate(c.createdAt)}' : c.title;
    return base.replaceAll(RegExp(r'[\\/:*?"<>|\s]+'), '_');
  }

  static String markdown(Conversation c) {
    final b = StringBuffer('# ${c.title.isEmpty ? 'MewHub chat' : c.title}\n\n');
    b.writeln('> ${formatDateTime(c.createdAt)}\n');
    for (final m in c.currentMessages) {
      final who = switch (m.role) {
        Role.user => '🧑 User',
        Role.assistant => '🐱 ${m.modelName ?? 'Assistant'}',
        _ => m.role.name,
      };
      b.writeln('### $who\n');
      for (final part in m.parts) {
        switch (part) {
          case TextPart(:final text):
            b.writeln('$text\n');
          case ReasoningPart(:final text):
            if (text.trim().isNotEmpty) {
              b.writeln('<details><summary>Thinking</summary>\n\n$text\n\n</details>\n');
            }
          case ToolPart():
            b.writeln('`tool: ${part.name}(${part.input})`\n');
          case CitationsPart(:final items):
            for (var i = 0; i < items.length; i++) {
              b.writeln('${i + 1}. [${items[i].title}](${items[i].url})');
            }
            b.writeln();
          case DocumentPart(:final fileName):
            b.writeln('📎 $fileName\n');
          case ImagePart():
            b.writeln('🖼️ (image)\n');
          default:
            break;
        }
      }
    }
    return b.toString();
  }
}

/// Writes [text] to a temp file in the sandbox and opens the system share sheet.
Future<void> shareText(String text, String fileName) async {
  final f = File(p.join(AppPaths.exports.path, fileName));
  await f.parent.create(recursive: true);
  await f.writeAsString(text);
  await SharePlus.instance.share(ShareParams(files: [XFile(f.path)], fileNameOverrides: [fileName]));
}

/// Lets the user save bytes via the system save dialog (Files app on iOS, SAF on Android).
Future<bool> saveBytes(Uint8List bytes, String fileName, {String mime = 'application/octet-stream'}) async {
  final uri = await FilePicker.saveFile(fileName: fileName, bytes: bytes, mimeType: mime);
  return uri != null;
}

Future<bool> saveText(String text, String fileName) =>
    saveBytes(Uint8List.fromList(utf8.encode(text)), fileName, mime: 'application/json');
