import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/i18n.dart';
import '../../data/network_settings.dart';
import '../../state/settings_store.dart';
import '../widgets/common.dart';

/// Timeout and retry controls shared by the existing Network settings page.
class NetworkOptions extends StatelessWidget {
  const NetworkOptions({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<SettingsStore>();
    final settings = store.value;
    final network = settings.network;
    void update(NetworkSettings Function(NetworkSettings) change) =>
        store.update((s) => s.copyWith(network: change(s.network)));

    Widget number({
      required String title,
      required String description,
      required int value,
      required int min,
      required int max,
      required ValueChanged<int> onChanged,
      bool enabled = true,
      bool count = false,
    }) => ListTile(
      enabled: enabled,
      title: Text(title),
      subtitle: Text(description),
      trailing: Text(count ? t('$value 次', '$value times') : t('$value 秒', '$value s')),
      onTap: !enabled
          ? null
          : () async {
              final result = await showDialog<int>(
                context: context,
                builder: (_) => _NumberDialog(title: title, value: value, min: min, max: max, count: count),
              );
              if (result != null && context.mounted) onChanged(result);
            },
    );

    return Column(
      children: [
        SettingsGroup(
          index: 1,
          title: t('请求超时', 'Request timeouts'),
          footer: t(
            '适用于本应用的 API 请求。响应超时按连续无数据的时间计算，持续输出不会被总时长截断；图片生成等专用请求保留各自的等待时间。',
            'Applies to API requests. The response timeout measures inactivity, not total generation time. Specialized requests such as image generation keep their own timeout.',
          ),
          children: [
            number(
              title: t('连接超时', 'Connection timeout'),
              description: t('建立网络连接的最长等待时间', 'Maximum wait to establish a connection'),
              value: network.connectTimeoutSeconds,
              min: 5,
              max: 120,
              onChanged: (v) => update((n) => n.copyWith(connectTimeoutSeconds: v)),
            ),
            number(
              title: t('响应超时', 'Response timeout'),
              description: t(
                '等待响应或流式输出停滞的最长时间；深度思考模型可适当调高',
                'Maximum wait for a response or stalled stream; increase for deep reasoning models',
              ),
              value: network.responseTimeoutSeconds,
              min: 10,
              max: 1800,
              onChanged: (v) => update((n) => n.copyWith(responseTimeoutSeconds: v)),
            ),
          ],
        ),
        SettingsGroup(
          index: 2,
          title: t('失败自动重试', 'Automatic retries'),
          footer: t(
            '仅重试聊天生成中尚未收到内容的临时故障。已收到内容、鉴权失败或请求参数错误时不自动重发；点击停止会同时取消重试等待。',
            'Retries chat generation only before any content arrives. Partial replies, authentication failures and invalid requests are not replayed. Stop also cancels the retry wait.',
          ),
          children: [
            SwitchListTile(
              secondary: const IconBadge(Icons.replay_rounded),
              title: Text(t('失败自动重试', 'Auto retry')),
              subtitle: Text(
                settings.autoRetry && network.maxRetries > 0
                    ? t('失败后最多重试 ${network.maxRetries} 次', 'Up to ${network.maxRetries} retries after failure')
                    : t('失败后直接显示错误', 'Show the error immediately after failure'),
              ),
              value: settings.autoRetry,
              onChanged: (v) => store.update((s) => s.copyWith(autoRetry: v)),
            ),
            number(
              title: t('最大重试次数', 'Maximum retries'),
              description: t('不含首次请求；设为 0 时不重试', 'Excludes the initial request; 0 disables retries'),
              value: network.maxRetries,
              min: 0,
              max: 20,
              count: true,
              enabled: settings.autoRetry,
              onChanged: (v) => update((n) => n.copyWith(maxRetries: v)),
            ),
            number(
              title: t('初始重试间隔', 'Initial retry delay'),
              description: t('首次失败后等待多久再试', 'Wait before the first retry'),
              value: network.retryDelaySeconds,
              min: 1,
              max: 60,
              enabled: settings.autoRetry,
              onChanged: (v) => update((n) => n.copyWith(retryDelaySeconds: v)),
            ),
            ExpansionTile(
              title: Text(t('更多重试设置', 'More retry options')),
              children: [
                SwitchListTile(
                  title: Text(t('逐步延长重试间隔', 'Exponential backoff')),
                  subtitle: Text(t('每次失败后间隔翻倍，减少持续请求', 'Double the delay after each failure')),
                  value: network.exponentialBackoff,
                  onChanged: settings.autoRetry ? (v) => update((n) => n.copyWith(exponentialBackoff: v)) : null,
                ),
                number(
                  title: t('单次等待上限', 'Maximum retry delay'),
                  description: t('限制每次重试前的等待时间', 'Limit the wait before each retry'),
                  value: network.maxRetryDelaySeconds,
                  min: network.retryDelaySeconds,
                  max: 300,
                  enabled: settings.autoRetry,
                  onChanged: (v) => update((n) => n.copyWith(maxRetryDelaySeconds: v)),
                ),
                SwitchListTile(
                  title: Text(t('限流时重试（429）', 'Retry rate limits (429)')),
                  value: network.retryOnRateLimit,
                  onChanged: settings.autoRetry ? (v) => update((n) => n.copyWith(retryOnRateLimit: v)) : null,
                ),
                SwitchListTile(
                  title: Text(t('服务器错误时重试（5xx）', 'Retry server errors (5xx)')),
                  value: network.retryOnServerError,
                  onChanged: settings.autoRetry ? (v) => update((n) => n.copyWith(retryOnServerError: v)) : null,
                ),
                SwitchListTile(
                  title: Text(t('遵循服务器建议等待时间', 'Respect Retry-After')),
                  subtitle: Text(
                    t('服务器要求等待超过上限时直接显示错误', 'Show the error if the server asks to wait longer than your limit'),
                  ),
                  value: network.respectRetryAfter,
                  onChanged: settings.autoRetry ? (v) => update((n) => n.copyWith(respectRetryAfter: v)) : null,
                ),
              ],
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          child: TextButton.icon(
            icon: const Icon(Icons.restore_rounded),
            label: Text(t('恢复超时与重试默认设置', 'Reset timeouts and retries')),
            onPressed: () async {
              if (await confirm(
                context,
                t('恢复默认设置？', 'Restore defaults?'),
                message: t(
                  '连接 30 秒、响应 120 秒、最多重试 5 次。代理和 User-Agent 保持不变。',
                  '30 s connection, 120 s response, up to 5 retries. Proxy and User-Agent stay unchanged.',
                ),
              )) {
                store.update((s) => s.copyWith(autoRetry: true, network: const NetworkSettings()));
              }
            },
          ),
        ),
      ],
    );
  }
}

class _NumberDialog extends StatefulWidget {
  const _NumberDialog({
    required this.title,
    required this.value,
    required this.min,
    required this.max,
    required this.count,
  });
  final String title;
  final int value;
  final int min;
  final int max;
  final bool count;

  @override
  State<_NumberDialog> createState() => _NumberDialogState();
}

class _NumberDialogState extends State<_NumberDialog> {
  final _form = GlobalKey<FormState>();
  late final _controller = TextEditingController(text: '${widget.value}');

  void _save() {
    if (_form.currentState!.validate()) Navigator.pop(context, int.parse(_controller.text));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: Form(
      key: _form,
      child: TextFormField(
        controller: _controller,
        autofocus: true,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(4)],
        decoration: InputDecoration(
          suffixText: widget.count ? t('次', 'times') : t('秒', 'seconds'),
          helperText: t('范围：${widget.min}–${widget.max}', 'Range: ${widget.min}–${widget.max}'),
        ),
        validator: (text) {
          final value = int.tryParse(text ?? '');
          return value == null || value < widget.min || value > widget.max
              ? t('请输入 ${widget.min}–${widget.max} 之间的整数', 'Enter an integer from ${widget.min} to ${widget.max}')
              : null;
        },
        onFieldSubmitted: (_) => _save(),
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: Text(t('取消', 'Cancel'))),
      FilledButton(onPressed: _save, child: Text(t('保存', 'Save'))),
    ],
  );
}
