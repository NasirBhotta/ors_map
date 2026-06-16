import 'package:flutter/material.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';
import 'package:ors_map_test/presentation/map_box_screen_duplicate.dart';
import 'package:ors_map_test/services/api_key_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ApiKeyService.load();
  if (ApiKeyService.mapboxAccessToken.isNotEmpty) {
    MapboxOptions.setAccessToken(ApiKeyService.mapboxAccessToken);
  }
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ORS Map',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF4285F4)),
        useMaterial3: true,
      ),
      home: const MapboxTestScreen(),
    );
  }
}
