import 'dart:convert';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

Future<String> savePdfBytesBackend(String fileName, Uint8List bytes) async {
  final url = 'data:application/pdf;base64,${base64Encode(bytes)}';
  final anchor = web.HTMLAnchorElement()
    ..href = url
    ..download = fileName;
  web.document.body!.append(anchor);
  anchor.click();
  anchor.remove();
  return '已下載 $fileName';
}
