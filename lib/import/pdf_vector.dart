import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:pdf_document/pdf_document.dart';
import 'package:pdf_graphics/pdf_graphics.dart';

/// PDF 向量显示：内容流解释成 Flutter Canvas 原语（纯 Dart，无 pdfium）。
/// 流程：录制命令 → 解码图片（异步）→ 重放到画布。
/// 坐标：全程 PDF 页空间（y 上），外层一次变换进屏（含 /Rotate）。
class VectorRenderStats {
  int fills = 0;
  int strokes = 0;
  int glyphOutlines = 0;
  int glyphFallback = 0;
  int imagesOk = 0;
  int imagesMiss = 0;
  int gradientsFlat = 0;
  int meshesFlat = 0;
  int ignored = 0;

  @override
  String toString() =>
      'fills=$fills strokes=$strokes outlines=$glyphOutlines '
      'fallback=$glyphFallback imgOk=$imagesOk imgMiss=$imagesMiss '
      'flat=$gradientsFlat/$meshesFlat ignored=$ignored';
}

ui.Color _toColor(PdfColor c, double alpha) => ui.Color.fromRGBO(
      (c.red * 255).round().clamp(0, 255),
      (c.green * 255).round().clamp(0, 255),
      (c.blue * 255).round().clamp(0, 255),
      alpha.clamp(0.0, 1.0),
    );

ui.Path _toPath(PdfPath p) {
  final out = ui.Path();
  for (final s in p.segments) {
    switch (s) {
      case PdfMoveTo(:final x, :final y):
        out.moveTo(x, y);
      case PdfLineTo(:final x, :final y):
        out.lineTo(x, y);
      case PdfCubicTo(
          :final x1,
          :final y1,
          :final x2,
          :final y2,
          :final x3,
          :final y3
        ):
        out.cubicTo(x1, y1, x2, y2, x3, y3);
      case PdfClosePath():
        out.close();
    }
  }
  return out;
}

/// PDF [a b c d e f] → Flutter 4x4（列主序）。
Float64List _m4(double a, double b, double c, double d, double e, double f) =>
    Float64List.fromList([
      a, b, 0, 0, //
      c, d, 0, 0, //
      0, 0, 1, 0, //
      e, f, 0, 1,
    ]);

/// 简单虚线展开（Display 用；颗颗等长）。
ui.Path _dashPath(ui.Path src, List<double> pattern, double phase) {
  if (pattern.isEmpty) return src;
  final out = ui.Path();
  for (final m in src.computeMetrics()) {
    var dist = -phase;
    var draw = true;
    var pi = 0;
    final total = m.length;
    while (dist < total) {
      final segLen = pattern[pi % pattern.length];
      final start = dist.clamp(0.0, total);
      final end = (dist + segLen).clamp(0.0, total);
      if (draw && end > start) {
        out.addPath(m.extractPath(start, end), ui.Offset.zero);
      }
      draw = !draw;
      dist += segLen;
      pi++;
    }
  }
  return out;
}

Future<ui.Image> _imageFromRgba(Uint8List rgba, int w, int h) {
  final c = Completer<ui.Image>();
  ui.decodeImageFromPixels(rgba, w, h, ui.PixelFormat.rgba8888, c.complete);
  return c.future;
}

class VectorCanvasDevice implements PdfDevice {
  VectorCanvasDevice(
    this.canvas,
    this.images,
    this.toScreen,
    this.pxScale, [
    VectorRenderStats? stats,
  ]) : stats = stats ?? VectorRenderStats();

  final ui.Canvas canvas;

  /// 预解码的图片（录制期收集请求 → 异步解码 → 重放期取用）。
  final Map<PdfImageRequest, ui.Image> images;

  /// PDF 页空间 → 屏像素（含翻转）：fallback 文字用它算屏坐标。
  final ui.Offset Function(double x, double y) toScreen;

  /// PDF pt → 屏像素的均匀倍率（fallback 字号用）。
  final double pxScale;
  final VectorRenderStats stats;
  final List<double> _alphaStack = [1.0];

