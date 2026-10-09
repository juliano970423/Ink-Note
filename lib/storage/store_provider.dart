import 'note_store.dart';
import 'store_backend_default.dart'
    if (dart.library.io) 'store_backend_io.dart'
    if (dart.library.js_interop) 'store_backend_web.dart';

/// 按平台創建存儲：桌面/移動端走文件 [NoteRepository]，
/// Web 走內存實現（僅供 UI/手感測試，reload 不持久）。
Future<NoteStore> createStore() => createStoreBackend();
