import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../ink/stroke_renderer.dart';
import '../models/note.dart';

/// 把筆記匯出為 PDF（純 Dart，可跑 Web）。
/// - PDF 底圖筆記：每張底圖一頁 PDF（底圖尺寸定頁面比例，筆跡按顯示座標疊加）。
/// - 有紙：每頁筆記一頁 PDF（空白尾頁不存，故無空頁）。
/// - 無限畫布：按筆跡包圍盒 + 邊距生成單頁。
/// - 隱藏圖層不匯出；多層按層由底到頂畫（每層內螢光墊底）。
Future<Uint8List> buildNotePdf(Note note,
    {double hlWidth = 3.0,
    Set<int> hiddenLayers = const {},
    Map<int, Uint8List> backgrounds = const {}}) async {
  List<Stroke> visible(List<Stroke> ss) =>
      ss.where((s) => !hiddenLayers.contains(s.layer)).toList();
  if (note.backgrounds.isNotEmpty) {
    final doc = pw.Document();
    for (var i = 0; i < note.backgrounds.length; i++) {
      final meta = note.backgrounds[i];
      // 頁面比例跟底圖走（寬固定 210mm）
      const wMm = 210.0;
      final hMm = wMm * meta.h / meta.w;
      final format = PdfPageFormat(wMm, hMm);
      const dpi = 150.0;
      final imgW = (format.width * dpi / 72).round().clamp(1, 4000);
      final imgH = (format.height * dpi / 72).round().clamp(1, 4000);
      // 筆跡顯示座標：底圖顯示 800 內容 px 寬
      const dispW = 800.0;
      final dispH = dispW * meta.h / meta.w;
      final strokes = visible(note.strokes.where((s) => s.page == i).toList());
      final png = await _rasterize(
          strokes, 24, 24, dispW, dispH, imgW, imgH,
          hlWidth: hlWidth, bg: backgrounds[i]);
      doc.addPage(
        pw.Page(
          pageFormat: format,
          build: (_) => pw.Container(
            width: format.width,
            height: format.height,
            child: pw.Image(pw.MemoryImage(png), fit: pw.BoxFit.fill),
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
    for (final s in note.strokes) {
      if (s.page > maxPage) maxPage = s.page;
    }
    if (note.strokes.isEmpty) {
      doc.addPage(pw.Page(pageFormat: PdfPageFormat(page.wMm, page.hMm),
          build: (_) => pw.Container()));
      return doc.save();
    }
    for (var i = 0; i <= maxPage; i++) {
      final strokes =
          visible(note.strokes.where((s) => s.page == i).toList());
      final format = PdfPageFormat(page.wMm, page.hMm);
      const dpi = 150.0;
      final imgW = (format.width * dpi / 72).round().clamp(1, 4000);
      final imgH = (format.height * dpi / 72).round().clamp(1, 4000);
      final png = await _rasterize(
          strokes, 24, 24, page.wPx, page.hPx, imgW, imgH,
          hlWidth: hlWidth);
      doc.addPage(
        pw.Page(
          pageFormat: format,
          build: (_) => pw.Container(
            width: format.width,
            height: format.height,
            child: pw.Image(pw.MemoryImage(png), fit: pw.BoxFit.fill),
          ),
        ),
      );
    }
    return doc.save();
  }

  // 無限畫布：單頁
  double minX = double.infinity,
      minY = double.infinity,
      maxX = -double.infinity,
      maxY = -double.infinity;
  for (final s in note.strokes) {
    for (final pt in s.points) {
      if (pt.x < minX) minX = pt.x;
      if (pt.y < minY) minY = pt.y;
      if (pt.x > maxX) maxX = pt.x;
      if (pt.y > maxY) maxY = pt.y;
    }
  }
  if (minX == double.infinity) {
    doc.addPage(pw.Page(pageFormat: PdfPageFormat.a4,
        build: (_) => pw.Container()));
    return doc.save();
  }
  const margin = 40.0;
  final srcX = minX - margin;
  final srcY = minY - margin;
  final srcW = (maxX - minX) + margin * 2;
  final srcH = (maxY - minY) + margin * 2;
  final dstW = PdfPageFormat.a4.width;
  final dstH = dstW * srcH / srcW;
  const dpi = 150.0;
  final imgW = (dstW * dpi / 72).round().clamp(1, 4000);
  final imgH = (dstH * dpi / 72).round().clamp(1, 4000);
  final png = await _rasterize(
      visible(note.strokes), srcX, srcY, srcW, srcH, imgW, imgH,
      hlWidth: hlWidth);
  final format = PdfPageFormat(dstW, dstH);
  doc.addPage(
    pw.Page(
      pageFormat: format,
      build: (_) => pw.Container(
        width: format.width,
        height: format.height,
        child: pw.Image(pw.MemoryImage(png), fit: pw.BoxFit.fill),
      ),
    ),
  );
  return doc.save();
}

/// 把 [strokes] 在畫布取材區內光柵化為 PNG（白底，可選底圖墊底）。
Future<Uint8List> _rasterize(
  List<Stroke> strokes,
  double srcX,
  double srcY,
  double srcW,
  double srcH,
  int imgW,
  int imgH, {
  double hlWidth = 3.0,
  Uint8List? bg,
}) async {
  final rec = ui.PictureRecorder();
  final canvas = ui.Canvas(rec);
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, imgW.toDouble(), imgH.toDouble()),
    ui.Paint()..color = const ui.Color(0xFFFFFFFF),
  );
  canvas.scale(imgW / srcW, imgH / srcH);
  canvas.translate(-srcX, -srcY);
  final bgBytes = bg;
  if (bgBytes != null) {
    final bgImg = await decodePng(bgBytes);
    if (bgImg != null) {
      canvas.drawImageRect(
        bgImg,
        ui.Rect.fromLTWH(
            0, 0, bgImg.width.toDouble(), bgImg.height.toDouble()),
        ui.Rect.fromLTWH(srcX, srcY, srcW, srcH),
        ui.Paint(),
      );
      bgImg.dispose();
    }
  }
  // 按層由底到頂（每層內螢光墊底）；單層時與舊行為一致
  final layers = strokes.map((s) => s.layer).toSet().toList()..sort();
  for (final l in layers) {
    paintStrokesLayered(
        canvas, strokes.where((s) => s.layer == l).toList(),
        hlWidth: hlWidth);
  }
  final pic = rec.endRecording();
  final img = await pic.toImage(imgW, imgH);
  final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
  pic.dispose();
  img.dispose();
  return bytes!.buffer.asUint8List();
}
