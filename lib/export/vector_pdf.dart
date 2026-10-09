import 'dart:math' as math;
import 'dart:typed_data';

import 'package:pdf_document/pdf_document.dart';

import '../ink/stroke_renderer.dart';
import '../models/note.dart';

/// 向量匯出：原 PDF 原樣保留（字保持向量可選），筆跡轉成 PDF 批註疊加上去。
/// 筆跡座標是顯示系（底圖顯示 [_dispW] 內容 px 寬，頁內 x∈[24, 24+_dispW]），
/// 按該頁實際尺寸映射到頁面空間（PDF y 原點在左下，另處理 /Rotate）。
/// 圖層由底到頂依次寫入（後寫的蓋在上面）。
/// 純 Dart，Web 可跑；加解密 PDF 會拋錯，調用方回退光柵。
const double _dispW = 800.0;

int _hexColor(String hex) {
  var h = hex.replaceAll('#', '');
  if (h.length == 6) h = 'FF$h';
  return int.parse(h.substring(2), radix: 16);
}

/// 顯示系點 → PDF 頁面空間點（旋轉感知）。
/// (fx, fy) 為頁內歸一化座標（左上原點），(rw, rh) 為旋轉後尺寸，
/// (mw, mh) 為未旋轉尺寸，rot 為 /Rotate。
/// 返回未旋轉用戶空間座標（crop 原點偏移由調用方加）。
math.Point<double> _unrotate(double fx, double fy, double rw, double rh,
    double mw, double mh, int rot) {
  final px = fx * rw;
  final py = (1 - fy) * rh;
  // /Rotate 是顯示時順時針轉：先轉後平移進正框，再求逆。
  // 90°: 顯示(px,py)=(y_u, mw-x_u) → (mw-py, px)
  // 270°: 顯示(px,py)=(mh-y_u, x_u) → (py, mh-px)
  switch (rot % 360) {
    case 90:
      return math.Point<double>(mw - py, px);
    case 180:
      return math.Point<double>(mw - px, mh - py);
    case 270:
      return math.Point<double>(py, mh - px);
    default:
      return math.Point<double>(px, py);
  }
}

/// 筆跡顯示座標映射到 PDF 頁面座標（點）。供測試。
/// (rotW, rotH) 為旋轉後尺寸（顯示系與之一致），(unrotW, unrotH) 為未旋轉尺寸。
List<(double, double)> mapStrokeToPdf(
  List<NotePoint> points, {
  required double dispH,
  required double rotW,
  required double rotH,
  required double unrotW,
  required double unrotH,
  required double cropLeft,
  required double cropBottom,
  required int rotation,
}) {
  return [
    for (final p in points)
      (() {
        final fx = (p.x - 24) / _dispW;
        final fy = (p.y - 24) / dispH;
        final r =
            _unrotate(fx, fy, rotW, rotH, unrotW, unrotH, rotation);
        return (r.x + cropLeft, r.y + cropBottom);
      })(),
  ];
}

