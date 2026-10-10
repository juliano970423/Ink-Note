import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:one_dollar_unistroke_recognizer/one_dollar_unistroke_recognizer.dart'
    as r1;
import 'package:perfect_freehand/perfect_freehand.dart' as pf;

import '../models/note.dart';
import 'velocity_tracker.dart';

/// 工具：書寫 / 按筆畫橡皮 / 像素橡皮 / 圈選。
enum ToolMode { pen, strokeEraser, pixelEraser, lasso }

/// 筆型：鋼筆刷（壓感填充）/ 虛線筆 / 螢光筆（半透明寬線墊底）。
enum PenType { brush, dashed, highlighter }

extension PenTypeLabel on PenType {
  String get label {
    switch (this) {
      case PenType.brush:
        return '筆刷';
      case PenType.dashed:
        return '虛線';
      case PenType.highlighter:
        return '螢光';
    }
  }

  static PenType parse(String? name) {
    for (final v in PenType.values) {
      if (v.name == name) return v;
    }
    return PenType.brush;
  }
}

/// 一筆的記憶體表示（含每個點的壓感與時間戳）。
class LiveStroke {
  final String color;
  final double size;
  final int page;
  final PenType penType;
  final double alpha;
  final List<Offset> positions = [];
  final List<double> pressures = [];
  final List<Duration> times = [];

  LiveStroke(
      {required this.color,
      required this.size,
      this.page = 0,
      this.penType = PenType.brush,
      this.alpha = 1.0});

  Stroke toStroke() {
    final base = times.isEmpty ? Duration.zero : times.first;
    final pts = List.generate(
      positions.length,
      (i) => NotePoint(
        x: positions[i].dx,
        y: positions[i].dy,
        p: pressures[i],
        t: (times[i] - base).inMilliseconds,
      ),
    );
    return Stroke(
        color: color,
        size: size,
        points: pts,
        page: page,
        type: penType.name,
        alpha: alpha);
  }
}

/// 快速移動時採樣點變稀：相鄰兩點距離 > [maxGap] 時線性插值補點（pressure 同步內插）。
List<Offset> interpolateGap(Offset a, Offset b, {double maxGap = 5.0}) {
  final dist = (b - a).distance;
  if (dist <= maxGap) return [b];
  final n = (dist / maxGap).ceil();
  return List.generate(n, (i) {
    final t = (i + 1) / n;
    return Offset(
      a.dx + (b.dx - a.dx) * t,
      a.dy + (b.dy - a.dy) * t,
    );
  });
}

/// 用 perfect_freehand（僅當輪廓生成器）把一筆轉成填充輪廓點列。
/// 調用方需 `simulatePressure: false`（壓感由我們自己算好傳入）。
List<Offset> strokeOutline(
  List<Offset> positions,
  List<double> pressures, {
  required StrokeParams params,
}) {
  assert(positions.length == pressures.length);
  final points = List.generate(
    positions.length,
    (i) => pf.PointVector(
      positions[i].dx,
      positions[i].dy,
      pressures[i].clamp(0.05, 1.0),
    ),
  );
  // perfect_freehand 只當輪廓生成器：壓感由我們自己算好傳入（simulatePressure: false）。
  final outline = pf.getStroke(
    points,
    options: pf.StrokeOptions(
      size: params.size,
      thinning: params.thinning,
      streamline: params.streamline,
      simulatePressure: false,
      isComplete: true,
    ),
  );
  return outline.map((e) => Offset(e.dx, e.dy)).toList();
}

/// 像素橡皮：抹除 [pos] 半徑 [radius] 內的採樣點，被抹除處斷開，
/// 一筆可能分裂成多筆（單點殘留保留為圓點筆）。全抹則返回空列表。
List<Stroke> eraseStrokePoints(Stroke s, Offset pos, double radius) {
  final runs = <List<NotePoint>>[];
  var cur = <NotePoint>[];
  for (final pt in s.points) {
    if ((Offset(pt.x, pt.y) - pos).distance <= radius) {
      if (cur.isNotEmpty) {
        runs.add(cur);
        cur = <NotePoint>[];
      }
    } else {
      cur.add(pt);
    }
  }
  if (cur.isNotEmpty) runs.add(cur);
  return runs
      .map((pts) => Stroke(
          color: s.color,
          size: s.size,
          points: pts,
          page: s.page,
          type: s.type,
          geometric: s.geometric))
      .toList();
}

