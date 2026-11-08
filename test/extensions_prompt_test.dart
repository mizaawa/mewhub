import 'package:flutter_test/flutter_test.dart';
import 'package:mewhub/ai/message.dart';
import 'package:mewhub/ai/provider_config.dart';
import 'package:mewhub/chat/prompt_builder.dart';
import 'package:mewhub/data/assistant.dart';
import 'package:mewhub/data/models_misc.dart';
import 'package:mewhub/data/settings.dart';

void main() {
  final model = ModelConfig(modelId: 'm');

  String system(List<ChatMessage> out) => out.firstWhere((m) => m.role == Role.system).text;

  test('lorebook entries trigger by keyword, constant entries always apply, disabled ones never do', () {
    final book = Lorebook(
      id: 'book',
      entries: [
        LoreEntry(keywords: const ['dragon'], content: 'LORE_DRAGON'),
        LoreEntry(constant: true, content: 'LORE_CONSTANT'),
        LoreEntry(keywords: const ['dragon'], content: 'LORE_DISABLED', enabled: false),
        LoreEntry(keywords: const ['castle'], content: 'LORE_DEPTH', position: InjectPosition.atDepth, depth: 1),
      ],
    );
    final settings = AppSettings.initial().copyWith(lorebooks: [book]);
    final linked = Assistant(id: 'a', lorebookIds: const {'book'});
    final out = PromptBuilder.build(
      settings: settings,
      assistant: linked,
      model: model,
      history: [ChatMessage.text(Role.user, 'Tell me about the Dragon near the castle')],
    );
    final sys = system(out);
    expect(sys, contains('LORE_DRAGON'));
    expect(sys, contains('LORE_CONSTANT'));
    expect(sys, isNot(contains('LORE_DISABLED')));
    expect(out.map((m) => m.text), contains('LORE_DEPTH'));

    final unlinked = PromptBuilder.build(
      settings: settings,
      assistant: Assistant(id: 'b'),
      model: model,
      history: [ChatMessage.text(Role.user, 'dragon')],
    );
    expect(unlinked.any((m) => m.text.contains('LORE_')), isFalse);

    final bookOff = PromptBuilder.build(
      settings: settings.copyWith(lorebooks: [book.copyWith(enabled: false)]),
      assistant: linked,
      model: model,
      history: [ChatMessage.text(Role.user, 'dragon')],
    );
    expect(bookOff.any((m) => m.text.contains('LORE_')), isFalse);
  });

  test('modes toggled for one chat and always-on modes are injected; memories are listed', () {
    final settings = AppSettings.initial().copyWith(
      modes: [
        ModeInjection(id: 'chat', name: 'Chat mode', content: 'MODE_CHAT'),
        ModeInjection(id: 'always', name: 'Always', content: 'MODE_ALWAYS'),
        ModeInjection(id: 'off', name: 'Off', content: 'MODE_OFF'),
      ],
    );
    final out = PromptBuilder.build(
      settings: settings,
      assistant: Assistant(id: 'a', modeIds: const {'always'}),
      model: model,
      history: [ChatMessage.text(Role.user, 'hi')],
      extraModeIds: const {'chat'},
      memories: [MemoryItem(id: 'abcdef0123', content: 'MEMORY_FACT')],
    );
    final sys = system(out);
    expect(sys, contains('MODE_CHAT'));
    expect(sys, contains('MODE_ALWAYS'));
    expect(sys, isNot(contains('MODE_OFF')));
    expect(sys, contains('[abcdef01] MEMORY_FACT'));
  });
}
