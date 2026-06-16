import 'package:flutter_tts/flutter_tts.dart';

class TtsService {
  // Singleton
  static final TtsService _instance = TtsService._internal();
  factory TtsService() => _instance;
  TtsService._internal();

  final FlutterTts _tts = FlutterTts();
  bool _isInitialized = false;

  Future<void> init() async {
    if (_isInitialized) return;

    // Pehle available engines dekho — phir set karo
    final engines = await _tts.getEngines;
    if (engines.contains('com.google.android.tts')) {
      await _tts.setEngine('com.google.android.tts');
    }

    await _tts.setLanguage('en-US');
    await _tts.setSpeechRate(0.5);
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);
    _isInitialized = true;
  }

  Future<void> speak(String text) async {
    await init();
    await _tts.stop();
    await _tts.speak(text);
  }

  Future<void> stop() async => _tts.stop();
}
