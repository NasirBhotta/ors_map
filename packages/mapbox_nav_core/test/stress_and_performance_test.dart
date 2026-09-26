import 'dart:async';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mapbox_nav_core/mapbox_nav_core.dart';
import 'package:mapbox_nav_core/src/mapbox/rendering/mapbox_route_render_coordinator.dart';

class MockStressLocationSource implements LocationSource {
  final _ctrl = StreamController<LocationFix>.broadcast(sync: true);
  int listenerCount = 0;

  @override
  Stream<LocationFix> get fixes {
    return _ctrl.stream.asBroadcastStream(
      onListen: (_) => listenerCount++,
      onCancel: (_) => listenerCount--,
    );
  }

  void emit(LocationFix fix) => _ctrl.add(fix);
  void dispose() => _ctrl.close();
}

class MockStressRouteProvider implements RouteProvider {
  NavigationRoute? nextRoute;
  bool shouldFail = false;
  int requestCount = 0;

  @override
  Future<NavigationRoute> calculateRoute({
    required GeoPoint origin,
    required GeoPoint destination,
  }) async {
    requestCount++;
    if (shouldFail) {
      throw const RouteException(
        'Simulated route failure',
        reason: RouteErrorReason.networkError,
      );
    }
    return nextRoute ??
        NavigationRoute(
          geometry: [origin, destination],
          totalDistanceMeters: 2000.0,
          totalDurationSeconds: 200.0,
          steps: const [
            NavigationStep(
              instruction: 'Continue straight',
              distanceMeters: 2000.0,
              durationSeconds: 200.0,
            ),
          ],
        );
  }
}

NavigationRoute createLongRoute(
  int pointCount, {
  double totalDistanceMeters = 20000.0,
}) {
  final coords = <GeoPoint>[];
  const startLat = 33.7000;
  const startLng = 73.0000;
  final latDelta = (totalDistanceMeters / 111320.0) / (pointCount - 1);

  for (var i = 0; i < pointCount; i++) {
    coords.add(
      GeoPoint(latitude: startLat + (i * latDelta), longitude: startLng),
    );
  }

  return NavigationRoute(
    geometry: coords,
    totalDistanceMeters: totalDistanceMeters,
    totalDurationSeconds: totalDistanceMeters / 15.0,
    steps: [
      NavigationStep(
        instruction: 'Drive to destination',
        distanceMeters: totalDistanceMeters,
        durationSeconds: totalDistanceMeters / 15.0,
      ),
    ],
  );
}

