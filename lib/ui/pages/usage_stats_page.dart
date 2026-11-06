import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/i18n.dart';
import '../../data/usage_statistics.dart';
import '../../state/app_state.dart';
import '../export.dart';
import '../widgets/common.dart';

class StatsPage extends StatefulWidget {
  const StatsPage({super.key, this.statistics});

  /// Injecting a snapshot makes the visual states testable without SQLite.
  final UsageStatistics? statistics;

  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage> {
  late Future<UsageStatistics> _future;
  int? _days = 30;
  DateTimeRange? _range;
  DateTime? _selectedDay;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<UsageStatistics> _load() =>
      widget.statistics == null ? context.read<AppState>().db.usageStatistics() : Future.value(widget.statistics!);

  Future<void> _refresh() async {
    setState(() => _future = _load());
    await _future;
  }

  UsagePeriod _period(UsageStatistics data) =>
      _range == null ? data.period(_days) : data.period(null, start: _range!.start, end: _range!.end);

  Future<void> _selectRange() async {
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
      initialDateRange: _range,
      helpText: t('选择统计日期', 'Select usage dates'),
    );
    if (range != null && mounted) setState(() => _range = range);
  }

  Future<void> _export() async {
    try {
      final period = _period(await _future);
      if (!mounted) return;
      await shareText(period.toCsv(), 'mewhub_usage_${statisticsDate(period.start)}_${statisticsDate(period.end)}.csv');
    } catch (error) {
      if (mounted) toast(context, '$error', error: true);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(t('用量统计', 'Usage stats')),
      actions: [
        IconButton(
          tooltip: t('导出当前时段 CSV', 'Export selected period as CSV'),
          onPressed: _export,
          icon: const Icon(Icons.ios_share_rounded),
        ),
        IconButton(
          tooltip: t('刷新统计', 'Refresh statistics'),
          onPressed: _refresh,
          icon: const Icon(Icons.refresh_rounded),
        ),
      ],
    ),
    body: FutureBuilder<UsageStatistics>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(t('统计加载失败', 'Could not load statistics')),
                TextButton(onPressed: _refresh, child: Text(t('重试', 'Retry'))),
              ],
            ),
          );
        }
        if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
        final data = snapshot.data!;
        final period = _period(data);
        return RefreshIndicator(
          onRefresh: _refresh,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _Heatmap(
                        data: data,
                        selected: _selectedDay,
                        onSelect: (day) => setState(() => _selectedDay = day),
                      ),
                      const SizedBox(height: 10),
                      _metricGrid([
                        _Metric(Icons.forum_outlined, t('总对话数', 'Conversations'), data.conversations.toString()),
                        _Metric(Icons.chat_bubble_outline_rounded, t('总消息数', 'Messages'), data.messages.toString()),
                        _Metric(Icons.rocket_launch_outlined, t('应用启动次数', 'App launches'), data.launches.toString()),
                      ]),
                      const SizedBox(height: 24),
                      Text(t('Token 用量', 'Token usage'), style: Theme.of(context).textTheme.titleLarge),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 2,
                        children: [
                          for (final item in <(int?, String)>[
                            (7, t('7 天', '7 days')),
                            (30, t('30 天', '30 days')),
                            (90, t('90 天', '90 days')),
                            (null, t('全部', 'All')),
                          ])
                            ChoiceChip(
                              label: Text(item.$2),
                              selected: _range == null && _days == item.$1,
                              onSelected: (_) => setState(() {
                                _days = item.$1;
                                _range = null;
                              }),
                            ),
                          ActionChip(
                            avatar: const Icon(Icons.date_range_outlined, size: 18),
                            label: Text(
                              _range == null
                                  ? t('自定义', 'Custom')
                                  : '${statisticsDate(_range!.start).substring(5)}–${statisticsDate(_range!.end).substring(5)}',
                            ),
                            onPressed: _selectRange,
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      _metricGrid([
                        _Metric(
                          Icons.north_rounded,
                          t('输入 Token', 'Input tokens'),
                          statisticsNumber(period.totals.input),
                        ),
                        _Metric(
                          Icons.south_rounded,
                          t('输出 Token', 'Output tokens'),
                          statisticsNumber(period.totals.output),
                        ),
                        _Metric(
                          Icons.bolt_outlined,
                          t('缓存节省 Token', 'Cached tokens'),
                          statisticsNumber(period.totals.cached),
                        ),
                        _Metric(
                          Icons.percent_rounded,
                          t('缓存命中率', 'Cache hit rate'),
                          '${(period.totals.cacheRate * 100).toStringAsFixed(1)}%',
                        ),
                      ]),
                      const SizedBox(height: 10),
                      _UsageChart(period: period),
                      const SizedBox(height: 10),
                      _Ranking(title: t('按模型', 'By model'), rows: period.models),
                      const SizedBox(height: 10),
                      _Ranking(title: t('按来源', 'By source'), rows: period.sources, source: true),
                      const SizedBox(height: 10),
                      _DailyDetails(period: period),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    ),
  );
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      child: Padding(padding: const EdgeInsets.all(16), child: child),
    );
  }
}

