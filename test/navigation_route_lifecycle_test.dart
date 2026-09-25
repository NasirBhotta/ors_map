import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ors_map_test/models/navigation_state.dart';
import 'package:ors_map_test/services/map_box_navigation_service.dart';
import 'package:ors_map_test/services/mapbox_route_service.dart';
import 'package:ors_map_test/services/navigation_location_source.dart';

const origin = NavigationCoordinate(73, 33);
const destinationA = NavigationCoordinate(73.01, 33.01);
const destinationB = NavigationCoordinate(73.02, 33.02);

MapboxRouteResult route(double distance) => MapboxRouteResult(
  coordinates: [
    [73, 33],
    [73.01, 33.01],
  ],
  distanceMeters: distance,
  durationSeconds: 90,
  steps: [
    MapboxStep(instruction: 'Continue', distance: distance, duration: 90),
  ],
);

class PendingRoutes {
  final calls = <Completer<MapboxRouteResult?>>[];

  Future<MapboxRouteResult?> fetch({
    required double fromLng,
    required double fromLat,
    required double toLng,
    required double toLat,
  }) {
    final call = Completer<MapboxRouteResult?>();
    calls.add(call);
    return call.future;
  }
}

class Fixes implements NavigationLocationSource {
  final controller = StreamController<NavigationFix>.broadcast(sync: true);
  @override
  Stream<NavigationFix> get fixes => controller.stream;

  void offRoute(int second) => controller.add(
    NavigationFix(
      latitude: 34,
      longitude: 74,
      accuracy: 5,
      altitude: 0,
      heading: 0,
      speedMetersPerSecond: 5,
      timestamp: DateTime.utc(2026, 1, 1, 0, 0, second),
    ),
  );
}

Future<void> flush() async {
  await Future<void>.delayed(Duration.zero);
}

