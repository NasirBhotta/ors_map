import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class ApiKeyService {
  static const MethodChannel _channel = MethodChannel('ors_map_test/api_keys');

  static String mapboxAccessToken = const String.fromEnvironment(
    'MAPBOX_ACCESS_TOKEN',
  );
  static String googleMapsApiKey = const String.fromEnvironment(
    'GOOGLE_MAPS_API_KEY',
  );

  static Future<void> load() async {
    try {
      final result = await _channel.invokeMapMethod<String, String>(
        'getApiKeys',
      );
      mapboxAccessToken = result?['mapboxAccessToken'] ?? mapboxAccessToken;
      googleMapsApiKey = result?['googleMapsApiKey'] ?? googleMapsApiKey;
    } catch (e) {
      debugPrint('API key load failed: $e');
    }

    if (mapboxAccessToken.isEmpty) {
      debugPrint('MAPBOX_ACCESS_TOKEN is missing.');
    }
    if (googleMapsApiKey.isEmpty) {
      debugPrint('GOOGLE_MAPS_API_KEY is missing.');
    }
  }
}
