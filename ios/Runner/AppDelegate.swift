import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var chatBackgroundTasks: [String: UIBackgroundTaskIdentifier] = [:]

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    let channel = FlutterMethodChannel(
      name: "io.github.mizaawa.mewhub/chat_generation",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterError(code: "background_task", message: "The application delegate is unavailable.", details: nil))
        return
      }
      guard let arguments = call.arguments as? [String: Any],
            let conversationId = arguments["conversationId"] as? String else {
        result(FlutterError(code: "missing_conversation", message: "A conversation id is required.", details: nil))
        return
      }

      switch call.method {
      case "start":
        self.beginChatBackgroundTask(conversationId, result: result)
      case "stop":
        self.endChatBackgroundTask(conversationId)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func beginChatBackgroundTask(
    _ conversationId: String,
    result: @escaping FlutterResult
  ) {
    if chatBackgroundTasks[conversationId] != nil {
      result(nil)
      return
    }

    let task = UIApplication.shared.beginBackgroundTask(withName: "MewHub Chat Generation") { [weak self] in
      self?.endChatBackgroundTask(conversationId)
    }
    guard task != .invalid else {
      result(FlutterError(code: "background_task_unavailable", message: "iOS did not grant background time.", details: nil))
      return
    }
    chatBackgroundTasks[conversationId] = task
    result(nil)
  }

  private func endChatBackgroundTask(_ conversationId: String) {
    guard let task = chatBackgroundTasks.removeValue(forKey: conversationId) else { return }
    UIApplication.shared.endBackgroundTask(task)
  }
}
