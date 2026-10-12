import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

Future<String> savePdfBytesBackend(String fileName, Uint8List bytes) async {
  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory(p.join(docs.path, 'MyInkNotes', 'exports'));
  await dir.create(recursive: true);
  final file = File(p.join(dir.path, fileName));
  await file.writeAsBytes(bytes, flush: true);
  // 手機端沙盒路徑用戶到不了：寫完直接調系統分享面板
  //（存文件/隔空投送/發送），桌面端保持只存文件。
  if (Platform.isAndroid || Platform.isIOS) {
    try {
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path)], text: fileName),
      );
      return '已分享 $fileName';
    } catch (_) {
      // 面板調不起（iPad 無錨點等）：至少文件落盤了，報路徑
      return file.path;
    }
  }
  return file.path;
}
