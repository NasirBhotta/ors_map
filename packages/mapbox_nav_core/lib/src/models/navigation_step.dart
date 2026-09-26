import 'package:meta/meta.dart';
import 'geo_point.dart';

/// An immutable, vendor-neutral representation of a single navigation maneuver or step.
@immutable
final class NavigationStep {
  /// The human-readable maneuver instruction (e.g., "Turn right onto Grand Avenue").
  final String instruction;

  /// The distance of this step in meters.
  final double distanceMeters;

  /// The estimated duration to traverse this step in seconds.
  final double durationSeconds;

  /// The geographic coordinate where the maneuver takes place, if available.
  final GeoPoint? maneuverPoint;

  /// Posted speed limit along this step in km/h, if provided by the routing engine.
  final int? speedLimitKmh;

  const NavigationStep({
    required this.instruction,
    required this.distanceMeters,
    required this.durationSeconds,
    this.maneuverPoint,
    this.speedLimitKmh,
  }) : assert(distanceMeters >= 0.0, 'distanceMeters must be non-negative'),
       assert(durationSeconds >= 0.0, 'durationSeconds must be non-negative');

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NavigationStep &&
          runtimeType == other.runtimeType &&
          instruction == other.instruction &&
          distanceMeters == other.distanceMeters &&
          durationSeconds == other.durationSeconds &&
          maneuverPoint == other.maneuverPoint &&
          speedLimitKmh == other.speedLimitKmh;

  @override
  int get hashCode => Object.hash(
    instruction,
    distanceMeters,
    durationSeconds,
    maneuverPoint,
    speedLimitKmh,
  );

  @override
  String toString() =>
      'NavigationStep("$instruction", distance: ${distanceMeters.toStringAsFixed(1)}m, '
      'duration: ${durationSeconds.toStringAsFixed(0)}s)';
}