/// 把畫布局部座標換算為內容座標並（有紙時）鉗制在紙內，防畫到紙外。
/// 畫面關係：screen = content * scale + pan。
Offset toContent(Offset local, Offset pan, double scale, Rect? pageRect) {
  var p = (local - pan) / scale;
  final r = pageRect;
  if (r != null) {
    p = Offset(
      p.dx.clamp(r.left, r.right),
      p.dy.clamp(r.top, r.bottom),
    );
  }
  return p;
}

/// 等弧長重採樣為 n 點（手寫識別 / 均勻虛線用）。
List<Offset> resamplePoints(List<Offset> pts, int n) {
  if (pts.length < 2 || n <= 1) {
    return List<Offset>.from(pts);
  }
  final total = pathLength(pts);
  if (total <= 0) return List<Offset>.filled(n, pts.first);
  final step = total / (n - 1);
  final out = <Offset>[pts.first];
  var acc = 0.0;
  var prev = pts.first;
  var i = 1;
  while (out.length < n - 1) {
    if (i >= pts.length) break;
    final d = (pts[i] - prev).distance;
    if (acc + d >= step) {
      final t = (step - acc) / d;
      final p = Offset(
        prev.dx + (pts[i].dx - prev.dx) * t,
        prev.dy + (pts[i].dy - prev.dy) * t,
      );
      out.add(p);
      prev = p;
      acc = 0.0;
    } else {
      acc += d;
      prev = pts[i];
      i++;
    }
  }
  while (out.length < n) {
    out.add(pts.last);
  }
  return out;
}

/// 虛線路徑：沿折線按 dash/gap 交替切段（圓頭由 Paint.strokeCap 處理）。
Path dashPath(List<Offset> pts, double dash, double gap) {
  final path = Path();
  if (pts.length < 2 || dash <= 0) return path;
  var drawing = true;
  var left = dash;
  var cur = pts[0];
  var sub = Path()..moveTo(cur.dx, cur.dy);
  var i = 1;
  var segLeft = (pts[1] - pts[0]).distance;
  var dir = segLeft == 0 ? Offset.zero : (pts[1] - pts[0]) / segLeft;
  while (true) {
    if (segLeft <= 0) {
      i++;
      if (i >= pts.length) break;
      cur = pts[i - 1];
      segLeft = (pts[i] - cur).distance;
      if (segLeft == 0) continue;
      dir = (pts[i] - cur) / segLeft;
      continue;
    }
    final step = left < segLeft ? left : segLeft;
    final next = cur + dir * step;
    if (drawing) sub.lineTo(next.dx, next.dy);
    cur = next;
    segLeft -= step;
    left -= step;
    if (left <= 0) {
      if (drawing) {
        path.addPath(sub, Offset.zero);
        sub = Path();
      } else {
        sub.moveTo(cur.dx, cur.dy);
      }
      drawing = !drawing;
      left = drawing ? dash : gap;
    }
  }
  if (drawing) path.addPath(sub, Offset.zero);
  return path;
}

/// 折線總長度。
double pathLength(List<Offset> pts) {
  var len = 0.0;
  for (var i = 1; i < pts.length; i++) {
    len += (pts[i] - pts[i - 1]).distance;
  }
  return len;
}

