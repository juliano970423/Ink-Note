import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  // 冷啟動：連接參數自帶 openURLContexts（LiveContainer 冷啟動注入的
  // file://、「打開方式」冷啟動選本 app）。交 super 後照常走 Flutter 生命週期。
  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    for context in connectionOptions.urlContexts {
      ShareRelay.shared.offer(url: context.url)
    }
    super.scene(scene, willConnectTo: session, options: connectionOptions)
  }

  // 暖啟動：app 已運行，系統直接送 openURLContexts。
  override func scene(
    _ scene: UIScene,
    openURLContexts URLContexts: Set<UIOpenURLContext>
  ) {
    for context in URLContexts {
      ShareRelay.shared.offer(url: context.url)
    }
    super.scene(scene, openURLContexts: URLContexts)
  }
}
