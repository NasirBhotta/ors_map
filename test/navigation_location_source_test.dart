import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ors_map_test/models/navigation_state.dart';
import 'package:ors_map_test/services/map_box_navigation_service.dart';
import 'package:ors_map_test/services/mapbox_route_service.dart';
import 'package:ors_map_test/services/navigation_location_source.dart';

class FakeLocationSource implements NavigationLocationSource {
  int subscriptions = 0;
  int cancellations = 0;
  late final StreamController<NavigationFix> controller =
      StreamController<NavigationFix>.broadcast(
        sync: true,
        onListen: () => subscriptions++,
        onCancel: () => cancellations++,
      );

  @override
  Stream<NavigationFix> get fixes => controller.stream;

  void add({double longitude = 73}) => controller.add(
    NavigationFix(
      latitude: 33,
      longitude: longitude,
      accuracy: 5,
      altitude: 100,
      heading: 90,
      speedMetersPerSecond: 4,
      timestamp: DateTime.utc(2026),
    ),
  );

  Future<void> close() => controller.close();
}

MapboxRouteResult testRoute() => MapboxRouteResult(
  coordinates: [
    [73, 33],
    [73.01, 33.01],
  ],
  distanceMeters: 1500,
  durationSeconds: 180,
  steps: [MapboxStep(instruction: 'Continue', distance: 1500, duration: 180)],
);

void main() {
  late FakeLocationSource source;
  late MapboxNavigationService service;
  const destination = NavigationCoordinate(74, 34);

  setUp(() {
    source = FakeLocationSource();
    service = MapboxNavigationService(staleLocationTimeout: const Duration(days: 9999), locationSource: source);
  });

  tearDown(() async {
    service.dispose();
    await source.close();
  });

  test(
    'repeated attachment, including style reload equivalent, subscribes once',
    () {
      service.attachLocationSource();
      service.attachLocationSource();
      service.attachLocationSource();
      expect(source.subscriptions, 1);
      expect(source.controller.hasListener, isTrue);
    },
  );

  test('a pre-navigation fix updates raw state only', () {
    var navigationCallbacks = 0;
    service.dispose();
    service = MapboxNavigationService(staleLocationTimeout: const Duration(days: 9999), 
      locationSource: source,
      onLocationUpdate: (_, _, _, _, _) => navigationCallbacks++,
    );
    service.attachLocationSource();
    source.add();
    final state = service.state;
    expect(state.status, NavigationStatus.idle);
    expect(state.rawLocation!.longitude, 73);
    expect(state.rawLocation!.latitude, 33);
    expect(state.locationQuality.accuracyMeters, 5);
    expect(state.locationQuality.timestamp, DateTime.utc(2026));
    expect(state.speedMetersPerSecond, 4);
    expect(state.activeRoute, isNull);
    expect(state.distanceAlongRouteMeters, isNull);
    expect(state.remainingDistanceMeters, isNull);
    expect(state.matchedLocation, isNull);
    expect(navigationCallbacks, 0);
  });

  test('starting navigation after observation does not resubscribe', () {
    service.attachLocationSource();
    source.add();
    service.startNavigation(route: testRoute(), destination: destination);
    service.attachLocationSource();
    expect(source.subscriptions, 1);
    expect(service.state.rawLocation!.longitude, 73);
    expect(service.state.status, NavigationStatus.navigating);
  });

  test(
    'start without explicit attach opens one source and repeated start reuses it',
    () {
      service.startNavigation(route: testRoute(), destination: destination);
      service.startNavigation(route: testRoute(), destination: destination);
      expect(source.subscriptions, 1);
    },
  );

  test(
    'stop and restart retain one feed and observation continues between routes',
    () {
      service.attachLocationSource();
      service.startNavigation(route: testRoute(), destination: destination);
      service.stopNavigation();
      expect(source.cancellations, 0);
      source.add(longitude: 73.2);
      expect(service.state.rawLocation!.longitude, 73.2);
      expect(service.state.status, NavigationStatus.stopped);
      expect(service.state.distanceAlongRouteMeters, isNull);
      service.startNavigation(route: testRoute(), destination: destination);
      expect(source.subscriptions, 1);
      expect(service.state.rawLocation!.longitude, 73.2);
    },
  );

  test(
    'one fix reaches one service source and one observation snapshot',
    () async {
      service.attachLocationSource();
      final observed = <NavigationState>[];
      final sub = service.states.listen(observed.add);
      source.add();
      await Future<void>.delayed(Duration.zero);
      expect(source.subscriptions, 1);
      expect(observed, hasLength(1));
      expect(observed.single.rawLocation!.longitude, 73);
      await sub.cancel();
    },
  );

  test('dispose cancels source and rejects late fixes or reattachment', () {
    service.attachLocationSource();
    service.dispose();
    final disposed = service.state;
    expect(source.cancellations, 1);
    expect(source.controller.hasListener, isFalse);
    source.add(longitude: 75);
    service.attachLocationSource();
    expect(service.state, same(disposed));
    expect(source.subscriptions, 1);
  });

  test(
    'stream errors do not corrupt the session and later fixes still work',
    () {
      service.attachLocationSource();
      service.beginSession(destination: destination);
      final sessionId = service.state.sessionId;
      source.controller.addError(StateError('GPS unavailable'));
      expect(service.state.sessionId, sessionId);
      expect(service.state.status, NavigationStatus.starting);
      source.add();
      expect(service.state.rawLocation!.longitude, 73);
      expect(service.state.sessionId, sessionId);
    },
  );

  test('source completion is safe and retains the last observation', () async {
    service.attachLocationSource();
    source.add();
    final before = service.state;
    await source.close();
    expect(service.state, same(before));
    expect(source.controller.hasListener, isFalse);
    service.stopNavigation();
    expect(service.state.rawLocation!.longitude, 73);
    expect(service.state.status, NavigationStatus.stopped);
  });
}
