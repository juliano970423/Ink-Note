import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../ink/stroke_renderer.dart';
import '../models/note.dart';

/// 把筆記匯出為 PDF（純 Dart，可跑 Web；全向量）。
/// - 筆跡：直接畫成向量路徑（壓感按寬度分段，螢光半透明，幾何圖形對應直線/矩形/橢圓/虛線），放大不糊。
/// - 貼圖：原 PNG/JPEG 嵌入（照片本來就是點陣，包向量殼）。
/// - PDF 底圖頁：底圖當整頁圖，其餘同上。
/// - 有紙：每頁筆記一頁 PDF（空白尾頁不存，故無空頁）。
/// - 無限畫布：按筆跡＋圖片包圍盒 + 邊距生成單頁。
/// - 隱藏圖層不匯出；多層按層由底到頂畫（每層先圖後筆，每層內螢光墊底）。
Future<Uint8List> buildNotePdf(
  Note note, {
  double hlWidth = 3.0,
  Set<int> hiddenLayers = const {},
  Map<int, Uint8List> backgrounds = const {},
  List<NoteImage> images = const [],
  Map<String, Uint8List> imageBytes = const {},
}) async {
  List<Stroke> visible(List<Stroke> ss) =>
      ss.where((s) => !hiddenLayers.contains(s.layer)).toList();
  List<NoteImage> visibleImgs(int page) => [
    for (final m in images)
      if (m.page == page && !hiddenLayers.contains(m.layer)) m,
  ];
  if (note.backgrounds.isNotEmpty) {
    final doc = pw.Document();
    for (var i = 0; i < note.backgrounds.length; i++) {
      final meta = note.backgrounds[i];
      // 頁面比例跟底圖走（寬固定 210mm）
      const wMm = 210.0;
      final hMm = wMm * meta.h / meta.w;
      final format = PdfPageFormat(wMm, hMm);
      // 筆跡顯示座標：底圖顯示 800 內容 px 寬，頁邊 24
      const dispW = 800.0;
      final dispH = dispW * meta.h / meta.w;
      final map = ExportPageMap(
        srcX: 24,
        srcY: 24,
        srcW: dispW,
        srcH: dispH,
        format: format,
      );
      final strokes = visible(note.strokes.where((s) => s.page == i).toList());
      doc.addPage(
        pw.Page(
          pageFormat: format,
          build: (_) => pw.Stack(
            children: [
              if (backgrounds[i] != null)
                pw.Positioned.fill(
                  child: pw.Image(
                    pw.MemoryImage(backgrounds[i]!),
                    fit: pw.BoxFit.fill,
                  ),
                ),
              ..._layered(
                map,
                strokes,
                visibleImgs(i),
                imageBytes,
                hlWidth: hlWidth,
              ),
            ],
          ),
        ),
      );
    }
    return doc.save();
  }
  final page = PageSize.byId(note.pageId);
  final doc = pw.Document();
  if (page != null) {
    var maxPage = 0;
    var any = false;
    for (final s in note.strokes) {
      any = true;
      if (s.page > maxPage) maxPage = s.page;
    }
    for (final m in images) {
      any = true;
      if (m.page > maxPage) maxPage = m.page;
    }
    if (!any) {
      doc.addPage(
        pw.Page(
          pageFormat: PdfPageFormat(page.wMm, page.hMm),
          build: (_) => pw.Container(),
        ),
      );
      return doc.save();
    }
    for (var i = 0; i <= maxPage; i++) {
      final strokes = visible(note.strokes.where((s) => s.page == i).toList());
      final format = PdfPageFormat(page.wMm, page.hMm);
      final map = ExportPageMap(
        srcX: 24,
        srcY: 24,
        srcW: page.wPx,
        srcH: page.hPx,
        format: format,
      );
      doc.addPage(
        pw.Page(
          pageFormat: format,
          build: (_) => pw.Stack(
            children: _layered(
              map,
              strokes,
              visibleImgs(i),
              imageBytes,
              hlWidth: hlWidth,
            ),
          ),
        ),
      );
    }
    return doc.save();
  }

  // 無限畫布：單頁（筆跡＋圖片一起算包圍盒）
  double minX = double.infinity,
      minY = double.infinity,
      maxX = -double.infinity,
      maxY = -double.infinity;
  void grow(double x0, double y0, double x1, double y1) {
    if (x0 < minX) minX = x0;
    if (y0 < minY) minY = y0;
    if (x1 > maxX) maxX = x1;
    if (y1 > maxY) maxY = y1;
  }

  for (final s in visible(note.strokes)) {
    for (final pt in s.points) {
      grow(pt.x, pt.y, pt.x, pt.y);
    }
  }
  final vimgs = [
    for (final m in images)
      if (!hiddenLayers.contains(m.layer)) m,
  ];
  for (final m in vimgs) {
    grow(m.x, m.y, m.x + m.w, m.y + m.h);
  }
  if (minX == double.infinity) {
    doc.addPage(
      pw.Page(pageFormat: PdfPageFormat.a4, build: (_) => pw.Container()),
    );
    return doc.save();
  }
  const margin = 40.0;
  final srcX = minX - margin;
  final srcY = minY - margin;
  final srcW = (maxX - minX) + margin * 2;
  final srcH = (maxY - minY) + margin * 2;
  final dstW = PdfPageFormat.a4.width;
  final dstH = dstW * srcH / srcW;
  final format = PdfPageFormat(dstW, dstH);
  final map = ExportPageMap(
    srcX: srcX,
    srcY: srcY,
    srcW: srcW,
    srcH: srcH,
    format: format,
  );
  doc.addPage(
    pw.Page(
      pageFormat: format,
      build: (_) => pw.Stack(
        children: _layered(
          map,
          visible(note.strokes),
          vimgs,
          imageBytes,
          hlWidth: hlWidth,
        ),
      ),
    ),
  );
  return doc.save();
}

