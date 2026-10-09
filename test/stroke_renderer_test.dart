import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_notes/ink/stroke_renderer.dart';
import 'package:ink_notes/models/note.dart';

void main() {
  test('近距離不補點，遠距離線性插值補點', () {
    final near = interpolateGap(const Offset(0, 0), const Offset(3, 4));
    expect(near.length, 1); // 距離=5 不超過 maxGap
    final far = interpolateGap(const Offset(0, 0), const Offset(11, 0));
    expect(far.length, greaterThan(1));
    expect(far.last, const Offset(11, 0));
    // 單調遞增
    for (var i = 1; i < far.length; i++) {
      expect(far[i].dx, greaterThan(far[i - 1].dx));
    }
  });

  test('像素橡皮：中段抹除分裂成兩筆', () {
    final s = Stroke(color: '#000', size: 4, points: [
      for (var i = 0; i < 10; i++)
        NotePoint(x: i * 10.0, y: 0, p: 1, t: i),
    ]);
    final rest = eraseStrokePoints(s, const Offset(45, 0), 12.0);
    expect(rest.length, 2);
    expect(rest.first.points.last.x, lessThan(45));
    expect(rest.last.points.first.x, greaterThan(45));
    // 顏色/粗細保留
    expect(rest.first.color, '#000');
  });

  test('像素橡皮：全抹返回空，未命中原樣', () {
    final s = Stroke(color: '#000', size: 4, points: [
      const NotePoint(x: 0, y: 0, p: 1, t: 0),
      const NotePoint(x: 5, y: 0, p: 1, t: 1),
    ]);
    expect(eraseStrokePoints(s, const Offset(2, 0), 10.0), isEmpty);
    final keep = eraseStrokePoints(s, const Offset(100, 100), 10.0);
    expect(keep.length, 1);
    expect(keep.first.points.length, 2);
  });

  test('toContent：縮放+平移換算，有紙鉗制在紙內', () {
    const page = Rect.fromLTWH(24, 24, 100, 100);
    expect(toContent(const Offset(0, 0), Offset.zero, 1.0, page),
        const Offset(24, 24));
    expect(toContent(const Offset(500, 500), Offset.zero, 1.0, page),
        const Offset(124, 124));
    expect(toContent(const Offset(50, 50), const Offset(10, 10), 1.0, page),
        const Offset(40, 40));
    // 2 倍縮放：屏幕 100 → 內容 50
    expect(toContent(const Offset(100, 100), Offset.zero, 2.0, null),
        const Offset(50, 50));
    // 平移後換算 + 無紙不過濾
    expect(toContent(const Offset(500, 500), Offset.zero, 1.0, null),
        const Offset(500, 500));
  });

  test('dashPath：兩點出虛線段，不足兩點為空', () {
    final d = dashPath(
        [const Offset(0, 0), const Offset(100, 0)], 10, 5);
    expect(d.computeMetrics().length, greaterThan(0));
    expect(dashPath([const Offset(0, 0)], 10, 5).computeMetrics().length, 0);
    expect(dashPath([], 10, 5).computeMetrics().length, 0);
  });

  test('pointInPolygon + selectStrokes：圈中命中', () {
    const loop = [
      Offset(0, 0),
      Offset(100, 0),
      Offset(100, 100),
      Offset(0, 100),
    ];
    expect(pointInPolygon(const Offset(50, 50), loop), isTrue);
    expect(pointInPolygon(const Offset(150, 50), loop), isFalse);
    const inside = Stroke(color: '#000', size: 4, points: [
      NotePoint(x: 50, y: 50, p: 1, t: 0),
      NotePoint(x: 60, y: 60, p: 1, t: 1),
    ]);
    const outside = Stroke(color: '#000', size: 4, points: [
      NotePoint(x: 200, y: 200, p: 1, t: 0),
      NotePoint(x: 210, y: 210, p: 1, t: 1),
    ]);
    // 橫穿圈邊的也命中
    const crosser = Stroke(color: '#000', size: 4, points: [
      NotePoint(x: -50, y: 50, p: 1, t: 0),
      NotePoint(x: 150, y: 50, p: 1, t: 1),
    ]);
    final hits = selectStrokes([inside, outside, crosser], loop);
    expect(hits.length, 2);
    expect(hits.contains(outside), isFalse);
  });

  test('筆型往返：type 存取，舊文件預設 brush', () {
    const s = Stroke(
        color: '#000', size: 4, points: [], type: 'highlighter');
    final rt =
        Stroke.fromJson(Map<String, dynamic>.from(s.toJson()));
    expect(rt.type, 'highlighter');
    expect(PenTypeLabel.parse(rt.type), PenType.highlighter);
    expect(PenTypeLabel.parse(null), PenType.brush);
    expect(PenTypeLabel.parse('nope'), PenType.brush);
  });

  test('Stroke.page 往返（預設 0 頁）', () {
    const s = Stroke(color: '#000', size: 4, points: [], page: 2);
    final rt = Stroke.fromJson(
        Map<String, dynamic>.from(s.toJson()));
    expect(rt.page, 2);
    final legacy = Stroke.fromJson(
        {'color': '#000', 'size': 4.0, 'points': []});
    expect(legacy.page, 0);
  });

  test('clampPan：內容至少留 keep 在屏內', () {
    // A4 紙左右 24~818，視口 770：pan.x ∈ [-698, 626]
    const page = Rect.fromLTWH(24, 24, 794, 1123);
    const view = Size(770, 800);
    expect(clampPan(const Offset(0, 0), view, page).dx, 0);
    expect(clampPan(const Offset(10000, 0), view, page).dx, 626);
    expect(clampPan(const Offset(-10000, 0), view, page).dx, -698);
    // 視口比內容還小到放不下 keep：鎖定中間，不亂飛
    const small = Rect.fromLTWH(0, 0, 100, 100);
    const tinyView = Size(50, 50);
    final locked = clampPan(const Offset(9999, -9999), tinyView, small);
    // lo = 100-100 = 0，hi = 50-0-100 = -50 → (0 + -50)/2
    expect(locked.dx, -25);
    expect(locked.dy, -25);
  });

  test('clampPan 200%：紙底的線滾得到（全屏幕系：視口+內容×scale）', () {
    // A4 紙并集（內容 px）：左右 24~818，單頁上下 24~1146；
    // scale=2 時內容矩形先×2 再拿屏幕視口 870×800 夾。
    const view = Size(870, 800);
    const content = Rect.fromLTWH(24 * 2, 24 * 2, 794 * 2, 1122 * 2);
    // 線在內容 y=1100 → 屏 2200；視口底 800 → pan.y 須 ≤ -1400 才看得見
    final p = clampPan(const Offset(0, -1400), view, content);
    expect(p.dy, -1400); // 不被夾回來
    // 上頂同理對稱：內容頂 48 → pan.y ≤ 800-48-120=632 才不擋
    expect(clampPan(const Offset(0, 632), view, content).dy, 632);
    // 出界還是會被夾：上到 +9999 → 回到 hi=632
    expect(clampPan(const Offset(0, 9999), view, content).dy, 632);
  });

  test('strokesBounds：空返回 null，有筆外擴 margin', () {
    expect(strokesBounds([]), isNull);
    const s = Stroke(color: '#000', size: 4, points: [
      NotePoint(x: 0, y: 0, p: 1, t: 0),
      NotePoint(x: 10, y: 20, p: 1, t: 1),
    ]);
    expect(strokesBounds([s], margin: 0), const Rect.fromLTRB(0, 0, 10, 20));
  });

  test('snapShape：停頓才判；直線/圓/矩形修正，其他不動', () {
    Stroke line(List<Offset> pts, {int stepMs = 8}) => Stroke(
        color: '#000',
        size: 4,
        points: [
          for (var i = 0; i < pts.length; i++)
            NotePoint(x: pts[i].dx, y: pts[i].dy, p: 1, t: i * stepMs),
        ]);
    int dwell(Stroke s) => 1100; // 停頓滿 1s（生產環境傳的就是這個量級的真實時長）

    // 近似直線（帶抖動）+ 收筆停頓 → 2 點直線段
    final straight = line(
        [for (var i = 0; i <= 20; i++) Offset(i * 10.0, (i % 2) * 2.0)]);
    final snapped = snapShape(straight, dwellMs: dwell(straight));
    expect(snapped.length, 1);
    expect(snapped.first.points.length, 2);
    // 同一筆快掃不停留（停頓僅 10ms）→ 不動
    expect(
        identical(
            snapShape(straight, dwellMs: 10).first,
            straight),
        isTrue);
    // 微斜 8° 直線 + 停頓 → 拉直成水平線（y 以出發點為準）
    {
      final tilt = line(
          [for (var i = 0; i <= 20; i++) Offset(i * 10.0, i * 1.4)]);
      final fixed = snapShape(tilt, dwellMs: dwell(tilt));
      expect(fixed.first.points.length, 2);
      final a = fixed.first.points[0], b = fixed.first.points[1];
      expect((a.y - b.y).abs() < 1e-6, isTrue);
      expect(a.y, closeTo(0, 1e-6));
    }
    // 微斜鉛直線 → 拉直成鉛直線（x 以出發點為準）
    {
      final tilt = line(
          [for (var i = 0; i <= 20; i++) Offset(i * 1.4, i * 10.0)]);
      final fixed = snapShape(tilt, dwellMs: dwell(tilt));
      expect(fixed.first.points.length, 2);
      final a = fixed.first.points[0], b = fixed.first.points[1];
      expect((a.x - b.x).abs() < 1e-6, isTrue);
      expect(a.x, closeTo(0, 1e-6));
    }
    // 30° 斜線 → 保持原斜率，不硬掰
    {
      final diag = line(
          [for (var i = 0; i <= 20; i++) Offset(i * 10.0, i * 5.8)]);
      final kept = snapShape(diag, dwellMs: dwell(diag));
      final a = kept.first.points.first, b = kept.first.points.last;
      expect((b.y - a.y).abs() > 1, isTrue);
      expect((b.x - a.x).abs() > 1, isTrue);
    }
    // 圓 + 停頓 → 閉環多邊形
    final circle = line([
      for (var i = 0; i <= 30; i++)
        Offset(100 + 60 * math.cos(i / 30 * 2 * math.pi),
            100 + 60 * math.sin(i / 30 * 2 * math.pi)),
    ]);
    final circled = snapShape(circle, dwellMs: dwell(circle));
    expect(circled.length, 1);
    expect(circled.first.points.length, greaterThan(10));
    // 矩形 + 停頓 → 四角閉環
    final rectPts = <Offset>[
      for (var i = 0; i <= 10; i++) Offset(i * 10.0, 0),
      for (var i = 1; i <= 10; i++) Offset(100, i * 6.0),
      for (var i = 1; i <= 10; i++) Offset(100 - i * 10.0, 60),
      for (var i = 1; i <= 10; i++) Offset(0, 60 - i * 6.0),
    ];
    final rected = snapShape(line(rectPts), dwellMs: dwell(line(rectPts)));
    expect(rected.length, 1);
    expect(rected.first.points.length, 5);
    // 輸出嚴格軸對齊（相鄰角點共用 x 或 y，不會放斜）
    {
      final c = rected.first.points
          .map((p) => Offset(p.x, p.y))
          .toList();
      for (var i = 0; i < 4; i++) {
        final a = c[i], b = c[(i + 1) % 4];
        expect((a.dx - b.dx).abs() < 1e-6 || (a.dy - b.dy).abs() < 1e-6,
            isTrue);
      }
    }
    // 整體旋轉 12 度的方形（$1 報 line/NaN）→ 幾何兜底照樣拉直
    {
      Offset rot(Offset p) {
        const a = 12 * math.pi / 180;
        const cx = 60.0, cy = 45.0;
        return Offset(
          cx + (p.dx - cx) * math.cos(a) - (p.dy - cy) * math.sin(a),
          cy + (p.dx - cx) * math.sin(a) + (p.dy - cy) * math.cos(a),
        );
      }
      final tilted = line(rectPts.map(rot).toList());
      final fixed = snapShape(tilted, dwellMs: dwell(tilted));
      expect(fixed.first.points.length, 5);
      final c =
          fixed.first.points.map((p) => Offset(p.x, p.y)).toList();
      for (var i = 0; i < 4; i++) {
        final a = c[i], b = c[(i + 1) % 4];
        expect((a.dx - b.dx).abs() < 1e-6 || (a.dy - b.dy).abs() < 1e-6,
            isTrue);
      }
    }
    // U 形（上開口）→ 不動，不硬掰成方形
    {
      final u = line([
        for (var i = 0; i <= 10; i++) Offset(0, i * 10.0),
        for (var i = 1; i <= 10; i++) Offset(i * 10.0, 100),
        for (var i = 1; i <= 10; i++) Offset(100, 100 - i * 10.0),
      ]);
      expect(identical(snapShape(u, dwellMs: dwell(u)).first, u), isTrue);
    }
    // 深拱形 → 不動
    final curve = line([
      for (var i = 0; i <= 20; i++)
        Offset(i * 10.0, 480 * (i / 20) * (1 - i / 20)),
    ]);
    expect(
        identical(snapShape(curve, dwellMs: dwell(curve)).first, curve),
        isTrue);
    // 太短不處理
    final tiny = line([const Offset(0, 0), const Offset(5, 0)]);
    expect(
        identical(snapShape(tiny, dwellMs: dwell(tiny)).first, tiny),
        isTrue);
    // 回歸：快畫快放（停頓 30ms）不修正——生產環境以前誤傳絕對時間戳，
    // upMs - last.t 恆巨大導致每次都修正。現在只認真實停頓。
    expect(identical(snapShape(straight, dwellMs: 30).first, straight),
        isTrue);
    expect(
        identical(
            snapShape(circle, dwellMs: 30).first, circle),
        isTrue);
    // 大角度歪斜（20°）方形 → 角點路徑照樣拉直成軸對齊
    {
      Offset rot(Offset p) {
        const a = 20 * math.pi / 180;
        const cx = 60.0, cy = 45.0;
        return Offset(
          cx + (p.dx - cx) * math.cos(a) - (p.dy - cy) * math.sin(a),
          cy + (p.dx - cx) * math.sin(a) + (p.dy - cy) * math.cos(a),
        );
      }
      final tilted = line(rectPts.map(rot).toList());
      final fixed = snapShape(tilted, dwellMs: dwell(tilted));
      expect(fixed.first.points.length, 5);
      final c =
          fixed.first.points.map((p) => Offset(p.x, p.y)).toList();
      for (var i = 0; i < 4; i++) {
        final a = c[i], b = c[(i + 1) % 4];
        expect((a.dx - b.dx).abs() < 1e-6 || (a.dy - b.dy).abs() < 1e-6,
            isTrue);
      }
    }
    // 三角形（3 角）→ 不動；W 形（4 拐但缺口大）→ 不動
    {
      final tri = line([
        for (var i = 0; i <= 10; i++) Offset(50 - i * 5.0, i * 8.0),
        for (var i = 1; i <= 10; i++) Offset(i * 10.0, 80),
        for (var i = 1; i <= 10; i++)
          Offset(100 - i * 5.0, 80 - i * 8.0),
      ]);
      expect(
          identical(snapShape(tri, dwellMs: dwell(tri)).first, tri),
          isTrue);
      final w = line([
        for (var i = 0; i <= 8; i++) Offset(i * 10.0, 80 - (i % 2) * 80),
      ]);
      expect(identical(snapShape(w, dwellMs: dwell(w)).first, w), isTrue);
    }
    // 手抖圓（$1 分低）→ 不被掰成方形（原樣或成圓，絕不 5 點矩形）
    {
      final rnd = math.Random(7);
      final pts = <Offset>[];
      for (var i = 0; i <= 40; i++) {
        final a = i / 40 * 2 * math.pi;
        pts.add(Offset(100 + 60 * math.cos(a) + (rnd.nextDouble() - 0.5) * 20,
            100 + 60 * math.sin(a) + (rnd.nextDouble() - 0.5) * 20));
      }
      final shaky = line(pts);
      final out = snapShape(shaky, dwellMs: dwell(shaky));
      expect(out.first.points.length == 5, isFalse);
    }
  });

  test('clipStrokeToRect：紙外丟掉，跨界插值', () {
    const r = Rect.fromLTWH(0, 0, 100, 100);
    Stroke line(List<Offset> pts) => Stroke(
        color: '#000',
        size: 4,
        points: [
          for (var i = 0; i < pts.length; i++)
            NotePoint(x: pts[i].dx, y: pts[i].dy, p: 1, t: i),
        ]);
    // 全外 → 空
    expect(
        clipStrokeToRect(
            line([const Offset(200, 200), const Offset(300, 300)]), r),
        isEmpty);
    // 穿框 → 保留框內段，邊界有插值點
    final clipped = clipStrokeToRect(
        line([const Offset(-50, 50), const Offset(150, 50)]), r);
    expect(clipped.length, 1);
    expect(clipped.first.points.first.x, 0);
    expect(clipped.first.points.last.x, 100);
    for (final p in clipped.first.points) {
      expect(p.x >= 0 && p.x <= 100, isTrue);
    }
  });

  test('resamplePoints：等弧 n 點', () {
    final pts = resamplePoints(
        [const Offset(0, 0), const Offset(100, 0)], 11);
    expect(pts.length, 11);
    for (var i = 1; i < pts.length; i++) {
      expect((pts[i] - pts[i - 1]).distance, closeTo(10, 1e-6));
    }
    expect(
        resamplePoints([const Offset(5, 5)], 4).length, 1);
  });

  test('flickDir：快而直的縱掃才翻頁', () {
    expect(flickDir(const Offset(0, -300), 0.2), 1);
    expect(flickDir(const Offset(0, 300), 0.2), -1);
    expect(flickDir(const Offset(0, -100), 0.2), 0); // 太慢
    expect(flickDir(const Offset(0, -300), 0.8), 0); // 太久
    expect(flickDir(const Offset(-300, -100), 0.2), 0); // 太橫
  });

  test('橡皮命中檢測：筆畫級距離判定', () {
    const s = Stroke(color: '#000', size: 4, points: [
      NotePoint(x: 0, y: 0, p: 1, t: 0),
      NotePoint(x: 100, y: 0, p: 1, t: 10),
    ]);
    expect(hitStroke(s, const Offset(50, 5)), isTrue);
    expect(hitStroke(s, const Offset(50, 50)), isFalse);
  });
}
