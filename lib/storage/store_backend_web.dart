import 'memory_note_store.dart';
import 'note_store.dart';

Future<NoteStore> createStoreBackend() async => MemoryNoteStore();
