import 'package:flutter_test/flutter_test.dart';
import 'package:mapbox_navigation/mapbox_navigation.dart';

class FakeRouteProvider implements RouteProvider {
  @override
  Future<NavigationRoute> calculateRoute({
    required GeoPoint origin,
    required GeoPoint destination,
  }) async {
    return NavigationRoute(
      geometry: const [
        GeoPoint(latitude: 33.0, longitude: 73.0),
        GeoPoint(latitude: 33.1, longitude: 73.1),
      ],
      totalDistanceMeters: 1000.0,
      totalDurationSeconds: 120.0,
      steps: [],
    );
  }
}

class FakeLocationSource implements LocationSource {
  @override
  Stream<LocationFix> get fixes => const Stream.empty();
}

void main() {
  group('NavigationMapView', () {
    test('K: widget parameters and appearance defaults instantiate cleanly', () {
      final controller = NavigationController(
        routeProvider: FakeRouteProvider(),
        locationSource: FakeLocationSource(),
      );

      final widget = NavigationMapView(
        controller: controller,
        accessToken: 'test_token',
        vehicle: const VehicleAppearance.model3D(
          modelUri: 'asset://assets/lowpoly_car.glb',
          scale: 0.05,
          bearingOffset: 180.0,
        ),
        routeTheme: const MapboxRouteTheme(),
      );

      expect(widget.accessToken, equals('test_token'));
      expect(widget.vehicle.scale, equals(0.05));
      expect(widget.vehicle.bearingOffset, equals(180.0));
      expect(widget.routeTheme.routeWidth, equals(9.0));
      expect(widget.routeTheme.casingWidth, equals(14.0));

      controller.dispose();
    });
  });
}
