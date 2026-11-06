/// WEB 佔位：瀏覽器沒有系統分享接收。與 share_receive.dart 同 API。
library;

import 'dart:async';

import 'share_common.dart';

class PdfShareReceiver {
  PdfShareReceiver._();

  static final PdfShareReceiver _instance = PdfShareReceiver._();

  factory PdfShareReceiver() => _instance;

  Stream<SharedPdf> receive() => Stream.empty();
}
