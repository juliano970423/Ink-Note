import 'dart:typed_data';

import 'export_saver_default.dart'
    if (dart.library.io) 'export_saver_io.dart'
    if (dart.library.js_interop) 'export_saver_web.dart';

/// 保存匯出的 PDF 字節，返回給用戶看的位置描述（路徑 / 已下載）。
Future<String> savePdfBytes(String fileName, Uint8List bytes) =>
    savePdfBytesBackend(fileName, bytes);
