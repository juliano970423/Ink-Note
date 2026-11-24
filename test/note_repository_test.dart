import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_notes/models/note.dart';
import 'package:ink_notes/storage/note_repository.dart';

Note _note(String id, String title, {int strokes = 1}) => Note(
      id: id,
      title: title,
      createdAt: DateTime.utc(2026, 10, 5, 17, 30),
      updatedAt: DateTime.utc(2026, 10, 5, 17, 30),
      strokes: List.generate(
        strokes,
        (i) => Stroke(color: '#000000', size: 4.0, points: [
          NotePoint(x: i.toDouble(), y: 0, p: 1.0, t: 0),
        ]),
      ),
    );

void main() {
  late Directory tmp;
  late NoteRepository repo;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('ink_notes_test');
    repo = await NoteRepository.createAt(tmp);
  });

  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('save + listAll + load 往返', () async {
    await repo.save(_note('a3f8c2', '會議記錄'));
    final all = await repo.listAll();
    expect(all.length, 1);
    final loaded = await repo.load('a3f8c2');
    expect(loaded.title, '會議記錄');
    expect(loaded.strokes.length, 1);
    // 渲染效果一致：p 值原樣存
    expect(loaded.strokes.first.points.first.p, 1.0);
  });

  test('貼圖：NoteImage json 往返＋PNG 存取刪', () async {
    final n = _note('img001', '貼圖');
    n.images.add(const NoteImage(
        id: 'ab12', page: 0, x: 10, y: 20, w: 100, h: 50, layer: 2));
    await repo.save(n);
    final loaded = await repo.load('img001');
    expect(loaded.images.length, 1);
    expect(loaded.images.first.id, 'ab12');
    expect(loaded.images.first.w, 100);
    expect(loaded.images.first.layer, 2);
    // 舊文件無 images 欄位 → 空列表（向前相容）
    final legacy = Note.fromJson({
      'id': 'old01',
      'title': '舊',
      'createdAt': '2026-10-05T17:30:00.000Z',
      'updatedAt': '2026-10-05T17:30:00.000Z',
      'strokes': [],
    });
    expect(legacy.images, isEmpty);
    // PNG：存→讀→刪→讀空；刪筆記連圖一起清
    final png = [1, 2, 3, 4, 5];
    await repo.saveImage('img001', 'ab12', png);
    expect(await repo.loadImage('img001', 'ab12'), png);
    await repo.deleteImage('img001', 'ab12');
    expect(await repo.loadImage('img001', 'ab12'), isNull);
    await repo.saveImage('img001', 'ab12', png);
    await repo.delete('img001');
    expect(await repo.loadImage('img001', 'ab12'), isNull);
  });

  test('原子寫入：無 .tmp 殘留', () async {
    await repo.save(_note('abcd12', 't'));
    final files = await Directory('${tmp.path}/notes')
        .list()
        .map((e) => e.path)
        .toList();
    expect(files.any((f) => f.endsWith('.tmp')), isFalse);
    expect(files.any((f) => f.endsWith('_abcd12.json')), isTrue);
  });

  test('二次保存產生 history gzip 快照並可回滾', () async {
    await repo.save(_note('a3f8c2', '會議記錄', strokes: 1));
    await repo.save(_note('a3f8c2', '會議記錄', strokes: 2));
    final hist = await repo.listHistory('a3f8c2');
    expect(hist.length, 1);
    expect(hist.first.endsWith('.json.gz'), isTrue);
    expect(hist.first.startsWith('v1_'), isTrue);

    // 再存一版 → v2
    await repo.save(_note('a3f8c2', '會議記錄', strokes: 3));
    expect((await repo.listHistory('a3f8c2')).length, 2);

    // 回滾到 v1（1 筆）
    final rolled = await repo.rollback('a3f8c2', hist.first);
    expect(rolled.strokes.length, 1);
    final reloaded = await repo.load('a3f8c2');
    expect(reloaded.strokes.length, 1);
  });

  test('搬資料夾：文件搬遷 + 歷史不斷 + 縮圖跟隨', () async {
    await repo.save(_note('a3f8c2', '會議記錄', strokes: 1));
    final moved = _note('a3f8c2', '會議記錄', strokes: 2)..folder = '工作';
    await repo.save(moved);
    final all = await repo.listAll();
    expect(all.length, 1);
    expect(all.first.folder, '工作');
    // 舊路徑文件已刪，新路徑存在
    final files = await Directory('${tmp.path}/notes')
        .list(recursive: true)
        .map((e) => e.path)
        .toList();
    expect(files.where((f) => f.endsWith('.json')).length, 1);
    expect(files.any((f) => f.contains('工作')), isTrue);
    // 歷史仍在且可回滾
    expect((await repo.listHistory('a3f8c2')).length, 1);
    expect((await repo.load('a3f8c2')).strokes.length, 2);
    // 資料夾管理
    expect(await repo.listFolders(), ['工作']);
    await repo.saveThumbnail('a3f8c2', [7, 7]);
    expect(await repo.loadThumbnail('a3f8c2'), [7, 7]);
  });

  test('deleteFolder 非空拒刪，搬空後可刪', () async {
    final n = _note('a3f8c2', 't')..folder = '工作';
    await repo.save(n);
    expect(() => repo.deleteFolder('工作'), throwsStateError);
    final empty = _note('a3f8c2', 't')..folder = '';
    await repo.save(empty);
    await repo.deleteFolder('工作');
    expect(await repo.listFolders(), isEmpty);
  });

  test('ensureFolder 建空資料夾落盤，重開仍在', () async {
    await repo.ensureFolder('空資料夾');
    expect(await repo.listFolders(), ['空資料夾']);
    // 重開 repository（模擬 App 重啟）仍在
    final reopened = NoteRepository(tmp);
    expect(await reopened.listFolders(), ['空資料夾']);
    await reopened.deleteFolder('空資料夾');
    expect(await reopened.listFolders(), isEmpty);
  });

  test('改名保存：舊文件名刪除、新文件名寫入', () async {
    await repo.save(_note('a3f8c2', '舊標題'));
    final n2 = _note('a3f8c2', '新標題');
    await repo.save(n2);
    final all = await repo.listAll();
    expect(all.length, 1);
    expect(all.first.title, '新標題');
  });

  // sidecar（底圖/原檔/貼圖/縮圖）全按 json 路徑推導：save 路徑變化時
  // 不跟著搬就全部失聯 = PDF 底圖永久不顯示的根因。
  const sidecarSuffixes = ['_bgk0.png', '_orig.pdf', '_imgab12.png', '.png'];

  test('改標題保存：sidecar 跟著搬到新 base（檔案系統斷言）', () async {
    await repo.save(_note('f0e1d2', '舊標題'));
    final oldJson = (await repo.findNoteFile('f0e1d2'))!;
    final oldBase = oldJson.path.replaceAll(RegExp(r'\.json$'), '');
    await repo.saveBackground('f0e1d2', 'k0', [1, 2, 3]);
    await repo.saveOriginalPdf('f0e1d2', [9, 9, 9]);
    await repo.saveImage('f0e1d2', 'ab12', [4, 5]);
    await repo.saveThumbnail('f0e1d2', [7]);

    await repo.save(_note('f0e1d2', '新標題'));
    final newJson = (await repo.findNoteFile('f0e1d2'))!;
    expect(newJson.path, isNot(oldJson.path));
    final newBase = newJson.path.replaceAll(RegExp(r'\.json$'), '');
    // 直接查檔案系統（走 load 會被孤兒自癒掩蓋，測不到搬移本身）
    for (final s in sidecarSuffixes) {
      expect(await File('$newBase$s').exists(), isTrue, reason: '新 base$s');
      expect(await File('$oldBase$s').exists(), isFalse, reason: '舊 base$s');
    }
    // load 也讀得到
    expect(await repo.loadBackground('f0e1d2', 'k0'), [1, 2, 3]);
    expect(await repo.loadOriginalPdf('f0e1d2'), [9, 9, 9]);
    expect(await repo.loadImage('f0e1d2', 'ab12'), [4, 5]);
    expect(await repo.loadThumbnail('f0e1d2'), [7]);
  });

  test('搬資料夾：sidecar 跟著搬進子目錄', () async {
    await repo.save(_note('b10001', '筆記'));
    final oldJson = (await repo.findNoteFile('b10001'))!;
    final oldBase = oldJson.path.replaceAll(RegExp(r'\.json$'), '');
    await repo.saveBackground('b10001', 'k0', [1, 2, 3]);
    await repo.saveOriginalPdf('b10001', [9]);
    await repo.saveImage('b10001', 'ab12', [4]);
    await repo.saveThumbnail('b10001', [7]);

    await repo.save(_note('b10001', '筆記')..folder = '工作');
    final newJson = (await repo.findNoteFile('b10001'))!;
    expect(newJson.path, contains('工作'));
    final newBase = newJson.path.replaceAll(RegExp(r'\.json$'), '');
    for (final s in sidecarSuffixes) {
      expect(await File('$newBase$s').exists(), isTrue, reason: '新 base$s');
      expect(await File('$oldBase$s').exists(), isFalse, reason: '舊 base$s');
    }
    expect(await repo.loadBackground('b10001', 'k0'), [1, 2, 3]);
    expect(await repo.loadOriginalPdf('b10001'), [9]);
    expect(await repo.loadImage('b10001', 'ab12'), [4]);
    expect(await repo.loadThumbnail('b10001'), [7]);
  });

  test('孤兒 sidecar 自癒：舊版只搬 json 遺留的檔，打開時掃描找回並搬回',
      () async {
    await repo.save(_note('c2ffee', '孤兒'));
    await repo.saveBackground('c2ffee', 'k0', [1, 2, 3]);
    await repo.saveOriginalPdf('c2ffee', [9]);
    await repo.saveImage('c2ffee', 'ab12', [4]);
    final json = (await repo.findNoteFile('c2ffee'))!;
    final oldBase = json.path.replaceAll(RegExp(r'\.json$'), '');
    // 模擬舊版 save 的行為：json 改名，sidecar 全留原地
    final newJson = await json
        .rename('${json.parent.path}/2026-01-01_孤兒_c2ffee.json');
    final newBase = newJson.path.replaceAll(RegExp(r'\.json$'), '');
    for (final s in ['_bgk0.png', '_orig.pdf', '_imgab12.png']) {
      expect(await File('$oldBase$s').exists(), isTrue, reason: '孤兒$s');
    }

    // 打開即自癒：讀到內容，且 sidecar 搬回當前 base
    expect(await repo.loadBackground('c2ffee', 'k0'), [1, 2, 3]);
    expect(await repo.loadOriginalPdf('c2ffee'), [9]);
    expect(await repo.loadImage('c2ffee', 'ab12'), [4]);
    for (final s in ['_bgk0.png', '_orig.pdf', '_imgab12.png']) {
      expect(await File('$newBase$s').exists(), isTrue, reason: '搬回$s');
      expect(await File('$oldBase$s').exists(), isFalse, reason: '孤兒消失$s');
    }
    // 第二次走快路徑（檔已在當前 base）
    expect(await repo.loadBackground('c2ffee', 'k0'), [1, 2, 3]);
  });
}
