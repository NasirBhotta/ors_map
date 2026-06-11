import 'dart:convert';

import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:ors_map_test/models/route_step.dart';

class OrsService {
  static const String _apiKey =
      'eyJvcmciOiI1YjNjZTM1OTc4NTExMTAwMDFjZjYyNDgiLCJpZCI6IjZmM2NmMjgzOTBmZDRmZGY4NDNmODgxZmNhYjcyYmVmIiwiaCI6Im11cm11cjY0In0=';

  static Future<RouteResult?> getRoute({
    required LatLng from,
    required LatLng to,
  }) async {
    // URL banao — notice karo lng,lat order (ulta hai Google se)

    final url = Uri.parse(
      'https://api.heigit.org/openrouteservice/v2/directions/driving-car'
      '?api_key=$_apiKey'
      '&start=${from.longitude},${from.latitude}' // pehle lng
      '&end=${to.longitude},${to.latitude}', // phir lat
    );

    try {
      final response = await http.get(
        url,
        headers: {'Accept': 'application/json, application/geo+json'},
      );

      // Agar response theek nahi aaya
      if (response.statusCode != 200) {
        print('ORS Error: ${response.statusCode}');
        print('Body: ${response.body}');
        return null;
      }

      final data = jsonDecode(response.body);

      // Coordinates nikalo
      // data → features → [0] → geometry → coordinates
      final coords = data['features'][0]['geometry']['coordinates'] as List;

      // ORS [lng, lat] deta hai, hum [lat, lng] chahte hain (LatLng ke liye)
      final points =
          coords.map((c) {
            return LatLng(
              c[1] as double, // lat second index par hai
              c[0] as double, // lng first index par hai
            );
          }).toList();

      // Distance aur duration bhi nikalo
      final segment = data['features'][0]['properties']['segments'][0];
      final distanceMeters = segment['distance'] as double;
      final durationSeconds = segment['duration'] as double;

      // yahan se steps nikalo — segment ke andar hain
      final stepsJson = segment['steps'] as List;

      final steps =
          stepsJson
              .map((s) => RouteStep.fromJson(s as Map<String, dynamic>))
              .toList();

      return RouteResult(
        points: points,
        distanceMeters: distanceMeters,
        durationSeconds: durationSeconds,
        steps: steps,
      );
    } catch (e) {
      print('ORS Exception: $e');
      return null;
    }
  }
}

class RouteResult {
  final List<LatLng> points;
  final double distanceMeters;
  final double durationSeconds;
  final List<RouteStep> steps;

  RouteResult({
    required this.points,
    required this.distanceMeters,
    required this.durationSeconds,
    required this.steps,
  });

  // Helper getters
  String get distanceText {
    if (distanceMeters >= 1000) {
      return '${(distanceMeters / 1000).toStringAsFixed(1)} km';
    }
    return '${distanceMeters.round()} m';
  }

  String get durationText {
    final minutes = (durationSeconds / 60).round();
    if (minutes >= 60) {
      return '${minutes ~/ 60} hr ${minutes % 60} min';
    }
    return '$minutes min';
  }
}
