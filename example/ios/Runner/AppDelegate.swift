import Flutter
import UIKit
import workmanager_apple

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Make plugins (path_provider) available to the background engine.
    // iOS only accepts a task whose handler was registered before launch
    // finished; scheduling it from Dart alone crashes with "No launch handler
    // registered". The identifier must match Info.plist and the Dart code.
    WorkmanagerPlugin.registerPeriodicTask(
      withIdentifier: "dev.example.flutterApiClientExample.offlineSync",
      frequency: NSNumber(value: 15 * 60)
    )
    WorkmanagerPlugin.registerLaunchHandlers()
    WorkmanagerPlugin.setPluginRegistrantCallback { registry in
      GeneratedPluginRegistrant.register(with: registry)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