/// 形狀快照：直線 / 圓 / 矩形（$1 識別庫判定 + 幾何兜底）。
/// 只有收筆前停頓滿 1s（[dwellMs] ≥ 1000，抬起時刻減末點時刻）才判定，
/// 快掃不停留的不碰。不像就原樣返回 [s]。只對筆刷筆调用。
/// 注意 [dwellMs] 是真實停頓時長（兩個絕對事件時間戳之差），不要傳時間戳。
List<Stroke> snapShape(Stroke s, {required int dwellMs}) {
  final pts = s.points.map((p) => Offset(p.x, p.y)).toList();
  if (pts.length < 8) return [s];
  final total = pathLength(pts);
  if (total < 60) return [s];
  final start = pts.first;
  // 收筆前按住約 1s 才判定；快掃不停留的不碰
  if (dwellMs < 1000) return [s];

  NotePoint np(Offset o, double p, int t) =>
      NotePoint(x: o.dx, y: o.dy, p: p, t: t);
  Stroke mk(List<Offset> poly) => Stroke(
        color: s.color,
        size: s.size,
        points: [
          for (var i = 0; i < poly.length; i++) np(poly[i], 0.9, i * 8),
        ],
        page: s.page,
        type: s.type,
        alpha: s.alpha,
        geometric: true,
      );

  final rec = r1.recognizeUnistroke(resamplePoints(pts, 64));
  if (rec != null && rec.score.isFinite) {
  // 直線：$1 專用直線算法（旋轉縮放不變）。
  // 常用線加軸吸附：±15° 內拉直成水平/鉛直，座標以出發點為準。
  if (rec.name == r1.DefaultUnistrokeNames.line && rec.score >= 0.6) {
    const axisTol = 0.2679; // tan(15°)
    final dx = pts.last.dx - start.dx;
    final dy = pts.last.dy - start.dy;
    if (dx.abs() > 1e-9 && dy.abs() <= axisTol * dx.abs()) {
      return [
        mk([Offset(start.dx, start.dy), Offset(pts.last.dx, start.dy)])
      ];
    }
    if (dy.abs() > 1e-9 && dx.abs() <= axisTol * dy.abs()) {
      return [
        mk([Offset(start.dx, start.dy), Offset(start.dx, pts.last.dy)])
      ];
    }
    return [
      mk([start, pts.last])
    ];
  }
  // 圓：包圍盒定圓心半徑，40 點閉環
  if (rec.name == r1.DefaultUnistrokeNames.circle && rec.score >= 0.8) {
    final (cc, cr) = rec.convertToCircle();
    final poly = <Offset>[
      for (var i = 0; i <= 40; i++)
        Offset(
          cc.dx + cr * math.cos(i / 40 * 2 * math.pi),
          cc.dy + cr * math.sin(i / 40 * 2 * math.pi),
        ),
    ];
    return [mk(poly)];
  }
  // 矩形：包圍盒四角閉環（只用 $1 做分類，幾何取原點 bbox，嚴格軸對齊）
  if (rec.name == r1.DefaultUnistrokeNames.rectangle && rec.score >= 0.8) {
    final r = _bboxOf(pts);
    return [
      mk([
        r.topLeft,
        r.topRight,
        r.bottomRight,
        r.bottomLeft,
        r.topLeft,
      ])
    ];
  }
  // $1 说是圆（分还行）→ 别硬掰成方形，直接原样
  if (rec.name == r1.DefaultUnistrokeNames.circle && rec.score >= 0.5) {
    return [s];
  }
  }
  // 幾何路徑一：角點數判定（歪斜手繪方形也能抓到，輸出嚴格軸對齊）。
  // 閉合門控：缺口太大（W 形這種）不算框。
  final qb = _bboxOf(pts);
  final qClosed =
      (pts.first - pts.last).distance <= 0.35 * (qb.width + qb.height);
  final corners = qClosed ? _cornerCount(pts) : 0;
  if (corners >= 4 && corners <= 6) {
    final r = qb;
    return [
      mk([
        r.topLeft,
        r.topRight,
        r.bottomRight,
        r.bottomLeft,
        r.topLeft,
      ])
    ];
  }
  // 幾何路徑二：圓角方形（無銳角點）用包圍盒邊緣覆蓋率判定；
  // 角點太多（圓/星形塗鴉）的不碰，免得圓被掰成方形。
  if (corners <= 3) {
    final fallback = _axisRect(pts);
    if (fallback != null) {
      return [
        mk([
          fallback.topLeft,
          fallback.topRight,
          fallback.bottomRight,
          fallback.bottomLeft,
          fallback.topLeft,
        ])
      ];
    }
  }
  return [s];
}

/// 轉角數：等弧重採樣 48 點，雙窗口轉向角找銳角拐點。
/// 真拐角在窄窗（±2 點）和寬窗（±5 點）下轉向都大；毛刺只在窄窗大、
/// 圓弧只在寬窗大，兩者都過濾掉。相鄰拐點合併後計數。
int _cornerCount(List<Offset> pts) {
  final re = resamplePoints(pts, 48);
  if (re.length < 12) return 0;
  double turn(int i, int k) {
    final n = re.length;
    if (i - k < 0 || i + k >= n) return 0; // 不跨頭尾，避免缺口處人工拐角
    final a = re[i - k];
    final b = re[i];
    final c = re[i + k];
    final v1x = b.dx - a.dx, v1y = b.dy - a.dy;
    final v2x = c.dx - b.dx, v2y = c.dy - b.dy;
    final l1 = math.sqrt(v1x * v1x + v1y * v1y);
    final l2 = math.sqrt(v2x * v2x + v2y * v2y);
    if (l1 < 1e-9 || l2 < 1e-9) return 0;
    final cross = v1x * v2y - v1y * v2x;
    final dot = v1x * v2x + v1y * v2y;
    return math.atan2(cross.abs(), dot);
  }

  final strong = <int>[];
  for (var i = 5; i < re.length - 5; i++) {
    if (turn(i, 2) > 0.7 && turn(i, 5) > 0.5) strong.add(i);
  }
  // 貪心去重：按強度取，互斥 5 點內
  strong.sort((a, b) => turn(b, 2).compareTo(turn(a, 2)));
  final picked = <int>[];
  for (final i in strong) {
    if (picked.every((p) => (p - i).abs() >= 5)) picked.add(i);
    if (picked.length > 6) break;
  }
  return picked.length;
}

