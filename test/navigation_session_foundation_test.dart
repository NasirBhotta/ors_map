import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:ors_map_test/models/navigation_state.dart';
import 'package:ors_map_test/services/map_box_navigation_service.dart';
import 'package:ors_map_test/services/mapbox_route_service.dart';

const destination = NavigationCoordinate(73.01, 33.01);

class FakeGeolocator extends geo.GeolocatorPlatform {
  final fixes = StreamController<geo.Position>.broadcast(sync: true);

  @override
  Stream<geo.Position> getPositionStream({
    geo.LocationSettings? locationSettings,
  }) => fixes.stream;
}

geo.Position fix({int second = 0}) => geo.Position(
  longitude: 73,
  latitude: 33,
  timestamp: DateTime.utc(2026, 1, 1, 0, 0, second),
  accuracy: 5,
  altitude: 0,
  altitudeAccuracy: 0,
  heading: 0,
  headingAccuracy: 0,
  speed: 0,
  speedAccuracy: 0,
);

MapboxRouteResult route({double distance = 100}) => MapboxRouteResult(
  coordinates: [
    [73, 33],
    [73.01, 33.01],
  ],
  distanceMeters: distance,
  durationSeconds: 30,
  steps: [
    MapboxStep(instruction: 'Continue', distance: distance, duration: 30),
  ],
);

