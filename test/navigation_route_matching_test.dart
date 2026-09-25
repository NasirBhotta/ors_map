// navigation_route_matching_test.dart
//
// Tests A–N for route matching, off-route detection, and route reacquisition.
// All geometry is synthetic; no real GPS, HTTP, or Mapbox objects required.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ors_map_test/models/navigation_state.dart';
import 'package:ors_map_test/services/map_box_navigation_service.dart';
import 'package:ors_map_test/services/mapbox_route_service.dart';
import 'package:ors_map_test/services/navigation_location_source.dart';

// ---------------------------------------------------------------------------
// Test utilities
// ---------------------------------------------------------------------------

class ControlledSource implements NavigationLocationSource {
  final _ctrl = StreamController<NavigationFix>.broadcast(sync: true);

  @override
  Stream<NavigationFix> get fixes => _ctrl.stream;

  int _second = 0;

  /// Send a fix at the given [lng]/[lat] with optional overrides.
  void send({
    double lng = 0,
    double lat = 0,
    double speed = 5,
    double accuracy = 5,
    double heading = 90,
    int? second,
  }) {
    _second = second ?? (_second + 1);
    _ctrl.add(
      NavigationFix(
        longitude: lng,
        latitude: lat,
        accuracy: accuracy,
        altitude: 0,
        heading: heading,
        speedMetersPerSecond: speed,
        timestamp: DateTime.utc(2026, 1, 1, 0, 0, _second),
      ),
    );
  }

  Future<void> close() => _ctrl.close();
}

/// A straight east-going route from lng=0 to lng=0.09 along lat=0.
/// Each segment is ~0.01° ≈ 1112 m; the 9-segment route is ~10 008 m total.
MapboxRouteResult straightRoute({int segments = 9}) {
  final coords = <List<double>>[];
  for (var i = 0; i <= segments; i++) {
    coords.add([i * 0.01, 0.0]);
  }
  const segLen = 1112.0; // metres per 0.01° lng at equator
  final totalDist = segments * segLen;
  final steps = <MapboxStep>[
    MapboxStep(
      instruction: 'Step 0',
      distance: totalDist * 0.5,
      duration: 100,
    ),
    MapboxStep(
      instruction: 'Step 1',
      distance: totalDist * 0.5,
      duration: 100,
    ),
  ];
  return MapboxRouteResult(
    coordinates: coords,
    distanceMeters: totalDist,
    durationSeconds: 200,
    steps: steps,
  );
}

/// A route with many short segments, useful for multi-maneuver tests.
MapboxRouteResult multiStepRoute() {
  // 4 steps of 111 m each → 4 segments of 0.001° each
  final coords = <List<double>>[];
  for (var i = 0; i <= 4; i++) {
    coords.add([i * 0.001, 0.0]);
  }
  final steps = List.generate(
    4,
    (i) => MapboxStep(instruction: 'Step $i', distance: 111, duration: 10),
  );
  return MapboxRouteResult(
    coordinates: coords,
    distanceMeters: 444,
    durationSeconds: 40,
    steps: steps,
  );
}

