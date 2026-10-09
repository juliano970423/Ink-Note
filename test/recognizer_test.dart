import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_notes/ink/stroke_renderer.dart';
import 'package:one_dollar_unistroke_recognizer/one_dollar_unistroke_recognizer.dart';

List<Offset> _linePts(Offset a, Offset b, int n) => [
      for (var i = 0; i <= n; i++)
        Offset(a.dx + (b.dx - a.dx) * i / n, a.dy + (b.dy - a.dy) * i / n)
    ];

/// $1 庫校準：直線用專用算法（要求 line 高分），箭頭示例模板僅參考。
void main() {
  List<Unistroke<String>> refs() {
    final lineTpl =
        Unistroke<String>('line', const [Offset(0, 0), Offset(1, 0)]);
    final arrowTpls = example$1Unistrokes
        .where((u) => u.name == 'arrow')
        .map((u) => Unistroke<String>(u.name, u.points))
        .toList();
    return [lineTpl, ...arrowTpls];
  }

  RecognizedCustomUnistroke<String>? rec(List<Offset> pts) =>
      recognizeCustomUnistroke<String>(resamplePoints(pts, 64),
          overrideReferenceUnistrokes: refs());

  test('直線认出 line 且高分', () {
    final r = rec(_linePts(const Offset(0, 0), const Offset(200, 3), 21));
    expect(r?.name, 'line');
    expect(r!.score, greaterThan(0.6));
  });

  test('圓和波浪不是 line 高分', () {
    final circle = [
      for (var i = 0; i <= 24; i++)
        Offset(100 + 60 * math.cos(i / 24 * 2 * math.pi),
            100 + 60 * math.sin(i / 24 * 2 * math.pi)),
    ];
    final rc = rec(circle);
    expect(rc?.name == 'line' && rc!.score >= 0.6, isFalse);
    final wavy = [
      for (var i = 0; i <= 20; i++)
        Offset(i * 10.0, 30 * (i % 2 == 0 ? 1 : -1)),
    ];
    final rw = rec(wavy);
    expect(rw?.name == 'line' && rw!.score >= 0.6, isFalse);
  });
}
