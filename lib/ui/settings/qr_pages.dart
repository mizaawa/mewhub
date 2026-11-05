import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/i18n.dart';

/// Full-screen QR scanner; pops with the decoded text.
class QrScanPage extends StatefulWidget {
  const QrScanPage({super.key});

  @override
  State<QrScanPage> createState() => _QrScanPageState();
}

class _QrScanPageState extends State<QrScanPage> {
  final _controller = MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  bool _done = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final box = size.shortestSide * 0.68;
    final window = Rect.fromCenter(center: Offset(size.width / 2, size.height / 2 - 40), width: box, height: box);
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        title: Text(t('扫描配置二维码', 'Scan config QR')),
        actions: [IconButton(icon: const Icon(Icons.flash_on_rounded), onPressed: () => _controller.toggleTorch())],
      ),
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller,
            scanWindow: window,
            onDetect: (capture) {
              if (_done) return;
              final v = capture.barcodes.map((b) => b.rawValue).whereType<String>().firstOrNull;
              if (v == null || v.isEmpty) return;
              _done = true;
              Navigator.pop(context, v);
            },
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
            child: CustomPaint(size: Size.infinite, painter: _ScanOverlay(window)),
          ),
          IgnorePointer(child: _ScanLine(window: window)),
        ],
      ),
    );
  }
}

class _ScanOverlay extends CustomPainter {
  _ScanOverlay(this.window);
  final Rect window;

  @override
  void paint(Canvas canvas, Size size) {
    final r = RRect.fromRectAndRadius(window, const Radius.circular(24));
    final path = Path()
      ..addRect(Offset.zero & size)
      ..addRRect(r)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(path, Paint()..color = Colors.black54);
    canvas.drawRRect(
      r,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_ScanOverlay old) => old.window != window;
}

class _ScanLine extends StatefulWidget {
  const _ScanLine({required this.window});
  final Rect window;

  @override
  State<_ScanLine> createState() => _ScanLineState();
}

class _ScanLineState extends State<_ScanLine> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800))..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _c,
    builder: (context, _) {
      final w = widget.window;
      final y = w.top + 12 + (w.height - 24) * Curves.easeInOut.transform(_c.value);
      return Stack(
        children: [
          Positioned(
            left: w.left + 16,
            width: w.width - 32,
            top: y,
            height: 2,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [Colors.transparent, Theme.of(context).colorScheme.primary, Colors.transparent],
                ),
              ),
            ),
          ),
        ],
      );
    },
  );
}
