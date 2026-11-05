import 'package:flutter/material.dart';

import '../../ai/model_registry.dart';
import '../../ai/provider_config.dart';
import '../../core/i18n.dart';

/// Opens the model editor; returns the edited model or null.
Future<ModelConfig?> editModel(BuildContext context, ModelConfig? model) => showModalBottomSheet<ModelConfig>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (ctx) => _ModelEditSheet(model: model),
);

class _ModelEditSheet extends StatefulWidget {
  const _ModelEditSheet({this.model});
  final ModelConfig? model;

  @override
  State<_ModelEditSheet> createState() => _ModelEditSheetState();
}

class _ModelEditSheetState extends State<_ModelEditSheet> {
  late ModelConfig _m = widget.model ?? ModelConfig(modelId: '');
  late final _id = TextEditingController(text: _m.modelId);
  late final _name = TextEditingController(text: widget.model == null ? '' : _m.displayName);
  late final _ctx = TextEditingController(text: '${_m.contextLength}');
  late List<(TextEditingController, TextEditingController)> _headers = [
    for (final h in _m.headers) (TextEditingController(text: h.key), TextEditingController(text: h.value)),
  ];
  late List<(TextEditingController, TextEditingController)> _bodies = [
    for (final b in _m.bodies) (TextEditingController(text: b.key), TextEditingController(text: b.value)),
  ];

  @override
  void dispose() {
    _id.dispose();
    _name.dispose();
    _ctx.dispose();
    for (final p in [..._headers, ..._bodies]) {
      p.$1.dispose();
      p.$2.dispose();
    }
    super.dispose();
  }

  void _guess() {
    final g = ModelRegistry.guess(_id.text.trim());
    setState(
      () => _m = _m.copyWith(
        type: g.type,
        input: g.input,
        output: g.output,
        abilities: g.abilities,
        contextLength: g.contextLength,
      ),
    );
    _ctx.text = '${g.contextLength}';
  }

  void _done() {
    final id = _id.text.trim();
    if (id.isEmpty) return;
    Navigator.pop(
      context,
      _m.copyWith(
        modelId: id,
        displayName: _name.text.trim().isEmpty ? id : _name.text.trim(),
        contextLength: int.tryParse(_ctx.text) ?? _m.contextLength,
        headers: [
          for (final h in _headers)
            if (h.$1.text.trim().isNotEmpty) KeyValue(h.$1.text.trim(), h.$2.text),
        ],
        bodies: [
          for (final b in _bodies)
            if (b.$1.text.trim().isNotEmpty) CustomBody(b.$1.text.trim(), b.$2.text),
        ],
      ),
    );
  }

  Set<T> _toggle<T>(Set<T> s, T v, bool on) => on ? {...s, v} : ({...s}..remove(v));

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget section(String s) => Padding(
      padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
      child: Text(
        s,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(color: scheme.primary, fontWeight: FontWeight.w700),
      ),
    );
    Widget chip(String label, bool on, ValueChanged<bool> f) =>
        FilterChip(label: Text(label), selected: on, onSelected: f);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.85,
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                children: [
                  Text(
                    widget.model == null ? t('添加模型', 'Add model') : t('编辑模型', 'Edit model'),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _id,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: t('模型 ID', 'Model ID'),
                      hintText: 'gpt-4.1 / claude-sonnet-4-5 / gemini-2.5-pro',
                      suffixIcon: IconButton(
                        tooltip: t('自动识别能力', 'Detect capabilities'),
                        icon: const Icon(Icons.auto_fix_high_rounded),
                        onPressed: _guess,
                      ),
                    ),
                    onSubmitted: (_) => _guess(),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _name,
                    decoration: InputDecoration(labelText: t('显示名称', 'Display name')),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _ctx,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(labelText: t('上下文长度 (tokens)', 'Context length (tokens)')),
                  ),
                  section(t('类型', 'Type')),
                  SegmentedButton<ModelType>(
                    segments: [
                      ButtonSegment(value: ModelType.chat, label: Text(t('对话', 'Chat'))),
                      ButtonSegment(value: ModelType.image, label: Text(t('绘图', 'Image'))),
                      ButtonSegment(value: ModelType.embedding, label: Text(t('嵌入', 'Embed'))),
                    ],
                    selected: {_m.type},
                    onSelectionChanged: (v) => setState(() => _m = _m.copyWith(type: v.first)),
                  ),
                  section(t('能力', 'Capabilities')),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      chip(
                        t('图片输入', 'Image input'),
                        _m.vision,
                        (v) => setState(() => _m = _m.copyWith(input: _toggle(_m.input, Modality.image, v))),
                      ),
                      chip(
                        t('图片输出', 'Image output'),
                        _m.imageOutput,
                        (v) => setState(() => _m = _m.copyWith(output: _toggle(_m.output, Modality.image, v))),
                      ),
                      chip(
                        t('工具调用', 'Tool use'),
                        _m.tools,
                        (v) => setState(() => _m = _m.copyWith(abilities: _toggle(_m.abilities, ModelAbility.tool, v))),
                      ),
                      chip(
                        t('推理', 'Reasoning'),
                        _m.reasoning,
                        (v) => setState(
                          () => _m = _m.copyWith(abilities: _toggle(_m.abilities, ModelAbility.reasoning, v)),
                        ),
                      ),
                    ],
                  ),
                  section(t('内置工具（服务端执行）', 'Built-in tools (server side)')),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      chip(
                        t('内置联网搜索', 'Native web search'),
                        _m.builtInTools.contains(BuiltInTool.search),
                        (v) => setState(
                          () => _m = _m.copyWith(builtInTools: _toggle(_m.builtInTools, BuiltInTool.search, v)),
                        ),
                      ),
                      chip(
                        t('URL 上下文 (Gemini)', 'URL context (Gemini)'),
                        _m.builtInTools.contains(BuiltInTool.urlContext),
                        (v) => setState(
                          () => _m = _m.copyWith(builtInTools: _toggle(_m.builtInTools, BuiltInTool.urlContext, v)),
                        ),
                      ),
                    ],
                  ),
                  section(t('自定义请求头', 'Custom headers')),
                  ..._kvEditor(_headers, 'X-Header', 'value'),
                  TextButton.icon(
                    onPressed: () =>
                        setState(() => _headers = [..._headers, (TextEditingController(), TextEditingController())]),
                    icon: const Icon(Icons.add_rounded),
                    label: Text(t('添加请求头', 'Add header')),
                  ),
                  section(
                    t('自定义请求体（JSON 值，支持 a.b 路径，null 表示删除）', 'Custom body (JSON values, a.b paths, null removes)'),
                  ),
                  ..._kvEditor(_bodies, 'top_k', '20'),
                  TextButton.icon(
                    onPressed: () =>
                        setState(() => _bodies = [..._bodies, (TextEditingController(), TextEditingController())]),
                    icon: const Icon(Icons.add_rounded),
                    label: Text(t('添加字段', 'Add field')),
                  ),
                ],
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(onPressed: _done, child: Text(t('保存', 'Save'))),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _kvEditor(List<(TextEditingController, TextEditingController)> list, String k, String v) => [
    for (var i = 0; i < list.length; i++)
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: list[i].$1,
                decoration: InputDecoration(hintText: k),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: list[i].$2,
                decoration: InputDecoration(hintText: v),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.remove_circle_outline_rounded),
              onPressed: () => setState(() => list.removeAt(i)),
            ),
          ],
        ),
      ),
  ];
}