void main() {
  late MapboxNavigationService service;

  setUp(() {
    service = MapboxNavigationService(staleLocationTimeout: const Duration(days: 9999), );
  });

  tearDown(() {
    service.dispose();
  });

  test(
    'actual start and stop retain one observation feed without route progress',
    () async {
      final previous = geo.GeolocatorPlatform.instance;
      final gps = FakeGeolocator();
      geo.GeolocatorPlatform.instance = gps;
      addTearDown(() async {
        geo.GeolocatorPlatform.instance = previous;
        await gps.fixes.close();
      });
      service.startNavigation(
        route: route(),
        destination: const NavigationCoordinate(74, 34),
      );
      expect(gps.fixes.hasListener, isTrue);
      gps.fixes.add(fix());
      await Future<void>.delayed(Duration.zero);
      expect(service.state.rawLocation!.longitude, 73);
      service.stopNavigation();
      final stopped = service.state;
      expect(gps.fixes.hasListener, isTrue);
      gps.fixes.add(fix(second: 1));
      await Future<void>.delayed(Duration.zero);
      expect(service.state, isNot(same(stopped)));
      expect(service.state.status, NavigationStatus.stopped);
      expect(service.state.rawLocation!.longitude, 73);
      expect(service.state.distanceAlongRouteMeters, isNull);
    },
  );

  test('delayed progress callback cannot mutate a newer session', () async {
    final previous = geo.GeolocatorPlatform.instance;
    final gps = FakeGeolocator();
    geo.GeolocatorPlatform.instance = gps;
    addTearDown(() async {
      geo.GeolocatorPlatform.instance = previous;
      service.dispose();
      await gps.fixes.close();
    });
    final entered = Completer<void>();
    final release = Completer<void>();
    var arrivals = 0;
    service.dispose();
    service = MapboxNavigationService(staleLocationTimeout: const Duration(days: 9999), 
      onRouteProgress: (_, _, _, _) {
        entered.complete();
        return release.future;
      },
      onDestinationReached: () => arrivals++,
    );
    service.startNavigation(
      route: route(),
      destination: const NavigationCoordinate(74, 34),
    );
    gps.fixes.add(fix());
    await entered.future;
    service.startNavigation(
      route: route(distance: 200),
      destination: const NavigationCoordinate(74, 34),
    );
    final newer = service.state;
    release.complete();
    await Future<void>.delayed(Duration.zero);
    expect(service.state, same(newer));
    expect(arrivals, 0);
  });

  test('published snapshots defensively own all route collections', () async {
    final coordinates = <List<double>>[
      [73, 33],
      [73.01, 33.01],
    ];
    final maneuver = <double>[73, 33];
    final steps = [
      MapboxStep(
        instruction: 'Continue',
        distance: 100,
        duration: 30,
        maneuverLocation: maneuver,
      ),
    ];
    final input = MapboxRouteResult(
      coordinates: coordinates,
      distanceMeters: 100,
      durationSeconds: 30,
      steps: steps,
    );
    final published = service.states.firstWhere((s) => s.activeRoute != null);
    service.beginSession(destination: destination);
    expect(service.commitRoute(service.beginRouteRequest(), input), isTrue);
    final snapshot = await published;

    coordinates.first[0] = 0;
    coordinates.clear();
    maneuver[0] = 0;
    steps.clear();
    expect(snapshot.activeRoute!.coordinates, [
      [73, 33],
      [73.01, 33.01],
    ]);
    expect(snapshot.currentStep!.maneuverLocation, [73, 33]);
    expect(snapshot.activeRoute!.steps, hasLength(1));
    expect(
      () => snapshot.activeRoute!.coordinates.clear(),
      throwsUnsupportedError,
    );
    expect(
      () => snapshot.activeRoute!.coordinates.first[0] = 0,
      throwsUnsupportedError,
    );
    expect(() => snapshot.activeRoute!.steps.clear(), throwsUnsupportedError);
    expect(
      () => snapshot.currentStep!.maneuverLocation![0] = 0,
      throwsUnsupportedError,
    );

    service.stopNavigation();
    expect(snapshot.status, NavigationStatus.navigating);
    expect(snapshot.activeRoute, same(input));
  });

  test('new session invalidates work even before its first route commits', () {
    service.beginSession(destination: destination);
    final old = service.beginRouteRequest();
    service.beginSession(destination: const NavigationCoordinate(74, 34));
    expect(service.state.sessionId, greaterThan(old.sessionId));
    expect(service.isCurrent(old), isFalse);
    expect(service.commitRoute(old, route()), isFalse);
    expect(service.state.activeRoute, isNull);
    expect(service.state.destination!.longitude, 74);
  });

  test('stop immediately invalidates requests and clears active state', () {
    service.beginSession(destination: destination);
    service.commitRoute(service.beginRouteRequest(), route());
    final pending = service.beginRouteRequest(rerouting: true);
    service.stopNavigation();
    final stopped = service.state;
    expect(service.isCurrent(pending), isFalse);
    expect(service.commitRoute(pending, route(distance: 200)), isFalse);
    expect(service.state, same(stopped));
    expect(stopped.status, NavigationStatus.stopped);
    expect(stopped.activeRoute, isNull);
    expect(stopped.destination, isNull);
    expect(stopped.routeRequestStatus, RouteRequestStatus.idle);
    expect(() => service.beginRouteRequest(), throwsStateError);
  });

  test('late reroute completion after stop cannot commit', () async {
    service.beginSession(destination: destination);
    service.commitRoute(service.beginRouteRequest(), route());
    final pending = service.beginRouteRequest(rerouting: true);
    final response = Completer<MapboxRouteResult>();
    final result = response.future.then((r) => service.commitRoute(pending, r));
    service.stopNavigation();
    response.complete(route(distance: 200));
    expect(await result, isFalse);
    expect(service.state.status, NavigationStatus.stopped);
  });

  test(
    'new request invalidates old request before either response arrives',
    () {
      service.beginSession(destination: destination);
      final first = service.beginRouteRequest();
      final second = service.beginRouteRequest();
      expect(second.routeRequestId, greaterThan(first.routeRequestId));
      expect(service.isCurrent(first), isFalse);
      expect(service.commitRoute(first, route()), isFalse);
      expect(service.isCurrent(second), isTrue);
      expect(service.commitRoute(second, route(distance: 200)), isTrue);
      expect(service.state.activeRoute!.distanceMeters, 200);
    },
  );

  test('responses completing in reverse order preserve newest route', () async {
    service.beginSession(destination: destination);
    final first = service.beginRouteRequest();
    final firstResponse = Completer<MapboxRouteResult>();
    final firstCommit = firstResponse.future.then(
      (r) => service.commitRoute(first, r),
    );
    final second = service.beginRouteRequest();
    final secondResponse = Completer<MapboxRouteResult>();
    final secondCommit = secondResponse.future.then(
      (r) => service.commitRoute(second, r),
    );
    secondResponse.complete(route(distance: 200));
    expect(await secondCommit, isTrue);
    final newest = service.state;
    firstResponse.complete(route(distance: 100));
    expect(await firstCommit, isFalse);
    expect(service.state, same(newest));
  });

  test('each commitment increments revision and consumes its token', () {
    service.beginSession(destination: destination);
    final first = service.beginRouteRequest();
    expect(service.state.routeRevision, 0);
    expect(service.commitRoute(first, route()), isTrue);
    expect(service.state.routeRevision, 1);
    expect(service.isCurrent(first), isFalse);
    expect(service.commitRoute(first, route()), isFalse);
    expect(service.state.routeRevision, 1);
    final second = service.beginRouteRequest(rerouting: true);
    expect(service.state.routeRevision, 1);
    expect(service.commitRoute(second, route(distance: 200)), isTrue);
    expect(service.state.routeRevision, 2);
    service.beginSession(destination: destination);
    service.commitRoute(service.beginRouteRequest(), route());
    expect(service.state.routeRevision, 3);
  });

  test('dispose rejects late commitments and all new work', () async {
    service.beginSession(destination: destination);
    final pending = service.beginRouteRequest();
    final response = Completer<MapboxRouteResult>();
    final commit = response.future.then((r) => service.commitRoute(pending, r));
    final states = <NavigationState>[];
    final done = Completer<void>();
    service.states.listen(states.add, onDone: done.complete);
    service.dispose();
    final disposed = service.state;
    response.complete(route());
    expect(await commit, isFalse);
    expect(service.isCurrent(pending), isFalse);
    expect(
      () => service.beginSession(destination: destination),
      throwsStateError,
    );
    expect(() => service.beginRouteRequest(), throwsStateError);
    service.stopNavigation();
    service.dispose();
    expect(service.state, same(disposed));
    expect(disposed.status, NavigationStatus.disposed);
    await done.future;
    expect(states.last.status, NavigationStatus.disposed);
  });

  test(
    'ownership cannot be used on another service with matching counters',
    () {
      final other = MapboxNavigationService(staleLocationTimeout: const Duration(days: 9999), );
      addTearDown(other.dispose);
      service.beginSession(destination: destination);
      other.beginSession(destination: destination);
      final token = service.beginRouteRequest();
      other.beginRouteRequest();
      expect(other.isCurrent(token), isFalse);
      expect(other.commitRoute(token, route()), isFalse);
    },
  );

  test(
    'route commitment initializes measured fields without inventing a fix',
    () {
      service.beginSession(destination: destination);
      service.commitRoute(service.beginRouteRequest(), route());
      final state = service.state;
      expect(state.currentStepIndex, 0);
      expect(state.currentStep!.instruction, 'Continue');
      expect(state.distanceAlongRouteMeters, 0);
      expect(state.remainingDistanceMeters, 100);
      expect(state.remainingDurationSeconds, 30);
      expect(state.rawLocation, isNull);
      expect(state.matchedLocation, isNull);
      expect(state.trackingStatus, TrackingStatus.unmatched);
      expect(state.locationQuality.freshness, LocationFreshness.unknown);
      expect(state.arrived, isFalse);
    },
  );
}
