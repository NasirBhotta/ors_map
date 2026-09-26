import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mapbox_nav_core/navigation.dart';
import 'package:mapbox_nav_core/src/tracking/route_metrics.dart';

class StubLocationSource implements LocationSource {
  @override
  Stream<LocationFix> get fixes => const Stream<LocationFix>.empty();
}

class StubRouteProvider implements RouteProvider {
  @override
  Future<NavigationRoute> calculateRoute({
    required GeoPoint origin,
    required GeoPoint destination,
  }) async {
    return NavigationRoute(
      geometry: [origin, destination],
      totalDistanceMeters: 100.0,
      totalDurationSeconds: 10.0,
      steps: const [
        NavigationStep(
          instruction: 'Proceed',
          distanceMeters: 100.0,
          durationSeconds: 10.0,
        ),
      ],
    );
  }
}

void main() {
  group('Geodesy Numerical Stability & Fuzz Tests', () {
    test('Haversine: identical coordinates return zero and never NaN', () {
      final d = RouteMetrics.haversine(0.0, 0.0, 0.0, 0.0);
      expect(d, equals(0.0));
      expect(d.isFinite, isTrue);
      expect(d.isNaN, isFalse);
    });

    test('Haversine: antipodal coordinates evaluate without NaN', () {
      final d = RouteMetrics.haversine(90.0, 0.0, -90.0, 0.0);
      expect(d.isFinite, isTrue);
      expect(d.isNaN, isFalse);
      expect(d, greaterThan(20000000.0));
    });

    test(
      'Haversine: 10,000 random coordinate pairs never yield NaN or negative distance',
      () {
        final rng = Random(42);
        for (var i = 0; i < 10000; i++) {
          final lat1 = (rng.nextDouble() * 180.0) - 90.0;
          final lng1 = (rng.nextDouble() * 360.0) - 180.0;
          final lat2 = (rng.nextDouble() * 180.0) - 90.0;
          final lng2 = (rng.nextDouble() * 360.0) - 180.0;

          final d = RouteMetrics.haversine(lat1, lng1, lat2, lng2);
          expect(
            d.isFinite,
            isTrue,
            reason: 'Iteration $i produced non-finite distance',
          );
          expect(d.isNaN, isFalse, reason: 'Iteration $i produced NaN');
          expect(
            d >= 0.0,
            isTrue,
            reason: 'Iteration $i produced negative distance',
          );
        }
      },
    );

    test(
      'normalizeBearing: normalizes arbitrary negative and large bearings to [0, 360)',
      () {
        expect(RouteMetrics.normalizeBearing(0.0), equals(0.0));
        expect(RouteMetrics.normalizeBearing(360.0), equals(0.0));
        expect(RouteMetrics.normalizeBearing(-1.0), equals(359.0));
        expect(RouteMetrics.normalizeBearing(-360.0), equals(0.0));
        expect(RouteMetrics.normalizeBearing(-720.0), equals(0.0));
        expect(RouteMetrics.normalizeBearing(725.5), closeTo(5.5, 0.0001));

        final rng = Random(1337);
        for (var i = 0; i < 5000; i++) {
          final b = (rng.nextDouble() * 20000.0) - 10000.0;
          final norm = RouteMetrics.normalizeBearing(b);
          expect(
            norm >= 0.0 && norm < 360.0,
            isTrue,
            reason: 'Bearing $b normalized to $norm',
          );
        }
      },
    );

    test('shortestBearingDelta: always yields value in [-180, 180]', () {
      final rng = Random(999);
      for (var i = 0; i < 5000; i++) {
        final from = rng.nextDouble() * 360.0;
        final to = rng.nextDouble() * 360.0;
        final delta = RouteMetrics.shortestBearingDelta(from, to);
        expect(
          delta >= -180.0 && delta <= 180.0,
          isTrue,
          reason: 'Delta from $from to $to was $delta',
        );
      }
    });
  });

  group('Model & Config Runtime Validation', () {
    test('NavigationRoute: rejects geometry with fewer than 2 points', () {
      expect(
        () => NavigationRoute(
          geometry: const [GeoPoint(latitude: 33.0, longitude: 73.0)],
          totalDistanceMeters: 0.0,
          totalDurationSeconds: 0.0,
          steps: const [],
        ),
        throwsA(isA<InvalidRouteException>()),
      );
    });

    test('NavigationRoute: rejects negative or NaN distance', () {
      expect(
        () => NavigationRoute(
          geometry: const [
            GeoPoint(latitude: 33.0, longitude: 73.0),
            GeoPoint(latitude: 33.1, longitude: 73.1),
          ],
          totalDistanceMeters: -100.0,
          totalDurationSeconds: 10.0,
          steps: const [],
        ),
        throwsA(isA<InvalidRouteException>()),
      );

      expect(
        () => NavigationRoute(
          geometry: const [
            GeoPoint(latitude: 33.0, longitude: 73.0),
            GeoPoint(latitude: 33.1, longitude: 73.1),
          ],
          totalDistanceMeters: double.nan,
          totalDurationSeconds: 10.0,
          steps: const [],
        ),
        throwsA(isA<InvalidRouteException>()),
      );
    });

    test(
      'NavigationConfig: validate catches invalid tracking and arrival values',
      () {
        const config1 = NavigationConfig(
          tracking: TrackingConfig(offRouteMeters: 50.0),
          arrival: ArrivalConfig(destinationRadiusMeters: 25.0),
        );
        expect(() => config1.validate(), returnsNormally);
      },
    );
  });

  group('Controller Lifecycle & Disposal Guards', () {
    test('Controller: double dispose is safe and idempotent', () {
      final controller = NavigationController(
        routeProvider: StubRouteProvider(),
        locationSource: StubLocationSource(),
      );
      expect(controller.state.status, NavigationStatus.idle);

      controller.dispose();
      expect(controller.state.status, NavigationStatus.disposed);

      // Second dispose call must not throw
      expect(() => controller.dispose(), returnsNormally);
    });

    test('Controller: double stopNavigation is safe and idempotent', () {
      final controller = NavigationController(
        routeProvider: StubRouteProvider(),
        locationSource: StubLocationSource(),
      );

      controller.stopNavigation();
      expect(controller.state.status, NavigationStatus.stopped);

      // Second stopNavigation must be a no-op
      expect(() => controller.stopNavigation(), returnsNormally);
      controller.dispose();
    });

    test(
      'Controller: invoking methods after dispose throws NavigationLifecycleException',
      () async {
        final controller = NavigationController(
          routeProvider: StubRouteProvider(),
          locationSource: StubLocationSource(),
        );
        controller.dispose();

        const pt = GeoPoint(latitude: 33.0, longitude: 73.0);
        final route = NavigationRoute(
          geometry: const [
            GeoPoint(latitude: 33.0, longitude: 73.0),
            GeoPoint(latitude: 33.1, longitude: 73.1),
          ],
          totalDistanceMeters: 500.0,
          totalDurationSeconds: 60.0,
          steps: const [],
        );

        expect(
          () => controller.calculateRoute(origin: pt, destination: pt),
          throwsA(
            isA<NavigationLifecycleException>().having(
              (e) => e.reason,
              'reason',
              LifecycleErrorReason.sessionDisposed,
            ),
          ),
        );

        expect(
          () => controller.startPreview(route: route, destination: pt),
          throwsA(
            isA<NavigationLifecycleException>().having(
              (e) => e.reason,
              'reason',
              LifecycleErrorReason.sessionDisposed,
            ),
          ),
        );

        expect(
          () => controller.startNavigation(route: route, destination: pt),
          throwsA(
            isA<NavigationLifecycleException>().having(
              (e) => e.reason,
              'reason',
              LifecycleErrorReason.sessionDisposed,
            ),
          ),
        );
      },
    );
  });
}
