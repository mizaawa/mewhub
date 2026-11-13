import 'package:flutter/material.dart';
import 'package:re_highlight/languages/all.dart';
import 'package:re_highlight/re_highlight.dart';
import 'package:re_highlight/styles/atom-one-dark.dart';
import 'package:re_highlight/styles/github.dart';

import '../../core/i18n.dart';
import '../theme.dart';
import 'common.dart';

final Highlight _hl = Highlight()..registerLanguages(builtinAllLanguages);

const _aliases = {
  'js': 'javascript',
  'ts': 'typescript',
  'py': 'python',
  'sh': 'bash',
  'shell': 'bash',
  'zsh': 'bash',
  'kt': 'kotlin',
  'rs': 'rust',
  'yml': 'yaml',
  'md': 'markdown',
  'html': 'xml',
  'vue': 'xml',
  'c++': 'cpp',
  'cs': 'csharp',
  'objc': 'objectivec',
  'golang': 'go',
  'ps1': 'powershell',
  'jsonc': 'json',
};

class CodeBlock extends StatefulWidget {
  const CodeBlock({super.key, required this.code, this.language, this.wrap = false, this.lineNumbers = false});
  final String code;
  final String? language;
  final bool wrap;
  final bool lineNumbers;

  @override
  State<CodeBlock> createState() => _CodeBlockState();
}

class _CodeBlockState extends State<CodeBlock> {
  bool _collapsed = false;
  bool _copied = false;
  late bool _wrap = widget.wrap;

  String? get _lang {
    final l = widget.language?.trim().toLowerCase();
    if (l == null || l.isEmpty) return null;
    final name = _aliases[l] ?? l;
    return builtinAllLanguages.containsKey(name) ? name : null;
  }

  TextSpan _highlight(TextStyle base, bool dark) {
    final lang = _lang;
    if (lang == null || widget.code.length > 60000) return TextSpan(text: widget.code, style: base);
    try {
      final result = _hl.highlight(code: widget.code, language: lang);
      final renderer = TextSpanRenderer(base, dark ? atomOneDarkTheme : githubTheme);
      result.render(renderer);
      return renderer.span ?? TextSpan(text: widget.code, style: base);
    } catch (_) {
      return TextSpan(text: widget.code, style: base);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final bg = MewThemeColors.of(context).codeSurface;
    final base = TextStyle(
      fontFamily: 'monospace',
      fontFamilyFallback: const ['Menlo', 'Courier'],
      fontSize: 13,
      height: 1.5,
      color: scheme.onSurface,
    );
    final lines = widget.code.split('\n');
    Widget body = SelectableText.rich(_highlight(base, dark));
    if (widget.lineNumbers) {
      body = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            List.generate(lines.length, (i) => '${i + 1}').join('\n'),
            style: base.copyWith(color: scheme.onSurfaceVariant.withValues(alpha: 0.6)),
            textAlign: TextAlign.right,
          ),
          const SizedBox(width: 12),
          if (_wrap) Expanded(child: body) else body,
        ],
      );
    }
    if (!_wrap) body = SingleChildScrollView(scrollDirection: Axis.horizontal, child: body);

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(14)),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(14, 4, 4, 4),
            color: scheme.onSurface.withValues(alpha: 0.03),
            child: Row(
              children: [
                Text(
                  widget.language?.isNotEmpty == true ? widget.language! : 'text',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
                ),
                const Spacer(),
                _HeaderButton(
                  icon: _wrap ? Icons.wrap_text_rounded : Icons.notes_rounded,
                  tooltip: t('自动换行', 'Wrap'),
                  onTap: () => setState(() => _wrap = !_wrap),
                ),
                _HeaderButton(
                  icon: _collapsed ? Icons.unfold_more_rounded : Icons.unfold_less_rounded,
                  tooltip: _collapsed ? t('展开', 'Expand') : t('折叠', 'Collapse'),
                  onTap: () => setState(() => _collapsed = !_collapsed),
                ),
                _HeaderButton(
                  icon: _copied ? Icons.check_rounded : Icons.copy_rounded,
                  tooltip: t('复制', 'Copy'),
                  onTap: () async {
                    await copyText(context, widget.code);
                    if (!mounted) return;
                    setState(() => _copied = true);
                    await Future<void>.delayed(const Duration(seconds: 2));
                    if (mounted) setState(() => _copied = false);
                  },
                ),
              ],
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: _collapsed
                ? const SizedBox(width: double.infinity)
                : Padding(padding: const EdgeInsets.fromLTRB(14, 10, 14, 12), child: body),
          ),
        ],
      ),
    );
  }
}

class _HeaderButton extends StatelessWidget {
  const _HeaderButton({required this.icon, required this.tooltip, required this.onTap});
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => IconButton(
    visualDensity: VisualDensity.compact,
    iconSize: 17,
    tooltip: tooltip,
    onPressed: onTap,
    icon: AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
      child: Icon(icon, key: ValueKey(icon)),
    ),
  );
}