/// 顯示座標取材區 → PDF 頁面座標（點；y 上翻，左下原點）。
class ExportPageMap {
  final double srcX, srcY, srcW, srcH;
  final PdfPageFormat format;
  late final double sc = format.width / srcW;

  ExportPageMap({
    required this.srcX,
    required this.srcY,
    required this.srcW,
    required this.srcH,
    required this.format,
  });

  double px(double x) => (x - srcX) * sc;
  double py(double y) => (srcY + srcH - y) * sc;
}

/// 按層由底到頂：每層先圖片 widgets，後一層筆跡 CustomPaint
/// （每層內螢光筆跡墊底，跟屏上一致）。
List<pw.Widget> _layered(
  ExportPageMap map,
  List<Stroke> strokes,
  List<NoteImage> images,
  Map<String, Uint8List> imageBytes, {
  required double hlWidth,
}) {
  final out = <pw.Widget>[];
  final layers = <int>{
    for (final s in strokes) s.layer,
    for (final m in images) m.layer,
  }.toList()..sort();
  for (final l in layers) {
    for (final m in images) {
      if (m.layer != l) continue;
      final bytes = imageBytes[m.id];
      if (bytes == null) continue;
      out.add(
        pw.Positioned(
          left: map.px(m.x),
          top: (m.y - map.srcY) * map.sc,
          child: pw.SizedBox(
            width: m.w * map.sc,
            height: m.h * map.sc,
            child: pw.Image(pw.MemoryImage(bytes), fit: pw.BoxFit.fill),
          ),
        ),
      );
    }
    final ls = strokes.where((s) => s.layer == l).toList();
    if (ls.isEmpty) continue;
    // 螢光墊底，其餘按原順序
    ls.sort((a, b) {
      final ah = PenTypeLabel.parse(a.type) == PenType.highlighter ? 0 : 1;
      final bh = PenTypeLabel.parse(b.type) == PenType.highlighter ? 0 : 1;
      return ah.compareTo(bh);
    });
    out.add(
      pw.CustomPaint(
        size: PdfPoint(map.format.width, map.format.height),
        painter: (g, _) => paintVectorStrokes(g, ls, map, hlWidth),
      ),
    );
  }
  return out;
}

/// '#rrggbb'/'#aarrggbb' → ARGB int
int _argb(String hex) {
  var h = hex.replaceAll('#', '');
  if (h.length == 6) h = 'FF$h';
  return int.parse(h, radix: 16);
}

/// 一批筆跡畫進 PdfGraphics（y 已上翻；線帽線角全圓）。
void paintVectorStrokes(
  PdfGraphics g,
  List<Stroke> strokes,
  ExportPageMap map,
  double hlWidth,
) {
  g.setLineCap(PdfLineCap.round);
  g.setLineJoin(PdfLineJoin.round);
  for (final s in strokes) {
    if (s.points.isEmpty) continue;
    _paintStroke(g, s, map, hlWidth);
  }
}

void _polyline(PdfGraphics g, List<(double, double)> pts) {
  g.moveTo(pts[0].$1, pts[0].$2);
  for (var i = 1; i < pts.length; i++) {
    g.lineTo(pts[i].$1, pts[i].$2);
  }
  g.strokePath();
}

