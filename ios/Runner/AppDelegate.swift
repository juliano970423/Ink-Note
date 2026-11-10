import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // file:// PDF 接收橋（LiveContainer 轉發 / 檔案 App「打開方式」）→ Dart。
    ShareRelay.shared.attach(applicationRegistrar: engineBridge.applicationRegistrar)
  }

  // 兜底：scene manifest 未生效時系統走 AppDelegate 這條（scene 生效時
  // 系統只會送 scene 的 openURLContexts，不會重複呼叫這裡）。
  override func application(
    _ application: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    ShareRelay.shared.offer(url: url)
    return super.application(application, open: url, options: options)
  }
}
