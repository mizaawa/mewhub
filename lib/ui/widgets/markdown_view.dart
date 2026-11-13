import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';

import '../theme.dart';
import 'code_block.dart';
import 'image_viewer.dart';

/// Markdown with code highlighting, LaTeX and tables.
class MarkdownView extends StatelessWidget {
  const MarkdownView({
    super.key,
    required this.data,
    this.latex = true,
    this.codeWrap = false,
    this.lineNumbers = false,
    this.selectable = false,
    this.fontScale = 1.0,
    this.fontFamily,
  });

  final String data;
  final bool latex;
  final bool codeWrap;
  final bool lineNumbers;
  final bool selectable;
  final double fontScale;
  final String? fontFamily;

  static final String _bs = String.fromCharCode(92);
  static final RegExp _displayParen = RegExp('${RegExp.escape('$_bs[')}([\\s\\S]+?)${RegExp.escape('$_bs]')}');
  static final RegExp _inlineParen = RegExp('${RegExp.escape('$_bs(')}([\\s\\S]+?)${RegExp.escape('$_bs)')}');

  /// Normalises backslash-bracket math delimiters to dollar signs.
  static String normalizeMath(String s) => s
      .replaceAllMapped(_displayParen, (m) => '\n\$\$${m.group(1)}\$\$\n')
      .replaceAllMapped(_inlineParen, (m) => '\$${m.group(1)}\$');

  MarkdownStyleSheet _sheet(ThemeData theme) {
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final body = theme.textTheme.bodyLarge!.copyWith(fontSize: 15.5 * fontScale, height: 1.62, fontFamily: fontFamily);
    return MarkdownStyleSheet.fromTheme(theme).copyWith(
      p: body,
      listBullet: body,
      h1: theme.textTheme.titleLarge?.copyWith(fontSize: 22 * fontScale, fontWeight: FontWeight.w700),
      h2: theme.textTheme.titleLarge?.copyWith(fontSize: 19 * fontScale, fontWeight: FontWeight.w700),
      h3: theme.textTheme.titleMedium?.copyWith(fontSize: 17 * fontScale, fontWeight: FontWeight.w700),
      h4: theme.textTheme.titleMedium?.copyWith(fontSize: 15.5 * fontScale),
      code: body.copyWith(
        fontFamily: 'monospace',
        fontFamilyFallback: const ['Menlo', 'Courier'],
        fontSize: 13.5 * fontScale,
        backgroundColor: scheme.primary.withValues(alpha: dark ? 0.18 : 0.10),
        color: MewThemeColors.resolve(theme).inlineCode,
      ),
      // The custom CodeBlock owns its surface and clipping. The markdown
      // package still decorates `pre`, which otherwise leaves a square halo.
      codeblockPadding: EdgeInsets.zero,
      codeblockDecoration: const BoxDecoration(),
      blockquoteDecoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.06),
        border: Border(left: BorderSide(color: scheme.primary.withValues(alpha: 0.6), width: 3)),
        borderRadius: const BorderRadius.horizontal(right: Radius.circular(10)),
      ),
      blockquotePadding: const EdgeInsets.fromLTRB(14, 8, 12, 8),
      tableBorder: TableBorder.all(color: scheme.outlineVariant, borderRadius: BorderRadius.circular(10)),
      tableHead: body.copyWith(fontWeight: FontWeight.w700),
      tableBody: body,
      tableCellsPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      tableHeadCellsDecoration: BoxDecoration(color: scheme.surfaceContainerHigh),
      tableColumnWidth: const IntrinsicColumnWidth(),
      tableScrollbarThumbVisibility: false,
      horizontalRuleDecoration: BoxDecoration(
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      a: body.copyWith(
        color: scheme.primary,
        decoration: TextDecoration.underline,
        decorationColor: scheme.primary.withValues(alpha: 0.4),
      ),
      blockSpacing: 10,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sheet = _sheet(theme);
    final text = latex ? normalizeMath(data) : data;
    return MarkdownBody(
      data: text,
      selectable: selectable,
      softLineBreak: true,
      styleSheet: sheet,
      extensionSet: md.ExtensionSet(
        [...md.ExtensionSet.gitHubFlavored.blockSyntaxes, if (latex) BlockMathSyntax()],
        [...md.ExtensionSet.gitHubFlavored.inlineSyntaxes, if (latex) InlineMathSyntax()],
      ),
      builders: {
        'pre': _CodeBuilder(wrap: codeWrap, lineNumbers: lineNumbers),
        if (latex) 'math': _MathBuilder(sheet.p!),
      },
      onTapLink: (text, href, title) {
        final u = href == null ? null : Uri.tryParse(href);
        if (u != null && (u.scheme == 'http' || u.scheme == 'https' || u.scheme == 'mailto')) {
          launchUrl(u, mode: LaunchMode.externalApplication);
        }
      },
      imageBuilder: (uri, title, alt) => NetworkImageTile(url: uri.toString()),
    );
  }
}

