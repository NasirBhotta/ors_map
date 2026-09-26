import 'package:meta/meta.dart';

/// An immutable, vendor-neutral geographic coordinate.
@immutable
final class GeoPoint {
  final double latitude;
  final double longitude;

  /// Creates a [GeoPoint] with [latitude] and [longitude] in degrees.
  ///
  /// Asserts that [latitude] is in [-90.0, 90.0] and [longitude] is in [-180.0, 180.0].
  const GeoPoint({required this.latitude, required this.longitude})
    : assert(
        latitude >= -90.0 && latitude <= 90.0,
        'latitude must be between -90.0 and 90.0 (received $latitude)',
      ),
      assert(
        longitude >= -180.0 && longitude <= 180.0,
        'longitude must be between -180.0 and 180.0 (received $longitude)',
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GeoPoint &&
          runtimeType == other.runtimeType &&
          latitude == other.latitude &&
          longitude == other.longitude;

  @override
  int get hashCode => Object.hash(latitude, longitude);

  @override
  String toString() => 'GeoPoint(lat: $latitude, lng: $longitude)';
}
