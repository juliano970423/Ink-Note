import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_notes/import/pdf_import.dart';
import 'package:ink_notes/import/share_common.dart';
import 'package:ink_notes/storage/memory_note_store.dart';
import 'package:ink_notes/ui/home_page.dart';
import 'package:pdf/pdf.dart' show PdfPageFormat;
import 'package:pdf/widgets.dart' as pw;

Future<List<int>> _twoPagePdf() {
  final doc = pw.Document();
  for (final text in ['one', 'two']) {
    doc.addPage(pw.Page(
        pageFormat: PdfPageFormat.a4,
        build: (_) => pw.Center(
            child: pw.Text(text, style: const pw.TextStyle(fontSize: 40)))));
  }
  return doc.save();
}

DateTime t(int ms) => DateTime.utc(2026, 1, 1).add(Duration(milliseconds: ms));

void main() {
  test('isPdfFile：MIME 優先；octet-stream 靠副檔名；兩者都不像就拒', () {
    // MIME 正規
    expect(
        isPdfFile(mimeType: 'application/pdf', fileName: 'x.txt'), isTrue);
    // 亂填 MIME + 正副檔名
    expect(
        isPdfFile(mimeType: 'application/octet-stream', fileName: 'a.PDF'),
        isTrue);
    // MIME 空但副檔名對
    expect(isPdfFile(mimeType: null, fileName: 'b.pdf'), isTrue);
    // 都不像
    expect(
        isPdfFile(mimeType: 'image/png', fileName: 'c.png'), isFalse);
    expect(isPdfFile(mimeType: null, fileName: 'd'), isFalse);
  });

  test('PdfShareSeen：窗口內同檔只接一次，過窗再分享照常收', () {
    final seen = PdfShareSeen(window: const Duration(seconds: 3), now: () => t(0));
    // 同一時間窗內同檔不重收（冷+暖重疊防禦）
    expect(seen.isNew('tmp/a.pdf', 100), isTrue);
    expect(seen.isNew('tmp/a.pdf', 100), isFalse);
    // 不同檔照收
    expect(seen.isNew('tmp/b.pdf', 200), isTrue);
    // 過了窗口：同檔再分享視為新的一次
    final later = PdfShareSeen(window: const Duration(seconds: 3), now: () => t(4000));
    expect(later.isNew('tmp/a.pdf', 100), isTrue);
  });

  test('createPdfNote：建兩頁底圖筆記、存原檔、存首頁底圖、不開編輯器', () async {
    final store = MemoryNoteStore();
    final bytes = Uint8List.fromList(await _twoPagePdf());
    final note = await createPdfNote(store, bytes, '會議記錄.pdf');

    expect(note.title, '會議記錄');
    expect(note.pageId, isNull);
    expect(note.backgrounds.length, 2);
    expect(note.backgrounds[0].src, 0);
    expect(note.backgrounds[1].src, 1);
    expect(note.strokes, isEmpty);

    final all = await store.listAll();
    expect(all.length, 1);
    expect(all.single.id, note.id);

    // 原 PDF 與第一頁底圖都落盤
    final original = await store.loadOriginalPdf(note.id);
    expect(original, isNotNull);
    expect(original, bytes);
    final bg = await store.loadBackground(note.id, note.backgrounds.first.key);
    expect(bg, isNotNull);
    expect((bg as Uint8List).isNotEmpty, isTrue);
  });

  test('createPdfNote：非法 PDF 直接拋，不留下半成品筆記', () async {
    final store = MemoryNoteStore();
    final bad = Uint8List.fromList([1, 2, 3, 4]);
    // PdfDocument.open 對壞檔拋 FormatException；0 頁是 StateError——兩者都算打不開。
    await expectLater(createPdfNote(store, bad, '壞檔.pdf'), throwsA(anything));
    expect(await store.listAll(), isEmpty);
  });

  test('ingestSharedPdf：建筆記＋提示；壞檔不自新增、提示打不開', () async {
    final store = MemoryNoteStore();
    final messages = <String>[];
    final title = await ingestSharedPdf(
      repo: store,
      bytes: Uint8List.fromList(await _twoPagePdf()),
      fileName: 'meeting notes.pdf',
      notify: messages.add,
      reload: () async {},
    );
    expect(title, 'meeting notes');
    expect(messages.single, contains('已導入'));

    // 壞檔：提示錯誤、列表不新增
    messages.clear();
    final fail = await ingestSharedPdf(
      repo: store,
      bytes: Uint8List.fromList([9, 9, 9]),
      fileName: 'broken.pdf',
      notify: messages.add,
      reload: () async {},
    );
    expect(fail, isEmpty);
    expect(messages.single, contains('打不開'));
    final all = await store.listAll();
    expect(all.length, 1);
  });
}
