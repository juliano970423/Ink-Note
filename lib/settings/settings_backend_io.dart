import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

Future<File> _file() async {
  final docs = await getApplicationDocumentsDirectory();
  return File(p.join(docs.path, 'MyInkNotes', 'settings.json'));
}

Future<Map<String, dynamic>?> loadSettingsMap() async {
  final f = await _file();
  if (!await f.exists()) return null;
  return jsonDecode(await f.readAsString()) as Map<String, dynamic>;
}

Future<void> saveSettingsMap(Map<String, dynamic> json) async {
  final f = await _file();
  await f.parent.create(recursive: true);
  final tmp = File('${f.path}.tmp');
  await tmp.writeAsString(jsonEncode(json), flush: true);
  await tmp.rename(f.path);
}
