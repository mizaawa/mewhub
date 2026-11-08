import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mewhub/ai/provider_config.dart';
import 'package:mewhub/data/assistant.dart';
import 'package:mewhub/data/config_transfer.dart';
import 'package:mewhub/data/models_misc.dart';
import 'package:mewhub/data/settings.dart';

AppSettings _configured() {
  final s = AppSettings.initial();
  final provider = ProviderConfig(
    id: 'gw',
    kind: ProviderKind.openai,
    name: 'Gateway',
    baseUrl: 'https://gw.example/v1',
    apiKey: 'sk-transfer-secret',
    models: [for (var i = 0; i < 30; i++) ModelConfig(modelId: 'vendor/model-$i')],
  );
  return s.copyWith(
    providers: [...s.providers, provider],
    mcpServers: [
      McpServerConfig(id: 'mt', name: 'mt', url: 'http://127.0.0.1:8848/mcp', headers: {'Authorization': 'Bearer mcp'}),
    ],
    lorebooks: [
      Lorebook(
        id: 'book',
        name: 'Lore',
        entries: [
          LoreEntry(keywords: const ['cat'], content: 'cat lore'),
        ],
      ),
    ],
    quickMessages: [QuickMessage(title: 'Sum', content: 'Summarise this')],
    onboarded: true,
  );
}

void main() {
  test('frames reassemble in any order, survive duplicates and keep secrets on request', () {
    final source = _configured();
    final frames = ConfigTransfer.encode(source, includeSecrets: true, id: 'abc123');
    expect(frames.length, greaterThan(1));
    expect(frames.every((f) => f.length < 600), isTrue, reason: 'codes must stay small enough to scan');

    final assembler = TransferAssembler();
    for (final f in [...frames.reversed, frames.first, 'not a frame']) {
      assembler.add(f);
    }
    expect(assembler.isComplete, isTrue);
    final json = assembler.decode();

    final current = AppSettings.initial();
    final merged = mergeTransferredSettings(json, current, keepLocalSecrets: true);
    expect(merged.providers.firstWhere((p) => p.id == 'gw').apiKey, 'sk-transfer-secret');
    expect(merged.providers.firstWhere((p) => p.id == 'gw').models, hasLength(30));
    expect(merged.providers.map((p) => p.id).toSet(), source.providers.map((p) => p.id).toSet());
    expect(merged.mcpServers.single.headers['Authorization'], 'Bearer mcp');
    expect(merged.lorebooks.single.entries.single.content, 'cat lore');
    expect(merged.quickMessages.single.content, 'Summarise this');
    expect(merged.modes.map((m) => m.id), source.modes.map((m) => m.id));
    expect(merged.titlePrompt, source.titlePrompt);
    // Device-local state stays with the receiving phone.
    expect(merged.onboarded, current.onboarded);
  });

  test('a transfer without secrets keeps keys already on the receiving device', () {
    final frames = ConfigTransfer.encode(_configured(), includeSecrets: false);
    final assembler = TransferAssembler();
    frames.forEach(assembler.add);
    final json = assembler.decode();
    expect(jsonEncode(json), isNot(contains('sk-transfer-secret')));
    expect(jsonEncode(json), isNot(contains('Bearer mcp')));

    final local = _configured().copyWith(
      providers: [for (final p in _configured().providers) p.id == 'gw' ? p.copyWith(apiKey: 'sk-local') : p],
    );
    final merged = mergeTransferredSettings(json, local, keepLocalSecrets: true);
    expect(merged.providers.firstWhere((p) => p.id == 'gw').apiKey, 'sk-local');
    expect(merged.mcpServers.single.headers['Authorization'], 'Bearer mcp');
  });

  test('mixing codes from two transfers restarts instead of combining them', () {
    final a = ConfigTransfer.encode(_configured(), includeSecrets: true, id: 'aaaaaa');
    final b = ConfigTransfer.encode(AppSettings.initial(), includeSecrets: true, id: 'bbbbbb');
    final assembler = TransferAssembler()..add(a.first);
    expect(assembler.received, 1);
    assembler.add(b.first);
    expect(assembler.count, b.length);
    expect(assembler.received, 1);
    for (final f in b) {
      assembler.add(f);
    }
    final merged = mergeTransferredSettings(assembler.decode(), AppSettings.initial(), keepLocalSecrets: true);
    expect(merged.lorebooks, isEmpty);
  });

  test('tampered or foreign payloads are rejected', () {
    final frames = ConfigTransfer.encode(_configured(), includeSecrets: false, id: 'cafe01');
    final parts = frames.first.split(':');
    final data = base64Url.decode(base64Url.normalize(parts.last));
    data[0] ^= 0xff;
    final tampered = [...parts.take(4), base64Url.encode(data)].join(':');
    final assembler = TransferAssembler();
    for (final f in [tampered, ...frames.skip(1)]) {
      assembler.add(f);
    }
    expect(assembler.decode, throwsFormatException);
    expect(TransferFrame.parse('MEWCFG1:zz:1/1:00000000:AA'), isNull);
    expect(TransferFrame.parse('MEWCFG1:ab:3/2:00000000:AA'), isNull);
    expect(TransferAssembler().decode, throwsFormatException);
  });
}
