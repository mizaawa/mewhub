import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import '../core/net.dart';
import '../core/paths.dart';
import '../core/util.dart';
import 'conversation.dart';
import 'database.dart';
import 'models_misc.dart';
import 'settings.dart';

/// ZIP backup: settings.json + conversations.jsonl + memories.json +
/// favorites.json + usage.json + app_launches.json + files/ avatars/ backgrounds/.
class BackupService {
  BackupService(this.db);
  final AppDatabase db;

  static const formatVersion = 1;

  Future<Uint8List> build(AppSettings settings, {bool includeSecrets = true, bool includeFiles = true}) async {
    final archive = Archive();
    void addText(String name, String text) => archive.add(ArchiveFile.bytes(name, utf8.encode(text)));
    addText(
      'manifest.json',
      jsonEncode({
        'app': 'MewHub',
        'format': formatVersion,
        'createdAt': DateTime.now().toIso8601String(),
        'secrets': includeSecrets,
      }),
    );
    addText('settings.json', jsonEncode(settings.toJson(withSecrets: includeSecrets)));
    final conv = StringBuffer();
    await for (final c in db.allConversations()) {
      conv.writeln(jsonEncode(c.toJson()));
    }
    addText('conversations.jsonl', conv.toString());
    final mem = await db.allMemories();
    addText(
      'memories.json',
      jsonEncode([
        for (final m in mem)
          {
            'id': m.id,
            'assistantId': m.assistantId,
            'content': m.content,
            'createdAt': m.createdAt.millisecondsSinceEpoch,
            'updatedAt': m.updatedAt.millisecondsSinceEpoch,
          },
      ]),
    );
    addText('usage.json', jsonEncode(await db.rawUsage()));
    addText('app_launches.json', jsonEncode(await db.rawAppLaunches()));
    addText(
      'favorites.json',
      jsonEncode([
        for (final favorite in await db.favorites())
          {
            'id': favorite.id,
            'conversationId': favorite.conversationId,
            'messageId': favorite.messageId,
            'snapshot': favorite.snapshot,
            'createdAt': favorite.createdAt.millisecondsSinceEpoch,
          },
      ]),
    );
    if (includeFiles) {
      for (final dir in [AppPaths.files, AppPaths.avatars, AppPaths.backgrounds]) {
        if (!await dir.exists()) continue;
        await for (final e in dir.list(recursive: true)) {
          if (e is! File) continue;
          final rel = p.relative(e.path, from: AppPaths.support.path).replaceAll(r'\', '/');
          archive.add(ArchiveFile.bytes(rel, await e.readAsBytes()));
        }
      }
    }
    return ZipEncoder().encodeBytes(archive);
  }

  static String fileName() {
    final n = DateTime.now();
    final stamp = '${n.year}${twoDigits(n.month)}${twoDigits(n.day)}_${twoDigits(n.hour)}${twoDigits(n.minute)}';
    return 'mewhub_backup_$stamp.zip';
  }

  /// Restores a backup. Conversations are merged by id; settings are replaced
  /// (API keys kept from the current install when the backup has none).
  Future<AppSettings> restore(Uint8List bytes, AppSettings current) async {
    final archive = ZipDecoder().decodeBytes(bytes);
    String? text(String name) {
      final f = archive.findFile(name);
      return f == null ? null : utf8.decode(f.content);
    }

    final manifest = asMap(tryJsonDecode(text('manifest.json') ?? '{}'));
    if (manifest['app'] != 'MewHub') throw const FormatException('Not a MewHub backup');
    final settingsJson = text('settings.json');
    var settings = current;
    if (settingsJson != null) {
      settings = AppSettings.fromJson(asMap(jsonDecode(settingsJson)));
      if (manifest['secrets'] != true) settings = preserveLocalSecrets(settings, current);
    }
    final conv = text('conversations.jsonl') ?? '';
    for (final line in const LineSplitter().convert(conv)) {
      if (line.trim().isEmpty) continue;
      await db.saveConversation(Conversation.fromJson(asMap(jsonDecode(line))));
    }
    for (final m in asList(tryJsonDecode(text('memories.json') ?? '[]'))) {
      final mm = asMap(m);
      await db.saveMemory(
        MemoryItem(
          id: asStrOrNull(mm['id']),
          assistantId: asStrOrNull(mm['assistantId']),
          content: asStr(mm['content']),
          createdAt: dateFromMs(mm['createdAt']),
          updatedAt: dateFromMs(mm['updatedAt']),
        ),
      );
    }
    for (final favorite in asList(tryJsonDecode(text('favorites.json') ?? '[]'))) {
      final data = asMap(favorite);
      await db.addFavorite(
        FavoriteItem(
          id: asStrOrNull(data['id']),
          conversationId: asStr(data['conversationId']),
          messageId: asStr(data['messageId']),
          snapshot: asStr(data['snapshot']),
          createdAt: dateFromMs(data['createdAt']),
        ),
      );
    }
    final usage = asList(tryJsonDecode(text('usage.json') ?? '[]'))
        .whereType<Map<dynamic, dynamic>>()
        .map(asMap)
        .toList();
    if (usage.isNotEmpty) await db.importUsage(usage);
    final launches = asList(tryJsonDecode(text('app_launches.json') ?? '[]'))
        .whereType<Map<dynamic, dynamic>>()
        .map(asMap)
        .toList();
    if (launches.isNotEmpty) await db.importAppLaunches(launches);
    for (final f in archive.files) {
      if (!f.isFile) continue;
      final name = f.name.replaceAll(r'\', '/');
      final allowed = name.startsWith('files/') || name.startsWith('avatars/') || name.startsWith('backgrounds/');
      if (!allowed) continue;
      // Guard against path traversal in crafted archives.
      final dest = p.normalize(p.join(AppPaths.support.path, name));
      if (!p.isWithin(AppPaths.support.path, dest)) continue;
      final out = File(dest);
      await out.parent.create(recursive: true);
      await out.writeAsBytes(f.content);
    }
    return settings;
  }

  /// Keep credentials already stored on this device when restoring a backup
  /// deliberately exported without secrets. IDs prevent applying a key to a
  /// different provider, service, MCP server, or proxy.
  static AppSettings preserveLocalSecrets(AppSettings restored, AppSettings current) {
    final providerKeys = {for (final item in current.providers) item.id: item.apiKey};
    final searchKeys = {for (final item in current.searchServices) item.id: item.apiKey};
    final mcpHeaders = {for (final item in current.mcpServers) item.id: item.headers};
    final proxyUrls = {for (final item in current.proxies) item.id: item.url};
    return restored.copyWith(
      providers: [
        for (final item in restored.providers)
          item.apiKey.isEmpty && (providerKeys[item.id]?.isNotEmpty ?? false)
              ? item.copyWith(apiKey: providerKeys[item.id])
              : item,
      ],
      searchServices: [
        for (final item in restored.searchServices)
          item.apiKey.isEmpty && (searchKeys[item.id]?.isNotEmpty ?? false)
              ? item.copyWith(apiKey: searchKeys[item.id])
              : item,
      ],
      mcpServers: [
        for (final item in restored.mcpServers)
          item.headers.isEmpty && (mcpHeaders[item.id]?.isNotEmpty ?? false)
              ? item.copyWith(headers: mcpHeaders[item.id])
              : item,
      ],
      webDav: restored.webDav.password.isEmpty && current.webDav.password.isNotEmpty
          ? restored.webDav.copyWith(password: current.webDav.password)
          : restored.webDav,
      proxies: [
        for (final item in restored.proxies)
          item.url.isEmpty && (proxyUrls[item.id]?.isNotEmpty ?? false) ? item.copyWith(url: proxyUrls[item.id]) : item,
      ],
      proxy: restored.proxy.isEmpty ? current.proxy : restored.proxy,
    );
  }
}

class WebDavFile {
  WebDavFile(this.name, this.href, this.size, this.modified);
  final String name;
  final String href;
  final int size;
  final DateTime? modified;
}

/// Minimal WebDAV client (PROPFIND / PUT / GET / DELETE / MKCOL).
class WebDavClient {
  WebDavClient(this.cfg);
  final WebDavConfig cfg;

  Uri _uri([String name = '']) {
    final base = cfg.url.endsWith('/') ? cfg.url : '${cfg.url}/';
    final dir = cfg.path.trim().replaceAll(RegExp(r'^/+|/+$'), '');
    return Uri.parse('$base${dir.isEmpty ? '' : '$dir/'}$name');
  }

  Map<String, String> get _auth => {
    'Authorization': 'Basic ${base64Encode(utf8.encode('${cfg.username}:${cfg.password}'))}',
  };

  Uri _resolve(String href) => href.startsWith('http') ? Uri.parse(href) : _uri().resolve(href);

  Future<void> ensureDir() async {
    try {
      await Net.text('MKCOL', _uri(), headers: _auth);
    } on ApiException catch (e) {
      // 405 = already exists; some servers answer 301 for the trailing slash.
      if (e.status != 405 && e.status != 301) rethrow;
    }
  }

  Future<void> upload(String name, Uint8List bytes) async {
    await ensureDir();
    final res = await Net.sendBytes('PUT', _uri(name), bytes, headers: {..._auth, 'Content-Type': 'application/zip'});
    await res.stream.drain<void>();
  }

  Future<Uint8List> download(String href) async => Uint8List.fromList(await Net.bytes(_resolve(href), headers: _auth));

  Future<void> delete(String href) => Net.text('DELETE', _resolve(href), headers: _auth);

  static const _propfind =
      '<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop>'
      '<d:getcontentlength/><d:getlastmodified/></d:prop></d:propfind>';

  Future<List<WebDavFile>> list() async {
    final xml = await Net.text(
      'PROPFIND',
      _uri(),
      headers: {..._auth, 'Depth': '1', 'Content-Type': 'application/xml'},
      body: _propfind,
    );
    final out = <WebDavFile>[];
    final responses = RegExp(
      r'<(?:\w+:)?response[\s>][\s\S]*?</(?:\w+:)?response>',
      caseSensitive: false,
    ).allMatches(xml);
    for (final r in responses) {
      final s = r.group(0)!;
      final href = RegExp(r'<(?:\w+:)?href[^>]*>([^<]+)</', caseSensitive: false).firstMatch(s)?.group(1);
      if (href == null || !href.toLowerCase().endsWith('.zip')) continue;
      final len = RegExp(r'getcontentlength[^>]*>(\d+)<', caseSensitive: false).firstMatch(s)?.group(1);
      final mod = RegExp(r'getlastmodified[^>]*>([^<]+)<', caseSensitive: false).firstMatch(s)?.group(1);
      DateTime? modified;
      try {
        modified = mod == null ? null : HttpDate.parse(mod.trim());
      } catch (_) {}
      final name = Uri.decodeComponent(href.split('/').where((e) => e.isNotEmpty).last);
      out.add(WebDavFile(name, href, int.tryParse(len ?? '') ?? 0, modified));
    }
    out.sort((a, b) => (b.modified ?? DateTime(0)).compareTo(a.modified ?? DateTime(0)));
    return out;
  }
}