  double get _alpha => _alphaStack.isEmpty ? 1.0 : _alphaStack.last;

  @override
  void save() => canvas.save();

  @override
  void restore() => canvas.restore();

  @override
  void fillPath(PdfPath path, PdfColor color, PdfFillRule rule, double alpha) {
    stats.fills++;
    final p = _toPath(path)
      ..fillType = rule == PdfFillRule.evenOdd
          ? ui.PathFillType.evenOdd
          : ui.PathFillType.nonZero;
    canvas.drawPath(
      p,
      ui.Paint()
        ..color = _toColor(color, alpha * _alpha)
        ..style = ui.PaintingStyle.fill,
    );
  }

  @override
  void fillPathGradient(
      PdfPath path, PdfFillRule rule, PdfGradient gradient, double alpha) {
    // 打印机式扁平化：取平均色（渐变极少，保真可接受）
    stats.gradientsFlat++;
    fillPath(path, gradient.averageColor, rule, alpha);
  }

  @override
  void fillMesh(PdfMesh mesh, double alpha) {
    stats.meshesFlat++;
    // 网格 shading 扁平化：顶点包围盒画平均色（罕见，保底不空白）
    var l = double.infinity,
        b = double.infinity,
        r = -double.infinity,
        t = -double.infinity;
    for (final v in mesh.vertices) {
      if (v.x < l) l = v.x;
      if (v.x > r) r = v.x;
      if (v.y < b) b = v.y;
      if (v.y > t) t = v.y;
    }
    if (l > r) return;
    canvas.drawRect(
      ui.Rect.fromLTRB(l, b, r, t),
      ui.Paint()..color = _toColor(mesh.averageColor, alpha * _alpha),
    );
  }

  @override
  void strokePath(
      PdfPath path, PdfColor color, PdfStroke stroke, double alpha) {
    stats.strokes++;
    var p = _toPath(path);
    if (stroke.dashArray.isNotEmpty) {
      p = _dashPath(p, stroke.dashArray, stroke.dashPhase);
    }
    canvas.drawPath(
      p,
      ui.Paint()
        ..color = _toColor(color, alpha * _alpha)
        ..style = ui.PaintingStyle.stroke
        ..strokeWidth = stroke.width
        ..strokeCap = switch (stroke.cap) {
          1 => ui.StrokeCap.round,
          2 => ui.StrokeCap.square,
          _ => ui.StrokeCap.butt,
        }
        ..strokeJoin = switch (stroke.join) {
          1 => ui.StrokeJoin.round,
          2 => ui.StrokeJoin.bevel,
          _ => ui.StrokeJoin.miter,
        },
    );
  }

  @override
  void clipPath(PdfPath path, PdfFillRule rule) {
    canvas.clipPath(_toPath(path));
  }

  @override
  void drawText(PdfTextRun run) {
    if (run.invisible || !run.fill) return;
    final glyphs = run.glyphs;
    if (glyphs == null || glyphs.isEmpty) return;
    final t = run.transform;
    final paint = ui.Paint()
      ..color = _toColor(run.color, run.fillAlpha * _alpha)
      ..style = ui.PaintingStyle.fill;
    for (final g in glyphs) {
      final o = g.outline;
      final tx = g.offset.toDouble(), ty = g.offsetY.toDouble();
      if (o == null) {
        // 空白（空格等）直接跳过：无墨可画，也不触发整 run 回退；
        // 可见缺字形才逐字兜底（引擎定位，位置精确无缝）。
        if (g.text == null || g.text!.trim().isEmpty) continue;
        stats.glyphFallback++;
        _drawFallbackGlyph(run, g, tx, ty);
        continue;
      }
      stats.glyphOutlines++;
      // page = T_run ∘ translate(offset)
      canvas.save();
      canvas.transform(_m4(
        t.a,
        t.b,
        t.c,
        t.d,
        t.a * tx + t.c * ty + t.e,
        t.b * tx + t.d * ty + t.f,
      ));
      canvas.drawPath(_toPath(o), paint);
      canvas.restore();
    }
  }

