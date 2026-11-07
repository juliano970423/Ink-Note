import receive_sharing_intent

/// 分享擴展入口：RSIShareViewController 收附件後自動把宿主 App 帶回前台
/// （shouldAutoRedirect 預設 true，不覆寫則不顯示對話框）；建筆記與提示都在
/// Dart 端完成，擴展本身不初始化 Flutter。
// 若編譯報 no such module 'receive_sharing_intent'：到 Runner target 的
// Build Phases，把 Embed Foundation Extensions 移到 Thin Binary 上面。
class ShareViewController: RSIShareViewController {}
