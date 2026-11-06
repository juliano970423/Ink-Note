/// 平台分享 → 筆記接收（Android 分享面板 / ACTION_VIEW；iOS 分享擴展 / 文件打開）。
/// 平台守衛在這裡一次做齊：不支援的環境（桌面/Web/測試主機）返回空流、
/// 永不碰 plugin channel——home 無需判斷平台，Windows 上跑測試也不會
/// MissingPluginException。
///
/// 插件發過來的是內容 URI 的暫存拷貝，會被系統回收：所以一律先讀成
/// bytes 再交出。冷啟動 (getInitialMedia) 讀完調 reset()，暖啟動靠
/// [PdfShareSeen] 短窗去重防重疊。
library;

import 'dart:async';
import 'dart:io' show File, Platform;

import 'package:path/path.dart' as p;
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import 'share_common.dart';

class PdfShareReceiver {
  PdfShareReceiver._();

  static final PdfShareReceiver _instance = PdfShareReceiver._();

  factory PdfShareReceiver() => _instance;

  StreamController<SharedPdf>? _ctl;
  final PdfShareSeen _seen = PdfShareSeen();

  /// 開始接收（同一進程多次調用共享同一條流，不會雙重 import）。
  Stream<SharedPdf> receive() {
    if (!(Platform.isAndroid || Platform.isIOS)) return Stream.empty();
    final existing = _ctl;
    if (existing != null) return existing.stream;
    final ctl = StreamController<SharedPdf>.broadcast();
    _ctl = ctl;
    ReceiveSharingIntent.instance.getMediaStream().listen((files) {
      for (final f in files) {
        _handle(ctl, f);
      }
    });
    ReceiveSharingIntent.instance.getInitialMedia().then((files) async {
      for (final f in files) {
        await _handle(ctl, f);
      }
      await ReceiveSharingIntent.instance.reset();
    });
    return ctl.stream;
  }

  Future<void> _handle(
      StreamController<SharedPdf> ctl, SharedMediaFile f) async {
    try {
      if (f.type != SharedMediaType.file) return;
      final name = p.basename(f.path);
      if (!isPdfFile(mimeType: f.mimeType, fileName: name)) return;
      final bytes = await File(f.path).readAsBytes();
      if (!_seen.isNew(f.path, bytes.length)) return;
      ctl.add(SharedPdf(fileName: name, bytes: bytes));
    } catch (_) {
      // 檔案已被系統清掉 / 無權限：靜默跳過，接收端不值得為它彈錯。
    }
  }
}