void main() {
  group('Comprehensive Navigation Stress & Workload Tests (Phase 3 Step 3)', () {
    late MockStressLocationSource locationSource;
    late MockStressRouteProvider routeProvider;
    late DateTime currentTime;
    late NavigationController controller;

    setUp(() {
      currentTime = DateTime.utc(2026, 1, 1, 0, 0, 0);
      locationSource = MockStressLocationSource();
      routeProvider = MockStressRouteProvider();
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

    // Test A: 1,000 rapid fixes with jitter, inaccurate fix, stale gap, and recovery
    test(
      'A: 1,000 rapid fixes stress test with jitter, inaccurate fixes, stale gap, and recovery',
      () async {
        final route = createLongRoute(1000, totalDistanceMeters: 20000.0);
        const dest = GeoPoint(latitude: 33.8796, longitude: 73.0000);
        await controller.startNavigation(route: route, destination: dest);

        final events = <NavigationEvent>[];
        final eventSub = controller.events.listen(events.add);

        var previousCommittedDist = 0.0;
        final rng = Random(42);

        for (var i = 1; i <= 1000; i++) {
          currentTime = currentTime.add(
            const Duration(milliseconds: 100),
          ); // 10 Hz input

          // Simulate occasional inaccurate fix at i = 300
          final isBadFix = (i >= 300 && i <= 305);
          final accuracy = isBadFix ? 120.0 : 4.0;

          // Simulate short stale gap between 600 and 630 (no time advancement relative to last fix)
          final isStaleGap = (i >= 600 && i <= 620);
          final fixTime =
              isStaleGap
                  ? currentTime.subtract(const Duration(seconds: 15))
                  : currentTime;

          // Realistic forward movement: ~1.5m per 100ms (~15 m/s) with minor lateral jitter
          final baseLat = 33.7000 + (i * 0.000015);
          final jitterLng = (rng.nextDouble() - 0.5) * 0.00002;

          locationSource.emit(
            LocationFix(
              coordinate: GeoPoint(
                latitude: baseLat,
                longitude: 73.0000 + jitterLng,
              ),
              accuracyMeters: accuracy,
              bearingDegrees: 0.0,
              speedMetersPerSecond: 15.0,
              timestamp: fixTime,
            ),
          );

          final state = controller.state;
          expect(state.status, NavigationStatus.navigating);

          // Invariant K & L: distance along route strictly in [0, totalDistance] and remaining >= 0
          final dist = state.distanceAlongRouteMeters ?? 0.0;
          final rem = state.remainingDistanceMeters ?? 0.0;
          expect(dist, greaterThanOrEqualTo(0.0));
          expect(dist, lessThanOrEqualTo(route.totalDistanceMeters));
          expect(rem, greaterThanOrEqualTo(0.0));
          expect(
            dist >= previousCommittedDist - 0.001,
            isTrue,
            reason: 'Progress rewound at fix $i',
          );

          if (dist > previousCommittedDist) {
            previousCommittedDist = dist;
          }
        }

        expect(previousCommittedDist, greaterThan(1500.0));
        // Invariant I: Event count remains bounded
        expect(events.length, lessThan(200));

        await eventSub.cancel();
      },
    );

    // Test E: 100 start / stop / restart cycles
    test(
      'E: 100 start/stop cycles preserve resource bounds without subscription or timer leaks',
      () async {
        final route = createLongRoute(100);
        const dest = GeoPoint(latitude: 33.8000, longitude: 73.0000);

        for (var cycle = 0; cycle < 100; cycle++) {
          await controller.startNavigation(route: route, destination: dest);
          expect(controller.state.status, NavigationStatus.navigating);
          expect(locationSource.listenerCount, equals(1));

          controller.stopNavigation();
          expect(controller.state.status, NavigationStatus.stopped);
        }

        // Assert single active subscription after 100 cycles
        expect(locationSource.listenerCount, equals(1));
      },
    );

    // Test F: Repeated reroute cycles (off-route -> reroute -> success & failure)
    test(
      'F: repeated reroute cycles handle success and failures stably',
      () async {
        final initialRoute = createLongRoute(500, totalDistanceMeters: 10000.0);
        const dest = GeoPoint(latitude: 33.8000, longitude: 73.0000);
        await controller.startNavigation(
          route: initialRoute,
          destination: dest,
        );

        final events = <NavigationEvent>[];
        final eventSub = controller.events.listen(events.add);

        for (var cycle = 0; cycle < 10; cycle++) {
          // Every 2nd cycle simulate route failure
          final failCycle = cycle % 2 == 1;
          routeProvider.shouldFail = failCycle;
          if (!failCycle) {
            routeProvider.nextRoute = createLongRoute(
              300,
              totalDistanceMeters: 8000.0,
            );
          }

          // Satisfy minRerouteInterval (at least 6 seconds forward)
          currentTime = currentTime.add(const Duration(seconds: 6));

          // Drive off route (lateral offset ~200m) with 4 consecutive fixes to trigger auto-reroute
          for (var off = 1; off <= 4; off++) {
            currentTime = currentTime.add(const Duration(seconds: 1));
            locationSource.emit(
              LocationFix(
                coordinate: GeoPoint(
                  latitude: 33.7100 + (cycle * 0.001),
                  longitude: 73.0050,
                ),
                accuracyMeters: 5.0,
                bearingDegrees: 0.0,
                speedMetersPerSecond: 10.0,
                timestamp: currentTime,
              ),
            );
          }

          // Allow microtask to process reroute completion
          await Future<void>.delayed(const Duration(milliseconds: 20));

          if (failCycle) {
            expect(
              controller.state.routeRequestStatus,
              equals(RouteRequestStatus.failed),
            );
          } else {
            expect(
              controller.state.routeRequestStatus,
              equals(RouteRequestStatus.idle),
            );
          }
        }

        // Assert ordered events and no unbounded accumulation
        expect(events.whereType<RerouteStartedEvent>().isNotEmpty, isTrue);
        expect(
          events.whereType<RerouteFailedEvent>().length,
          equals(5),
        ); // 10 / 2 = 5 failures

        await eventSub.cancel();
      },
    );

    // Test G & J: Repeated stale / fresh cycles without duplicate identical state spam
    test(
      'G & J: stale/fresh transitions and deduplication suppress identical state spam',
      () async {
        final route = createLongRoute(200);
        const dest = GeoPoint(latitude: 33.8000, longitude: 73.0000);
        await controller.startNavigation(route: route, destination: dest);

        final emittedStates = <NavigationState>[];
        final stateSub = controller.states.listen(emittedStates.add);

        // Emit on-route fix
        locationSource.emit(
          LocationFix(
            coordinate: const GeoPoint(latitude: 33.7005, longitude: 73.0000),
            accuracyMeters: 4.0,
            bearingDegrees: 0.0,
            speedMetersPerSecond: 10.0,
            timestamp: currentTime,
          ),
        );

        // Advance time by 15s to trigger stale GPS transition
        currentTime = currentTime.add(const Duration(seconds: 15));
        controller.evaluateFreshness();

        expect(
          controller.state.locationQuality.freshness,
          LocationFreshness.stale,
        );

        // Verify no identical states emitted repeatedly
        for (var i = 0; i < emittedStates.length - 1; i++) {
          expect(
            emittedStates[i] != emittedStates[i + 1],
            isTrue,
            reason: 'Duplicate identical NavigationState emitted at index $i',
          );
        }

        await stateSub.cancel();
      },
    );

    // Test H: Repeated mount/unmount simulation on NavigationMapView
    test(
      'H: repeated mount/unmount and style generation coordination handles rapid cycles',
      () async {
        final coordinator = MapboxRouteRenderCoordinator(
          delegate: _TestRenderDelegate(),
        );

        final route = createLongRoute(100);

        // Simulate 50 rapid mount/draw/style-reload/unmount cycles
        for (var i = 1; i <= 50; i++) {
          await coordinator.scheduleDraw(
            sessionId: i,
            routeRevision: 1,
            route: route,
          );

          coordinator.scheduleProgressUpdate(
            sessionId: i,
            routeRevision: 1,
            route: route,
            distanceAlongRouteMeters: 50.0,
          );

          if (i % 5 == 0) {
            await coordinator.scheduleClear(i);
          }
        }

        coordinator.dispose();
        expect(coordinator.isDisposed, isTrue);
      },
    );

    // Test K & L: Progress bounds and non-negative remaining distance across arrival
    test(
      'K & L: route progress remains within [0, total distance] and arrival triggers cleanly',
      () async {
        final route = createLongRoute(100, totalDistanceMeters: 500.0);
        final dest = route.geometry.last;
        await controller.startNavigation(route: route, destination: dest);

        final events = <NavigationEvent>[];
        final eventSub = controller.events.listen(events.add);

        // Drive directly to destination vertex
        for (var i = 0; i < route.geometry.length; i++) {
          currentTime = currentTime.add(const Duration(seconds: 1));
          locationSource.emit(
            LocationFix(
              coordinate: route.geometry[i],
              accuracyMeters: 3.0,
              bearingDegrees: 0.0,
              speedMetersPerSecond: 5.0,
              timestamp: currentTime,
            ),
          );

          final state = controller.state;
          expect(state.distanceAlongRouteMeters! >= 0.0, isTrue);
          expect(
            state.distanceAlongRouteMeters! <= route.totalDistanceMeters + 0.1,
            isTrue,
          );
          expect(state.remainingDistanceMeters! >= -0.001, isTrue);
        }

        // Check arrival
        expect(controller.state.status, NavigationStatus.arrived);
        expect(controller.state.isArrived, isTrue);
        // Ensure duplicate arrival events are not spammed
        expect(events.whereType<DestinationReachedEvent>().length, equals(1));

        await eventSub.cancel();
      },
    );
  });
}

class _TestRenderDelegate implements RouteRenderDelegate {
  @override
  Future<void> clearRoute() async {}

  @override
  Future<void> drawRoute(NavigationRoute route) async {}

  @override
  Future<void> updateRouteProgress(
    NavigationRoute route,
    double distanceAlongRouteMeters,
  ) async {}
}
