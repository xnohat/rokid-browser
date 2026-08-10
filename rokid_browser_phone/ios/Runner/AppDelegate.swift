import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {

  private let methodChannelName = "com.rokid.rokid_browser_phone/methods"
  private let eventChannelName  = "com.rokid.rokid_browser_phone/events"

  private var ble: BleCentral?
  private var eventSink: FlutterEventSink?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    let messenger = engineBridge.pluginRegistry.registrar(forPlugin: "RokidBle")!.messenger()

    // MethodChannel — mirrors the Android surface: sendCommand / resetConnection.
    let methodChannel = FlutterMethodChannel(name: methodChannelName, binaryMessenger: messenger)
    methodChannel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {
      case "sendCommand":
        if let json = call.arguments as? String, !json.isEmpty {
          self.ble?.send(json)
        }
        result(true)
      case "resetConnection":
        self.ble?.reset()
        result(true)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    // EventChannel — streams bt_status + glasses JSON, identical to Android.
    let eventChannel = FlutterEventChannel(name: eventChannelName, binaryMessenger: messenger)
    eventChannel.setStreamHandler(self)
  }

  private func emitStatus(_ status: String) {
    let json = "{\"type\":\"bt_status\",\"status\":\"\(status)\"}"
    DispatchQueue.main.async { self.eventSink?(json) }
  }
}

extension AppDelegate: FlutterStreamHandler {
  func onListen(withArguments arguments: Any?,
                eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    self.eventSink = events

    if ble == nil {
      let b = BleCentral()
      b.onMessage = { [weak self] json in
        DispatchQueue.main.async { self?.eventSink?(json) }
      }
      b.onStatus = { [weak self] status in
        self?.emitStatus(status)
      }
      ble = b
      b.start()
    }
    emitStatus("listening")
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }
}
