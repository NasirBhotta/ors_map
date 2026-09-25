import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:mapbox_navigation/navigation.dart';

class MatchTestLocationSource implements LocationSource {
  final _ctrl = StreamController<LocationFix>.broadcast(sync: true);
  @override
  Stream<LocationFix> get fixes => _ctrl.stream;
  void emit(LocationFix fix) => _ctrl.add(fix);
  void dispose() => _ctrl.close();
}

class MatchTestRouteProvider implements RouteProvider {
  @override
  Future<NavigationRoute> calculateRoute({
    required GeoPoint origin,
    required GeoPoint destination,
  }) async {
    return straightRoute();
  }
}

NavigationRoute straightRoute() {
  // 5 vertices along longitude 73.0 (going north from lat 33.70 to 33.74)
  // Each 0.01 degrees of latitude is ~1110 meters
  return NavigationRoute(
    geometry: const [
      GeoPoint(latitude: 33.7000, longitude: 73.0000),
      GeoPoint(latitude: 33.7100, longitude: 73.0000),
      GeoPoint(latitude: 33.7200, longitude: 73.0000),
      GeoPoint(latitude: 33.7300, longitude: 73.0000),
      GeoPoint(latitude: 33.7400, longitude: 73.0000),
    ],
    totalDistanceMeters: 4440.0,
    totalDurationSeconds: 300.0,
    steps: const [
      NavigationStep(
        instruction: 'Head north on Highway 1',
        distanceMeters: 4440.0,
        durationSeconds: 300.0,
      ),
    ],
  );
}

LocationFix makeFixAt({
  required double lat,
  required double lng,
  required int second,
  double bearing = 0.0,
  double speed = 15.0,
  double accuracy = 5.0,
}) {
  return LocationFix(
    coordinate: GeoPoint(latitude: lat, longitude: lng),
    accuracyMeters: accuracy,
    bearingDegrees: bearing,
    speedMetersPerSecond: speed,
    timestamp: DateTime.utc(2026, 1, 1, 0, 0, second),
  );
}

void main() {
  group('NavigationController Route Matching & Reacquisition', () {
    late MatchTestLocationSource locationSource;
    late MatchTestRouteProvider routeProvider;
    late DateTime currentTime;
    late NavigationController controller;

    setUp(() {
      currentTime = DateTime.utc(2026, 1, 1, 0, 0, 0);
      locationSource = MatchTestLocationSource();
      routeProvider = MatchTestRouteProvider();
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

    // Requirement I: Normal route matching
    test('I: normal forward movement produces monotonically increasing route progress', () async {
      final route = straightRoute();
      const dest = GeoPoint(latitude: 33.7400, longitude: 73.0000);
      await controller.startNavigation(route: route, destination: dest);

      var previousDistance = -1.0;
      for (var i = 1; i <= 4; i++) {
        currentTime = DateTime.utc(2026, 1, 1, 0, 0, i);
        // Step forward by 0.0001 lat (~11m) each second for normal driving at 15 m/s
        locationSource.emit(
          makeFixAt(lat: 33.7000 + i * 0.0001, lng: 73.0000, second: i),
        );

        final dist = controller.state.distanceAlongRouteMeters;
        expect(dist, isNotNull);
        expect(dist! > previousDistance, isTrue);
        expect(controller.state.trackingStatus, TrackingStatus.onRoute);
        previousDistance = dist;
      }
    });

    // Requirement J: Off-route candidate cannot corrupt progress
    test('J: off-route fix preserves authoritative distanceAlongRoute without rewinding or corrupting', () async {
      final route = straightRoute();
      const dest = GeoPoint(latitude: 33.7400, longitude: 73.0000);
      await controller.startNavigation(route: route, destination: dest);

      // Lock onto route at ~1100m
      currentTime = DateTime.utc(2026, 1, 1, 0, 0, 1);
      locationSource.emit(makeFixAt(lat: 33.7100, lng: 73.0000, second: 1));
      final lockedDist = controller.state.distanceAlongRouteMeters!;
      expect(controller.state.trackingStatus, TrackingStatus.onRoute);

      // Now emit an off-route fix 2 km away laterally
      currentTime = DateTime.utc(2026, 1, 1, 0, 0, 2);
      locationSource.emit(makeFixAt(lat: 33.7100, lng: 73.0200, second: 2));

      expect(controller.state.trackingStatus, TrackingStatus.offRoute);
      expect(controller.state.matchedPoint, isNull);
      // Authoritative measured distance is preserved intact
      expect(controller.state.distanceAlongRouteMeters, equals(lockedDist));
    });

    // Requirement K: Off-route → reacquisition
    test('K: several consecutive unmatched fixes trigger reacquisition mode to reacquire route ahead', () async {
      final route = straightRoute();
      const dest = GeoPoint(latitude: 33.7400, longitude: 73.0000);
      await controller.startNavigation(route: route, destination: dest);

      // Lock on initial segment
      currentTime = DateTime.utc(2026, 1, 1, 0, 0, 1);
      locationSource.emit(makeFixAt(lat: 33.7000, lng: 73.0000, second: 1));
      expect(controller.state.trackingStatus, TrackingStatus.onRoute);

      // 3 consecutive off-route fixes
      for (var s = 2; s <= 4; s++) {
        currentTime = DateTime.utc(2026, 1, 1, 0, 0, s);
        locationSource.emit(makeFixAt(lat: 33.7000, lng: 73.0300, second: s));
        expect(controller.state.trackingStatus, TrackingStatus.offRoute);
      }

      // Re-entry fix far ahead on the route (at lat 33.7300, ~3.3km ahead)
      currentTime = DateTime.utc(2026, 1, 1, 0, 0, 5);
      locationSource.emit(makeFixAt(lat: 33.7300, lng: 73.0000, second: 5));

      // In reacquisition mode, global scan succeeds and snaps to the advanced route segment
      expect(controller.state.trackingStatus, TrackingStatus.onRoute);
      expect(controller.state.distanceAlongRouteMeters! > 3000.0, isTrue);
    });

    // Requirement L: Start away from route → join
    test('L: route starting in reacquisition mode successfully locks onto first on-route fix', () async {
      final route = straightRoute();
      const dest = GeoPoint(latitude: 33.7400, longitude: 73.0000);
      await controller.startNavigation(route: route, destination: dest);

      // First fix is off route (e.g. user in a parking garage 300m away)
      currentTime = DateTime.utc(2026, 1, 1, 0, 0, 1);
      locationSource.emit(makeFixAt(lat: 33.7000, lng: 73.0050, second: 1));
      expect(controller.state.trackingStatus, TrackingStatus.offRoute);
      expect(controller.state.matchedPoint, isNull);

      // Second fix joins the road
      currentTime = DateTime.utc(2026, 1, 1, 0, 0, 2);
      locationSource.emit(makeFixAt(lat: 33.7010, lng: 73.0000, second: 2));
      expect(controller.state.trackingStatus, TrackingStatus.onRoute);
      expect(controller.state.matchedPoint, isNotNull);
    });
  });
}
