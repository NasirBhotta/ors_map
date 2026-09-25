// navigation_screen_render_lifecycle_test.dart
//
// Tests A–J for Mapbox route rendering lifecycle, generation safety,
// structural operation serialization, style reload recovery, and authoritative
// progress line updates.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ors_map_test/models/navigation_state.dart';
import 'package:ors_map_test/services/mapbox_route_render_coordinator.dart';
import 'package:ors_map_test/services/mapbox_route_service.dart';

class MockRouteRenderDelegate implements RouteRenderDelegate {
  final List<String> callLog = [];
  final List<MapboxRouteResult> drawnRoutes = [];
  final List<double> progressDistances = [];

  Completer<void>? drawCompleter;
  Completer<void>? clearCompleter;
  Completer<void>? progressCompleter;

  bool shouldThrowOnDraw = false;

  @override
  Future<void> drawRoute(MapboxRouteResult route) async {
    callLog.add('drawRoute:${route.distanceMeters}');
    if (shouldThrowOnDraw) {
      throw StateError('Simulated Mapbox draw failure');
    }
    drawnRoutes.add(route);
    if (drawCompleter != null) {
      await drawCompleter!.future;
    }
  }

  @override
  Future<void> clearRoute() async {
    callLog.add('clearRoute');
    if (clearCompleter != null) {
      await clearCompleter!.future;
    }
  }

  @override
  Future<void> updateRouteProgress(
    MapboxRouteResult route,
    double distanceAlongRouteMeters,
  ) async {
    callLog.add('updateRouteProgress:$distanceAlongRouteMeters');
    progressDistances.add(distanceAlongRouteMeters);
    if (progressCompleter != null) {
      await progressCompleter!.future;
    }
  }
}

MapboxRouteResult sampleRoute(double distance) {
  return MapboxRouteResult(
    coordinates: [
      [0.0, 0.0],
      [0.01, 0.01],
    ],
    distanceMeters: distance,
    durationSeconds: 100,
    steps: [
      MapboxStep(instruction: 'Go', distance: distance, duration: 100),
    ],
  );
}

