import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../data/settings.dart';

/// System text-to-speech with markdown stripped.
class TtsService extends ChangeNotifier {
  final FlutterTts _tts = FlutterTts();
  String? speakingId;
  bool _init = false;

  Future<void> _ensure() async {
    if (_init) return;
    _init = true;
    if (Platform.isIOS) {
      await _tts.setSharedInstance(true);
      await _tts.setIosAudioCategory(IosTextToSpeechAudioCategory.playback, [
        IosTextToSpeechAudioCategoryOptions.mixWithOthers,
        IosTextToSpeechAudioCategoryOptions.duckOthers,
      ]);
    }
    _tts.setCompletionHandler(_done);
    _tts.setCancelHandler(_done);
    _tts.setErrorHandler((_) => _done());
  }

  void _done() {
    speakingId = null;
    notifyListeners();
  }

  Future<void> toggle(String id, String text, TtsSettings s) async {
    await _ensure();
    if (speakingId == id) {
      await stop();
      return;
    }
    await _tts.stop();
    speakingId = id;
    notifyListeners();
    if (s.language.isNotEmpty) await _tts.setLanguage(s.language);
    await _tts.setSpeechRate(s.rate);
    await _tts.setPitch(s.pitch);
    await _tts.speak(clean(text, onlyQuoted: s.onlyQuoted));
  }

  Future<void> stop() async {
    await _tts.stop();
    _done();
  }

  static String clean(String text, {bool onlyQuoted = false}) {
    var s = text;
    if (onlyQuoted) {
      final q = RegExp(r'["“「『]([^"”」』]+)["”」』]').allMatches(s).map((m) => m.group(1)).join('\n');
      if (q.isNotEmpty) s = q;
    }
    return s
        .replaceAll(RegExp(r'```[\s\S]*?```'), ' ')
        .replaceAllMapped(RegExp(r'`([^`]*)`'), (m) => m.group(1)!)
        .replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)'), '')
        .replaceAllMapped(RegExp(r'\[([^\]]+)\]\([^)]*\)'), (m) => m.group(1)!)
        .replaceAll(RegExp(r'[#>*_~|]'), '')
        .replaceAll(RegExp(r'\n{2,}'), '\n')
        .trim();
  }
}
