import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../ink/stroke_renderer.dart';

/// 手繪橡皮圖標（SDK 沒有合適的整筆擦 glyph，`delete_sweep` 像清空全部）。
/// 顏色跟隨 IconTheme（IconButton 選中態自動變色）。

/// 按筆畫橡皮：一條波浪線被橡皮從中壓斷（碰到即整筆刪除）。
class StrokeEraserIcon extends StatelessWidget {
  final double size;
  const StrokeEraserIcon({super.key, this.size = 24});

  @override
  Widget build(BuildContext context) {
    final color = IconTheme.of(context).color ?? Colors.black;
    return CustomPaint(
      size: Size.square(size),
      painter: _StrokeEraserPainter(color),
    );
  }
}

class _StrokeEraserPainter extends CustomPainter {
  final Color color;
  _StrokeEraserPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24;
    final line = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2 * s
      ..strokeCap = StrokeCap.round;
    // 波浪線，中間留缺口（被橡皮壓住的部分）
    final left = Path()
      ..moveTo(1 * s, 17 * s)
      ..quadraticBezierTo(4 * s, 12 * s, 7 * s, 16 * s);
    final right = Path()
      ..moveTo(17 * s, 16 * s)
      ..quadraticBezierTo(20 * s, 12 * s, 23 * s, 17 * s);
    canvas.drawPath(left, line);
    canvas.drawPath(right, line);
    // 橡皮：傾斜圓角矩形
    canvas.save();
    canvas.translate(12 * s, 11 * s);
    canvas.rotate(-0.5);
    final body = Paint()..color = color;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset.zero, width: 11 * s, height: 7 * s),
          Radius.circular(1.8 * s)),
      body,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_StrokeEraserPainter old) => old.color != color;
}

/// 像素橡皮：橡皮 + 被抹碎的點（拖抹局部擦除）。
class PixelEraserIcon extends StatelessWidget {
  final double size;
  const PixelEraserIcon({super.key, this.size = 24});

  @override
  Widget build(BuildContext context) {
    final color = IconTheme.of(context).color ?? Colors.black;
    return CustomPaint(
      size: Size.square(size),
      painter: _PixelEraserPainter(color),
    );
  }
}

class _PixelEraserPainter extends CustomPainter {
  final Color color;
  _PixelEraserPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24;
    final line = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2 * s
      ..strokeCap = StrokeCap.round;
    // 短線段 + 抹碎的散點
    canvas.drawLine(Offset(1 * s, 18 * s), Offset(8 * s, 18 * s), line);
    final dot = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    for (final p in [
      Offset(11.5 * s, 16.5 * s),
      Offset(14 * s, 18.5 * s),
      Offset(11 * s, 20 * s),
    ]) {
      canvas.drawCircle(p, 1.3 * s, dot);
    }
    // 小橡皮
    canvas.save();
    canvas.translate(17 * s, 9 * s);
    canvas.rotate(-0.5);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset.zero, width: 9 * s, height: 6 * s),
          Radius.circular(1.5 * s)),
      Paint()..color = color,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PixelEraserPainter old) => old.color != color;
}

/// 筆刷按鈕：一眼看出當前筆色+筆型的色塊（glyph 視亮度反白）。
class PenColorButton extends StatelessWidget {
  final String hexColor;
  final PenType penType;
  final double size;
  const PenColorButton(
      {super.key,
      required this.hexColor,
      this.penType = PenType.brush,
      this.size = 28});

  static Color parse(String hex) {
    var h = hex.replaceAll('#', '');
    if (h.length == 6) h = 'FF$h';
    return Color(int.parse(h, radix: 16));
  }

  @override
  Widget build(BuildContext context) {
    final c = parse(hexColor);
    final glyph = c.computeLuminance() > 0.5 ? Colors.black : Colors.white;
    Widget mark;
    switch (penType) {
      case PenType.dashed:
        mark = CustomPaint(
          size: Size.square(size * 0.55),
          painter: _DashesPainter(glyph),
        );
        break;
      case PenType.highlighter:
        mark = CustomPaint(
          size: Size.square(size * 0.55),
          painter: _MarkerPainter(glyph),
        );
        break;
      case PenType.brush:
        mark = Icon(Icons.brush, size: size * 0.55, color: glyph);
        break;
    }
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: c,
        shape: BoxShape.circle,
        border: Border.all(
          color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.6),
          width: 1.5,
        ),
      ),
      child: Center(child: mark),
    );
  }
}

class _DashesPainter extends CustomPainter {
  final Color color;
  _DashesPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24;
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3 * s
      ..strokeCap = StrokeCap.round;
    for (final x in [2.0, 10.0, 18.0]) {
      canvas.drawLine(Offset(x * s, 12 * s), Offset((x + 5) * s, 12 * s), p);
    }
  }

  @override
  bool shouldRepaint(_DashesPainter old) => old.color != color;
}

class _MarkerPainter extends CustomPainter {
  final Color color;
  _MarkerPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24;
    canvas.save();
    canvas.translate(12 * s, 12 * s);
    canvas.rotate(-0.6);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset.zero, width: 16 * s, height: 7 * s),
          Radius.circular(3.5 * s)),
      Paint()..color = color,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_MarkerPainter old) => old.color != color;
}

/// 圈選圖標：虛線圈（跟全屏方框區分開）。
class LassoIcon extends StatelessWidget {
  final double size;
  const LassoIcon({super.key, this.size = 24});

  @override
  Widget build(BuildContext context) {
    final color = IconTheme.of(context).color ?? Colors.black;
    return CustomPaint(
      size: Size.square(size),
      painter: _LassoPainter(color),
    );
  }
}

class _LassoPainter extends CustomPainter {
  final Color color;
  _LassoPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24;
    // 虛線橢圓：參數採樣
    final pts = <Offset>[];
    for (var i = 0; i <= 48; i++) {
      final a = i / 48 * 2 * math.pi;
      pts.add(Offset(
        11 * s + 8 * s * math.cos(a),
        11 * s + 6.5 * s * math.sin(a),
      ));
    }
    canvas.drawPath(
      dashPath(pts, 3.5 * s, 2.5 * s),
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2 * s
        ..strokeCap = StrokeCap.round,
    );
    // 小尾巴（套索繩頭）
    canvas.drawLine(
      Offset(19 * s, 15 * s),
      Offset(22.5 * s, 20 * s),
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2 * s
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_LassoPainter old) => old.color != color;
}
