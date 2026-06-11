// lib/models/route_step.dart

import 'package:flutter/material.dart';

class RouteStep {
  final String instruction; // "Turn left onto Jinnah Avenue"
  final double distance; // 1200.0 (meters mein)
  final double duration; // 144.0 (seconds mein)
  final int type; // 0=left, 1=right, 4=straight, 10=arrive

  const RouteStep({
    required this.instruction,
    required this.distance,
    required this.duration,
    required this.type,
  });

  // ORS ke JSON se directly banao
  factory RouteStep.fromJson(Map<String, dynamic> json) {
    return RouteStep(
      instruction: json['instruction'] ?? '',
      distance: (json['distance'] ?? 0).toDouble(),
      duration: (json['duration'] ?? 0).toDouble(),
      type: json['type'] ?? 0,
    );
  }

  // Distance ko readable banao
  // 450 → "450 m" | 1200 → "1.2 km"
  String get distanceText {
    if (distance < 1000) {
      return '${distance.toInt()} m';
    }
    return '${(distance / 1000).toStringAsFixed(1)} km';
  }

  // Type se icon decide karo
  // ORS ke type codes: 0=left, 1=right, 4=straight, 10=destination
  IconData get icon {
    switch (type) {
      case 0:
        return Icons.turn_left_rounded;
      case 1:
        return Icons.turn_right_rounded;
      case 2:
        return Icons.turn_sharp_left_rounded;
      case 3:
        return Icons.turn_sharp_right_rounded;
      case 4:
        return Icons.straight_rounded;
      case 10:
        return Icons.location_on_rounded;
      default:
        return Icons.navigation_rounded;
    }
  }
}
