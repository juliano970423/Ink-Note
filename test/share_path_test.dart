// file:// 路徑 → SharedPdf 的轉換（iOS file:// 橋的純邏輯部分，頭 windows 宿主可跑）。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_notes/import/share_receive.dart';

void main() {
  Directory? tmp;

  setUp(() async => tmp = await Directory.systemTemp.createTemp('share_path'));
  tearDown(() async => await tmp?.delete(recursive: true));

  Future<String> write(String name, List<int> bytes) async {
    final f = File('${tmp!.path}/$name');
    await f.writeAsBytes(bytes);
    return f.path;
  }

  test('.pdf 檔 → SharedPdf（檔名去副檔名交給上層做標題）', () async {
    final path = await write(
        'report.pdf', Uint8List.fromList([0x25, 0x50, 0x44, 0x46, 0x2D]));
    final pdf = await sharedPdfFromPath(path);
    expect(pdf, isNotNull);
    expect(pdf!.fileName, 'report.pdf');
    expect(pdf.size, 5);
  });

  test('大寫 .PDF 也要收', () async {
    final path = await write('老筆記.PDF', Uint8List.fromList([0x25]));
    final pdf = await sharedPdfFromPath(path);
    expect(pdf, isNotNull);
    expect(pdf!.fileName, '老筆記.PDF');
  });

  test('非 .pdf 副檔名 → null（不是 PDF，靜默丟掉）', () async {
    final path = await write('照片.txt', Uint8List.fromList([0x25, 0x50]));
    expect(await sharedPdfFromPath(path), isNull);
  });

  test('副檔名 pdf 但打不開（被清掉）→ 拋出，由呼叫者 catch', () async {
    expect(sharedPdfFromPath('${tmp!.path}/ghost.pdf'),
        throwsA(isA<FileSystemException>()));
  });
}
