import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:mapbox_navigation/navigation.dart';

class FreshnessLocationSource implements LocationSource {
  final _ctrl = StreamController<LocationFix>.broadcast(sync: true);
  @override
  Stream<LocationFix> get fixes => _ctrl.stream;
  void emit(LocationFix fix) => _ctrl.add(fix);
  void dispose() => _ctrl.close();
}

class FreshnessRouteProvider implements RouteProvider {
  @override
  Future<NavigationRoute> calculateRoute({
    required GeoPoint origin,
    required GeoPoint destination,
  }) async {
    return sampleRoute();
  }
}

NavigationRoute sampleRoute() {
  return NavigationRoute(
    geometry: const [
      GeoPoint(latitude: 33.7000, longitude: 73.0000),
      GeoPoint(latitude: 33.7100, longitude: 73.0100),
      GeoPoint(latitude: 33.7200, longitude: 73.0200),
    ],
    totalDistanceMeters: 2500.0,
    totalDurationSeconds: 180.0,
    steps: const [
      NavigationStep(
        instruction: 'Drive straight',
        distanceMeters: 2500.0,
        durationSeconds: 180.0,
      ),
    ],
  );
}

LocationFix createFixAt({
  required double lat,
  required double lng,
  required DateTime timestamp,
  double speed = 10.0,
}) {
  return LocationFix(
    coordinate: GeoPoint(latitude: lat, longitude: lng),
    accuracyMeters: 5.0,
    bearingDegrees: 45.0,
    speedMetersPerSecond: speed,
    timestamp: timestamp,
  );
}

void main() {
  group('NavigationController GPS Freshness & Staleness', () {
    late FreshnessLocationSource locationSource;
    late FreshnessRouteProvider routeProvider;
    late DateTime currentTime;
    late NavigationController controller;

    setUp(() {
      currentTime = DateTime.utc(2026, 1, 1, 0, 0, 0);
      locationSource = FreshnessLocationSource();
      routeProvider = FreshnessRouteProvider();
      controller = NavigationController(
        routeProvider: routeProvider,
        locationSource: locationSource,
        config: const NavigationConfig(
          freshness: FreshnessConfig(staleTimeout: Duration(seconds: 4)),
        ),
        clock: () => currentTime,
      );
    });

    tearDown(() {
      controller.dispose();
      locationSource.dispose();
    });

    // Requirement M: GPS stale without new event
    test('M: staleness transition occurs from elapsed time alone without any new GPS fix', () async {
      final route = sampleRoute();
      const dest = GeoPoint(latitude: 33.7200, longitude: 73.0200);
      await controller.startNavigation(route: route, destination: dest);

      // Deliver fresh fix at t = 0
      locationSource.emit(
        createFixAt(lat: 33.7000, lng: 73.0000, timestamp: currentTime),
      );
      expect(controller.state.locationQuality.freshness, LocationFreshness.fresh);

      // Advance clock by 5 seconds (stale timeout is 4 seconds)
      currentTime = currentTime.add(const Duration(seconds: 5));

      // Wait 1.1s for the periodic 1-second freshness timer to tick
      await Future<void>.delayed(const Duration(milliseconds: 1100));

      expect(controller.state.locationQuality.freshness, LocationFreshness.stale);
    });

    // Requirement N: Stale GPS freezes measured progress
    test('N: fix delivered with timestamp already stale on arrival is rejected without advancing progress', () async {
      final route = sampleRoute();
      const dest = GeoPoint(latitude: 33.7200, longitude: 73.0200);
      await controller.startNavigation(route: route, destination: dest);

      // Fresh fix at t = 10s
      currentTime = DateTime.utc(2026, 1, 1, 0, 0, 10);
      locationSource.emit(
        createFixAt(lat: 33.7050, lng: 73.0050, timestamp: currentTime),
      );
      final lockedDist = controller.state.distanceAlongRouteMeters!;
      expect(controller.state.locationQuality.freshness, LocationFreshness.fresh);

      // Clock moves to t = 20s
      currentTime = DateTime.utc(2026, 1, 1, 0, 0, 20);

      // Platform delivers a buffered/delayed fix with timestamp = 12s (8s old, older than 4s timeout)
      locationSource.emit(
        createFixAt(
          lat: 33.7100,
          lng: 73.0100,
          timestamp: DateTime.utc(2026, 1, 1, 0, 0, 12),
        ),
      );

      // State was not mutated by the stale-on-delivery fix
      expect(controller.state.distanceAlongRouteMeters, equals(lockedDist));
    });

    // Requirement O: Fresh GPS recovery
    test('O: fresh GPS fix restores fresh status and allows progress to resume normally', () async {
      final route = sampleRoute();
      const dest = GeoPoint(latitude: 33.7200, longitude: 73.0200);
      await controller.startNavigation(route: route, destination: dest);

      // Fix at t = 0s
      currentTime = DateTime.utc(2026, 1, 1, 0, 0, 0);
      locationSource.emit(
        createFixAt(lat: 33.7000, lng: 73.0000, timestamp: currentTime),
      );
      expect(controller.state.locationQuality.freshness, LocationFreshness.fresh);

      // Stale at t = 10s
      currentTime = DateTime.utc(2026, 1, 1, 0, 0, 10);
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      expect(controller.state.locationQuality.freshness, LocationFreshness.stale);

      // Fresh fix arrives at t = 10s
      locationSource.emit(
        createFixAt(lat: 33.7050, lng: 73.0050, timestamp: currentTime),
      );

      expect(controller.state.locationQuality.freshness, LocationFreshness.fresh);
      expect(controller.state.distanceAlongRouteMeters! > 500.0, isTrue);
    });
  });
}
