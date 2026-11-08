import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/i18n.dart';
import '../../data/config_transfer.dart';
import '../../state/app_state.dart';
import '../../state/settings_store.dart';
import '../widgets/common.dart';
import 'qr_pages.dart';

/// Shows the current configuration as a looping sequence of QR codes.
class ConfigQrSendPage extends StatefulWidget {
  const ConfigQrSendPage({super.key, required this.includeSecrets});
  final bool includeSecrets;

  @override
  State<ConfigQrSendPage> createState() => _ConfigQrSendPageState();
}

class _ConfigQrSendPageState extends State<ConfigQrSendPage> {
  late final List<String> _frames = ConfigTransfer.encode(
    context.read<SettingsStore>().value,
    includeSecrets: widget.includeSecrets,
  );
  Timer? _timer;
  int _index = 0;
  bool _paused = false;
  double _speed = 1;

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  void _schedule() {
    _timer?.cancel();
    if (_frames.length < 2 || _paused) return;
    _timer = Timer.periodic(Duration(milliseconds: (650 / _speed).round()), (_) {
      if (mounted) setState(() => _index = (_index + 1) % _frames.length);
    });
  }

  void _step(int delta) => setState(() => _index = (_index + delta + _frames.length) % _frames.length);

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final summary = transferSummary(context.read<SettingsStore>().value);
    final side = MediaQuery.sizeOf(context).shortestSide.clamp(240.0, 440.0) - 68;
    return Scaffold(
      appBar: AppBar(title: Text(t('展示配置二维码', 'Show config QR'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
        children: [
          Text(
            t(
              '在另一台设备打开 设置 → 备份与恢复 → 扫码接收配置，对准下方二维码，直到进度走满。',
              'On the other device open Settings → Backup & restore → Scan config and hold it on this code until the progress fills.',
            ),
            style: tt.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          Center(
            child: Container(
              key: const ValueKey('config-qr'),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(color: scheme.shadow.withValues(alpha: 0.12), blurRadius: 24, offset: const Offset(0, 8)),
                ],
              ),
              child: QrImageView(
                data: _frames[_index],
                size: side,
                padding: EdgeInsets.zero,
                backgroundColor: Colors.white,
                errorCorrectionLevel: QrErrorCorrectLevel.L,
                semanticsLabel: 'config qr ${_index + 1}/${_frames.length}',
              ),
            ),
          ),
          const SizedBox(height: 14),
          _FrameDots(count: _frames.length, current: _index),
          const SizedBox(height: 6),
          Center(
            child: Text(
              _frames.length == 1
                  ? t('只有 1 张，扫一次即可', 'A single code')
                  : t(
                      '第 ${_index + 1} / ${_frames.length} 张 · 自动循环',
                      'Code ${_index + 1} of ${_frames.length} · looping',
                    ),
              key: const ValueKey('config-qr-index'),
              style: tt.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          if (_frames.length > 1) ...[
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  tooltip: t('上一张', 'Previous'),
                  onPressed: () => _step(-1),
                  icon: const Icon(Icons.skip_previous_rounded),
                ),
                FilledButton.tonalIcon(
                  onPressed: () {
                    setState(() => _paused = !_paused);
                    _schedule();
                  },
                  icon: Icon(_paused ? Icons.play_arrow_rounded : Icons.pause_rounded),
                  label: Text(_paused ? t('继续', 'Resume') : t('暂停', 'Pause')),
                ),
                IconButton(
                  tooltip: t('下一张', 'Next'),
                  onPressed: () => _step(1),
                  icon: const Icon(Icons.skip_next_rounded),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Center(
              child: SegmentedButton<double>(
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(value: 0.6, label: Text(t('慢', 'Slow'))),
                  ButtonSegment(value: 1, label: Text(t('标准', 'Normal'))),
                  ButtonSegment(value: 1.6, label: Text(t('快', 'Fast'))),
                ],
                selected: {_speed},
                onSelectionChanged: (v) {
                  setState(() => _speed = v.first);
                  _schedule();
                },
              ),
            ),
          ],
          const SizedBox(height: 12),
          SettingsGroup(
            title: t('包含内容', 'Included'),
            footer: widget.includeSecrets
                ? t(
                    '二维码里包含 API Key 等密钥，只给自己的设备扫描，不要截图分享。',
                    'These codes contain API keys and passwords. Scan them only with your own devices and do not share screenshots.',
                  )
                : t('未包含密钥。对方设备上已有的同一供应商密钥会被保留。', 'Secrets are left out. Keys already on the other device are kept.'),
            children: [
              ListTile(
                leading: const IconBadge(Icons.hub_outlined),
                title: Text(
                  t(
                    '${summary.providers} 个启用的供应商 · ${summary.models} 个模型',
                    '${summary.providers} enabled providers · ${summary.models} models',
                  ),
                ),
              ),
              ListTile(
                leading: const IconBadge(Icons.face_retouching_natural_outlined),
                title: Text(
                  t(
                    '${summary.assistants} 个助手 · ${summary.mcp} 个 MCP 服务器',
                    '${summary.assistants} assistants · ${summary.mcp} MCP servers',
                  ),
                ),
              ),
              ListTile(
                leading: const IconBadge(Icons.menu_book_outlined),
                title: Text(
                  t(
                    '${summary.lorebooks} 本世界书 · ${summary.quick} 条快捷短语',
                    '${summary.lorebooks} lorebooks · ${summary.quick} quick messages',
                  ),
                ),
              ),
              ListTile(
                leading: IconBadge(Icons.block_rounded, color: scheme.onSurfaceVariant),
                title: Text(t('不含聊天记录、记忆和附件', 'Chats, memories and files are not included')),
                subtitle: Text(t('需要完整迁移请用备份文件', 'Use a backup file to move everything')),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _FrameDots extends StatelessWidget {
  const _FrameDots({required this.count, required this.current});
  final int count;
  final int current;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (count > 24) {
      return LinearProgressIndicator(value: (current + 1) / count, borderRadius: BorderRadius.circular(4));
    }
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 5,
      runSpacing: 5,
      children: [
        for (var i = 0; i < count; i++)
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: i == current ? 18 : 7,
            height: 7,
            decoration: BoxDecoration(
              color: i == current ? scheme.primary : scheme.outlineVariant,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
      ],
    );
  }
}

/// Scans the looping config codes, then asks before applying them.
class ConfigQrReceivePage extends StatefulWidget {
  const ConfigQrReceivePage({super.key});

  @override
  State<ConfigQrReceivePage> createState() => _ConfigQrReceivePageState();
}

class _ConfigQrReceivePageState extends State<ConfigQrReceivePage> {
  final _controller = MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  final _assembler = TransferAssembler();
  bool _done = false;
  String? _hint;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    var changed = false;
    for (final raw in capture.barcodes.map((b) => b.rawValue).whereType<String>()) {
      if (!ConfigTransfer.looksLikeFrame(raw)) {
        if (_hint == null) setState(() => _hint = t('这不是 MewHub 配置二维码', 'Not a MewHub config code'));
        continue;
      }
      if (_assembler.add(raw)) changed = true;
    }
    if (!changed) return;
    HapticFeedback.selectionClick();
    setState(() => _hint = null);
    if (_assembler.isComplete) _finish();
  }

  Future<void> _finish() async {
    _done = true;
    await _controller.stop();
    final Map<String, dynamic> json;
    try {
      json = _assembler.decode();
    } catch (e) {
      _assembler.reset();
      _done = false;
      await _controller.start();
      if (mounted) setState(() => _hint = t('数据校验失败，请重新扫描：$e', 'Data check failed, scan again: $e'));
      return;
    }
    if (!mounted) return;
    final applied = await confirmAndApplyTransfer(context, json);
    if (!mounted) return;
    if (applied) {
      Navigator.of(context).pop(true);
    } else {
      _assembler.reset();
      _done = false;
      setState(() {});
      await _controller.start();
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final box = size.shortestSide * 0.72;
    final window = Rect.fromCenter(center: Offset(size.width / 2, size.height / 2 - 60), width: box, height: box);
    final count = _assembler.count;
    final got = _assembler.receivedIndices;
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        title: Text(t('扫码接收配置', 'Scan config')),
        actions: [
          IconButton(
            tooltip: t('手电筒', 'Torch'),
            icon: const Icon(Icons.flashlight_on_rounded),
            onPressed: () => _controller.toggleTorch(),
          ),
        ],
      ),
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller,
            scanWindow: window,
            onDetect: _onDetect,
            errorBuilder: (context, error) => Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  t(
                    '无法打开相机：${error.errorCode.name}\n请在系统设置中允许 MewHub 使用相机。',
                    'Cannot open camera: ${error.errorCode.name}\nAllow camera access for MewHub in system settings.',
                  ),
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70),
                ),
              ),
            ),
          ),
          IgnorePointer(
            child: CustomPaint(size: Size.infinite, painter: MewScanOverlay(window)),
          ),
          IgnorePointer(child: ScanLine(window: window)),
          Positioned(
            left: 24,
            right: 24,
            top: window.bottom + 24,
            child: Column(
              children: [
                Text(
                  count == 0
                      ? t('对准另一台设备上的配置二维码', 'Point at the config code on the other device')
                      : t('已收到 ${got.length} / $count 张，保持对准', '${got.length} of $count received, keep pointing'),
                  key: const ValueKey('config-scan-progress'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                if (count > 0)
                  TweenAnimationBuilder<double>(
                    tween: Tween(end: _assembler.progress),
                    duration: const Duration(milliseconds: 250),
                    builder: (context, v, _) => LinearProgressIndicator(
                      value: v,
                      minHeight: 6,
                      borderRadius: BorderRadius.circular(4),
                      backgroundColor: Colors.white24,
                    ),
                  ),
                if (count > 1 && count <= 40) ...[
                  const SizedBox(height: 10),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 4,
                    runSpacing: 4,
                    children: [
                      for (var i = 1; i <= count; i++)
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          width: 9,
                          height: 9,
                          decoration: BoxDecoration(
                            color: got.contains(i) ? Theme.of(context).colorScheme.primary : Colors.white24,
                            shape: BoxShape.circle,
                          ),
                        ),
                    ],
                  ),
                ],
                if (_hint != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _hint!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Color(0xFFFFB4A8)),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Shows what a received config contains and applies it after confirmation.
/// Returns true when the settings were replaced.
Future<bool> confirmAndApplyTransfer(BuildContext context, Map<String, dynamic> json) async {
  final store = context.read<SettingsStore>();
  final app = context.read<AppState>();
  final incoming = mergeTransferredSettings(json, store.value, keepLocalSecrets: true);
  final s = transferSummary(incoming);
  final withSecrets = json['_transfer'] is Map && (json['_transfer'] as Map)['secrets'] == true;
  final ok = await confirm(
    context,
    t('导入这份配置？', 'Import this configuration?'),
    message: [
      t('• ${s.providers} 个启用的供应商，${s.models} 个模型', '• ${s.providers} enabled providers, ${s.models} models'),
      t('• ${s.assistants} 个助手，${s.mcp} 个 MCP 服务器', '• ${s.assistants} assistants, ${s.mcp} MCP servers'),
      t('• ${s.lorebooks} 本世界书，${s.quick} 条快捷短语', '• ${s.lorebooks} lorebooks, ${s.quick} quick messages'),
      withSecrets
          ? t('• 包含 API Key 等密钥', '• Includes API keys and passwords')
          : t('• 不含密钥，本机已有的密钥会保留', '• No secrets; keys on this device are kept'),
      '',
      t(
        '本机的设置会被替换，聊天记录、记忆和附件不受影响。',
        'Settings on this device are replaced. Chats, memories and files stay as they are.',
      ),
    ].join('\n'),
    ok: t('导入', 'Import'),
  );
  if (!ok) return false;
  await app.mcp.closeAll();
  store.replace(incoming);
  await store.flush();
  app.newChat();
  if (context.mounted) toast(context, t('配置已导入', 'Configuration imported'));
  return true;
}
