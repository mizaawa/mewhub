import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Keeps Android alive while Dart continues consuming a chat's response stream.
/// iOS requests its time-limited background-execution window.
abstract final class BackgroundGeneration {
  static const _channel = MethodChannel('io.github.mizaawa.mewhub/chat_generation');

  static Future<void> start(String conversationId) => _invoke('start', conversationId);
  static Future<void> stop(String conversationId) => _invoke('stop', conversationId);

  static Future<void> _invoke(String method, String conversationId) async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _channel.invokeMethod<void>(method, {'conversationId': conversationId});
    } on MissingPluginException {
      debugPrint('Android chat background service is unavailable.');
    } on PlatformException catch (error) {
      debugPrint('Unable to $method background generation: ${error.message}');
    }
  }
}
