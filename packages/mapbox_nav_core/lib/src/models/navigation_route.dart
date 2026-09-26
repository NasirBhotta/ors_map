import 'package:flutter/foundation.dart';
import '../errors/navigation_errors.dart';
import 'geo_point.dart';
import 'navigation_step.dart';

/// An immutable, vendor-neutral navigation route.
@immutable
final class NavigationRoute {
  /// The ordered polyline coordinates comprising the entire route.
  final List<GeoPoint> geometry;

  /// Total travel distance in meters.
  final double totalDistanceMeters;

  /// Total estimated travel time in seconds.
  final double totalDurationSeconds;

  /// The sequence of turn-by-turn steps along the route.
  final List<NavigationStep> steps;

  NavigationRoute({
    required List<GeoPoint> geometry,
    required this.totalDistanceMeters,
    required this.totalDurationSeconds,
    required List<NavigationStep> steps,
  }) : geometry = List<GeoPoint>.unmodifiable(geometry),
       steps = List<NavigationStep>.unmodifiable(steps) {
    if (geometry.length < 2) {
      throw const InvalidRouteException(
        'Route geometry must contain at least 2 points',
      );
    }
    if (!totalDistanceMeters.isFinite || totalDistanceMeters < 0.0) {
      throw const InvalidRouteException(
        'totalDistanceMeters must be a finite, non-negative number',
      );
    }
    if (!totalDurationSeconds.isFinite || totalDurationSeconds < 0.0) {
      throw const InvalidRouteException(
        'totalDurationSeconds must be a finite, non-negative number',
      );
    }
  }

  /// Human-readable distance text (e.g. "450 m" or "12.4 km").
  String get distanceText {
    if (totalDistanceMeters >= 1000) {
      return '${(totalDistanceMeters / 1000).toStringAsFixed(1)} km';
    }
    return '${totalDistanceMeters.round()} m';
  }

  /// Human-readable duration text (e.g. "14 min" or "1 hr 25 min").
  String get durationText {
    final minutes = (totalDurationSeconds / 60).round();
    if (minutes >= 60) {
      final hours = minutes ~/ 60;
      final remainingMin = minutes % 60;
      return '$hours hr $remainingMin min';
    }
    return '$minutes min';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NavigationRoute &&
          runtimeType == other.runtimeType &&
          totalDistanceMeters == other.totalDistanceMeters &&
          totalDurationSeconds == other.totalDurationSeconds &&
          listEquals(geometry, other.geometry) &&
          listEquals(steps, other.steps);

  @override
  int get hashCode => Object.hash(
    Object.hashAll(geometry),
    totalDistanceMeters,
    totalDurationSeconds,
    Object.hashAll(steps),
  );

  @override
  String toString() =>
      'NavigationRoute($distanceText, $durationText, '
      'points: ${geometry.length}, steps: ${steps.length})';
}