/// PNG/JPEG 字節解碼為 ui.Image（底圖/縮圖用），失敗返回 null。
Future<ui.Image?> decodePng(Uint8List bytes) async {
  try {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    return frame.image;
  } catch (_) {
    return null;
  }
}

/// 點列包圍盒。
Rect _bboxOf(List<Offset> pts) {
  var l = double.infinity, t = double.infinity;
  var r = -double.infinity, b = -double.infinity;
  for (final p in pts) {
    if (p.dx < l) l = p.dx;
    if (p.dy < t) t = p.dy;
    if (p.dx > r) r = p.dx;
    if (p.dy > b) b = p.dy;
  }
  return Rect.fromLTRB(l, t, r, b);
}

/// 軸對齊矩形判定：閉合 + 四條邊都有足夠點貼邊。
/// 不像返回 null。U 形/拱形/直線/圓分散點會被擋掉。
Rect? _axisRect(List<Offset> pts) {
  final r = _bboxOf(pts);
  final w = r.width, h = r.height;
  if (w < 24 || h < 24) return null;
  if (w > h * 6 || h > w * 6) return null; // 細長條是線不是框
  // 閉合：首尾距離相對周長要小
  if ((pts.first - pts.last).distance > 0.30 * (w + h)) return null;
  final tol = math.max(8.0, 0.16 * math.min(w, h));
  var near = 0;
  var top = 0, bottom = 0, left = 0, right = 0;
  for (final p in pts) {
    final dTop = (p.dy - r.top).abs();
    final dBottom = (p.dy - r.bottom).abs();
    final dLeft = (p.dx - r.left).abs();
    final dRight = (p.dx - r.right).abs();
    final m = math.min(math.min(dTop, dBottom), math.min(dLeft, dRight));
    if (m <= tol) {
      near++;
      if (dTop == m) {
        top++;
      } else if (dBottom == m) {
        bottom++;
      } else if (dLeft == m) {
        left++;
      } else {
        right++;
      }
    }
  }
  if (near < pts.length * 0.72) return null;
  final each = pts.length * 0.06;
  if (top < each || bottom < each || left < each || right < each) return null;
  return r;
}

/// 把筆畫裁到矩形內：保留框內連段（含穿框而過的段），跨界處插值補邊界點。
/// 全在外面返回空列表。
List<Stroke> clipStrokeToRect(Stroke s, Rect r) {
  const eps = 1e-9;
  NotePoint at(NotePoint a, NotePoint b, double t) => NotePoint(
        x: a.x + (b.x - a.x) * t,
        y: a.y + (b.y - a.y) * t,
        p: a.p + (b.p - a.p) * t,
        t: a.t,
      );

  final runs = <List<NotePoint>>[];
  var cur = <NotePoint>[];
  final pts = s.points;
  if (pts.length == 1) {
    final p = pts.first;
    if (p.x >= r.left && p.x <= r.right && p.y >= r.top && p.y <= r.bottom) {
      return [
        Stroke(
            color: s.color,
            size: s.size,
            points: [p],
            page: s.page,
            type: s.type,
            geometric: s.geometric)
      ];
    }
    return [];
  }
  for (var i = 0; i + 1 < pts.length; i++) {
    final a = pts[i], b = pts[i + 1];
    final seg = _liangBarsky(Offset(a.x, a.y), Offset(b.x, b.y), r);
    if (seg == null) {
      if (cur.isNotEmpty) {
        runs.add(cur);
        cur = <NotePoint>[];
      }
      continue;
    }
    final t0 = seg[0], t1 = seg[1];
    if (cur.isEmpty) cur.add(at(a, b, t0));
    if (t1 >= 1 - eps) {
      cur.add(b);
    } else {
      cur.add(at(a, b, t1));
      runs.add(cur);
      cur = <NotePoint>[];
    }
  }
  if (cur.isNotEmpty) runs.add(cur);
  return runs
      .map((run) => Stroke(
          color: s.color,
          size: s.size,
          points: run,
          page: s.page,
          type: s.type,
          geometric: s.geometric))
      .toList();
}

