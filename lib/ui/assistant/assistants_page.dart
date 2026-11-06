import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/attachments.dart';
import '../../core/i18n.dart';
import '../../core/paths.dart';
import '../../data/assistant.dart';
import '../../data/character_card.dart';
import '../../state/app_state.dart';
import '../../state/settings_store.dart';
import '../widgets/common.dart';
import '../widgets/motion.dart';
import 'assistant_edit_page.dart';

class AssistantsPage extends StatelessWidget {
  const AssistantsPage({super.key});

  Future<void> _importCard(BuildContext context) async {
    final store = context.read<SettingsStore>();
    try {
      final files = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['png', 'json']);
      if (files.isEmpty) return;
      final f = files.first;
      final bytes = await f.readAsBytes();
      String? avatar;
      if (f.name.toLowerCase().endsWith('.png')) avatar = await Attachments.storeBytes(bytes, 'png');
      final r = CharacterCardImporter.parse(bytes, avatarPath: avatar);
      store.upsertAssistant(r.assistant);
      if (r.lorebook != null) store.upsertLorebook(r.lorebook!);
      if (context.mounted) {
        toast(context, t('已导入角色「${r.assistant.name}」', 'Imported "${r.assistant.name}"'));
      }
    } catch (e) {
      if (context.mounted) toast(context, t('导入失败：$e', 'Import failed: $e'), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<SettingsStore>();
    final list = store.value.assistants;
    return Scaffold(
      appBar: AppBar(
        title: Text(t('助手', 'Assistants')),
        actions: [
          IconButton(
            tooltip: t('导入角色卡', 'Import character card'),
            icon: const Icon(Icons.file_download_outlined),
            onPressed: () => _importCard(context),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add_rounded),
        label: Text(t('新建', 'New')),
        onPressed: () {
          final a = Assistant(name: t('新助手', 'New assistant'), avatar: '✨');
          store.upsertAssistant(a);
          Navigator.of(context).push(MaterialPageRoute(builder: (_) => AssistantEditPage(assistantId: a.id)));
        },
      ),
      body: GridView.builder(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 240,
          mainAxisExtent: 168,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
        ),
        itemCount: list.length,
        itemBuilder: (context, i) => EntranceFx(
          index: i,
          child: _AssistantCard(a: list[i]),
        ),
      ),
    );
  }
}

class _AssistantCard extends StatelessWidget {
  const _AssistantCard({required this.a});
  final Assistant a;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final store = context.read<SettingsStore>();
    final current = store.value.currentAssistantId == a.id;
    return Pressable(
      scale: 0.97,
      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => AssistantEditPage(assistantId: a.id))),
      onLongPress: () => _menu(context, store),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 280),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLowest,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: current ? scheme.primary : scheme.outlineVariant, width: current ? 1.6 : 1),
          boxShadow: current
              ? [BoxShadow(color: scheme.primary.withValues(alpha: 0.15), blurRadius: 18, offset: const Offset(0, 6))]
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Hero(
                  tag: 'assistant-${a.id}',
                  child: AvatarView(value: a.avatar, fallback: a.name, size: 44),
                ),
                const Spacer(),
                if (current) Icon(Icons.check_circle_rounded, color: scheme.primary, size: 20),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              a.name.isEmpty ? 'MewBot' : a.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            Expanded(
              child: Text(
                a.systemPrompt.isEmpty ? t('没有系统提示词', 'No system prompt') : a.systemPrompt,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _menu(BuildContext context, SettingsStore store) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.chat_bubble_outline_rounded),
              title: Text(t('用它开始新对话', 'Start a chat')),
              onTap: () {
                Navigator.pop(ctx);
                context.read<AppState>().newChat(assistantId: a.id);
                Navigator.of(context).popUntil((r) => r.isFirst);
              },
            ),
            ListTile(
              leading: const Icon(Icons.copy_all_rounded),
              title: Text(t('复制', 'Duplicate')),
              onTap: () {
                Navigator.pop(ctx);
                store.upsertAssistant(Assistant.fromJson({...a.toJson(), 'id': null, 'name': '${a.name} (copy)'}));
              },
            ),
            if (store.value.assistants.length > 1)
              ListTile(
                leading: Icon(Icons.delete_outline_rounded, color: Theme.of(ctx).colorScheme.error),
                title: Text(t('删除', 'Delete'), style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
                onTap: () async {
                  Navigator.pop(ctx);
                  final ok = await confirm(
                    context,
                    t('删除助手「${a.name}」？', 'Delete "${a.name}"?'),
                    message: t('该助手下未置顶的对话也会被删除', "This assistant's unpinned chats are deleted too"),
                    destructive: true,
                  );
                  if (!ok || !context.mounted) return;
                  final app = context.read<AppState>();
                  await app.db.deleteConversationsOf(a.id);
                  store.removeAssistant(a.id);
                  if (a.avatarIsImage) {
                    try {
                      await File(AppPaths.resolve(a.avatar)).delete();
                    } catch (_) {}
                  }
                  await app.refreshList();
                },
              ),
          ],
        ),
      ),
    );
  }
}
