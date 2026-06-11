import 'package:flutter_tts/flutter_tts.dart';

class TtsService {
  // Singleton — puri app mein ek hi instance
  static final TtsService _instance = TtsService._internal();
  factory TtsService() => _instance;
  TtsService._internal();

  final FlutterTts _tts = FlutterTts();
  bool _isInitialized = false;

  Future<void> init() async {
    if (_isInitialized) return;

    await _tts.setLanguage('en-US');
    await _tts.setSpeechRate(0.5); // thodi slow — navigation ke liye better
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);

    _isInitialized = true;
  }

  // Yeh main function hai — instruction bolega
  Future<void> speak(String text) async {
    await init();
    await _tts.stop(); // pehle jo chal raha ho band karo
    await _tts.speak(text); // phir naya bolao
  }

  Future<void> stop() async {
    await _tts.stop();
  }
}