void main() {
  late MockRouteRenderDelegate delegate;
  late MapboxRouteRenderCoordinator coordinator;
  final errors = <Object>[];

  setUp(() {
    delegate = MockRouteRenderDelegate();
    errors.clear();
    coordinator = MapboxRouteRenderCoordinator(
      delegate: delegate,
      onError: (err) => errors.add(err),
    );
  });

  tearDown(() {
    coordinator.dispose();
  });

  // =========================================================================
  // A. Old draw after new route
  // =========================================================================
  test('A: old draw after new route cannot replace new route', () async {
    final route1 = sampleRoute(100);
    final route2 = sampleRoute(200);

    // Make drawRoute hang for revision 1
    delegate.drawCompleter = Completer<void>();

    // Start drawing revision 1
    final draw1Future = coordinator.scheduleDraw(
      sessionId: 1,
      routeRevision: 1,
      route: route1,
    );

    // Before revision 1 completes, schedule revision 2
    final draw2Future = coordinator.scheduleDraw(
      sessionId: 1,
      routeRevision: 2,
      route: route2,
    );

    // Let revision 1 finish its underlying draw
    delegate.drawCompleter!.complete();
    await draw1Future;
    await draw2Future;

    // Both draw calls executed in sequence, but revision 2 was drawn last
    expect(delegate.drawnRoutes.last.distanceMeters, 200);
    expect(coordinator.currentGeneration.routeRevision, 2);
  });

  // =========================================================================
  // B. Old clear after new route
  // =========================================================================
  test('B: old clear after new route cannot remove new route', () async {
    final routeNew = sampleRoute(500);

    // Make clearRoute hang
    delegate.clearCompleter = Completer<void>();

    // Start old session clear
    final clearFuture = coordinator.scheduleClear(1);

    // Immediately start new session and schedule draw
    final drawFuture = coordinator.scheduleDraw(
      sessionId: 2,
      routeRevision: 1,
      route: routeNew,
    );

    // Let clear finish
    delegate.clearCompleter!.complete();
    await clearFuture;
    await drawFuture;

    // The final call in the log must be the draw, NOT the clear
    expect(delegate.callLog.last, startsWith('drawRoute'));
    expect(delegate.drawnRoutes.last.distanceMeters, 500);
  });

  // =========================================================================
  // C. Stop while draw pending
  // =========================================================================
  test('C: stop while draw pending does not resurrect stopped route', () async {
    final route = sampleRoute(300);

    delegate.drawCompleter = Completer<void>();

    final drawFuture = coordinator.scheduleDraw(
      sessionId: 1,
      routeRevision: 1,
      route: route,
    );

    // Stop navigation while draw is in flight
    final clearFuture = coordinator.scheduleClear(1);

    // Let draw complete
    delegate.drawCompleter!.complete();
    await drawFuture;
    await clearFuture;

    // Final operation must be clearRoute
    expect(delegate.callLog.last, 'clearRoute');
  });

  // =========================================================================
  // D. Style reload with active route
  // =========================================================================
  test('D: style reload with active route rebuilds latest authoritative route', () async {
    final route = sampleRoute(400);

    final activeState = NavigationState(
      sessionId: 1,
      status: NavigationStatus.navigating,
      routeRevision: 3,
      activeRoute: route,
    );

    await coordinator.onStyleReloaded(activeState);

    expect(delegate.drawnRoutes.last.distanceMeters, 400);
    expect(coordinator.currentGeneration.routeRevision, 3);
  });

  // =========================================================================
  // E. Style reload with no route
  // =========================================================================
  test('E: style reload with no route clears and does not restore obsolete route', () async {
    final stoppedState = const NavigationState(
      sessionId: 1,
      status: NavigationStatus.stopped,
      routeRevision: 0,
      activeRoute: null,
    );

    await coordinator.onStyleReloaded(stoppedState);

    expect(delegate.callLog.last, 'clearRoute');
    expect(delegate.drawnRoutes, isEmpty);
  });

  // =========================================================================
  // F. Progress rendering source
  // =========================================================================
  test('F: progress rendering consumes authoritative distance and coalesces', () async {
    final route = sampleRoute(1000);

    await coordinator.scheduleDraw(
      sessionId: 1,
      routeRevision: 1,
      route: route,
    );

    // Make progress call hang so we can test coalescing
    delegate.progressCompleter = Completer<void>();

    coordinator.scheduleProgressUpdate(
      sessionId: 1,
      routeRevision: 1,
      route: route,
      distanceAlongRouteMeters: 50.0,
    );

    // Intermediate rapid updates while first is in-flight
    coordinator.scheduleProgressUpdate(
      sessionId: 1,
      routeRevision: 1,
      route: route,
      distanceAlongRouteMeters: 60.0,
    );
    coordinator.scheduleProgressUpdate(
      sessionId: 1,
      routeRevision: 1,
      route: route,
      distanceAlongRouteMeters: 75.0,
    );

    // Release first progress call
    delegate.progressCompleter!.complete();
    await Future<void>.delayed(Duration.zero);

    // After coalescing, 50.0 was processed first, and the last update 75.0 was processed
    expect(delegate.progressDistances.contains(50.0), isTrue);
    expect(delegate.progressDistances.last, 75.0);
  });

  // =========================================================================
  // G. Dispose during render
  // =========================================================================
  test('G: dispose during render rejects late native mutations', () async {
    final route = sampleRoute(200);

    delegate.drawCompleter = Completer<void>();

    final drawFuture = coordinator.scheduleDraw(
      sessionId: 1,
      routeRevision: 1,
      route: route,
    );
    await Future<void>.delayed(Duration.zero); // let draw enter delegate
    expect(delegate.drawnRoutes.length, 1);

    // Dispose coordinator while draw is in flight
    coordinator.dispose();

    delegate.drawCompleter!.complete();
    await drawFuture;

    // After dispose, new requests are rejected
    await coordinator.scheduleDraw(
      sessionId: 2,
      routeRevision: 1,
      route: route,
    );

    expect(delegate.drawnRoutes.length, 1); // No new route was drawn after dispose
  });

  // =========================================================================
  // H. Route replacement ordering
  // =========================================================================
  test('H: structural operations execute deterministically in FIFO order', () async {
    final r1 = sampleRoute(100);
    final r2 = sampleRoute(200);

    await coordinator.scheduleDraw(sessionId: 1, routeRevision: 1, route: r1);
    await coordinator.scheduleClear(1);
    await coordinator.scheduleDraw(sessionId: 2, routeRevision: 1, route: r2);

    expect(delegate.callLog, [
      'drawRoute:100.0',
      'clearRoute',
      'drawRoute:200.0',
    ]);
  });

  // =========================================================================
  // I. Rapid route revisions
  // =========================================================================
  test('I: rapid route revisions keep only the latest revision eligible', () async {
    final r1 = sampleRoute(10);
    final r2 = sampleRoute(20);
    final r3 = sampleRoute(30);

    await Future.wait([
      coordinator.scheduleDraw(sessionId: 1, routeRevision: 1, route: r1),
      coordinator.scheduleDraw(sessionId: 1, routeRevision: 2, route: r2),
      coordinator.scheduleDraw(sessionId: 1, routeRevision: 3, route: r3),
    ]);

    expect(coordinator.currentGeneration.routeRevision, 3);
    expect(delegate.drawnRoutes.last.distanceMeters, 30);
  });

  // =========================================================================
  // J. Rendering failure does not corrupt NavigationState
  // =========================================================================
  test('J: rendering failure is captured without crashing', () async {
    final route = sampleRoute(500);
    delegate.shouldThrowOnDraw = true;

    await coordinator.scheduleDraw(
      sessionId: 1,
      routeRevision: 1,
      route: route,
    );

    expect(errors, hasLength(1));
    expect(errors.first, isA<StateError>());
  });
}
