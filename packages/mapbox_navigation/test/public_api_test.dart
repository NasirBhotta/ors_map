import 'package:flutter_test/flutter_test.dart';
import 'package:mapbox_navigation/mapbox_navigation.dart';

void main() {
  group('Public API Surface Verification', () {
    test('mapbox_navigation.dart exports all required presentation and core types', () {
      const point = GeoPoint(latitude: 33.5651, longitude: 73.0169);
      expect(point.latitude, 33.5651);

      final fix = LocationFix(
        coordinate: point,
        accuracyMeters: 5.0,
        bearingDegrees: 45.0,
        speedMetersPerSecond: 10.0,
        timestamp: DateTime.now(),
      );
      expect(fix.coordinate.latitude, 33.5651);
      expect(fix.bearingDegrees, 45.0);
      expect(fix.speedMetersPerSecond, 10.0);

      final route = NavigationRoute(
        geometry: const [
          GeoPoint(latitude: 33.0, longitude: 73.0),
          GeoPoint(latitude: 33.1, longitude: 73.1),
        ],
        totalDistanceMeters: 1000,
        totalDurationSeconds: 60,
        steps: const [
          NavigationStep(
            instruction: 'Drive straight',
            distanceMeters: 1000,
            durationSeconds: 60,
          ),
        ],
      );
      expect(route.totalDistanceMeters, 1000);

      const config = NavigationConfig();
      expect(config.arrival.destinationRadiusMeters, 30.0);

      final cameraController = NavigationCameraController();
      expect(cameraController.isFollowing, isTrue);
      expect(cameraController.isOverview, isFalse);
      cameraController.dispose();

      const appearance = VehicleAppearance.model3D();
      expect(appearance.scale, 0.05);

      const theme = MapboxRouteTheme();
      expect(theme.routeWidth, 9.0);

      final provider = MapboxRouteProvider(accessToken: 'test_token');
      expect(provider.accessToken, 'test_token');
    });
  });
}
