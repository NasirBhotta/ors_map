import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:ors_map_test/services/api_key_service.dart';

class MapboxStep {
  final String instruction;
  final double distance; // meters
  final double duration; // seconds
  final List<double>? maneuverLocation; // [lng, lat]

  MapboxStep({
    required this.instruction,
    required this.distance,
    required this.duration,
    this.maneuverLocation,
  });

  factory MapboxStep.fromJson(Map<String, dynamic> json) {
    final maneuver = json['maneuver'] as Map<String, dynamic>?;
    final location = maneuver?['location'];

    return MapboxStep(
      instruction: maneuver?['instruction'] ?? '',
      distance: (json['distance'] as num).toDouble(),
      duration: (json['duration'] as num).toDouble(),
      maneuverLocation:
          location is List && location.length >= 2
              ? [
                (location[0] as num).toDouble(),
                (location[1] as num).toDouble(),
              ]
              : null,
    );
  }
}

class MapboxRouteResult {
  final List<List<double>> coordinates; // [[lng, lat], ...]
  final double distanceMeters;
  final double durationSeconds;
  final List<MapboxStep> steps;

  MapboxRouteResult({
    required this.coordinates,
    required this.distanceMeters,
    required this.durationSeconds,
    required this.steps,
  });

  String get distanceText {
    if (distanceMeters >= 1000) {
      return '${(distanceMeters / 1000).toStringAsFixed(1)} km';
    }
    return '${distanceMeters.round()} m';
  }

  String get durationText {
    final minutes = (durationSeconds / 60).round();
    if (minutes >= 60) return '${minutes ~/ 60} hr ${minutes % 60} min';
    return '$minutes min';
  }
}

class MapboxRouteService {
  static Future<MapboxRouteResult?> getRoute({
    required double fromLng,
    required double fromLat,
    required double toLng,
    required double toLat,
  }) async {
    final token = ApiKeyService.mapboxAccessToken;
    if (token.isEmpty) {
      debugPrint('Route error: MAPBOX_ACCESS_TOKEN is missing.');
      return null;
    }

    final url = Uri.parse(
      'https://api.mapbox.com/directions/v5/mapbox/driving/'
      '$fromLng,$fromLat;$toLng,$toLat'
      '?access_token=$token'
      '&geometries=geojson'
      '&steps=true'
      '&overview=full',
    );

    try {
      final response = await http.get(url);
      if (response.statusCode != 200) return null;

      final data = jsonDecode(response.body);
      final route = data['routes'][0];

      final coords =
          (route['geometry']['coordinates'] as List)
              .map((c) => [(c[0] as num).toDouble(), (c[1] as num).toDouble()])
              .toList();

      final allSteps = <MapboxStep>[];
      for (final leg in route['legs'] as List) {
        for (final step in leg['steps'] as List) {
          allSteps.add(MapboxStep.fromJson(step as Map<String, dynamic>));
        }
      }

      return MapboxRouteResult(
        coordinates: coords,
        distanceMeters: (route['distance'] as num).toDouble(),
        durationSeconds: (route['duration'] as num).toDouble(),
        steps: allSteps,
      );
    } catch (e) {
      debugPrint('Route error: $e');
      return null;
    }
  }
}
