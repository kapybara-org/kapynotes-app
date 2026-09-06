import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {

  /// A cold launch through the widget: the URL arrives folded into the
  /// options the scene connects with.
  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    QuickCapture.shared.absorb(connectionOptions.urlContexts)
    super.scene(scene, willConnectTo: session, options: connectionOptions)
  }

  /// A warm one: the app was already running, so the URL comes on its own.
  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    QuickCapture.shared.absorb(URLContexts)
    super.scene(scene, openURLContexts: URLContexts)
  }
}
