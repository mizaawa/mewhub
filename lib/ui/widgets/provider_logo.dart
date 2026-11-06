import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../ai/provider_config.dart';
import '../../core/i18n.dart';
import '../../core/site_icon.dart';
import '../../data/provider_branding.dart';
import 'common.dart';

class ProviderLogo extends StatefulWidget {
  const ProviderLogo({super.key, required this.provider, this.size = 42});
  final ProviderConfig provider;
  final double size;

  @override
  State<ProviderLogo> createState() => _ProviderLogoState();
}

class _ProviderLogoState extends State<ProviderLogo> {
  http.Client? _client;
  Future<Uint8List?>? _liveIcon;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void didUpdateWidget(ProviderLogo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.provider.isZako != widget.provider.isZako) _refresh();
  }

  void _refresh() {
    _client?.close();
    _client = widget.provider.isZako ? http.Client() : null;
    _liveIcon = _client == null ? null : loadSiteIcon(Uri.parse(zakoBaseUrl), client: _client);
  }

  @override
  void dispose() {
    _client?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.provider;
    final asset = p.iconAsset;
    if (asset == null) return AvatarView(value: '', fallback: p.name, size: widget.size);
    Widget fallback() => Image.asset(asset, fit: BoxFit.contain);
    return Semantics(
      label: '${p.name} logo',
      image: true,
      child: Container(
        width: widget.size,
        height: widget.size,
        padding: const EdgeInsets.all(5),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(widget.size * 0.3),
          border: Border.all(color: Theme.of(context).colorScheme.outlineVariant, width: 0.8),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(widget.size * 0.2),
          child: FutureBuilder<Uint8List?>(
            future: _liveIcon,
            builder: (context, snapshot) => snapshot.data == null
                ? fallback()
                : Image.memory(snapshot.data!, fit: BoxFit.contain, errorBuilder: (_, _, _) => fallback()),
          ),
        ),
      ),
    );
  }
}

class OfficialProviderTag extends StatelessWidget {
  const OfficialProviderTag({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(color: scheme.primaryContainer, borderRadius: BorderRadius.circular(6)),
      child: Text(
        t('官方', 'Official'),
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: scheme.onPrimaryContainer),
      ),
    );
  }
}