/// Liang-Barsky 線段裁剪：返回 [t0, t1]，不相交返回 null。
List<double>? _liangBarsky(Offset a, Offset b, Rect r) {
  var t0 = 0.0, t1 = 1.0;
  final dx = b.dx - a.dx, dy = b.dy - a.dy;
  bool clip(double p, double q) {
    if (p == 0) return q >= 0;
    final t = q / p;
    if (p < 0) {
      if (t > t1) return false;
      if (t > t0) t0 = t;
    } else {
      if (t < t0) return false;
      if (t < t1) t1 = t;
    }
    return true;
  }

  if (!clip(-dx, a.dx - r.left)) return null;
  if (!clip(dx, r.right - a.dx)) return null;
  if (!clip(-dy, a.dy - r.top)) return null;
  if (!clip(dy, r.bottom - a.dy)) return null;
  if (t0 > t1) return null;
  return [t0, t1];
}

/// 雙指快掃翻頁判定：0.5s 內縱向速度 >800px/s 且縱向主導。
/// 返回 +1 下一頁 / -1 上一頁 / 0 不翻。
int flickDir(Offset delta, double dtSeconds) {
  if (dtSeconds <= 0 || dtSeconds >= 0.5) return 0;
  if (delta.dy.abs() <= 800 * dtSeconds) return 0;
  if (delta.dy.abs() <= 1.5 * delta.dx.abs()) return 0;
  return delta.dy < 0 ? 1 : -1;
}

/// 射線法點在多邊形內判定。
bool pointInPolygon(Offset p, List<Offset> loop) {
  var inside = false;
  for (var i = 0, j = loop.length - 1; i < loop.length; j = i++) {
    final a = loop[i], b = loop[j];
    if ((a.dy > p.dy) != (b.dy > p.dy) &&
        p.dx < (b.dx - a.dx) * (p.dy - a.dy) / (b.dy - a.dy) + a.dx) {
      inside = !inside;
    }
  }
  return inside;
}

bool _segIntersect(Offset p1, Offset p2, Offset p3, Offset p4) {
  double d(Offset a, Offset b, Offset c) =>
      (b.dx - a.dx) * (c.dy - a.dy) - (b.dy - a.dy) * (c.dx - a.dx);
  final d1 = d(p3, p4, p1), d2 = d(p3, p4, p2);
  final d3 = d(p1, p2, p3), d4 = d(p1, p2, p4);
  return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) &&
      ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0));
}

/// 圈選命中：任一採樣點在圈內，或任一段與圈邊相交。
List<Stroke> selectStrokes(List<Stroke> strokes, List<Offset> loop) {
  if (loop.length < 3) return [];
  var lx0 = double.infinity,
      ly0 = double.infinity,
      lx1 = -double.infinity,
      ly1 = -double.infinity;
  for (final p in loop) {
    if (p.dx < lx0) lx0 = p.dx;
    if (p.dy < ly0) ly0 = p.dy;
    if (p.dx > lx1) lx1 = p.dx;
    if (p.dy > ly1) ly1 = p.dy;
  }
  final hit = <Stroke>[];
  for (final s in strokes) {
    // 筆BBox與圈BBox相交才可能命中（端點全在外、但線段穿框而過的也要留）
    var sx0 = double.infinity,
        sy0 = double.infinity,
        sx1 = -double.infinity,
        sy1 = -double.infinity;
    for (final pt in s.points) {
      if (pt.x < sx0) sx0 = pt.x;
      if (pt.y < sy0) sy0 = pt.y;
      if (pt.x > sx1) sx1 = pt.x;
      if (pt.y > sy1) sy1 = pt.y;
    }
    if (sx1 < lx0 || sx0 > lx1 || sy1 < ly0 || sy0 > ly1) continue;
    var ok = false;
    for (final pt in s.points) {
      if (pointInPolygon(Offset(pt.x, pt.y), loop)) {
        ok = true;
        break;
      }
    }
    if (!ok) {
      outer:
      for (var i = 0; i + 1 < s.points.length; i++) {
        final a = Offset(s.points[i].x, s.points[i].y);
        final b = Offset(s.points[i + 1].x, s.points[i + 1].y);
        for (var j = 0; j < loop.length; j++) {
          if (_segIntersect(a, b, loop[j], loop[(j + 1) % loop.length])) {
            ok = true;
            break outer;
          }
        }
      }
    }
    if (ok) hit.add(s);
  }
  return hit;
}

