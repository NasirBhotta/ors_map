import 'package:geolocator/geolocator.dart' as geolocator;

/// A GPS observation, independent of Geolocator and the map SDK.
final class NavigationFix {
  final double latitude;
  final double longitude;
  final double accuracy;
  final double altitude;
  final double heading;
  final double speedMetersPerSecond;
  final DateTime timestamp;

  const NavigationFix({
    required this.latitude,
    required this.longitude,
    required this.accuracy,
    required this.altitude,
    required this.heading,
    required this.speedMetersPerSecond,
    required this.timestamp,
  });
}

abstract interface class NavigationLocationSource {
  Stream<NavigationFix> get fixes;
}

/// Permissions are handled by the host screen.
final class GeolocatorNavigationLocationSource
    implements NavigationLocationSource {
  const GeolocatorNavigationLocationSource();

  @override
  Stream<NavigationFix> get fixes => geolocator.Geolocator.getPositionStream(
    locationSettings: const geolocator.LocationSettings(
      accuracy: geolocator.LocationAccuracy.bestForNavigation,
      distanceFilter: 1,
    ),
  ).map(
    (position) => NavigationFix(
      latitude: position.latitude,
      longitude: position.longitude,
      accuracy: position.accuracy,
      altitude: position.altitude,
      heading: position.heading,
      speedMetersPerSecond: position.speed,
      timestamp: position.timestamp,
    ),
  );
}
