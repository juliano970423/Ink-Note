/// 分享接收的純邏輯（與平台、UI 無關；Web/測試都能安全導入）。
library;

import 'dart:typed_data';

/// 一份分享進來的 PDF（已讀成 bytes；插件只宣稱類型，拷貝暫存檔）。
class SharedPdf {
  final String fileName;
  final Uint8List bytes;

  SharedPdf({required this.fileName, required this.bytes});

  int get size => bytes.length;
}

/// 這個分享是不是 PDF：MIME 優先（application/pdf），
/// 副檔名兜底——不少 App 分享時 MIME 亂填或填 application/octet-stream。
bool isPdfFile({required String? mimeType, required String fileName}) {
  final m = (mimeType ?? '').toLowerCase();
  if (m.contains('pdf')) return true;
  return fileName.toLowerCase().endsWith('.pdf');
}

/// 短窗去重：冷啟動 (getInitialMedia) 與暖啟動 (getMediaStream) 事件
/// 在部分機型會重疊發同一份；窗口內同 (path, size) 只接一次，
/// 過了窗口的同檔再分享照常收。
class PdfShareSeen {
  final Duration window;
  final DateTime Function() now;
  final Map<String, DateTime> _at = {};

  PdfShareSeen(
      {this.window = const Duration(seconds: 3), DateTime Function()? now})
      : now = now ?? DateTime.now;

  bool isNew(String path, int size) {
    final key = '$size\u0000$path';
    final t = now();
    final prev = _at[key];
    if (prev != null && t.difference(prev) < window) return false;
    _at[key] = t;
    return true;
  }
}