/// 筆跡包圍盒（向外擴 [margin]），空筆記返回 null。
/// margin 給足（600），免得在內容邊緣想繼續畫時被邊界擋住。
Rect? strokesBounds(List<Stroke> strokes, {double margin = 600}) {
  if (strokes.isEmpty) return null;
  var minX = double.infinity,
      minY = double.infinity,
      maxX = -double.infinity,
      maxY = -double.infinity;
  for (final s in strokes) {
    for (final pt in s.points) {
      if (pt.x < minX) minX = pt.x;
      if (pt.y < minY) minY = pt.y;
      if (pt.x > maxX) maxX = pt.x;
      if (pt.y > maxY) maxY = pt.y;
    }
  }
  if (minX == double.infinity) return null;
  return Rect.fromLTRB(
      minX - margin, minY - margin, maxX + margin, maxY + margin);
}

/// 平移硬邊界：保證內容區 [content] 至少有 [keep] px 留在視口內，紙飛不出去。
/// 內容比視口小到連 keep 都放不下時鎖定居中。
Offset clampPan(Offset pan, Size viewport, Rect content, {double keep = 120}) {
  double clampAxis(double p, double view, double c0, double c1) {
    final k = keep.clamp(0, (c1 - c0).toDouble());
    // 可見內容區間 [L, L+view]（L = -p）需與 [c0, c1] 重疊至少 k：
    // L ≤ c1-k → p ≥ k-c1；L+view ≥ c0+k → p ≤ view-c0-k
    final lo = k - c1;
    final hi = view - c0 - k;
    if (lo > hi) return (lo + hi) / 2;
    return p.clamp(lo, hi);
  }

  return Offset(
    clampAxis(pan.dx, viewport.width, content.left, content.right),
    clampAxis(pan.dy, viewport.height, content.top, content.bottom),
  );
}

/// 單筆命中檢測（按筆畫橡皮用）：中心線折線任一線段距離 <= threshold 即命中。
bool hitStroke(Stroke s, Offset pos, {double threshold = 12.0}) {
  if (s.points.isEmpty) return false;
  if (s.points.length == 1) {
    final pt = s.points.first;
    return (Offset(pt.x, pt.y) - pos).distance <= threshold;
  }
  for (var i = 0; i < s.points.length - 1; i++) {
    final a = Offset(s.points[i].x, s.points[i].y);
    final b = Offset(s.points[i + 1].x, s.points[i + 1].y);
    if (_segDist(pos, a, b) <= threshold) return true;
  }
  return false;
}

double _segDist(Offset p, Offset a, Offset b) {
  final abx = b.dx - a.dx;
  final aby = b.dy - a.dy;
  final len2 = abx * abx + aby * aby;
  if (len2 == 0) return (p - a).distance;
  var t = ((p.dx - a.dx) * abx + (p.dy - a.dy) * aby) / len2;
  t = t.clamp(0.0, 1.0);
  final cx = a.dx + abx * t;
  final cy = a.dy + aby * t;
  return (Offset(p.dx - cx, p.dy - cy)).distance;
}

/// 頁 + 層分組鍵（paintPagesToPicture 用）。
typedef PageLayer = ({int page, int layer});

/// 只把 PDF 底圖畫成一張 Picture（顯示分層：底圖層，筆跡另成一張疊上面）。
Future<ui.Picture> paintBgToPicture({
  Map<int, ui.Image>? backgrounds,
  Rect? Function(int page)? bgRectOf,
}) async {
  final rec = ui.PictureRecorder();
  final canvas = ui.Canvas(rec);
  // PDF 底圖墊在一切之下（高品質過濾：縮進 800px 快取要乾淨，
  // 放大看時 GPU 放大也盡量平滑）
  final bgs = backgrounds;
  final rOf = bgRectOf;
  if (bgs != null && rOf != null) {
    for (final entry in bgs.entries) {
      final r = rOf(entry.key);
      if (r == null) continue;
      canvas.drawImageRect(
        entry.value,
        Rect.fromLTWH(0, 0, entry.value.width.toDouble(),
            entry.value.height.toDouble()),
        r,
        Paint()..filterQuality = FilterQuality.high,
      );
    }
  }
  return rec.endRecording();
}