// 壓感分段：相鄰同寬度（0.25pt 一檔）併成一段畫，筆觸粗細跟屏上一致。
void _paintStroke(PdfGraphics g, Stroke s, ExportPageMap map, double hlWidth) {
  final type = PenTypeLabel.parse(s.type);
  final color = PdfColor.fromInt(_argb(s.color));
  final pts = [for (final p in s.points) (map.px(p.x), map.py(p.y))];
  if (type == PenType.highlighter) {
    g.saveContext();
    g.setGraphicState(PdfGraphicState(strokeOpacity: s.alpha.clamp(0.05, 1.0)));
    g.setStrokeColor(color);
    g.setLineWidth((s.size * hlWidth * map.sc).clamp(0.5, 1000));
    if (pts.length == 1) {
      g.drawLine(pts[0].$1, pts[0].$2, pts[0].$1 + 0.01, pts[0].$2);
      g.strokePath();
    } else {
      _polyline(g, pts);
    }
    g.restoreContext();
    return;
  }
  if (type == PenType.dashed && pts.length >= 2) {
    final dash = s.size * 2.5 * map.sc;
    final gap = s.size * 1.5 * map.sc;
    g.saveContext();
    g.setStrokeColor(color);
    g.setLineWidth((s.size * map.sc).clamp(0.5, 1000));
    g.setLineDashPattern([dash, gap]);
    _polyline(g, pts);
    g.restoreContext();
    return;
  }
  if (s.geometric && pts.length == 2) {
    g.saveContext();
    g.setStrokeColor(color);
    g.setLineWidth((s.size * map.sc).clamp(0.5, 1000));
    g.drawLine(pts[0].$1, pts[0].$2, pts[1].$1, pts[1].$2);
    g.strokePath();
    g.restoreContext();
    return;
  }
  if (s.geometric && pts.length == 5) {
    var l = double.infinity, b = double.infinity;
    var r = -double.infinity, t = -double.infinity;
    for (final p in pts) {
      if (p.$1 < l) l = p.$1;
      if (p.$2 < b) b = p.$2;
      if (p.$1 > r) r = p.$1;
      if (p.$2 > t) t = p.$2;
    }
    g.saveContext();
    g.setStrokeColor(color);
    g.setLineWidth((s.size * map.sc).clamp(0.5, 1000));
    g.drawRect(l, b, r - l, t - b);
    g.strokePath();
    g.restoreContext();
    return;
  }
  if (s.geometric && pts.length > 8) {
    var l = double.infinity, b = double.infinity;
    var r = -double.infinity, t = -double.infinity;
    for (final p in pts) {
      if (p.$1 < l) l = p.$1;
      if (p.$2 < b) b = p.$2;
      if (p.$1 > r) r = p.$1;
      if (p.$2 > t) t = p.$2;
    }
    g.saveContext();
    g.setStrokeColor(color);
    g.setLineWidth((s.size * map.sc).clamp(0.5, 1000));
    g.drawEllipse((l + r) / 2, (b + t) / 2, (r - l) / 2, (t - b) / 2);
    g.strokePath();
    g.restoreContext();
    return;
  }
  if (pts.length == 1) {
    g.saveContext();
    g.setStrokeColor(color);
    g.setLineWidth((s.size * map.sc).clamp(0.5, 1000));
    g.drawLine(pts[0].$1, pts[0].$2, pts[0].$1 + 0.01, pts[0].$2);
    g.strokePath();
    g.restoreContext();
    return;
  }
  // 普通手寫：按壓感寬度分段畫
  g.saveContext();
  g.setStrokeColor(color);
  var run = <(double, double)>[pts[0]];
  var runW = _bucket(s.points[0].p, s.size, map.sc);
  void flush() {
    if (run.isEmpty) return;
    g.setLineWidth(runW);
    if (run.length == 1) {
      g.drawLine(run[0].$1, run[0].$2, run[0].$1 + 0.01, run[0].$2);
      g.strokePath();
    } else {
      _polyline(g, run);
    }
  }

  for (var i = 1; i < pts.length; i++) {
    final w = _bucket(s.points[i].p, s.size, map.sc);
    if (w == runW) {
      run.add(pts[i]);
    } else {
      // 轉折點兩邊各留，段不斷線
      run.add(pts[i]);
      flush();
      run = [pts[i]];
      runW = w;
    }
  }
  flush();
  g.restoreContext();
}

double _bucket(double p, double size, double sc) =>
    ((size * sc * p.clamp(0.05, 1.0)).clamp(0.5, 1000) * 4).round() / 4;
