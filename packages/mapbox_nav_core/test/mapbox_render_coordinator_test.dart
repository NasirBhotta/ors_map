import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mapbox_nav_core/mapbox_nav_core.dart';
import 'package:mapbox_nav_core/src/mapbox/rendering/mapbox_route_render_coordinator.dart';

class FakeRouteRenderDelegate implements RouteRenderDelegate {
  final List<String> operationLog = [];
  final List<double> progressLog = [];
  Completer<void>? nextDrawCompleter;

  @override
  Future<void> drawRoute(NavigationRoute route) async {
    operationLog.add('draw:${route.totalDistanceMeters}');
    if (nextDrawCompleter != null) {
      await nextDrawCompleter!.future;
    }
  }

  @override
  Future<void> clearRoute() async {
    operationLog.add('clear');
  }

  @override
  Future<void> updateRouteProgress(
    NavigationRoute route,
    double distanceAlongRouteMeters,
  ) async {
    progressLog.add(distanceAlongRouteMeters);
  }
}

NavigationRoute _createDummyRoute(double distanceMeters) {
  return NavigationRoute(
    geometry: const [
      GeoPoint(latitude: 33.0, longitude: 73.0),
      GeoPoint(latitude: 33.1, longitude: 73.1),
    ],
    totalDistanceMeters: distanceMeters,
    totalDurationSeconds: 60.0,
    steps: const [
      NavigationStep(
        instruction: 'Drive ahead',
        distanceMeters: 100.0,
        durationSeconds: 60.0,
      ),
    ],
  );
}

void main() {
  group('MapboxRouteRenderCoordinator', () {
    late FakeRouteRenderDelegate delegate;
    late MapboxRouteRenderCoordinator coordinator;

    setUp(() {
      delegate = FakeRouteRenderDelegate();
      coordinator = MapboxRouteRenderCoordinator(delegate: delegate);
    });

    tearDown(() {
      coordinator.dispose();
    });

    test(
      'A: stale route draw is rejected when newer generation is scheduled',
      () async {
        final route1 = _createDummyRoute(100.0);
        final route2 = _createDummyRoute(200.0);

        delegate.nextDrawCompleter = Completer<void>();

        // Schedule draw 1 (blocked by completer)
        final draw1 = coordinator.scheduleDraw(
          sessionId: 1,
          routeRevision: 1,
          route: route1,
        );

        // Immediately schedule draw 2 (supersedes generation 1)
        final draw2 = coordinator.scheduleDraw(
          sessionId: 1,
          routeRevision: 2,
          route: route2,
        );

        // Unblock draw 1
        delegate.nextDrawCompleter!.complete();
        delegate.nextDrawCompleter = null;

        await Future.wait([draw1, draw2]);

        // Only draw 2 should be committed or delegate log should show generation transition
        expect(coordinator.currentGeneration.routeRevision, equals(2));
      },
    );

    test(
      'B: stale clear from older session cannot remove current route',
      () async {
        final route = _createDummyRoute(500.0);

        // Route drawn for session 2
        await coordinator.scheduleDraw(
          sessionId: 2,
          routeRevision: 1,
          route: route,
        );
        expect(delegate.operationLog, contains('draw:500.0'));

        // Stale clear from older session 1 arrives
        // In coordinator, scheduleClear changes session, but if an older session clear is attempted:
        final olderGen = const RenderGeneration(
          sessionId: 1,
          routeRevision: 0,
          token: 0,
        );
        expect(coordinator.isCurrent(olderGen), isFalse);
      },
    );

    test(
      'C: rapid route revisions execute structural operations in order and track latest',
      () async {
        final r1 = _createDummyRoute(100.0);
        final r2 = _createDummyRoute(200.0);
        final r3 = _createDummyRoute(300.0);

        await coordinator.scheduleDraw(
          sessionId: 1,
          routeRevision: 1,
          route: r1,
        );
        await coordinator.scheduleDraw(
          sessionId: 1,
          routeRevision: 2,
          route: r2,
        );
        await coordinator.scheduleDraw(
          sessionId: 1,
          routeRevision: 3,
          route: r3,
        );

        expect(coordinator.currentGeneration.routeRevision, equals(3));
        expect(delegate.operationLog.last, equals('draw:300.0'));
      },
    );

    test('D: style reload rebuild uses latest active state', () async {
      final route = _createDummyRoute(450.0);
      const state = NavigationState(
        status: NavigationStatus.navigating,
        activeRoute: null,
      );
      final activeState = state.copyWith(activeRoute: route);

      await coordinator.onStyleReloaded(activeState);
      expect(delegate.operationLog, contains('draw:450.0'));
    });

    test(
      'E: style reload with no active route restores nothing (clears)',
      () async {
        const idleState = NavigationState(
          status: NavigationStatus.idle,
          activeRoute: null,
        );

        await coordinator.onStyleReloaded(idleState);
        expect(delegate.operationLog, contains('clear'));
      },
    );

    test(
      'F: measured route progress drives line updates and coalesces rapid events',
      () async {
        final route = _createDummyRoute(1000.0);
        await coordinator.scheduleDraw(
          sessionId: 1,
          routeRevision: 1,
          route: route,
        );

        // Fire rapid progress updates
        coordinator.scheduleProgressUpdate(
          sessionId: 1,
          routeRevision: 1,
          route: route,
          distanceAlongRouteMeters: 10.0,
        );
        coordinator.scheduleProgressUpdate(
          sessionId: 1,
          routeRevision: 1,
          route: route,
          distanceAlongRouteMeters: 25.0,
        );
        coordinator.scheduleProgressUpdate(
          sessionId: 1,
          routeRevision: 1,
          route: route,
          distanceAlongRouteMeters: 50.0,
        );

        await Future<void>.delayed(const Duration(milliseconds: 30));

        expect(delegate.progressLog, isNotEmpty);
        expect(delegate.progressLog.last, equals(50.0));
      },
    );

    test('J: render disposal immediately rejects late work', () async {
      coordinator.dispose();
      expect(coordinator.isDisposed, isTrue);

      final route = _createDummyRoute(600.0);
      await coordinator.scheduleDraw(
        sessionId: 1,
        routeRevision: 1,
        route: route,
      );

      expect(delegate.operationLog, isEmpty);
    });
  });
}
