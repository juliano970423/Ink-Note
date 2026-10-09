import 'note_store.dart';

/// 兜底：未知平台直接報錯（不應到達）。
Future<NoteStore> createStoreBackend() =>
    throw UnsupportedError('no NoteStore backend for this platform');
