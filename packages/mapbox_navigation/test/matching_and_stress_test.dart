import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mapbox_navigation/navigation.dart';

class StressTestLocationSource implements LocationSource {
  final _ctrl = StreamController<LocationFix>.broadcast(sync: true);
  @override
  Stream<LocationFix> get fixes => _ctrl.stream;
  void emit(LocationFix fix) => _ctrl.add(fix);
  void dispose() => _ctrl.close();
}

class StressTestRouteProvider implements RouteProvider {
  NavigationRoute? customRoute;

  @override
  Future<NavigationRoute> calculateRoute({
    required GeoPoint origin,
    required GeoPoint destination,
  }) async {
    return customRoute ??
        NavigationRoute(
          geometry: [origin, destination],
          totalDistanceMeters: 1000.0,
          totalDurationSeconds: 100.0,
          steps: const [
            NavigationStep(
              instruction: 'Proceed',
              distanceMeters: 1000.0,
              durationSeconds: 100.0,
            ),
          ],
        );
  }
}

void main() {
  group('NavigationController Stress & Difficult Geometries', () {
    late StressTestLocationSource locationSource;
    late StressTestRouteProvider routeProvider;
    late DateTime currentTime;
    late NavigationController controller;

    setUp(() {
      currentTime = DateTime.utc(2026, 1, 1, 0, 0, 0);
      locationSource = StressTestLocationSource();
      routeProvider = StressTestRouteProvider();
      controller = NavigationController(
        routeProvider: routeProvider,
        locationSource: locationSource,
        clock: () => currentTime,
      );
    });

    tearDown(() {
      controller.dispose();
      locationSource.dispose();
    });

    test('Stress: 1,000 rapid sequential fixes processed stably without error', () async {
      // 10km route going north
      final route = NavigationRoute(
        geometry: const [
          GeoPoint(latitude: 33.7000, longitude: 73.0000),
          GeoPoint(latitude: 33.8000, longitude: 73.0000),
        ],
        totalDistanceMeters: 11100.0,
        totalDurationSeconds: 1000.0,
        steps: const [
          NavigationStep(
            instruction: 'Drive north',
            distanceMeters: 11100.0,
            durationSeconds: 1000.0,
          ),
        ],
      );

      const dest = GeoPoint(latitude: 33.8000, longitude: 73.0000);
      await controller.startNavigation(route: route, destination: dest);

      var lastDistance = -1.0;
      for (var i = 1; i <= 1000; i++) {
        currentTime = DateTime.utc(2026, 1, 1, 0, 0, 0).add(Duration(milliseconds: i * 200));
        // Moving ~2m per 200ms tick (~10 m/s = 36 km/h)
        final lat = 33.7000 + (i * 0.00002);
        locationSource.emit(
          LocationFix(
            coordinate: GeoPoint(latitude: lat, longitude: 73.0000),
            accuracyMeters: 4.0,
            bearingDegrees: 0.0,
            speedMetersPerSecond: 10.0,
            timestamp: currentTime,
          ),
        );

        final state = controller.state;
        expect(state.status, NavigationStatus.navigating);
        expect(state.trackingStatus, TrackingStatus.onRoute);
        expect(state.distanceAlongRouteMeters, isNotNull);
        expect(state.distanceAlongRouteMeters! >= lastDistance, isTrue,
            reason: 'Fix $i caused backward progress jump');
        lastDistance = state.distanceAlongRouteMeters!;
      }

      expect(lastDistance, greaterThan(2000.0));
    });

    test('Stress: 50 rapid start/stop/start cycles execute cleanly', () async {
      final route = NavigationRoute(
        geometry: const [
          GeoPoint(latitude: 33.0, longitude: 73.0),
          GeoPoint(latitude: 33.1, longitude: 73.1),
        ],
        totalDistanceMeters: 1000.0,
        totalDurationSeconds: 100.0,
        steps: const [
          NavigationStep(
            instruction: 'Go',
            distanceMeters: 1000.0,
            durationSeconds: 100.0,
          ),
        ],
      );
      const dest = GeoPoint(latitude: 33.1, longitude: 73.1);

      for (var cycle = 0; cycle < 50; cycle++) {
        await controller.startNavigation(route: route, destination: dest);
        expect(controller.state.status, NavigationStatus.navigating);

        controller.stopNavigation();
        expect(controller.state.status, NavigationStatus.stopped);
      }
    });

    test('Geometry: U-turn route does not jump to opposite leg in tracking mode', () async {
      // Route goes East along lat 33.7000 for ~500m, then U-turns and returns West along lat 33.7002 (~22m offset)
      final uTurnRoute = NavigationRoute(
        geometry: const [
          GeoPoint(latitude: 33.7000, longitude: 73.0000),
          GeoPoint(latitude: 33.7000, longitude: 73.0050), // East leg
          GeoPoint(latitude: 33.7002, longitude: 73.0050), // U-turn curve
          GeoPoint(latitude: 33.7002, longitude: 73.0000), // West return leg
        ],
        totalDistanceMeters: 1000.0,
        totalDurationSeconds: 120.0,
        steps: const [
          NavigationStep(
            instruction: 'Drive East',
            distanceMeters: 500.0,
            durationSeconds: 60.0,
          ),
          NavigationStep(
            instruction: 'Make U-Turn and return West',
            distanceMeters: 500.0,
            durationSeconds: 60.0,
          ),
        ],
      );

      const dest = GeoPoint(latitude: 33.7002, longitude: 73.0000);
      await controller.startNavigation(route: uTurnRoute, destination: dest);

      // Start on East leg heading East (bearing 90)
      currentTime = DateTime.utc(2026, 1, 1, 0, 0, 1);
      locationSource.emit(
        LocationFix(
          coordinate: const GeoPoint(latitude: 33.7000, longitude: 73.0010),
          accuracyMeters: 5.0,
          bearingDegrees: 90.0,
          speedMetersPerSecond: 10.0,
          timestamp: currentTime,
        ),
      );

      final initialDist = controller.state.distanceAlongRouteMeters!;
      expect(controller.state.trackingStatus, TrackingStatus.onRoute);
      expect(initialDist, lessThan(200.0)); // Should be on the outbound leg (<500m)

      // Advance along East leg
      currentTime = DateTime.utc(2026, 1, 1, 0, 0, 2);
      locationSource.emit(
        LocationFix(
          coordinate: const GeoPoint(latitude: 33.7000, longitude: 73.0020),
          accuracyMeters: 5.0,
          bearingDegrees: 90.0,
          speedMetersPerSecond: 10.0,
          timestamp: currentTime,
        ),
      );

      final secondDist = controller.state.distanceAlongRouteMeters!;
      expect(secondDist, greaterThan(initialDist));
      expect(secondDist, lessThan(350.0)); // Remains strictly on East leg, didn't jump to West leg (which is at >700m)
    });
  });
}
