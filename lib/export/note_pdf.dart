import 'dart:typed_data';
import 'dart:ui' show Offset;

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../ink/stroke_renderer.dart';
import '../ink/velocity_tracker.dart';
import '../models/note.dart';

/// 把筆記匯出為 PDF（純 Dart，可跑 Web；全向量）。
/// - 筆刷筆：跟屏上 `paintStroke` 同一數學——`strokeOutline` 填充輪廓
///   （同一套 thinning/streamline，size 取存檔值，壓感取存好的 p），
///   屏上什麼粗細，紙上就是什麼粗細；單點圓公式也一致。
/// - 螢光/虛線/幾何：同屏上（中心線描邊、等弧虛線、手柄公式），幾何筆
///   控制點直接描邊不走壓感輪廓。
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
  StrokeParams? params,
}) async {
  // 輪廓參數跟屏上重放一致：當前手感（thinning/streamline），size 逐筆取存檔。
  final eff = params ?? StrokeParams();
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
                params: eff,
              ),
            ],
          ),
        ),
      );
    }
    // 相容舊資料：PDF 筆記理論上已在保存時把虛擬尾頁轉成 PageBg，
    // 這裡再兜底補空白尾頁（尺寸套末頁）。
    if (note.extraPages > 0) {
      final last = note.backgrounds.last;
      const wMm = 210.0;
      final hMm = wMm * last.h / last.w;
      final format = PdfPageFormat(wMm, hMm);
      for (var i = 0; i < note.extraPages; i++) {
        doc.addPage(pw.Page(pageFormat: format, build: (_) => pw.Container()));
      }
    }
    return doc.save();
  }
  final page = PageSize.byId(note.pageId);
  final doc = pw.Document();
  if (page != null) {
    var maxPage = -1;
    for (final s in note.strokes) {
      if (s.page > maxPage) maxPage = s.page;
    }
    for (final m in images) {
      if (m.page > maxPage) maxPage = m.page;
    }
    if (note.extraPages > 0) {
      maxPage += note.extraPages;
    }
    if (maxPage < 0) {
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
              params: eff,
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
          params: eff,
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
  required StrokeParams params,
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
        painter: (g, _) => paintVectorStrokes(g, ls, map, hlWidth, params),
      ),
    );
  }
  return out;
}

/// 一批筆跡畫進 PdfGraphics（跟屏上 paintStroke 同分支同公式，
/// 只是把 dart:ui 換成 PDF 操作符；y 已上翻；線帽線角全圓）。
void paintVectorStrokes(
  PdfGraphics g,
  List<Stroke> strokes,
  ExportPageMap map,
  double hlWidth,
  StrokeParams params,
) {
  g.setLineCap(PdfLineCap.round);
  g.setLineJoin(PdfLineJoin.round);
  for (final s in strokes) {
    if (s.points.isEmpty) continue;
    _paintStroke(g, s, map, hlWidth, params);
  }
}

void _polyline(PdfGraphics g, List<(double, double)> pts) {
  g.moveTo(pts[0].$1, pts[0].$2);
  for (var i = 1; i < pts.length; i++) {
    g.lineTo(pts[i].$1, pts[i].$2);
  }
  g.strokePath();
}

void _fillCircle(PdfGraphics g, double cx, double cy, double r) {
  if (r <= 0) return;
  g.drawEllipse(cx, cy, r, r);
  g.fillPath();
}