class _CodeBuilder extends MarkdownElementBuilder {
  _CodeBuilder({required this.wrap, required this.lineNumbers});
  final bool wrap;
  final bool lineNumbers;

  @override
  bool isBlockElement() => true;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final codeEl = element.children?.whereType<md.Element>().where((e) => e.tag == 'code').firstOrNull;
    final cls = codeEl?.attributes['class'] ?? '';
    final lang = cls.startsWith('language-') ? cls.substring(9) : null;
    var code = (codeEl ?? element).textContent;
    if (code.endsWith('\n')) code = code.substring(0, code.length - 1);
    return CodeBlock(code: code, language: lang, wrap: wrap, lineNumbers: lineNumbers);
  }
}

class _MathBuilder extends MarkdownElementBuilder {
  _MathBuilder(this.style);
  final TextStyle style;

  @override
  bool isBlockElement() => false;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final tex = element.textContent;
    final display = element.attributes['display'] == 'true';
    final math = Math.tex(
      tex,
      mathStyle: display ? MathStyle.display : MathStyle.text,
      textStyle: (parentStyle ?? style).copyWith(fontSize: (style.fontSize ?? 15) * (display ? 1.08 : 1.0)),
      onErrorFallback: (e) => Text(display ? '\$\$$tex\$\$' : '\$$tex\$', style: style),
    );
    if (!display) return math;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: math),
    );
  }
}

/// `$$ ... $$` on its own line(s).
class BlockMathSyntax extends md.BlockSyntax {
  @override
  RegExp get pattern => RegExp(r'^\s*\$\$');

  @override
  md.Node? parse(md.BlockParser parser) {
    final first = parser.current.content.trim();
    final buf = StringBuffer();
    final rest = first.substring(2);
    if (rest.endsWith(r'$$') && rest.length >= 2) {
      parser.advance();
      buf.write(rest.substring(0, rest.length - 2));
    } else {
      buf.writeln(rest);
      parser.advance();
      while (!parser.isDone) {
        final line = parser.current.content;
        final idx = line.indexOf(r'$$');
        if (idx >= 0) {
          buf.write(line.substring(0, idx));
          parser.advance();
          break;
        }
        buf.writeln(line);
        parser.advance();
      }
    }
    final el = md.Element('math', [md.Text(buf.toString().trim())]);
    el.attributes['display'] = 'true';
    return md.Element('p', [el]);
  }
}

/// Inline `$...$` (no leading/trailing space) and `$$...$$`.
class InlineMathSyntax extends md.InlineSyntax {
  InlineMathSyntax()
    : super(r'\$\$([^\$]+?)\$\$|\$(?!\s)((?:[^\$\n]|\\\$)+?)(?<![\s\\])\$(?!\d)', startCharacter: 0x24);

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final display = match.group(1) != null;
    final el = md.Element('math', [md.Text((match.group(1) ?? match.group(2) ?? '').trim())]);
    if (display) el.attributes['display'] = 'true';
    parser.addNode(el);
    return true;
  }
}