  /// drawParagraph 在带反射的 CTM 下会镜像字形，所以这里只算好
  /// 屏坐标，攒到 [fallbacks]，外层翻转恢复后统一画（恒等变换，字形正常）。
  final List<({ui.Paragraph para, ui.Offset at})> fallbacks = [];

  /// 单个缺字形的系统字体兜底（引擎给的位置，与描边字形无缝拼接）。
  /// 字号 = 变换轴模长（em→页已含字号，切记开方）。
  void _drawFallbackGlyph(
      PdfTextRun run, PdfGlyphPlacement g, double tx, double ty) {
    final t = run.transform;
    final sx2 = t.a * t.a + t.b * t.b;
    final sy2 = t.c * t.c + t.d * t.d;
    final norm2 = sx2 >= sy2 ? sx2 : sy2;
    if (norm2 <= 0) return;
    final fsPx = math.sqrt(norm2) * pxScale;
    if (fsPx <= 0) return;
    final builder = ui.ParagraphBuilder(
      ui.ParagraphStyle(fontSize: fsPx, height: 1.0),
    )
      ..pushStyle(ui.TextStyle(color: _toColor(run.color, 1.0)))
      ..addText(g.text ?? '');
    final para = builder.build()
      ..layout(const ui.ParagraphConstraints(width: double.infinity));
    final o = toScreen(
      t.a * tx + t.c * ty + t.e,
      t.b * tx + t.d * ty + t.f,
    );
    fallbacks.add((para: para, at: ui.Offset(o.dx, o.dy - fsPx)));
  }

  @override
  void drawImage(PdfImageRequest request) {
    final img = images[request];
    if (img == null) {
      stats.imagesMiss++;
      return;
    }
    stats.imagesOk++;
    // Do 语义：单位正方形经 transform 落页（含旋转精确）。
    // 位图行序是 y 下的：在 R 空间里先翻一次（translate+scale，
    // transform 可含负缩放，drawImageRect 的负高 dst 反而画不出），
    // 首行落到页空间顶部，外层 y 翻转后正好正像。
    final m = request.transform;
    canvas.save();
    canvas.transform(_m4(m.a, m.b, m.c, m.d, m.e, m.f));
    canvas.translate(0, 1);
    canvas.scale(1, -1);
    canvas.drawImageRect(
      img,
      ui.Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
      const ui.Rect.fromLTWH(0, 0, 1, 1),
      ui.Paint()..filterQuality = ui.FilterQuality.medium,
    );
    canvas.restore();
  }

  @override
  void setBlendMode(PdfBlendMode mode) {
    // 显示层只做 srcOver 近似
    if (mode != PdfBlendMode.normal) stats.ignored++;
  }

  @override
  void setOverprint(
      {required bool fill, required bool stroke, required int mode}) {
    // 解释器已在 colorant 缓冲里结算，残余忽略
  }

  @override
  void beginGroup(double alpha, {bool knockout = false}) {
    // 透明组扁平化：alpha 栈相乘（打印机同款近似）
    _alphaStack.add((_alphaStack.last * alpha).clamp(0.0, 1.0));
    canvas.save();
  }

  @override
  void endGroup() {
    if (_alphaStack.length > 1) _alphaStack.removeLast();
    canvas.restore();
  }

  @override
  void beginSoftMasked() {}

  @override
  void endSoftMasked({
    required bool luminosity,
    required PdfRect backdrop,
    required void Function() drawMask,
    double backdropLuminance = 0,
    double transferScale = 1,
    double transferOffset = 0,
  }) {
    stats.ignored++;
  }
}

