import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'note_repository.dart';
import 'note_store.dart';

Future<NoteStore> createStoreBackend() async {
  final docs = await getApplicationDocumentsDirectory();
  final root = Directory(p.join(docs.path, 'MyInkNotes'));
  return NoteRepository.createAt(root);
}
