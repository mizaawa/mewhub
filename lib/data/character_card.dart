import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../ai/message.dart';
import '../core/util.dart';
import 'assistant.dart';

/// Imports SillyTavern / TavernAI character cards (V1, V2, V3) from JSON or
/// PNG (`chara` / `ccv3` tEXt/iTXt/zTXt chunks) into an [Assistant] plus an
/// optional embedded lorebook.
class CharacterCardImporter {
  static ({Assistant assistant, Lorebook? lorebook}) parse(Uint8List bytes, {String? avatarPath}) {
    Map<String, dynamic> json;
    if (bytes.length > 8 && bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47) {
      final text = _pngText(bytes);
      final raw = text['ccv3'] ?? text['chara'];
      if (raw == null) throw const FormatException('PNG has no character data');
      json = asMap(jsonDecode(_maybeBase64(raw)));
    } else {
      json = asMap(jsonDecode(utf8.decode(bytes)));
    }
    return fromJson(json, avatarPath: avatarPath);
  }

  static String _maybeBase64(String s) {
    final t = s.trim();
    if (t.startsWith('{')) return t;
    return utf8.decode(base64.decode(base64.normalize(t)));
  }

  static Map<String, String> _pngText(Uint8List b) {
    final out = <String, String>{};
    var i = 8;
    final bd = ByteData.sublistView(b);
    while (i + 8 <= b.length) {
      final len = bd.getUint32(i);
      final type = String.fromCharCodes(b.sublist(i + 4, i + 8));
      final start = i + 8;
      final end = start + len;
      if (end > b.length) break;
      final data = b.sublist(start, end);
      if (type == 'tEXt') {
        final z = data.indexOf(0);
        if (z > 0) out[latin1.decode(data.sublist(0, z))] = latin1.decode(data.sublist(z + 1));
      } else if (type == 'iTXt') {
        final z = data.indexOf(0);
        if (z > 0) {
          final key = latin1.decode(data.sublist(0, z));
          final compressed = data[z + 1] == 1;
          var p = z + 3;
          p = data.indexOf(0, p) + 1; // language tag
          p = data.indexOf(0, p) + 1; // translated keyword
          final payload = data.sublist(p);
          out[key] = utf8.decode(compressed ? const ZLibDecoder().decodeBytes(payload) : payload);
        }
      } else if (type == 'zTXt') {
        final z = data.indexOf(0);
        if (z > 0) {
          out[latin1.decode(data.sublist(0, z))] = latin1.decode(const ZLibDecoder().decodeBytes(data.sublist(z + 2)));
        }
      } else if (type == 'IEND') {
        break;
      }
      i = end + 4;
    }
    return out;
  }

  static ({Assistant assistant, Lorebook? lorebook}) fromJson(Map<String, dynamic> j, {String? avatarPath}) {
    final d = j['data'] is Map ? asMap(j['data']) : j;
    final name = asStr(d['name'], 'Character');
    final parts = <String>[
      if (asStr(d['system_prompt']).trim().isNotEmpty) asStr(d['system_prompt']).trim(),
      if (asStr(d['description']).trim().isNotEmpty) asStr(d['description']).trim(),
      if (asStr(d['personality']).trim().isNotEmpty) "{{char}}'s personality: ${asStr(d['personality']).trim()}",
      if (asStr(d['scenario']).trim().isNotEmpty) 'Scenario: ${asStr(d['scenario']).trim()}',
      if (asStr(d['mes_example']).trim().isNotEmpty) 'Example dialogue:\n${asStr(d['mes_example']).trim()}',
      if (asStr(d['post_history_instructions']).trim().isNotEmpty) asStr(d['post_history_instructions']).trim(),
    ];
    String sub(String s) => s.replaceAll(RegExp(r'\{\{\s*char\s*\}\}|<BOT>', caseSensitive: false), name);
    Lorebook? book;
    final cb = asMapOrNull(d['character_book']);
    if (cb != null) {
      book = Lorebook(
        name: asStr(cb['name'], '$name lore'),
        description: asStr(cb['description']),
        entries: [
          for (final e in asList(cb['entries']))
            () {
              final m = asMap(e);
              final pos = asStr(m['position']);
              return LoreEntry(
                name: asStr(m['comment'], asStr(m['name'])),
                enabled: asBool(m['enabled'], true),
                keywords: asList(m['keys']).map((k) => k.toString()).toList(),
                caseSensitive: asBool(m['case_sensitive']),
                constant: asBool(m['constant']),
                content: asStr(m['content']),
                priority: asInt(m['insertion_order'], asInt(m['priority'])),
                position: pos == 'before_char' ? InjectPosition.beforeSystem : InjectPosition.afterSystem,
              );
            }(),
        ],
      );
    }
    final greeting = sub(asStr(d['first_mes']));
    final assistant = Assistant(
      name: name,
      avatar: avatarPath ?? '',
      systemPrompt: sub(parts.join('\n\n')),
      greeting: greeting,
      lorebookIds: book == null ? const {} : {book.id},
      presetMessages: const <ChatMessage>[],
      localTools: const {},
      temperature: 0.9,
    );
    return (assistant: assistant, lorebook: book);
  }
}