/// 显示用页空间 → 屏像素变换（含 CropBox 原点 + /Rotate）。
/// 返回 (matrix, displayW, displayH)。
(Float64List, double, double) _displayTransform(
    PdfRect crop, int rotation, double scale) {
  final w = crop.width, h = crop.height;
  final rot = rotation % 360;
  final swap = rot == 90 || rot == 270;
  final dw = (swap ? h : w) * scale;
  final dh = (swap ? w : h) * scale;
  // 先平移到 crop 原点，再旋转映射，最后缩放到像素
  late double a, b, c, d, e, f;
  switch (rot) {
    case 90:
      a = 0; b = scale; c = scale; d = 0; e = 0; f = 0;
    case 180:
      a = -scale; b = 0; c = 0; d = scale; e = dw; f = 0;
    case 270:
      a = 0; b = -scale; c = -scale; d = 0; e = dw; f = dh;
    default:
      a = scale; b = 0; c = 0; d = -scale; e = 0; f = dh;
  }
  // 叠加 crop 原点平移：P' = M · T(-l, -b)
  final l = crop.left, bb = crop.bottom;
  final e2 = a * -l + c * -bb + e;
  final f2 = b * -l + d * -bb + f;
  return (_m4(a, b, c, d, e2, f2), dw, dh);
}

/// 向量渲染一页到位图尺寸（白底）。返回 PNG 字节 + 实际像素尺寸。
/// [widthPx] 为显示宽；高度按 CropBox 等比（超 4000 按比缩回）。
/// 失败返回 null（调用方保留旧图/回退光栅）。
Future<({Uint8List png, int w, int h})?> renderPdfPageVector(
  PdfDocument doc,
  int srcPage, {
  required double widthPx,
  VectorRenderStats? stats,
}) async {
  try {
    if (srcPage < 0 || srcPage >= doc.pageCount) return null;
    final page = doc.page(srcPage);
    final crop = page.cropBox;
    if (crop.width <= 0 || crop.height <= 0) return null;
    var scale = widthPx / (page.rotation == 90 || page.rotation == 270
        ? crop.height
        : crop.width);
    var dw = (page.rotation == 90 || page.rotation == 270
            ? crop.height
            : crop.width) *
        scale;
    var dh = (page.rotation == 90 || page.rotation == 270
            ? crop.width
            : crop.height) *
        scale;
    if (dh > 4000) {
      final k = 4000 / dh;
      scale *= k;
      dw *= k;
      dh = 4000;
    }
    // 1. 录制（解释器只跑一次）
    final recording = RecordingPdfDevice();
    PdfInterpreter(
      cos: doc.cos,
      device: recording,
      resolveOverprint: false,
      collectCharOffsets: false,
    ).drawPage(page);
    // 2. 图片预解码（异步）
    final images = <PdfImageRequest, ui.Image>{};
    for (final req in recording.imageRequests) {
      try {
        final decoded = decodePdfImagePixels(doc.cos, req.stream);
        if (decoded == null) continue;
        images[req] =
            await _imageFromRgba(decoded.rgba, decoded.width, decoded.height);
      } catch (_) {}
    }
    // 3. 重放进屏
    final W = dw.round().clamp(1, 4000);
    final H = dh.round().clamp(1, 4000);
    final rec = ui.PictureRecorder();
    final canvas = ui.Canvas(rec);
    canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, W.toDouble(), H.toDouble()),
      ui.Paint()..color = const ui.Color(0xFFFFFFFF),
    );
    final st = stats ?? VectorRenderStats();
    final (m, _, __) = _displayTransform(crop, page.rotation, scale);
    ui.Offset toScreen(double x, double y) => ui.Offset(
          m[0] * x + m[4] * y + m[12],
          m[1] * x + m[5] * y + m[13],
        );
    canvas.save();
    canvas.transform(m);
    final dev = VectorCanvasDevice(canvas, images, toScreen, scale, st);
    replayCommands(recording.commands, dev);
    canvas.restore();
    // fallback 文字在恒等变换下画（反射 CTM 会镜像字形）
    for (final fb in dev.fallbacks) {
      canvas.drawParagraph(fb.para, fb.at);
    }
    final pic = rec.endRecording();
    final outImg = await pic.toImage(W, H);
    final data =
        await outImg.toByteData(format: ui.ImageByteFormat.png);
    outImg.dispose();
    pic.dispose();
    for (final v in images.values) {
      v.dispose();
    }
    if (data == null) return null;
    return (png: data.buffer.asUint8List(), w: W, h: H);
  } catch (_) {
    return null;
  }
}
