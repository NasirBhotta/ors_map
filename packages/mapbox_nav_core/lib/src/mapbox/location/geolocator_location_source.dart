import 'package:geolocator/geolocator.dart' as geolocator;
import 'package:mapbox_nav_core/src/errors/navigation_errors.dart';
import 'package:mapbox_nav_core/src/location/location_source.dart';
import 'package:mapbox_nav_core/src/models/geo_point.dart';
import 'package:mapbox_nav_core/src/models/location_fix.dart';

/// Concrete [LocationSource] powered by the `geolocator` plugin.
///
/// Automatically converts device GPS fixes into package [LocationFix] instances,
/// normalizing platform-specific differences (such as iOS negative sentinels) and
/// mapping platform exceptions into typed [LocationUnavailableException]s.
final class GeolocatorLocationSource implements LocationSource {
  final geolocator.LocationAccuracy accuracy;
  final int distanceFilter;

  const GeolocatorLocationSource({
    this.accuracy = geolocator.LocationAccuracy.bestForNavigation,
    this.distanceFilter = 1,
  });

  /// Normalizes a platform [geolocator.Position] into an immutable [LocationFix],
  /// guarding against iOS/Android sentinel values (e.g., negative speed, course, accuracy).
  static LocationFix normalizePosition(geolocator.Position position) {
    // 1. Heading: iOS course unavailable is -1.0; clamp negative or NaN to 0.0, wrap positive into [0.0, 360.0).
    final heading =
        position.heading.isNaN || position.heading < 0.0
            ? 0.0
            : ((position.heading % 360.0) + 360.0) % 360.0;

    // 2. Speed: iOS speed unavailable is -1.0; clamp negative or NaN to 0.0.
    final speed =
        position.speed.isNaN || position.speed < 0.0 ? 0.0 : position.speed;

    // 3. Accuracy: iOS invalid horizontal accuracy is -1.0. Clamping to 100.0 avoids fake 1.0m accuracy from abs().
    final accuracy =
        position.accuracy.isNaN || position.accuracy < 0.0
            ? 100.0
            : position.accuracy;

    // 4. Altitude: clamp NaN to 0.0.
    final altitude = position.altitude.isNaN ? 0.0 : position.altitude;

    // 5. Timestamp: ensure UTC normalization across platforms.
    final timestamp = position.timestamp.toUtc();

    return LocationFix(
      coordinate: GeoPoint(
        latitude: position.latitude,
        longitude: position.longitude,
      ),
      accuracyMeters: accuracy,
      altitudeMeters: altitude,
      bearingDegrees: heading,
      speedMetersPerSecond: speed,
      timestamp: timestamp,
    );
  }

  @override
  Stream<LocationFix> get fixes => geolocator.Geolocator.getPositionStream(
        locationSettings: geolocator.LocationSettings(
          accuracy: accuracy,
          distanceFilter: distanceFilter,
        ),
      )
      .handleError((Object error, StackTrace stackTrace) {
        if (error is geolocator.LocationServiceDisabledException) {
          throw LocationUnavailableException(
            'Location services (GPS) are disabled on this device.',
            reason: LocationErrorReason.serviceDisabled,
            cause: error,
          );
        } else if (error is geolocator.PermissionDeniedException ||
            error is geolocator.PermissionDefinitionsNotFoundException) {
          throw LocationUnavailableException(
            'Location permission denied: $error',
            reason: LocationErrorReason.permissionDenied,
            cause: error,
          );
        }
        throw LocationUnavailableException(
          'Location stream encountered error: $error',
          reason: LocationErrorReason.invalidData,
          cause: error,
        );
      })
      .map(normalizePosition);
}
