import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_notes/ink/stroke_renderer.dart';
import 'package:ink_notes/models/note.dart';

Future<ui.Image> _render(List<Stroke> strokes) async {
  final pic = await paintStrokesToPicture(strokes);
  final img = await pic.toImage(200, 200);
  pic.dispose();
  return img;
}

List<int> _pixel(ui.Image img, List<int> bytes, int x, int y) {
  final i = (y * 200 + x) * 4;
  return bytes.sublist(i, i + 4);
}

void main() {
  test('虛線有缺口、螢光半透明、筆刷實心', () async {
    List<NotePoint> line(int y) => [
          NotePoint(x: 10, y: y.toDouble(), p: 1.0, t: 0),
          NotePoint(x: 110, y: y.toDouble(), p: 1.0, t: 10),
        ];
    final img = await _render([
      Stroke(color: '#000000', size: 4.0, points: line(50)),
      Stroke(
          color: '#ff0000',
          size: 4.0,
          points: line(100),
          type: 'dashed'),
      Stroke(
          color: '#f9ab00',
          size: 4.0,
          points: line(150),
          type: 'highlighter',
          alpha: 0.35),
    ]);
    final bytes =
        (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!
            .buffer
            .asUint8List()
            .toList();
    img.dispose();

    // 筆刷實心黑
    final b = _pixel(img, bytes, 60, 50);
    expect(b[3], 255);
    expect(b[0] + b[1] + b[2], lessThan(60));

    // 虛線：dash 內有墨（x=15），gap 內透明（dash=10,gap=6 → 21~25 為 gap）
    final d1 = _pixel(img, bytes, 15, 100);
    expect(d1[0], greaterThan(200)); // 紅
    expect(d1[3], 255);
    final d2 = _pixel(img, bytes, 23, 100);
    expect(d2[3], 0); // 缺口透明

    // 螢光：半透明黃（rawRgba 是 premultiplied：249*.35≈87，171*.35≈60，alpha≈89）
    final h = _pixel(img, bytes, 60, 150);
    expect(h[3], inInclusiveRange(80, 100));
    expect(h[0], inInclusiveRange(75, 100));
    expect(h[1], inInclusiveRange(50, 70));
    expect(h[2], lessThan(10));
  });

  test('幾何矩形：四條邊都有墨，中心透明（壓感輪廓會吃掉右下邊）', () async {
    const r = [
      NotePoint(x: 20, y: 20, p: 0.9, t: 0),
      NotePoint(x: 60, y: 20, p: 0.9, t: 8),
      NotePoint(x: 60, y: 60, p: 0.9, t: 16),
      NotePoint(x: 20, y: 60, p: 0.9, t: 24),
      NotePoint(x: 20, y: 20, p: 0.9, t: 32),
    ];
    final img = await _render([
      const Stroke(
          color: '#000000', size: 4.0, points: r, geometric: true),
    ]);
    final bytes =
        (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!
            .buffer
            .asUint8List()
            .toList();
    img.dispose();
    // 四邊中點都有墨
    for (final p in const [
      [40, 20],
      [40, 60],
      [20, 40],
      [60, 40],
    ]) {
      final px = _pixel(img, bytes, p[0], p[1]);
      expect(px[3], greaterThan(100), reason: 'edge $p');
    }
    // 中心透明（描邊環，非實心）
    expect(_pixel(img, bytes, 40, 40)[3], 0);
    // 框外透明
    expect(_pixel(img, bytes, 5, 5)[3], 0);
  });

  test('螢光標準半透明：蓋字（字透出深色），白紙染黃', () async {
    final rec = ui.PictureRecorder();
    final canvas = ui.Canvas(rec);
    // 白紙底（真實頁面如此；透明底會讓 srcOver 算出錯）
    canvas.drawRect(
      const ui.Rect.fromLTWH(0, 0, 200, 200),
      ui.Paint()..color = const ui.Color(0xFFFFFFFF),
    );
    // 黑條假裝是字
    canvas.drawRect(
      const ui.Rect.fromLTWH(10, 48, 100, 4),
      ui.Paint()..color = const ui.Color(0xFF000000),
    );
    // 黃螢光橫跨黑條（存檔的螢光筆自帶 0.35 透明）
    paintStroke(
      canvas,
      const Stroke(
        color: '#ffff00',
        size: 4.0,
        alpha: 0.35,
        points: [
          NotePoint(x: 10, y: 50, p: 1, t: 0),
          NotePoint(x: 110, y: 50, p: 1, t: 10),
        ],
        type: 'highlighter',
      ),
    );
    final pic = rec.endRecording();
    final img = await pic.toImage(200, 200);
    final bytes =
        (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!
            .buffer
            .asUint8List()
            .toList();
    img.dispose();
    pic.dispose();
    // 字上是深橄欖色（黃×0.35 蓋黑 ≈ (89,89,0)，字沒消失）
    final t = _pixel(img, bytes, 60, 50);
    expect(t[3], 255);
    expect(t[0], inInclusiveRange(60, 120));
    expect(t[1], inInclusiveRange(60, 120));
    expect(t[2], lessThan(60));
    // 白紙染淡黃（≈ (255,255,165)）
    final p = _pixel(img, bytes, 60, 44);
    expect(p[3], greaterThan(200));
    expect(p[0], greaterThan(200));
    expect(p[1], greaterThan(200));
    expect(p[2], inInclusiveRange(100, 220));
  });

  test('修正產物帶 geometric 標記，存檔往返保留', () {
    const s = Stroke(color: '#000', size: 4, points: [], geometric: true);
    final rt =
        Stroke.fromJson(Map<String, dynamic>.from(s.toJson()));
    expect(rt.geometric, isTrue);
    const legacy = Stroke(color: '#000', size: 4, points: []);
    final rt2 = Stroke.fromJson(
        Map<String, dynamic>.from(legacy.toJson()));
    expect(rt2.geometric, isFalse);
    // 舊文件（無欄位）預設 false
    final rt3 = Stroke.fromJson({'color': '#000', 'size': 4.0, 'points': []});
    expect(rt3.geometric, isFalse);
  });
}