void _paintStroke(PdfGraphics g, Stroke s, ExportPageMap map, double hlWidth,
    StrokeParams params) {
  final type = PenTypeLabel.parse(s.type);
  final alpha = s.alpha.clamp(0.05, 1.0);
  final color = PdfColor.fromInt(hexToArgb(s.color));
  final pts = [for (final p in s.points) (map.px(p.x), map.py(p.y))];
  // 幾何筆（修正產物）：控制點直接描邊，閉環首尾相接；
  // 不走壓感輪廓（跟屏上一樣）。闭环判定用顯示座標。
  if (type == PenType.brush && s.geometric) {
    if (pts.length == 1) {
      g.saveContext();
      g.setFillColor(color);
      _fillCircle(g, pts[0].$1, pts[0].$2, s.size * 0.5 * map.sc);
      g.restoreContext();
      return;
    }
    g.saveContext();
    g.setStrokeColor(color);
    g.setLineWidth((s.size * map.sc).clamp(0.5, 1000));
    g.moveTo(pts[0].$1, pts[0].$2);
    for (var i = 1; i < pts.length; i++) {
      g.lineTo(pts[i].$1, pts[i].$2);
    }
    final first = s.points.first, last = s.points.last;
    if ((Offset(first.x, first.y) - Offset(last.x, last.y)).distance < 1e-6) {
      g.closePath();
    }
    g.strokePath();
    g.restoreContext();
    return;
  }
  if (type == PenType.highlighter) {
    if (pts.length == 1) {
      g.saveContext();
      g.setGraphicState(PdfGraphicState(fillOpacity: alpha));
      g.setFillColor(color);
      _fillCircle(g, pts[0].$1, pts[0].$2, (s.size * 1.5 + 1) * map.sc);
      g.restoreContext();
      return;
    }
    g.saveContext();
    g.setGraphicState(PdfGraphicState(strokeOpacity: alpha));
    g.setStrokeColor(color);
    g.setLineWidth((s.size * (s.hlw ?? hlWidth) * map.sc).clamp(0.5, 1000));
    _polyline(g, pts);
    g.restoreContext();
    return;
  }
  if (type == PenType.dashed) {
    if (pts.length == 1) {
      g.saveContext();
      g.setFillColor(color);
      _fillCircle(g, pts[0].$1, pts[0].$2, s.size * 0.5 * map.sc);
      g.restoreContext();
      return;
    }
    // 屏上先按 2px 等弧重採樣再打虛線（節距跟速度無關）——同樣處理
    var dpts =
        s.points.map((e) => Offset(e.x, e.y)).toList();
    final len = pathLength(dpts);
    if (len > 0) {
      dpts = resamplePoints(dpts, (len / 2).ceil().clamp(2, 4000));
    }
    final dash = s.size * 2.5 * map.sc;
    final gap = s.size * 1.5 * map.sc;
    g.saveContext();
    g.setStrokeColor(color);
    g.setLineWidth((s.size * map.sc).clamp(0.5, 1000));
    g.setLineDashPattern([dash, gap]);
    _polyline(g, [for (final p in dpts) (map.px(p.dx), map.py(p.dy))]);
    g.restoreContext();
    return;
  }
  if (pts.length == 1) {
    // 單點筆：屏上公式 r = size*p*0.5+0.5（顯示 px）填充圓
    final pt = s.points.first;
    g.saveContext();
    g.setFillColor(color);
    _fillCircle(g, pts[0].$1, pts[0].$2,
        (s.size * pt.p.clamp(0.05, 1.0) * 0.5 + 0.5) * map.sc);
    g.restoreContext();
    return;
  }
  // 普通筆刷：跟屏上同一調用——size 取存檔值，壓感取存好的 p，
  // thinning/streamline 存檔凍結值優先（老筆記缺欄位才用傳入 params）；
  // 輪廓點列顯示座標算完再映射，跟屏上只差一個仿射變換，形狀完全一致。
  final base = params;
  final peff = StrokeParams(
    maxSpeed: base.maxSpeed,
    emaWeight: base.emaWeight,
    thinning: s.thinning ?? base.thinning,
    streamline: s.streamline ?? base.streamline,
    size: s.size,
  );
  final outline = strokeOutline(
    [for (final p in s.points) Offset(p.x, p.y)],
    [for (final p in s.points) p.p],
    params: peff,
  );
  if (outline.length < 3) return;
  g.saveContext();
  g.setFillColor(color);
  g.moveTo(map.px(outline[0].dx), map.py(outline[0].dy));
  for (var i = 1; i < outline.length; i++) {
    g.lineTo(map.px(outline[i].dx), map.py(outline[i].dy));
  }
  g.closePath();
  g.fillPath();
  g.restoreContext();
}