/// 把多頁多層筆畫渲染成 ui.Picture（連續頁面快取用）。
/// [groups] 以 (頁, 層) 分組；繪製順序：底圖 → 層由底到頂，每層內螢光筆墊底。
/// [byPage] 為頁內座標筆畫，[origin] 把頁內座標平移到堆疊座標（紙筆記第 i 頁平移
/// (0, top(i)-24)，無限畫布恆零）。螢光筆依然全部墊底。
/// [includeBackgrounds] 顯示分層時傳 false（底圖另成一張走 [paintBgToPicture]）；
/// 匯出/縮圖合成保持預設 true。
Future<ui.Picture> paintPagesToPicture(
  Map<PageLayer, List<Stroke>> groups,
  Offset Function(int page) origin, {
  double hlWidth = 3.0,
  StrokeParams? params,
  Map<int, ui.Image>? backgrounds,
  Rect? Function(int page)? bgRectOf,
  bool includeBackgrounds = true,
}) async {
  final rec = ui.PictureRecorder();
  final canvas = ui.Canvas(rec);
  if (includeBackgrounds) {
    final bgPic =
        await paintBgToPicture(backgrounds: backgrounds, bgRectOf: bgRectOf);
    canvas.drawPicture(bgPic);
    bgPic.dispose();
  }
  final keys = groups.keys.toList()
    ..sort((a, b) {
      final l = a.layer.compareTo(b.layer);
      return l != 0 ? l : a.page.compareTo(b.page);
    });
  // 先畫所有組的螢光（墊底），再畫其餘
  for (final passHl in [true, false]) {
    for (final k in keys) {
      canvas.save();
      canvas.translate(origin(k.page).dx, origin(k.page).dy);
      for (final s in groups[k]!) {
        final isHl = PenTypeLabel.parse(s.type) == PenType.highlighter;
        if (isHl == passHl) {
          paintStroke(canvas, s, hlWidth: hlWidth, params: params);
        }
      }
      canvas.restore();
    }
  }
  return rec.endRecording();
}

/// 連續頁面：內容 y 歸屬哪一頁（頁間縫隙按就近向上歸屬）。
int pageFromY(double y, List<Rect> pageRects, {double gapHalf = 24}) {
  for (var i = 0; i < pageRects.length; i++) {
    if (y <= pageRects[i].bottom + gapHalf) return i;
  }
  return pageRects.isEmpty ? 0 : pageRects.length - 1;
}

/// 堆疊座標 → 頁內座標（第 0 頁恆等，零遷移）。
Offset pageLocalOf(Offset stacked, Rect pageRect) =>
    stacked - Offset(0, pageRect.top - 24);

/// 頁內座標 → 堆疊座標。
Offset stackedOf(Offset local, Rect pageRect) =>
    local + Offset(0, pageRect.top - 24);
Future<ui.Picture> paintStrokesToPicture(
  List<Stroke> strokes, {
  ui.Size? logicalSize,
  double hlWidth = 3.0,
  StrokeParams? params,
}) async {
  final rec = ui.PictureRecorder();
  final canvas = ui.Canvas(rec);
  paintStrokesLayered(canvas, strokes, hlWidth: hlWidth, params: params);
  return rec.endRecording();
}

/// 螢光先畫、其餘後畫（縮圖 / PDF / 快取共用）。
/// [hlWidth] 為螢光筆寬度倍數（相對 s.size）。
void paintStrokesLayered(ui.Canvas canvas, List<Stroke> strokes,
    {double hlWidth = 3.0, StrokeParams? params}) {
  for (final s in strokes) {
    if (PenTypeLabel.parse(s.type) == PenType.highlighter) {
      paintStroke(canvas, s, hlWidth: hlWidth, params: params);
    }
  }
  for (final s in strokes) {
    if (PenTypeLabel.parse(s.type) != PenType.highlighter) {
      paintStroke(canvas, s, hlWidth: hlWidth, params: params);
    }
  }
}

/// 中心線折線路徑（虛線/螢光筆用）。
Path _centerPath(Stroke s) {
  final path = Path();
  if (s.points.isEmpty) return path;
  path.moveTo(s.points.first.x, s.points.first.y);
  for (var i = 1; i < s.points.length; i++) {
    path.lineTo(s.points[i].x, s.points[i].y);
  }
  return path;
}

