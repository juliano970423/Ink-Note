import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

Future<String> savePdfBytesBackend(String fileName, Uint8List bytes) async {
  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory(p.join(docs.path, 'MyInkNotes', 'exports'));
  await dir.create(recursive: true);
  final file = File(p.join(dir.path, fileName));
  await file.writeAsBytes(bytes, flush: true);
  return file.path;
}
