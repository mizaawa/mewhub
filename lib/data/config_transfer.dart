import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../core/util.dart';
import 'backup.dart';
import 'defaults.dart';
import 'settings.dart';

/// Moves the MewHub configuration (settings, providers, assistants, MCP,
/// lorebooks...) between devices through a sequence of QR codes.
///
/// Payload: zlib(JSON of [AppSettings.toJson]) split into chunks. Each frame:
/// `MEWCFG1:<id>:<index>/<count>:<crc32 of whole payload>:<base64url chunk>`.
/// Chats, memories and files are not included; use a backup file for those.
class ConfigTransfer {
  static const prefix = 'MEWCFG1';

  /// Bytes per frame. ~510 characters per code fits QR version 15 at low
  /// error correction (77×77 modules), which phone cameras read off a screen
  /// reliably. Larger configs simply use more frames.
  static const chunkBytes = 360;

  /// Refuses unreasonably large payloads (and zip bombs on decode).
  static const maxPayload = 4 * 1024 * 1024;

  static List<String> encode(AppSettings settings, {required bool includeSecrets, String? id}) {
    final json = settings.toJson(withSecrets: includeSecrets)
      ..['_transfer'] = {'app': 'MewHub', 'secrets': includeSecrets, 'at': DateTime.now().millisecondsSinceEpoch};
    // Device-local state that should not follow the config to another phone.
    for (final k in ['onboarded', 'lastBackupAt']) {
      json.remove(k);
    }
    // Missing keys load as defaults, so unchanged defaults need no space.
    const defaults = {
      'titlePrompt': defaultTitlePrompt,
      'suggestionPrompt': defaultSuggestionPrompt,
      'translatePrompt': defaultTranslatePrompt,
      'ocrPrompt': defaultOcrPrompt,
      'compressPrompt': defaultCompressPrompt,
    };
    defaults.forEach((k, v) {
      if (json[k] == v) json.remove(k);
    });
    if (jsonEncode(json['modes']) == jsonEncode([for (final m in defaultModes()) m.toJson()])) json.remove('modes');
    // Untouched built-in provider templates are recreated by the receiver.
    final templates = {for (final p in defaultProviders()) p.id: jsonEncode(p.toJson(withSecrets: false))};
    json['providers'] = [
      for (final p in asList(json['providers']))
        if (templates[asMap(p)['id']] != jsonEncode(p)) p else {'id': asMap(p)['id'], '_template': true},
    ];
    final packed = const ZLibEncoder().encodeBytes(utf8.encode(jsonEncode(json)), level: 9);
    final crc = getCrc32(packed).toRadixString(16).padLeft(8, '0');
    final tag = id ?? randomHex(3);
    final count = (packed.length / chunkBytes).ceil().clamp(1, 9999);
    return [
      for (var i = 0; i < count; i++)
        '$prefix:$tag:${i + 1}/$count:$crc:'
            '${base64Url.encode(packed.sublist(i * chunkBytes, ((i + 1) * chunkBytes).clamp(0, packed.length)))}',
    ];
  }

  static bool looksLikeFrame(String raw) => raw.startsWith('$prefix:');
}

class TransferFrame {
  const TransferFrame(this.id, this.index, this.count, this.crc, this.data);
  final String id;
  final int index;
  final int count;
  final String crc;
  final Uint8List data;

  static final _pattern = RegExp(r'^MEWCFG1:([0-9a-f]{1,16}):(\d{1,4})/(\d{1,4}):([0-9a-f]{8}):([A-Za-z0-9_\-=]*)$');

  static TransferFrame? parse(String raw) {
    final m = _pattern.firstMatch(raw.trim());
    if (m == null) return null;
    final index = int.parse(m.group(2)!);
    final count = int.parse(m.group(3)!);
    if (count < 1 || index < 1 || index > count) return null;
    try {
      final data = base64Url.decode(base64Url.normalize(m.group(5)!));
      return TransferFrame(m.group(1)!, index, count, m.group(4)!, data);
    } on FormatException {
      return null;
    }
  }
}

/// Collects frames in any order. A frame from a different transfer (another
/// id/crc) restarts the collection so mixed codes never combine.
class TransferAssembler {
  String? _id;
  String? _crc;
  int _count = 0;
  final Map<int, Uint8List> _parts = {};

  int get count => _count;
  int get received => _parts.length;
  bool get isComplete => _count > 0 && _parts.length == _count;
  double get progress => _count == 0 ? 0 : _parts.length / _count;
  Set<int> get receivedIndices => _parts.keys.toSet();

  /// Returns true when [raw] was a new, valid frame.
  bool add(String raw) {
    final f = TransferFrame.parse(raw);
    if (f == null) return false;
    if (f.id != _id || f.crc != _crc || f.count != _count) {
      _id = f.id;
      _crc = f.crc;
      _count = f.count;
      _parts.clear();
    }
    if (_parts.containsKey(f.index)) return false;
    _parts[f.index] = f.data;
    return true;
  }

  void reset() {
    _id = null;
    _crc = null;
    _count = 0;
    _parts.clear();
  }

  /// Joins, verifies and inflates the payload into settings JSON.
  Map<String, dynamic> decode() {
    if (!isComplete) throw const FormatException('Transfer is incomplete');
    final packed = BytesBuilder(copy: false);
    for (var i = 1; i <= _count; i++) {
      packed.add(_parts[i]!);
    }
    final bytes = packed.takeBytes();
    if (getCrc32(bytes).toRadixString(16).padLeft(8, '0') != _crc) {
      throw const FormatException('Checksum mismatch');
    }
    final Uint8List json;
    try {
      json = const ZLibDecoder().decodeBytes(bytes, verify: true, maxOutputSize: ConfigTransfer.maxPayload);
    } catch (_) {
      throw const FormatException('Corrupted transfer data');
    }
    final decoded = asMapOrNull(jsonDecode(utf8.decode(json)));
    if (decoded == null || asMap(decoded['_transfer'])['app'] != 'MewHub') {
      throw const FormatException('Not a MewHub configuration');
    }
    return decoded;
  }
}

/// Builds the settings to apply on the receiving device. Credentials that the
/// sender left out are kept from this device (matched by id), and device-local
/// state (onboarding, backup time) is preserved.
AppSettings mergeTransferredSettings(Map<String, dynamic> json, AppSettings current, {required bool keepLocalSecrets}) {
  final templates = {for (final p in defaultProviders()) p.id: p.toJson(withSecrets: false)};
  final expanded = {
    ...json,
    'providers': [
      for (final p in asList(json['providers']))
        if (asMap(p)['_template'] == true && templates.containsKey(asMap(p)['id'])) templates[asMap(p)['id']] else p,
    ],
  };
  final incoming = AppSettings.fromJson(expanded);
  final withSecrets = asMap(json['_transfer'])['secrets'] == true;
  final base = withSecrets || !keepLocalSecrets ? incoming : BackupService.preserveLocalSecrets(incoming, current);
  return base.copyWith(onboarded: current.onboarded || base.onboarded, lastBackupAt: current.lastBackupAt);
}

/// Counts shown on both devices before a transfer.
({int providers, int models, int assistants, int mcp, int lorebooks, int quick}) transferSummary(AppSettings s) => (
  providers: s.providers.where((p) => p.enabled).length,
  models: s.allModels().length,
  assistants: s.assistants.length,
  mcp: s.mcpServers.length,
  lorebooks: s.lorebooks.length,
  quick: s.quickMessages.length,
);