Uint8List buildVectorPdf({
  required Uint8List original,
  required List<Stroke> strokes,
  required List<PageBg> backgrounds,
  double hlWidth = 3.0,
}) {
  final doc = PdfDocument.open(original);
  final editor = PdfEditor(doc);
  final origCount = doc.pageCount;

  // 顯示頁 → 原 PDF 頁：
  // - src 有值：顯式來源（越界/重複認領 → 空白頁）；
  // - src 為 null + key 為空：程式內建筆記，按位置對應（舊行為）；
  // - src 為 null + key 是舊式 `p{j}`：舊文件條目，按原位置 j 認領；
  // - src 為 null + 新 key：後加的空白頁。
  final used = <int>{};
  final effSrc = <int?>[];
  for (var i = 0; i < backgrounds.length; i++) {
    int? s = backgrounds[i].src;
    if (s == null) {
      int? j;
      final key = backgrounds[i].key;
      if (key.isEmpty) {
        j = i;
      } else {
        final m = RegExp(r'^p(\d+)$').firstMatch(key);
        if (m != null) j = int.parse(m[1]!);
      }
      if (j != null && j < origCount && !used.contains(j)) s = j;
    }
    if (s != null && (s < 0 || s >= origCount || !used.add(s))) s = null;
    effSrc.add(s);
  }
  // 源頁尺寸先記下（空白頁參照最近的有源頁）。
  final srcBox = <int, PdfRect>{};
  for (var j = 0; j < origCount; j++) {
    srcBox[j] = doc.pages[j].cropBox;
  }
  PdfRect blankBoxFor(int i) {
    for (var d = 0; d < effSrc.length; d++) {
      for (final k in [i - d, i + d]) {
        if (k >= 0 && k < effSrc.length && effSrc[k] != null) {
          return srcBox[effSrc[k]]!;
        }
      }
    }
    return srcBox[origCount - 1]!;
  }

  if (origCount > 0 && effSrc.isNotEmpty) {
    // 刪掉顯示中不再引用的源頁（全刪光就拋錯 → 調用方回退光柵）。
    final drop = [
      for (var j = 0; j < origCount; j++)
        if (!used.contains(j)) j
    ];
    if (drop.length >= origCount) {
      throw StateError('no source pages referenced');
    }
    if (drop.isNotEmpty) editor.removePages(drop);
    // 剩下的源頁按顯示順序排（keepSrc 無重複；恆等排列跳過）。
    final keepSrc = [for (final s in effSrc) if (s != null) s];
    final cur = used.toList()..sort();
    final order = [for (final s in keepSrc) cur.indexOf(s)];
    if (order.asMap().entries.any((e) => e.key != e.value)) {
      editor.reorderPages(order);
    }
    // 空白顯示頁按顯示位置插入（升序插，at==i 恆成立）。
    for (var i = 0; i < effSrc.length; i++) {
      if (effSrc[i] == null) {
        final b = blankBoxFor(i);
        editor.insertBlankPage(
            width: b.width, height: b.height, at: i);
      }
    }
  }

  var needPages = backgrounds.length;
  for (final s in strokes) {
    if (s.page + 1 > needPages) needPages = s.page + 1;
  }
  // 筆跡超出底圖列表（理論上 fromJson 已補齊）：按末頁尺寸補空白頁
  if (needPages > doc.pageCount && doc.pageCount > 0) {
    final last = doc.pages[doc.pageCount - 1];
    final lw = last.cropBox.width;
    final lh = last.cropBox.height;
    while (doc.pageCount < needPages) {
      editor.insertBlankPage(width: lw, height: lh);
    }
  }

  for (var i = 0; i < needPages && i < doc.pageCount; i++) {
    final page = doc.pages[i];
    final box = page.cropBox;
    final rot = page.rotation;
    // 旋轉後尺寸（底圖渲染系與之一致）
    final rw = (rot == 90 || rot == 270) ? box.height : box.width;
    final rh = (rot == 90 || rot == 270) ? box.width : box.height;
    // 顯示高度：底圖比例；超出底圖的空白頁套用同頁比例
    final bg = i < backgrounds.length
        ? backgrounds[i]
        : backgrounds.isNotEmpty
            ? backgrounds.last
            : const PageBg(w: 800, h: 1131);
    final dispH = _dispW * bg.h / bg.w;
    final sc = rw / _dispW; // 顯示 px → pt（等比）

    // 本頁可見筆按圖層由底到頂（同層保持原順序）
    final indexed = <(int, Stroke)>[];
    for (var k = 0; k < strokes.length; k++) {
      if (strokes[k].page == i) indexed.add((k, strokes[k]));
    }
    indexed.sort((a, b) {
      final l = a.$2.layer.compareTo(b.$2.layer);
      return l != 0 ? l : a.$1.compareTo(b.$1);
    });

    (double, double) mp(NotePoint p) {
      final fx = (p.x - 24) / _dispW;
      final fy = (p.y - 24) / dispH;
      final u = _unrotate(fx, fy, rw, rh, box.width, box.height, rot);
      return (u.x + box.left, u.y + box.bottom);
    }

    for (final (_, s) in indexed) {
      if (s.points.isEmpty) continue;
      final type = PenTypeLabel.parse(s.type);
      final color = _hexColor(s.color);
      if (type == PenType.highlighter) {
        // 螢光：寬線低透明（標準 PDF 高亮做法，字透得出來）
        editor.addInk(
          i,
          [
            [for (final p in s.points) mp(p)]
          ],
          color: color,
          strokeWidth: math.max(0.5, s.size * hlWidth * sc),
          opacity: s.alpha.clamp(0.05, 1.0),
        );
        continue;
      }
      if (type == PenType.dashed && s.points.length >= 2) {
        final dash = s.size * 2.5 * sc;
        final gap = s.size * 1.5 * sc;
        editor.addPolyLine(
          i,
          [for (final p in s.points) mp(p)],
          strokeColor: color,
          strokeWidth: math.max(0.5, s.size * sc),
          dashPattern: [dash, gap],
        );
        continue;
      }
      if (s.geometric && s.points.length == 2) {
        final a = mp(s.points[0]);
        final b = mp(s.points[1]);
        editor.addLine(i, a, b,
            strokeColor: color,
            strokeWidth: math.max(0.5, s.size * sc));
        continue;
      }
      if (s.geometric && s.points.length == 5) {
        // 閉環矩形 → 外接框正方形批註
        var l = double.infinity,
            b = double.infinity,
            r = -double.infinity,
            t = -double.infinity;
        for (final p in s.points) {
          final m = mp(p);
          if (m.$1 < l) l = m.$1;
          if (m.$2 < b) b = m.$2;
          if (m.$1 > r) r = m.$1;
          if (m.$2 > t) t = m.$2;
        }
        editor.addSquare(i, PdfRect(l, b, r, t),
            strokeColor: color,
            strokeWidth: math.max(0.5, s.size * sc));
        continue;
      }
      if (s.geometric && s.points.length > 8) {
        // 閉環圓 → 外接框圓批註
        var l = double.infinity,
            b = double.infinity,
            r = -double.infinity,
            t = -double.infinity;
        for (final p in s.points) {
          final m = mp(p);
          if (m.$1 < l) l = m.$1;
          if (m.$2 < b) b = m.$2;
          if (m.$1 > r) r = m.$1;
          if (m.$2 > t) t = m.$2;
        }
        editor.addCircle(i, PdfRect(l, b, r, t),
            strokeColor: color,
            strokeWidth: math.max(0.5, s.size * sc));
        continue;
      }
      if (s.points.length == 1) {
        // 單點 → 小圓點
        final m = mp(s.points.first);
        final rr = math.max(0.5, s.size * sc * 0.5);
        editor.addCircle(
            i, PdfRect(m.$1 - rr, m.$2 - rr, m.$1 + rr, m.$2 + rr),
            strokeColor: color,
            strokeWidth: 0.5);
        continue;
      }
      // 普通手寫：壓感 polyline
      editor.addInk(
        i,
        [
          [for (final p in s.points) mp(p)]
        ],
        color: color,
        strokeWidth: math.max(0.5, s.size * sc),
        pressures: [
          [for (final p in s.points) p.p.clamp(0.05, 1.0)]
        ],
      );
    }
  }
  return editor.save();
}