/// 在 dart:ui 畫布上繪製單筆（縮圖 / PDF / Picture 快取共用）。
/// 壓感取自存好的 `p`，不重算。螢光透明度取自存好的 `alpha`。
void paintStroke(ui.Canvas canvas, Stroke s,
    {double hlWidth = 3.0, StrokeParams? params}) {
  final type = PenTypeLabel.parse(s.type);
  final alpha = s.alpha.clamp(0.05, 1.0);
  // 幾何筆（修正產物）：折線控制點直接描邊，首尾相接的閉環；
  // 不走壓感輪廓（尖角折線的輪廓會算歪）。
  if (type == PenType.brush && s.geometric) {
    if (s.points.isEmpty) return;
    if (s.points.length == 1) {
      final pt = s.points.first;
      canvas.drawCircle(
        Offset(pt.x, pt.y),
        s.size * 0.5,
        Paint()..color = _parseColor(s.color),
      );
      return;
    }
    final path = Path()
      ..moveTo(s.points.first.x, s.points.first.y);
    for (var i = 1; i < s.points.length; i++) {
      path.lineTo(s.points[i].x, s.points[i].y);
    }
    final first = s.points.first, last = s.points.last;
    if ((Offset(first.x, first.y) - Offset(last.x, last.y)).distance < 1e-6) {
      path.close();
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = _parseColor(s.color)
        ..style = PaintingStyle.stroke
        ..strokeWidth = s.size
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    return;
  }
  if (type == PenType.highlighter) {
    // 標準半透明：蓋在字上（「字下面」需求已收回），字透得出來就好。
    if (s.points.isEmpty) return;
    if (s.points.length == 1) {
      final pt = s.points.first;
      canvas.drawCircle(
        Offset(pt.x, pt.y),
        s.size * 1.5 + 1,
        Paint()..color = _parseColor(s.color).withValues(alpha: alpha),
      );
      return;
    }
    canvas.drawPath(
      _centerPath(s),
      Paint()
        ..color = _parseColor(s.color).withValues(alpha: alpha)
        ..style = PaintingStyle.stroke
        ..strokeWidth = s.size * hlWidth
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    return;
  }
  if (type == PenType.dashed) {
    if (s.points.length == 1) {
      final pt = s.points.first;
      canvas.drawCircle(
        Offset(pt.x, pt.y),
        s.size * 0.5,
        Paint()..color = _parseColor(s.color),
      );
      return;
    }
    // 先按 2px 等弧重採樣：虛線節距與書寫速度無關，顆顆等長
    var pts = s.points.map((e) => Offset(e.x, e.y)).toList();
    final len = pathLength(pts);
    if (len > 0) pts = resamplePoints(pts, (len / 2).ceil().clamp(2, 4000));
    canvas.drawPath(
      dashPath(pts, s.size * 2.5, s.size * 1.5),
      Paint()
        ..color = _parseColor(s.color)
        ..style = PaintingStyle.stroke
        ..strokeWidth = s.size
        ..strokeCap = StrokeCap.round,
    );
    return;
  }
  if (s.points.length == 1) {
    final pt = s.points.first;
    final paint = Paint()
      ..color = _parseColor(s.color)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset(pt.x, pt.y), s.size * pt.p * 0.5 + 0.5, paint);
    return;
  }
  final positions = s.points.map((e) => Offset(e.x, e.y)).toList();
  final pressures = s.points.map((e) => e.p).toList();
  // 輪廓參數必須和書寫預覽用同一套（thinning/streamline），否則收筆閃變；
  // size 取存檔值，壓感取存好的 p，不重算。
  final eff = (params ?? StrokeParams()).copy()..size = s.size;
  final outline = strokeOutline(positions, pressures, params: eff);
  if (outline.length < 3) return;
  final path = Path()..moveTo(outline.first.dx, outline.first.dy);
  for (var i = 1; i < outline.length; i++) {
    path.lineTo(outline[i].dx, outline[i].dy);
  }
  path.close();
  canvas.drawPath(
    path,
    Paint()
      ..color = _parseColor(s.color)
      ..style = PaintingStyle.fill,
  );
}

Color _parseColor(String hex) {
  var h = hex.replaceAll('#', '');
  if (h.length == 6) h = 'FF$h';
  return Color(int.parse(h, radix: 16));
}
