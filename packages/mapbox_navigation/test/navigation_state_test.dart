import 'package:flutter_test/flutter_test.dart';
import 'package:mapbox_navigation/navigation.dart';

void main() {
  group('NavigationState', () {
    test('initializes with expected authoritative defaults', () {
      const state = NavigationState();

      expect(state.status, NavigationStatus.idle);
      expect(state.routeRequestStatus, RouteRequestStatus.idle);
      expect(state.trackingStatus, TrackingStatus.unmatched);
      expect(state.activeRoute, isNull);
      expect(state.destination, isNull);
      expect(state.rawFix, isNull);
      expect(state.matchedPoint, isNull);
      expect(state.bearingDegrees, 0.0);
      expect(state.speedMps, 0.0);
      expect(state.speedKmh, 0.0);
      expect(state.distanceAlongRouteMeters, isNull);
      expect(state.remainingDistanceMeters, isNull);
      expect(state.remainingDurationSeconds, isNull);
      expect(state.currentStepIndex, isNull);
      expect(state.currentStep, isNull);
      expect(state.locationQuality.freshness, LocationFreshness.unknown);
      expect(state.isArrived, isFalse);
    });

    test('copyWith produces expected updated state', () {
      const state = NavigationState();
      const coord = GeoPoint(latitude: 33.7, longitude: 73.0);
      final fix = LocationFix(
        coordinate: coord,
        accuracyMeters: 4.5,
        bearingDegrees: 180,
        speedMetersPerSecond: 15.0, // 54 km/h
        timestamp: DateTime.utc(2026, 1, 1),
      );

      final updated = state.copyWith(
        status: NavigationStatus.navigating,
        trackingStatus: TrackingStatus.onRoute,
        rawFix: fix,
        matchedPoint: coord,
        speedMps: 15.0,
        bearingDegrees: 180.0,
        distanceAlongRouteMeters: 120.0,
        remainingDistanceMeters: 880.0,
      );

      expect(updated.status, NavigationStatus.navigating);
      expect(updated.trackingStatus, TrackingStatus.onRoute);
      expect(updated.speedKmh, 54.0);
      expect(updated.matchedPoint, coord);
      expect(updated.distanceAlongRouteMeters, 120.0);
      expect(updated.remainingDistanceMeters, 880.0);
      expect(updated.isArrived, isFalse);
    });

    test('LocationQuality computes age relative to current clock', () {
      final t0 = DateTime.utc(2026, 1, 1, 12, 0, 0);
      final quality = LocationQuality(
        timestamp: t0,
        accuracyMeters: 5.0,
        freshness: LocationFreshness.fresh,
      );

      final t1 = DateTime.utc(2026, 1, 1, 12, 0, 4);
      expect(quality.age(t1), const Duration(seconds: 4));

      // Clock skew (now earlier than timestamp) returns Duration.zero
      final tPast = DateTime.utc(2026, 1, 1, 11, 59, 59);
      expect(quality.age(tPast), Duration.zero);

      // Unknown quality returns null age
      const unknown = LocationQuality();
      expect(unknown.age(t1), isNull);
    });
  });
}
