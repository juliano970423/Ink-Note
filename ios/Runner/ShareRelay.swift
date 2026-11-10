import Flutter
import UIKit

/// 系統投遞 file:// PDF 的接收橋。
///
/// LiveContainer 的「Open In App」（分享面板 → LiveContainer → 二級選單選本 app）
/// 最終由 LC 的 TweakLoader hook 把原始檔案的 file:// URL 以 UIOpenURLAction
/// 塞進來；正式安裝時檔案 App「打開方式」同樣遞 file:// openURLContext。
/// 兩者在此統一收口，送進 Dart 的 PdfShareReceiver。
///
/// 時序：冷啟動時 scene 連接早於 Dart 初始化——檔案路徑先緩存在 pending，
/// Dart 調 takePending 一次取走並置 dartReady；之後暖啟動直接 invokeMethod
/// ("onFileUrl") 推送，不再落緩存。
final class ShareRelay: NSObject {
  static let shared = ShareRelay()

  private var pending: [String] = []
  private var channel: FlutterMethodChannel?
  private var dartReady = false

  /// engine 就緒後由 AppDelegate 呼叫：註冊 takePending 的 handler。
  /// 用 bridge 本身接參，避開 applicationRegistrar 在不同 SDK 下
  /// 裸協定/nsObject 複合型別的橋接差異。
  func attach(implicitEngineBridge bridge: FlutterImplicitEngineBridge) {
    let channel = FlutterMethodChannel(
      name: "ink_notes/share_receiver",
      binaryMessenger: bridge.applicationRegistrar.messenger()
    )
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "takePending":
        guard let self else {
          result(nil as [String]?)
          return
        }
        result(self.takePending())
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.channel = channel
  }

  /// 取走全部緩存的路徑（清空），並把窗門自此轉為直接推送。
  private func takePending() -> [String] {
    defer {
      pending.removeAll()
      dartReady = true
    }
    return pending
  }

  /// 系統投遞一個 URL；只收 file:// 且副檔名 .pdf，其餘忽略。
  func offer(url: URL) {
    guard url.isFileURL else { return }
    let path = url.path
    guard path.lowercased().hasSuffix(".pdf") else { return }
    if dartReady, let channel {
      channel.invokeMethod("onFileUrl", arguments: path)
    } else {
      pending.append(path)
    }
  }
}
