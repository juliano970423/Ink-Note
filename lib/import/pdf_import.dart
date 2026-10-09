import 'dart:typed_data';

import 'package:pdf_document/pdf_document.dart';

import 'pdf_vector.dart';

/// PDF 一页的渲染结果（PNG 字节 + 像素尺寸）。
class RenderedPdfPage {
  final Uint8List png;
  final int w;
  final int h;

  RenderedPdfPage({required this.png, required this.w, required this.h});
}

/// 全页盒子元数据（不渲染，纯解析，毫秒级）：给懒加载导入用，
/// 先建全部页的底图条目（尺寸按 2400 基线等比），像素后台再填。
/// 返回每页 (w, h, src)，w/h 为空表示该页盒子非法（跳过）。
List<({int w, int h, int src})> pageBoxMetas(Uint8List pdfBytes) {
  final doc = PdfDocument.open(pdfBytes);
  final out = <({int w, int h, int src})>[];
  for (var i = 0; i < doc.pageCount; i++) {
    final page = doc.page(i);
    final crop = page.cropBox;
    if (crop.width <= 0 || crop.height <= 0) continue;
    final rot = page.rotation;
    final w = (rot == 90 || rot == 270) ? crop.height : crop.width;
    final h = (rot == 90 || rot == 270) ? crop.width : crop.height;
    var rw = 2400;
    var rh = (2400 * h / w).round();
    if (rh > 4000) {
      rw = (4000 * w / h).round().clamp(1, 4000);
      rh = 4000;
    }
    out.add((w: rw, h: rh.clamp(1, 4000), src: i));
  }
  return out;
}

/// 把 PDF 字节逐页渲染为 PNG（[renderWidth] 为渲染宽度 px，高度按比例）。
/// 向量渲染（纯 Dart，无 pdfium）：文字是字形描边，任意宽度都锐。
/// 2400 宽（A4 约 290 DPI）：显示 800px 落进快取是 3 倍超採；
/// 缩放时按需重渲染更高宽度（见 [renderPdfPageAtWidth] + [bgUpgradeWidth]）。
/// [maxPages] 只渲前 N 页（懒加载导入：先开编辑器，其余后台填）。
/// 白底。调用方负责存底图、建笔记。
Future<List<RenderedPdfPage>> renderPdfPages(
  Uint8List pdfBytes, {
  int renderWidth = 2400,
  int? maxPages,
}) async {
  final doc = PdfDocument.open(pdfBytes);
  final out = <RenderedPdfPage>[];
  final n = maxPages == null
      ? doc.pageCount
      : maxPages.clamp(0, doc.pageCount);
  for (var i = 0; i < n; i++) {
    final r = await renderPdfPageVector(doc, i,
        widthPx: renderWidth.toDouble());
    if (r == null) continue;
    out.add(RenderedPdfPage(png: r.png, w: r.w, h: r.h));
  }
  return out;
}

/// 单页按需渲染（缩放时提清晰度用，[srcPage] 为原 PDF 页码，0 起）。
/// 宽度按 [renderWidth]，高度等比（超 4000 按比缩回来，不压扁）。
/// 頁碼非法/渲染失敗返回 null（調用方保留舊圖）。
Future<RenderedPdfPage?> renderPdfPageAtWidth(
  Uint8List pdfBytes,
  int srcPage, {
  required int renderWidth,
}) async {
  try {
    final doc = PdfDocument.open(pdfBytes);
    if (srcPage < 0 || srcPage >= doc.pageCount) return null;
    final r = await renderPdfPageVector(doc, srcPage,
        widthPx: renderWidth.toDouble());
    if (r == null) return null;
    return RenderedPdfPage(png: r.png, w: r.w, h: r.h);
  } catch (_) {
    return null;
  }
}

/// 縮放後底圖需要多少寬才夠銳（顯示 800px × scale × dpr，按需取檔位）。
/// [decoded] 是當前解碼圖寬（缺圖傳 0，順手補上）；返回 null = 夠用不用動。
/// 檔位 [2400, 3200, 4000]（4000 是單邊上限兼記憶體止損；只升不降）。
int? bgUpgradeWidth(
    {required double scale,
    required double dpr,
    required int decoded,
    int maxWidth = 4000}) {
  const steps = [2400, 3200, 4000];
  final required = (800 * scale * dpr).ceil();
  if (decoded >= required) return null;
  for (final s in steps) {
    if (s >= required) return s > maxWidth ? maxWidth : s;
  }
  return decoded < maxWidth ? maxWidth : null;
}