class _Metric {
  const _Metric(this.icon, this.label, this.value);
  final IconData icon;
  final String label;
  final String value;
}

Widget _metricGrid(List<_Metric> metrics) => LayoutBuilder(
  builder: (context, constraints) {
    final half = (constraints.maxWidth - 10) / 2;
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        for (var index = 0; index < metrics.length; index++)
          SizedBox(
            width: metrics.length == 3 && index == 2 ? constraints.maxWidth : half,
            child: _Panel(
              child: SizedBox(
                height: 108,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Icon(metrics[index].icon, size: 20, color: Theme.of(context).colorScheme.primary),
                    Text(
                      metrics[index].value,
                      style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    Text(
                      metrics[index].label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  },
);

class _Heatmap extends StatelessWidget {
  const _Heatmap({required this.data, required this.selected, required this.onSelect});
  final UsageStatistics data;
  final DateTime? selected;
  final ValueChanged<DateTime> onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final maxCount = data.activity.values.fold<int>(1, math.max);
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(t('聊天热力图', 'Chat activity'), style: Theme.of(context).textTheme.titleMedium)),
              Text(t('近 26 周', '26 weeks'), style: Theme.of(context).textTheme.labelSmall),
            ],
          ),
          const SizedBox(height: 14),
          LayoutBuilder(
            builder: (context, constraints) {
              final cell = ((constraints.maxWidth - 30 - 25 * 3) / 26).clamp(3.0, 13.0).toDouble();
              final step = cell + 3;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    height: 16,
                    child: Stack(
                      children: [
                        for (var week = 0; week < 26; week++)
                          if (week == 0 || data.heatmapStart.add(Duration(days: week * 7)).day <= 7)
                            Positioned(
                              left: 30 + week * step,
                              child: Text(
                                data.heatmapStart.add(Duration(days: week * 7)).month.toString() + t('月', 'm'),
                                style: TextStyle(fontSize: 9, color: scheme.onSurfaceVariant),
                              ),
                            ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 30,
                        child: Column(
                          children: [
                            for (var weekday = 0; weekday < 7; weekday++)
                              SizedBox(
                                height: step,
                                child: Text(
                                  weekday == 0
                                      ? t('一', 'M')
                                      : weekday == 2
                                      ? t('三', 'W')
                                      : weekday == 4
                                      ? t('五', 'F')
                                      : '',
                                  style: TextStyle(fontSize: 9, color: scheme.onSurfaceVariant),
                                ),
                              ),
                          ],
                        ),
                      ),
                      for (var week = 0; week < 26; week++)
                        Padding(
                          padding: EdgeInsets.only(right: week == 25 ? 0 : 3),
                          child: Column(
                            children: [
                              for (var weekday = 0; weekday < 7; weekday++)
                                _cell(context, week, weekday, cell, maxCount),
                            ],
                          ),
                        ),
                    ],
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text(t('少', 'Less'), style: Theme.of(context).textTheme.labelSmall),
              const SizedBox(width: 5),
              for (var level = 0; level < 5; level++)
                Container(
                  width: 11,
                  height: 11,
                  margin: const EdgeInsets.only(right: 4),
                  decoration: BoxDecoration(
                    color: level == 0
                        ? scheme.surfaceContainerHighest
                        : scheme.primary.withValues(alpha: 0.2 + 0.2 * level),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              Text(t('多', 'More'), style: Theme.of(context).textTheme.labelSmall),
              const Spacer(),
              Text(
                '${data.activeDays} ${t('活跃天', 'active days')}',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(color: scheme.primary),
              ),
            ],
          ),
          if (selected != null) ...[
            const SizedBox(height: 7),
            Text(
              '${statisticsDate(selected!)} · ${data.activity[selected] ?? 0} ${t('条消息', 'messages')}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ] else if (data.currentStreak > 0) ...[
            const SizedBox(height: 7),
            Text(
              '${data.currentStreak} ${t('天连续活跃', 'day streak')}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.primary),
            ),
          ],
        ],
      ),
    );
  }

  Widget _cell(BuildContext context, int week, int weekday, double size, int maxCount) {
    final scheme = Theme.of(context).colorScheme;
    final day = data.heatmapStart.add(Duration(days: week * 7 + weekday));
    final count = data.activity[day] ?? 0;
    final future = day.isAfter(data.today);
    final color = future
        ? scheme.surfaceContainerLow
        : count == 0
        ? scheme.surfaceContainerHighest
        : scheme.primary.withValues(alpha: 0.24 + 0.76 * math.sqrt(count / maxCount));
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Tooltip(
        message: '${statisticsDate(day)} · $count ${t('条消息', 'messages')}',
        child: GestureDetector(
          onTap: future ? null : () => onSelect(day),
          child: Semantics(
            label: '${statisticsDate(day)} $count ${t('条消息', 'messages')}',
            child: Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(3),
                border: day == selected ? Border.all(color: scheme.onSurface) : null,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _UsageChart extends StatelessWidget {
  const _UsageChart({required this.period});
  final UsagePeriod period;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final days = period.chartDays;
    final maxY = math.max(1, days.fold<int>(0, (max, day) => math.max(max, day.usage.total))).toDouble();
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(t('每日用量', 'Daily usage'), style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            t('本期总计', 'Period total'),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          Text(
            statisticsNumber(period.totals.total),
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
          Text(
            '${t('输入', 'Input')} ${statisticsNumber(period.totals.input)}  ·  ${t('缓存', 'Cache')} ${statisticsNumber(period.totals.cached)}  ·  ${t('输出', 'Output')} ${statisticsNumber(period.totals.output)}',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 18),
          SizedBox(
            height: 190,
            child: period.totals.total == 0
                ? Center(child: Text(t('这个时段还没有 Token 用量', 'No token usage in this period')))
                : BarChart(
                    BarChartData(
                      alignment: BarChartAlignment.spaceBetween,
                      maxY: maxY * 1.14,
                      barTouchData: BarTouchData(
                        touchTooltipData: BarTouchTooltipData(
                          getTooltipColor: (_) => scheme.onSurface,
                          getTooltipItem: (group, groupIndex, rod, rodIndex) {
                            final day = days[group.x];
                            final label =
                                statisticsDate(day.date).substring(5) +
                                (day.end == null ? '' : '–${statisticsDate(day.end!).substring(5)}');
                            return BarTooltipItem(
                              '$label\n${statisticsNumber(day.usage.total)} Token',
                              TextStyle(color: scheme.surface, fontSize: 12, fontWeight: FontWeight.w600),
                            );
                          },
                        ),
                      ),
                      gridData: FlGridData(
                        drawVerticalLine: false,
                        horizontalInterval: maxY / 2,
                        getDrawingHorizontalLine: (_) => FlLine(color: scheme.outlineVariant, strokeWidth: 1),
                      ),
                      borderData: FlBorderData(show: false),
                      titlesData: FlTitlesData(
                        topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                        rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                        leftTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 43,
                            getTitlesWidget: (value, meta) => Text(
                              statisticsNumber(value.round()),
                              style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant),
                            ),
                          ),
                        ),
                        bottomTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 24,
                            getTitlesWidget: (value, meta) {
                              final index = value.toInt();
                              if (index < 0 ||
                                  index >= days.length ||
                                  (index != 0 && index != days.length ~/ 2 && index != days.length - 1)) {
                                return const SizedBox.shrink();
                              }
                              return SideTitleWidget(
                                meta: meta,
                                child: Text(
                                  statisticsDate(days[index].date).substring(5),
                                  style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                      barGroups: [
                        for (var index = 0; index < days.length; index++)
                          BarChartGroupData(
                            x: index,
                            barRods: [
                              BarChartRodData(
                                toY: days[index].usage.total.toDouble(),
                                width: days.length > 70
                                    ? 3
                                    : days.length > 30
                                    ? 5
                                    : 9,
                                borderRadius: BorderRadius.circular(2),
                                color: scheme.primary,
                                rodStackItems: [
                                  BarChartRodStackItem(
                                    0,
                                    days[index].usage.input.toDouble(),
                                    scheme.primary.withValues(alpha: 0.48),
                                  ),
                                  BarChartRodStackItem(
                                    days[index].usage.input.toDouble(),
                                    days[index].usage.total.toDouble(),
                                    scheme.primary,
                                  ),
                                ],
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 14,
            runSpacing: 4,
            children: [
              _SmallFact(t('请求', 'Requests'), period.totals.requests.toString()),
              _SmallFact(t('活跃天', 'Active days'), period.activeDays.toString()),
              _SmallFact(t('日均', 'Daily average'), statisticsNumber(period.dailyAverage)),
              _SmallFact(t('峰值', 'Peak'), statisticsNumber(period.peak.usage.total)),
            ],
          ),
        ],
      ),
    );
  }
}

class _SmallFact extends StatelessWidget {
  const _SmallFact(this.label, this.value);
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => Text(
    '$label  $value',
    style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
  );
}

class _Ranking extends StatelessWidget {
  const _Ranking({required this.title, required this.rows, this.source = false});
  final String title;
  final List<UsageRanking> rows;
  final bool source;

  String _name(UsageRanking row) {
    if (!source) return row.name.isEmpty ? (row.id.isEmpty ? t('未知模型', 'Unknown model') : row.id) : row.name;
    return switch (row.id) {
      'chat' => t('聊天', 'Chat'),
      'suggestions' => t('建议', 'Suggestions'),
      'title' => t('标题', 'Title'),
      'translation' => t('翻译', 'Translation'),
      'ocr' => t('文字识别', 'OCR'),
      'compression' => t('上下文压缩', 'Compression'),
      _ => row.id.isEmpty ? t('其他', 'Other') : row.id,
    };
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final total = rows.fold<int>(0, (sum, row) => sum + row.usage.total);
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          if (rows.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(t('暂无数据', 'No data'), style: TextStyle(color: scheme.onSurfaceVariant)),
            ),
          for (final row in rows) ...[
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(child: Text(_name(row), maxLines: 1, overflow: TextOverflow.ellipsis)),
                const SizedBox(width: 8),
                Text(
                  '${statisticsNumber(row.usage.total)} · ${total == 0 ? '0' : (row.usage.total * 100 / total).round().toString()}%',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: total == 0 ? 0 : row.usage.total / total,
                minHeight: 7,
                color: scheme.primary,
                backgroundColor: scheme.surfaceContainerHighest,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${row.usage.requests} ${t('次请求', 'requests')}  ·  ↑${statisticsNumber(row.usage.input)}  ↓${statisticsNumber(row.usage.output)}  ${t('缓存', 'cache')} ${statisticsNumber(row.usage.cached)}',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }
}

class _DailyDetails extends StatelessWidget {
  const _DailyDetails({required this.period});
  final UsagePeriod period;
  @override
  Widget build(BuildContext context) => _Panel(
    child: ExpansionTile(
      tilePadding: EdgeInsets.zero,
      childrenPadding: EdgeInsets.zero,
      title: Text(t('最近每日明细', 'Recent daily details'), style: Theme.of(context).textTheme.titleMedium),
      subtitle: Text(
        t('展开查看最近 7 天，导出可获取完整明细', 'Latest 7 days; export for full details'),
        style: Theme.of(context).textTheme.bodySmall,
      ),
      children: [
        for (final day in period.daily.reversed.take(7))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                Expanded(child: Text(statisticsDate(day.date).substring(5))),
                Text('${statisticsNumber(day.usage.total)} Token'),
              ],
            ),
          ),
      ],
    ),
  );
}
