import 'package:geolocator/geolocator.dart' as geolocator;
import 'package:mapbox_navigation/src/location/location_source.dart';
import 'package:mapbox_navigation/src/models/geo_point.dart';
import 'package:mapbox_navigation/src/models/location_fix.dart';

/// Concrete [LocationSource] powered by the `geolocator` plugin.
///
/// Automatically converts device GPS fixes into package [LocationFix] instances.
final class GeolocatorLocationSource implements LocationSource {
  final geolocator.LocationAccuracy accuracy;
  final int distanceFilter;

  const GeolocatorLocationSource({
    this.accuracy = geolocator.LocationAccuracy.bestForNavigation,
    this.distanceFilter = 1,
  });

  @override
  Stream<LocationFix> get fixes => geolocator.Geolocator.getPositionStream(
        locationSettings: geolocator.LocationSettings(
          accuracy: accuracy,
          distanceFilter: distanceFilter,
        ),
      ).map(
        (position) {
          final heading = position.heading.isNaN || position.heading < 0.0
              ? 0.0
              : position.heading % 360.0;
          final speed = position.speed.isNaN || position.speed < 0.0
              ? 0.0
              : position.speed;

          return LocationFix(
            coordinate: GeoPoint(
              latitude: position.latitude,
              longitude: position.longitude,
            ),
            accuracyMeters: position.accuracy.abs(),
            altitudeMeters: position.altitude,
            bearingDegrees: heading,
            speedMetersPerSecond: speed,
            timestamp: position.timestamp,
          );
        },
      );
}