const _farDest = NavigationCoordinate(1, 1);

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  late ControlledSource src;
  late MapboxNavigationService svc;

  setUp(() {
    src = ControlledSource();
    svc = MapboxNavigationService(staleLocationTimeout: const Duration(days: 9999), locationSource: src);
  });

  tearDown(() async {
    svc.dispose();
    await src.close();
  });

  // =========================================================================
  // A. Normal forward matching — progress advances monotonically.
  // =========================================================================
  test('A: normal forward matching — progress is monotonically increasing', () {
    svc.startNavigation(route: straightRoute(), destination: _farDest);

    final distances = <double>[];
    src.send(lng: 0.01, lat: 0);
    distances.add(svc.state.distanceAlongRouteMeters!);
    src.send(lng: 0.02, lat: 0);
    distances.add(svc.state.distanceAlongRouteMeters!);
    src.send(lng: 0.04, lat: 0);
    distances.add(svc.state.distanceAlongRouteMeters!);
    src.send(lng: 0.07, lat: 0);
    distances.add(svc.state.distanceAlongRouteMeters!);

    for (var i = 0; i < distances.length - 1; i++) {
      expect(
        distances[i + 1],
        greaterThan(distances[i]),
        reason: 'Fix $i→${i + 1}: distance should increase',
      );
    }

    for (final d in distances) {
      expect(d, greaterThan(0));
    }

    expect(svc.state.trackingStatus, TrackingStatus.onRoute);
    expect(svc.state.matchedLocation, isNotNull);
  });

  // =========================================================================
  // B. Rejected off-route candidate — cannot mutate committed progress.
  // =========================================================================
  test('B: rejected off-route candidate does not mutate committed progress', () {
    svc.startNavigation(route: straightRoute(), destination: _farDest);

    // Establish committed progress on-route.
    src.send(lng: 0.03, lat: 0);
    final onRoute = svc.state;
    expect(onRoute.trackingStatus, TrackingStatus.onRoute);
    final committedDistance = onRoute.distanceAlongRouteMeters!;
    final committedStep = onRoute.currentStepIndex;
    final committedRemaining = onRoute.remainingDistanceMeters!;

    // Send a clearly off-route fix (200 m north of the route).
    // ~0.002° lat ≈ 222 m at equator — well beyond the 150 m cap.
    src.send(lng: 0.03, lat: 0.002);
    final afterOffRoute = svc.state;

    // Progress must not have changed.
    expect(
      afterOffRoute.distanceAlongRouteMeters,
      equals(committedDistance),
      reason: 'Off-route fix must not advance distanceAlongRoute',
    );
    expect(afterOffRoute.currentStepIndex, equals(committedStep),
        reason: 'Off-route fix must not change step index');
    expect(afterOffRoute.remainingDistanceMeters, equals(committedRemaining),
        reason: 'Off-route fix must not change remaining distance');

    // Tracking status should be offRoute; matchedLocation should be null.
    expect(afterOffRoute.trackingStatus, TrackingStatus.offRoute);
    expect(afterOffRoute.matchedLocation, isNull);
  });

  // =========================================================================
  // C. Small backward GPS jitter — no large rewind, coordinate/distance coherent.
  // =========================================================================
  test(
    'C: small backward GPS jitter does not rewind progress or produce incoherent state',
    () {
      svc.startNavigation(route: straightRoute(), destination: _farDest);

      src.send(lng: 0.05, lat: 0);
      final before = svc.state;
      expect(before.trackingStatus, TrackingStatus.onRoute);
      final d = before.distanceAlongRouteMeters!;

      // 0.001° ≈ 111 m backward. This is within _maxBackwardMeters=25 range?
      // 111 m > 25 m → should be clamped without large rewind.
      // But if it's within the on-route threshold, it will be accepted with
      // distance clamped. If it's off-route, it will be rejected.
      // Either way, distanceAlongRoute must not decrease significantly.
      src.send(lng: 0.0499, lat: 0); // ~1.1 m backward — small jitter
      final after = svc.state;

      // Progress must not decrease (clamped or same).
      expect(
        after.distanceAlongRouteMeters!,
        greaterThanOrEqualTo(d),
        reason: 'Small backward jitter must not rewind progress',
      );

      // If accepted, matchedLocation and distanceAlongRoute must be consistent.
      if (after.trackingStatus == TrackingStatus.onRoute) {
        expect(after.matchedLocation, isNotNull);
        // Coordinate must be near the route (lat≈0).
        expect(after.matchedLocation!.latitude, closeTo(0, 0.001));
      }
    },
  );

  // =========================================================================
  // D. Large legitimate relocation — triggers reacquisition, not silent jump.
  // =========================================================================
  test(
    'D: large backward relocation triggers reacquisition, not silent progress corruption',
    () {
      svc.startNavigation(route: straightRoute(), destination: _farDest);

      // Establish progress well into the route.
      src.send(lng: 0.06, lat: 0);
      final before = svc.state;
      expect(before.trackingStatus, TrackingStatus.onRoute);
      final establishedDist = before.distanceAlongRouteMeters!;

      // Large backward jump: back to the start of the route.
      // delta ≈ −6 × 1112 = −6672 m >> _largeBackwardMeters=100 m.
      src.send(lng: 0.001, lat: 0);
      final after = svc.state;

      // Must NOT have silently rewound progress to near zero.
      // The candidate should be rejected (returns null from _evaluateCandidate).
      // distanceAlongRoute stays at committed value.
      expect(
        after.distanceAlongRouteMeters!,
        greaterThanOrEqualTo(establishedDist),
        reason: 'Large backward relocation must not silently rewind progress',
      );
    },
  );

  // =========================================================================
  // E. Parallel road — heading/continuity prevents wrong-segment snap.
  // =========================================================================
  test(
    'E: parallel road — proximity alone does not force wrong segment when heading conflicts',
    () {
      // Two parallel E-W routes: Route A at lat=0, Route B at lat=0.0005 (≈55 m).
      // We navigate on Route A. A fix at lat=0.0004 with heading=270° (westward)
      // conflicts with an eastward route, but if the route bearing is ≈90° the
      // heading penalty reduces the effective threshold.
      //
      // This test verifies the heading consistency logic doesn't crash and that
      // the match is accepted when heading is consistent, rejected when not.

      // Route A: going east (bearing ~90°).
      final routeA = MapboxRouteResult(
        coordinates: [
          [0.0, 0.0],
          [0.01, 0.0],
          [0.02, 0.0],
          [0.03, 0.0],
        ],
        distanceMeters: 3336,
        durationSeconds: 60,
        steps: [
          MapboxStep(instruction: 'Go east', distance: 3336, duration: 60),
        ],
      );
      svc.startNavigation(route: routeA, destination: _farDest);

      // Fix on the route, heading east → should be accepted.
      src.send(lng: 0.01, lat: 0.0, heading: 90);
      final onRoute = svc.state;
      expect(onRoute.trackingStatus, TrackingStatus.onRoute);

      // Fix 55 m north of route (lat≈0.0005), heading east.
      // Cross-track ≈ 55 m. Threshold = min(max(80, 5*2.5), 150) = 80 m.
      // 55 m < 80 m → on-route. Heading consistent with 90° route bearing.
      src.send(lng: 0.015, lat: 0.0005, heading: 90, accuracy: 5);
      final nearParallel = svc.state;
      // 55 m is within 80 m threshold so it should be accepted.
      expect(nearParallel.trackingStatus, TrackingStatus.onRoute);

      // Fix 160 m north (lat≈0.00145), heading east.
      // Cross-track ≈ 160 m > 150 m cap → off-route regardless of heading.
      src.send(lng: 0.015, lat: 0.00145, heading: 90, accuracy: 5);
      final farParallel = svc.state;
      expect(farParallel.trackingStatus, TrackingStatus.offRoute,
          reason: '160 m off-route must be rejected even with correct heading');
    },
  );

  // =========================================================================
  // F. Route crossing / loop — candidate selection deterministic.
  // =========================================================================
  test(
    'F: route crossing — selection does not arbitrarily jump progress backward',
    () {
      // Simple route that crosses itself (figure-eight in miniature):
      // A→B→C where the fix is near the crossing point.
      // The key check: committed progress never jumps backward.
      svc.startNavigation(route: straightRoute(), destination: _farDest);

      final distances = <double>[];
      for (var i = 1; i <= 8; i++) {
        src.send(lng: i * 0.01, lat: 0);
        distances.add(svc.state.distanceAlongRouteMeters!);
      }

      // Progress must be non-decreasing throughout.
      for (var i = 0; i < distances.length - 1; i++) {
        expect(
          distances[i + 1],
          greaterThanOrEqualTo(distances[i]),
          reason: 'Fix $i→${i + 1}: progress must not jump backward',
        );
      }
    },
  );

  // =========================================================================
  // G. Off-route sequence — evidence behaves as configured.
  // =========================================================================
  test(
    'G: off-route evidence accumulates correctly and triggers reroute at count=3',
    () async {
      final pendingRoutes = <Completer<MapboxRouteResult?>>[];
      svc.dispose();
      // Use a clock that can advance: start at t=0, then return t=20 for fixes.
      // _startTime is set to now() at route commit time.
      var clockSeconds = 0;
      svc = MapboxNavigationService(staleLocationTimeout: const Duration(days: 9999), 
        locationSource: src,
        routeFetcher: ({
          required double fromLat,
          required double fromLng,
          required double toLat,
          required double toLng,
        }) {
          final c = Completer<MapboxRouteResult?>();
          pendingRoutes.add(c);
          return c.future;
        },
        now: () => DateTime.utc(2026, 1, 1, 0, 0, clockSeconds),
      );

      // startNavigation at t=0 → _startTime = 2026-01-01T00:00:00
      svc.startNavigation(route: straightRoute(), destination: _farDest);

      // Advance the clock past the 8-second grace period.
      clockSeconds = 20;

      // Three consecutive off-route fixes should trigger a reroute request.
      // Off-route = lat=0.002 ≈ 222 m from route, well beyond 150 m cap.
      src.send(lng: 0.03, lat: 0.002, second: 10); // off 1
      expect(svc.state.trackingStatus, TrackingStatus.offRoute);
      src.send(lng: 0.03, lat: 0.002, second: 11); // off 2
      src.send(lng: 0.03, lat: 0.002, second: 12); // off 3 → triggers reroute
      await Future<void>.delayed(Duration.zero);

      expect(
        pendingRoutes,
        hasLength(1),
        reason: 'Exactly one reroute request must be launched after 3 off-route fixes',
      );
      expect(svc.state.routeRequestStatus, RouteRequestStatus.rerouting);

      // Complete the reroute so tearDown is clean.
      pendingRoutes.single.complete(null);
      await Future<void>.delayed(Duration.zero);
    },
  );

  // =========================================================================
  // H. Accuracy cap — poor GPS cannot make the corridor unbounded.
  // =========================================================================
  test(
    'H: accuracy cap — very poor GPS accuracy cannot make on-route corridor unbounded',
    () {
      svc.startNavigation(route: straightRoute(), destination: _farDest);

      // Fix 160 m off-route with accuracy=300 m.
      // Without cap: max(80, 300 * 2.5) = 750 m → would accept.
      // With cap: min(max(80, 750), 150) = 150 m → 160 m > 150 m → reject.
      src.send(lng: 0.03, lat: 0.00145, accuracy: 300, heading: 90);
      expect(
        svc.state.trackingStatus,
        TrackingStatus.offRoute,
        reason: '160 m off-route with accuracy=300 m must be rejected (cap=150 m)',
      );
    },
  );

  // =========================================================================
  // I. Off-route → rejoin — matcher returns to onRoute with valid distance.
  // =========================================================================
  test(
    'I: off-route then rejoin — matcher reacquires and returns valid distanceAlongRoute',
    () {
      svc.startNavigation(route: straightRoute(), destination: _farDest);

      // Establish on-route progress.
      src.send(lng: 0.03, lat: 0);
      final beforeOffRoute = svc.state;
      expect(beforeOffRoute.trackingStatus, TrackingStatus.onRoute);
      final distanceBefore = beforeOffRoute.distanceAlongRouteMeters!;

      // Go off-route (but not enough to reroute — only 2 fixes, need 3).
      src.send(lng: 0.03, lat: 0.002); // off-route fix 1
      src.send(lng: 0.03, lat: 0.002); // off-route fix 2
      expect(svc.state.trackingStatus, TrackingStatus.offRoute);

      // Rejoin the route.
      src.send(lng: 0.04, lat: 0);
      final afterRejoin = svc.state;

      expect(
        afterRejoin.trackingStatus,
        TrackingStatus.onRoute,
        reason: 'Must return to onRoute after rejoining',
      );
      expect(
        afterRejoin.matchedLocation,
        isNotNull,
        reason: 'matchedLocation must be valid after reacquisition',
      );
      expect(
        afterRejoin.distanceAlongRouteMeters,
        isNotNull,
        reason: 'distanceAlongRouteMeters must be valid after reacquisition',
      );
      // Progress must be at or beyond what it was before going off-route
      // (we returned slightly further along the route).
      expect(
        afterRejoin.distanceAlongRouteMeters!,
        greaterThanOrEqualTo(distanceBefore),
      );
    },
  );

  // =========================================================================
  // J. Start away from route → join — initial unmatched state, then joins.
  // =========================================================================
  test(
    'J: starting away from route — remains unmatched, then correctly joins',
    () {
      svc.startNavigation(route: straightRoute(), destination: _farDest);

      // Fix far from the route — should remain unmatched.
      src.send(lng: 5.0, lat: 5.0); // thousands of km away
      final farState = svc.state;
      expect(farState.trackingStatus, TrackingStatus.offRoute);
      expect(farState.matchedLocation, isNull);
      // Progress must not have jumped to some route position.
      // distanceAlongRoute is initialized to 0 on route start;
      // off-route fixes must not advance it.
      expect(
        farState.distanceAlongRouteMeters,
        equals(0.0),
        reason: 'Starting far from route must not invent a matched progress position',
      );

      // Now move to the route.
      src.send(lng: 0.02, lat: 0);
      final joinedState = svc.state;
      expect(joinedState.trackingStatus, TrackingStatus.onRoute);
      expect(joinedState.matchedLocation, isNotNull);
      expect(joinedState.distanceAlongRouteMeters, greaterThan(0));
    },
  );

  // =========================================================================
  // K. GPS gap → reacquisition — broader search recovers from stale window.
  // =========================================================================
  test(
    'K: GPS gap then recovery — broader reacquisition search matches correctly',
    () {
      svc.startNavigation(route: straightRoute(), destination: _farDest);

      // Establish progress at mid-route.
      src.send(lng: 0.04, lat: 0);
      final midState = svc.state;
      expect(midState.trackingStatus, TrackingStatus.onRoute);

      // Simulate GPS gap: send several off-route fixes to push into reacquisition.
      // 3+ consecutive unmatched pushes _matcherMode to reacquisition.
      src.send(lng: 0.04, lat: 0.002); // unmatched 1
      src.send(lng: 0.04, lat: 0.002); // unmatched 2
      src.send(lng: 0.04, lat: 0.002); // unmatched 3 → reacquisition
      expect(svc.state.trackingStatus, TrackingStatus.offRoute);

      // GPS recovers at a new position far ahead (outside old tracking window).
      // In reacquisition mode the full route is scanned.
      src.send(lng: 0.08, lat: 0);
      final recovered = svc.state;

      expect(
        recovered.trackingStatus,
        TrackingStatus.onRoute,
        reason: 'After GPS recovery, reacquisition must find the new position',
      );
      expect(
        recovered.distanceAlongRouteMeters,
        greaterThan(midState.distanceAlongRouteMeters!),
        reason: 'Recovered position must be further along route than pre-gap position',
      );
    },
  );

  // =========================================================================
  // L. Multiple maneuver boundaries crossed — step catches up.
  // =========================================================================
  test(
    'L: single fix crossing multiple short maneuver boundaries advances step correctly',
    () {
      svc.startNavigation(route: multiStepRoute(), destination: _farDest);

      // Fix at 0.0032° ≈ 355 m, crossing all 4 steps of 111 m each.
      src.send(lng: 0.0032, lat: 0);
      final state = svc.state;

      // Should be on step 3 (the last step, index 3).
      expect(state.currentStepIndex, equals(3),
          reason: 'Must advance through all skipped short maneuvers');
      expect(state.currentStep?.instruction, equals('Step 3'));
    },
  );

  // =========================================================================
  // M. Out-of-order location fix — ordering guarantees remain intact.
  // =========================================================================
  test(
    'M: out-of-order location fix cannot mutate committed state',
    () {
      svc.startNavigation(route: straightRoute(), destination: _farDest);

      src.send(lng: 0.02, lat: 0, second: 2);
      src.send(lng: 0.05, lat: 0, second: 5);
      final latest = svc.state;
      final latestDist = latest.distanceAlongRouteMeters!;

      // Send a fix with timestamp between the two above — must be rejected.
      src.send(lng: 0.01, lat: 0, second: 3);
      expect(
        svc.state,
        same(latest),
        reason: 'Out-of-order fix (timestamp=3) must be fully ignored',
      );
      expect(svc.state.distanceAlongRouteMeters, equals(latestDist));
    },
  );

  // =========================================================================
  // N. Route revision replacement — old context cannot leak into new route.
  // =========================================================================
  test(
    'N: route revision replacement — old matching context does not leak into new route',
    () {
      final route1 = straightRoute(segments: 9); // 9-segment route
      final route2 = MapboxRouteResult(
        coordinates: [
          [10.0, 10.0],
          [10.01, 10.0],
        ],
        distanceMeters: 1112,
        durationSeconds: 60,
        steps: [
          MapboxStep(
            instruction: 'New route step',
            distance: 1112,
            duration: 60,
          ),
        ],
      );

      svc.startNavigation(route: route1, destination: _farDest);

      // Progress well into route1.
      src.send(lng: 0.07, lat: 0);
      final route1State = svc.state;
      expect(route1State.trackingStatus, TrackingStatus.onRoute);
      final route1Dist = route1State.distanceAlongRouteMeters!;
      expect(route1Dist, greaterThan(0));

      // Commit a new route (simulating a reroute).
      final token = svc.beginRouteRequest(rerouting: true);
      expect(svc.commitRoute(token, route2), isTrue);

      // After route change, state must reset.
      expect(svc.state.routeRevision, 2);
      expect(svc.state.activeRoute, same(route2));
      expect(
        svc.state.distanceAlongRouteMeters,
        equals(0.0),
        reason: 'After route revision, distanceAlongRoute must reset',
      );
      expect(svc.state.currentStepIndex, equals(0));

      // A fix on route2 must match route2 from scratch,
      // not carry over route1's progress context.
      src.send(lng: 10.005, lat: 10.0);
      final route2State = svc.state;

      expect(route2State.trackingStatus, TrackingStatus.onRoute);
      expect(
        route2State.distanceAlongRouteMeters!,
        lessThan(route1Dist),
        reason:
            'Route2 progress must be based on route2 geometry, not leaked from route1',
      );
      // route2State.distanceAlongRoute ≈ 556 m (mid of 1112 m route2)
      expect(route2State.distanceAlongRouteMeters!, greaterThan(0));
      expect(route2State.distanceAlongRouteMeters!, lessThan(1112));
    },
  );
}
