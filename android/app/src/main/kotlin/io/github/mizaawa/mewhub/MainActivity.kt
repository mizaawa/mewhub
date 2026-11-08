package io.github.mizaawa.mewhub

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "io.github.mizaawa.mewhub/chat_generation")
            .setMethodCallHandler { call, result ->
                val conversationId = call.argument<String>("conversationId")
                if (conversationId.isNullOrBlank()) {
                    result.error("missing_conversation", "A conversation id is required.", null)
                    return@setMethodCallHandler
                }
                try {
                    when (call.method) {
                        "start" -> ChatGenerationService.start(this, conversationId)
                        "stop" -> ChatGenerationService.stop(this, conversationId)
                        else -> {
                            result.notImplemented()
                            return@setMethodCallHandler
                        }
                    }
                    result.success(null)
                } catch (error: Exception) {
                    result.error("background_service", error.message, null)
                }
            }
    }
}
