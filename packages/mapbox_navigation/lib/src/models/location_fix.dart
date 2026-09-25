import 'package:meta/meta.dart';
import 'geo_point.dart';

/// An immutable, vendor-neutral normalized GPS observation.
@immutable
final class LocationFix {
  /// The measured geographic coordinate.
  final GeoPoint coordinate;

  /// The estimated horizontal accuracy radius in meters (1-sigma).
  final double accuracyMeters;

  /// The estimated altitude above the WGS 84 reference ellipsoid in meters.
  final double altitudeMeters;

  /// The horizontal direction of travel in degrees [0.0, 360.0).
  final double bearingDegrees;

  /// The instantaneous horizontal speed in meters per second.
  final double speedMetersPerSecond;

  /// The UTC timestamp when this fix was recorded by the location provider.
  final DateTime timestamp;

  const LocationFix({
    required this.coordinate,
    required this.accuracyMeters,
    this.altitudeMeters = 0.0,
    required this.bearingDegrees,
    required this.speedMetersPerSecond,
    required this.timestamp,
  })  : assert(accuracyMeters >= 0.0, 'accuracyMeters must be non-negative'),
        assert(
          bearingDegrees >= 0.0 && bearingDegrees <= 360.0,
          'bearingDegrees must be within [0.0, 360.0]',
        ),
        assert(
          speedMetersPerSecond >= 0.0,
          'speedMetersPerSecond must be non-negative',
        );

  /// Convenience getter for speed in kilometers per hour.
  double get speedKmh => speedMetersPerSecond * 3.6;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LocationFix &&
          runtimeType == other.runtimeType &&
          coordinate == other.coordinate &&
          accuracyMeters == other.accuracyMeters &&
          altitudeMeters == other.altitudeMeters &&
          bearingDegrees == other.bearingDegrees &&
          speedMetersPerSecond == other.speedMetersPerSecond &&
          timestamp == other.timestamp;

  @override
  int get hashCode => Object.hash(
        coordinate,
        accuracyMeters,
        altitudeMeters,
        bearingDegrees,
        speedMetersPerSecond,
        timestamp,
      );

  @override
  String toString() =>
      'LocationFix(coord: $coordinate, acc: ${accuracyMeters.toStringAsFixed(1)}m, '
      'bearing: ${bearingDegrees.toStringAsFixed(1)}°, '
      'speed: ${speedKmh.toStringAsFixed(1)}km/h, time: $timestamp)';
}