void main() {
  late PendingRoutes provider;
  late Fixes fixes;
  late MapboxNavigationService service;
  var clock = DateTime.utc(2026, 1, 1);
  var routeChanges = 0;

  setUp(() {
    provider = PendingRoutes();
    fixes = Fixes();
    clock = DateTime.utc(2026, 1, 1);
    routeChanges = 0;
    service = MapboxNavigationService(staleLocationTimeout: const Duration(days: 9999), 
      routeFetcher: provider.fetch,
      locationSource: fixes,
      now: () => clock,
      onRouteChanged: (_, _) async {
        routeChanges++;
      },
    );
  });

  tearDown(() async {
    service.dispose();
    await fixes.controller.close();
  });

  Future<void> triggerReroute() async {
    service.startNavigation(route: route(100), destination: destinationA);
    clock = clock.add(const Duration(seconds: 9));
    fixes.offRoute(1);
    fixes.offRoute(2);
    fixes.offRoute(3);
    await flush();
    expect(provider.calls, hasLength(1));
    expect(service.state.routeRequestStatus, RouteRequestStatus.rerouting);
  }

  test(
    'latest destination request wins and obsolete draw token is rejected',
    () async {
      final first = service.requestPreviewRoute(
        origin: origin,
        destination: destinationA,
      );
      final second = service.requestPreviewRoute(
        origin: origin,
        destination: destinationB,
      );
      provider.calls[1].complete(route(200));
      final secondToken = await second;
      expect(secondToken, isNotNull);
      var draws = 0;
      if (service.isCurrent(secondToken!)) draws++;
      provider.calls[0].complete(route(100));
      final firstToken = await first;
      if (firstToken != null && service.isCurrent(firstToken)) draws++;
      expect(firstToken, isNull);
      expect(draws, 1);
      expect(service.state.destination!.longitude, destinationB.longitude);
      expect(service.state.activeRoute!.distanceMeters, 200);
      expect(service.state.routeRevision, 1);
      expect(service.state.status, NavigationStatus.preview);
    },
  );

  test(
    'reroute completing after stop cannot restore route or emit change',
    () async {
      await triggerReroute();
      service.stopNavigation();
      final stopped = service.state;
      provider.calls.single.complete(route(200));
      await flush();
      expect(service.state, same(stopped));
      expect(service.state.activeRoute, isNull);
      expect(routeChanges, 0);
    },
  );

  test('reroute completing after a new session cannot affect it', () async {
    await triggerReroute();
    service.startNavigation(route: route(300), destination: destinationB);
    final newer = service.state;
    provider.calls.single.complete(route(200));
    await flush();
    expect(service.state, same(newer));
    expect(service.state.activeRoute!.distanceMeters, 300);
    expect(routeChanges, 0);
  });

  test('reroute from an obsolete route revision cannot replace it', () async {
    await triggerReroute();
    final replacement = service.beginRouteRequest();
    expect(service.commitRoute(replacement, route(300)), isTrue);
    final newer = service.state;
    provider.calls.single.complete(route(200));
    await flush();
    expect(service.state, same(newer));
    expect(service.state.activeRoute!.distanceMeters, 300);
    expect(routeChanges, 0);
  });

  test('off-route fixes while rerouting launch only one request', () async {
    await triggerReroute();
    fixes.offRoute(4);
    fixes.offRoute(5);
    fixes.offRoute(6);
    await flush();
    expect(provider.calls, hasLength(1));
    provider.calls.single.complete(route(200));
    await flush();
    expect(routeChanges, 1);
    expect(service.state.activeRoute!.distanceMeters, 200);
  });

  test(
    'failed reroute preserves the active route and measured context',
    () async {
      await triggerReroute();
      final previous = service.state.activeRoute;
      final revision = service.state.routeRevision;
      provider.calls.single.complete(null);
      await flush();
      expect(service.state.activeRoute, same(previous));
      expect(service.state.routeRevision, revision);
      expect(service.state.routeRequestStatus, RouteRequestStatus.failed);
      expect(service.state.status, NavigationStatus.navigating);
      expect(routeChanges, 0);
    },
  );

  test('timeout cannot partially replace route state', () async {
    service.dispose();
    service = MapboxNavigationService(staleLocationTimeout: const Duration(days: 9999), 
      routeFetcher: provider.fetch,
      locationSource: fixes,
      routeRequestTimeout: const Duration(milliseconds: 5),
      now: () => clock,
    );
    service.startNavigation(route: route(100), destination: destinationA);
    clock = clock.add(const Duration(seconds: 9));
    fixes.offRoute(1);
    fixes.offRoute(2);
    fixes.offRoute(3);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(service.state.routeRequestStatus, RouteRequestStatus.failed);
    expect(service.state.activeRoute!.distanceMeters, 100);
    expect(service.state.routeRevision, 1);
    provider.calls.single.complete(route(200));
    await flush();
    expect(service.state.activeRoute!.distanceMeters, 100);
  });

  test(
    'dispose rejects late initial route response and emits no callback',
    () async {
      final pending = service.requestNavigationRoute(
        origin: origin,
        destination: destinationA,
      );
      service.dispose();
      final disposed = service.state;
      provider.calls.single.complete(route(200));
      expect(await pending, isNull);
      expect(service.state, same(disposed));
      expect(routeChanges, 0);
    },
  );

  test(
    'route replacement publishes matching route, metrics, and first step',
    () async {
      service.startNavigation(route: route(100), destination: destinationA);
      final emitted = <NavigationState>[];
      final subscription = service.states.listen(emitted.add);
      final token = service.beginRouteRequest(rerouting: true);
      expect(service.commitRoute(token, route(250)), isTrue);
      await flush();
      final committed = emitted.last;
      expect(committed.activeRoute!.distanceMeters, 250);
      expect(committed.remainingDistanceMeters, 250);
      expect(committed.remainingDurationSeconds, 90);
      expect(committed.currentStepIndex, 0);
      expect(committed.currentStep, same(committed.activeRoute!.steps.first));
      expect(committed.routeRequestStatus, RouteRequestStatus.idle);
      expect(committed.routeRevision, 2);
      await subscription.cancel();
    },
  );
}
