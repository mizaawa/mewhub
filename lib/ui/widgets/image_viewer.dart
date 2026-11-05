import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:share_plus/share_plus.dart';

import '../../ai/encoding.dart';
import '../../core/i18n.dart';
import '../../core/net.dart';
import '../../core/paths.dart';
import 'common.dart';

/// Resolves a stored image reference (sandbox path / data uri / http url) to an ImageProvider.
ImageProvider imageProviderFor(String url) {
  if (url.startsWith('data:')) {
    final bytes = MediaEncoder.decodeDataUri(url);
    if (bytes != null) return MemoryImage(bytes);
  }
  if (url.startsWith('http://') || url.startsWith('https://')) return NetworkImage(url);
  return FileImage(File(AppPaths.resolve(url)));
}

Future<Uint8List?> imageBytesFor(String url) async {
  if (url.startsWith('data:')) return MediaEncoder.decodeDataUri(url);
  if (url.startsWith('http://') || url.startsWith('https://')) {
    return Uint8List.fromList(await Net.bytes(Uri.parse(url)));
  }
  final f = File(AppPaths.resolve(url));
  return await f.exists() ? f.readAsBytes() : null;
}

class NetworkImageTile extends StatelessWidget {
  const NetworkImageTile({super.key, required this.url, this.maxHeight = 320});
  final String url;
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: GestureDetector(
        onTap: () => openImageViewer(context, url),
        child: Hero(
          tag: 'img-$url',
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxHeight),
              child: Image(
                image: imageProviderFor(url),
                fit: BoxFit.contain,
                frameBuilder: (context, child, frame, sync) => AnimatedOpacity(
                  opacity: frame == null && !sync ? 0 : 1,
                  duration: const Duration(milliseconds: 350),
                  child: child,
                ),
                errorBuilder: (context, e, st) => Container(
                  height: 80,
                  color: scheme.surfaceContainerHigh,
                  child: Icon(Icons.broken_image_outlined, color: scheme.onSurfaceVariant),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

void openImageViewer(BuildContext context, String url) {
  Navigator.of(context).push(
    PageRouteBuilder<void>(
      opaque: false,
      barrierColor: Colors.black87,
      transitionDuration: const Duration(milliseconds: 320),
      pageBuilder: (context, a, b) => FadeTransition(
        opacity: a,
        child: _ImageViewer(url: url),
      ),
    ),
  );
}

class _ImageViewer extends StatelessWidget {
  const _ImageViewer({required this.url});
  final String url;

  Future<void> _save(BuildContext context) async {
    try {
      final bytes = await imageBytesFor(url);
      if (bytes == null) throw Exception('no data');
      if (!await Gal.hasAccess(toAlbum: false)) {
        if (!await Gal.requestAccess(toAlbum: false)) throw Exception(t('没有相册权限', 'Photo access denied'));
      }
      await Gal.putImageBytes(bytes, name: 'mewhub_${DateTime.now().millisecondsSinceEpoch}');
      if (context.mounted) toast(context, t('已保存到相册', 'Saved to Photos'));
    } catch (e) {
      if (context.mounted) toast(context, '$e', error: true);
    }
  }

  Future<void> _share(BuildContext context) async {
    final bytes = await imageBytesFor(url);
    if (bytes == null) return;
    final f = File('${AppPaths.exports.path}/image_${DateTime.now().millisecondsSinceEpoch}.png');
    await f.writeAsBytes(bytes);
    await SharePlus.instance.share(ShareParams(files: [XFile(f.path)]));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              onTap: () => Navigator.pop(context),
              child: InteractiveViewer(
                maxScale: 6,
                child: Center(
                  child: Hero(
                    tag: 'img-$url',
                    child: Image(image: imageProviderFor(url)),
                  ),
                ),
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  IconButton.filledTonal(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                  const Spacer(),
                  IconButton.filledTonal(onPressed: () => _share(context), icon: const Icon(Icons.ios_share_rounded)),
                  const SizedBox(width: 8),
                  IconButton.filledTonal(onPressed: () => _save(context), icon: const Icon(Icons.download_rounded)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
