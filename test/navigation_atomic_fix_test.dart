import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ors_map_test/models/navigation_state.dart';
import 'package:ors_map_test/services/map_box_navigation_service.dart';
import 'package:ors_map_test/services/mapbox_route_service.dart';
import 'package:ors_map_test/services/navigation_location_source.dart';

class ControlledLocationSource implements NavigationLocationSource {
  final controller = StreamController<NavigationFix>.broadcast(sync: true);

  @override
  Stream<NavigationFix> get fixes => controller.stream;

  void send(
    double longitude,
    int second, {
    double latitude = 0,
    double speed = 5,
    double accuracy = 5,
  }) {
    controller.add(
      NavigationFix(
        longitude: longitude,
        latitude: latitude,
        accuracy: accuracy,
        altitude: 0,
        heading: 90,
        speedMetersPerSecond: speed,
        timestamp: DateTime.utc(2026, 1, 1, 0, 0, second),
      ),
    );
  }
}

const farDestination = NavigationCoordinate(1, 1);

MapboxRouteResult route({
  double distance = 1112,
  double duration = 100,
  String instruction = 'First',
  double endLongitude = 0.01,
}) => MapboxRouteResult(
  coordinates: [
    [0, 0],
    [endLongitude / 2, 0],
    [endLongitude, 0],
  ],
  distanceMeters: distance,
  durationSeconds: duration,
  steps: [
    MapboxStep(
      instruction: instruction,
      distance: distance * 0.4,
      duration: duration / 2,
    ),
    MapboxStep(
      instruction: 'Last $instruction',
      distance: distance * 0.6,
      duration: duration / 2,
    ),
  ],
);

void main() {
  late ControlledLocationSource source;
  late MapboxNavigationService service;

  setUp(() {
    source = ControlledLocationSource();
    service = MapboxNavigationService(staleLocationTimeout: const Duration(days: 9999), locationSource: source);
  });

  tearDown(() async {
    service.dispose();
    await source.controller.close();
  });

  void start(MapboxRouteResult active) {
    service.startNavigation(route: active, destination: farDestination);
  }

  test(
    'one fix commits one coherent route snapshot before callbacks',
    () async {
      final active = route();
      start(active);
      final snapshots = <NavigationState>[];
      final subscription = service.states.listen(snapshots.add);
      source.send(0.002, 1);
      final committed = service.state;
      await Future<void>.delayed(Duration.zero);
      expect(snapshots, hasLength(1));
      expect(snapshots.single, same(committed));
      expect(committed.activeRoute, same(active));
      expect(committed.routeRevision, 1);
      expect(committed.rawLocation!.longitude, 0.002);
      expect(committed.matchedLocation!.longitude, closeTo(0.002, 0.00001));
      expect(committed.distanceAlongRouteMeters, greaterThan(0));
      expect(
        committed.remainingDistanceMeters,
        lessThan(active.distanceMeters),
      );
      expect(
        committed.remainingDurationSeconds,
        lessThan(active.durationSeconds),
      );
      expect(
        committed.currentStep,
        same(active.steps[committed.currentStepIndex!]),
      );
      await subscription.cancel();
    },
  );

  test('rapid fixes commit synchronously in timestamp order', () async {
    final pending = Completer<void>();
    service.dispose();
    service = MapboxNavigationService(staleLocationTimeout: const Duration(days: 9999), 
      locationSource: source,
      onRouteProgress: (_, _, _, _) => pending.future,
    );
    start(route());
    final observed = <NavigationState>[];
    final subscription = service.states.listen(observed.add);
    source.send(0.001, 1);
    final first = service.state;
    source.send(0.003, 2);
    final second = service.state;
    source.send(0.006, 3);
    final third = service.state;
    expect(
      first.distanceAlongRouteMeters!,
      lessThan(second.distanceAlongRouteMeters!),
    );
    expect(
      second.distanceAlongRouteMeters!,
      lessThan(third.distanceAlongRouteMeters!),
    );
    expect(third.rawLocation!.longitude, 0.006);
    await Future<void>.delayed(Duration.zero);
    expect(observed, [same(first), same(second), same(third)]);
    pending.complete();
    await subscription.cancel();
  });

  test('older fixes cannot rewind any measured field', () {
    start(route());
    source.send(0.002, 2);
    source.send(0.006, 4);
    final latest = service.state;
    source.send(0.001, 3);
    expect(service.state, same(latest));
    expect(service.state.rawLocation!.longitude, 0.006);
    expect(service.state.matchedLocation!.longitude, closeTo(0.006, 0.00001));
    expect(service.state.currentStepIndex, latest.currentStepIndex);
    expect(
      service.state.remainingDistanceMeters,
      latest.remainingDistanceMeters,
    );
  });

  test('duplicate timestamps are ignored, including across a route stop', () {
    start(route());
    source.send(0.002, 1);
    final first = service.state;
    source.send(0.007, 1);
    expect(service.state, same(first));
    service.stopNavigation();
    final stopped = service.state;
    source.send(0.008, 1);
    expect(service.state, same(stopped));
  });

  test(
    'a pending progress callback cannot block measured step advancement',
    () async {
      final pending = Completer<void>();
      var stepNotifications = 0;
      service.dispose();
      service = MapboxNavigationService(staleLocationTimeout: const Duration(days: 9999), 
        locationSource: source,
        onRouteProgress: (_, _, _, _) => pending.future,
        onStepChanged: (_, _) => stepNotifications++,
      );
      start(route());
      source.send(0.006, 1);
      expect(service.state.currentStepIndex, 1);
      expect(service.state.currentStep!.instruction, 'Last First');
      await Future<void>.delayed(Duration.zero);
      expect(stepNotifications, 1);
      pending.complete();
      await Future<void>.delayed(Duration.zero);
      expect(service.state.currentStepIndex, 1);
    },
  );

  test(
    'throwing progress and instruction callbacks leave state committed',
    () async {
      service.dispose();
      service = MapboxNavigationService(staleLocationTimeout: const Duration(days: 9999), 
        locationSource: source,
        onRouteProgress: (_, _, _, _) => throw StateError('UI failed'),
        onStepChanged: (_, _) => throw StateError('instruction failed'),
      );
      start(route());
      source.send(0.006, 1);
      final committed = service.state;
      expect(committed.currentStepIndex, 1);
      expect(committed.distanceAlongRouteMeters, greaterThan(0));
      await Future<void>.delayed(Duration.zero);
      source.send(0.007, 2);
      await Future<void>.delayed(Duration.zero);
      expect(service.state.rawLocation!.longitude, 0.007);
      expect(service.state.routeRevision, committed.routeRevision);
    },
  );

  test(
    'replacement publishes geometry, metrics, and steps as one revision',
    () async {
      final first = route();
      final second = route(
        distance: 4000,
        duration: 800,
        instruction: 'Replacement',
        endLongitude: 0.02,
      );
      start(first);
      source.send(0.002, 1);
      final snapshots = <NavigationState>[];
      final subscription = service.states.listen(snapshots.add);
      final ownership = service.beginRouteRequest(rerouting: true);
      expect(service.commitRoute(ownership, second), isTrue);
      final replacement = service.state;
      source.send(0.008, 2);
      final progressed = service.state;
      await Future<void>.delayed(Duration.zero);
      expect(replacement.routeRevision, 2);
      expect(replacement.activeRoute, same(second));
      expect(replacement.currentStep, same(second.steps.first));
      expect(replacement.distanceAlongRouteMeters, 0);
      expect(replacement.remainingDistanceMeters, 4000);
      expect(replacement.remainingDurationSeconds, 800);
      expect(progressed.routeRevision, 2);
      expect(progressed.activeRoute, same(second));
      expect(progressed.remainingDurationSeconds, lessThan(800));
      for (final snapshot in snapshots) {
        if (snapshot.activeRoute == second) {
          expect(snapshot.routeRevision, 2);
          expect(snapshot.currentStep, isIn(second.steps));
          expect(snapshot.remainingDistanceMeters, lessThanOrEqualTo(4000));
        }
      }
      await subscription.cancel();
    },
  );

  test(
    'stopping in the first notification suppresses later side effects',
    () async {
      var progressNotifications = 0;
      var stepNotifications = 0;
      service.dispose();
      service = MapboxNavigationService(staleLocationTimeout: const Duration(days: 9999), 
        locationSource: source,
        onLocationUpdate: (_, _, _, _, _) {
          expect(service.state.currentStepIndex, 1);
          service.stopNavigation();
        },
        onRouteProgress: (_, _, _, _) async => progressNotifications++,
        onStepChanged: (_, _) => stepNotifications++,
      );
      start(route());
      source.send(0.006, 1);
      await Future<void>.delayed(Duration.zero);
      expect(service.state.status, NavigationStatus.stopped);
      expect(progressNotifications, 0);
      expect(stepNotifications, 0);
    },
  );

  test('a state listener can stop before any fix callback runs', () async {
    var locationNotifications = 0;
    var progressNotifications = 0;
    service.dispose();
    service = MapboxNavigationService(staleLocationTimeout: const Duration(days: 9999), 
      locationSource: source,
      onLocationUpdate: (_, _, _, _, _) => locationNotifications++,
      onRouteProgress: (_, _, _, _) async => progressNotifications++,
    );
    start(route());
    final subscription = service.states.listen((snapshot) {
      if (snapshot.status == NavigationStatus.navigating &&
          snapshot.rawLocation != null) {
        service.stopNavigation();
      }
    });
    source.send(0.002, 1);
    expect(service.state.distanceAlongRouteMeters, greaterThan(0));
    await Future<void>.delayed(Duration.zero);
    expect(service.state.status, NavigationStatus.stopped);
    expect(locationNotifications, 0);
    expect(progressNotifications, 0);
    await subscription.cancel();
  });

  test('asynchronous callback failure cannot roll back progress', () async {
    service.dispose();
    service = MapboxNavigationService(staleLocationTimeout: const Duration(days: 9999), 
      locationSource: source,
      onRouteProgress: (_, _, _, _) async {
        await Future<void>.delayed(Duration.zero);
        throw StateError('delayed UI failure');
      },
    );
    start(route());
    source.send(0.002, 1);
    final committed = service.state;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(service.state, same(committed));
    source.send(0.004, 2);
    expect(
      service.state.distanceAlongRouteMeters,
      greaterThan(committed.distanceAlongRouteMeters!),
    );
  });

  test('session replacement during calculation rejects the old fix', () {
    service.dispose();
    service = MapboxNavigationService(staleLocationTimeout: const Duration(days: 9999), 
      locationSource: source,
      compassHeadingProvider: () {
        service.beginSession(destination: const NavigationCoordinate(2, 2));
        return 90;
      },
    );
    start(route());
    source.send(0.002, 1, latitude: 0.01, speed: 0);
    expect(service.state.status, NavigationStatus.starting);
    expect(service.state.destination!.longitude, 2);
    expect(service.state.activeRoute, isNull);
    expect(service.state.rawLocation, isNull);
  });

  test(
    'arrival is committed once before a failing arrival notification',
    () async {
      var observedCommittedArrival = false;
      service.dispose();
      service = MapboxNavigationService(staleLocationTimeout: const Duration(days: 9999), 
        locationSource: source,
        onDestinationReached: () {
          observedCommittedArrival = service.state.arrived;
          throw StateError('arrival UI failed');
        },
      );
      service.startNavigation(
        route: route(),
        destination: const NavigationCoordinate(0, 0),
      );
      final snapshots = <NavigationState>[];
      final subscription = service.states.listen(snapshots.add);
      source.send(0, 1);
      expect(service.state.status, NavigationStatus.arrived);
      expect(service.state.arrived, isTrue);
      expect(service.state.activeRoute, isNotNull);
      await Future<void>.delayed(Duration.zero);
      expect(snapshots, hasLength(1));
      expect(observedCommittedArrival, isTrue);
      source.send(0.002, 2);
      expect(service.state.status, NavigationStatus.arrived);
      expect(service.state.trackingStatus, TrackingStatus.unmatched);
      expect(service.state.matchedLocation, isNull);
      await subscription.cancel();
    },
  );

  test('unusable fix preserves snapshot and a later valid fix still works', () {
    start(route());
    source.send(0.002, 1);
    final valid = service.state;
    source.send(double.nan, 2);
    source.send(0.003, 2, accuracy: double.infinity);
    expect(service.state, same(valid));
    source.send(0.004, 3);
    expect(service.state.rawLocation!.longitude, 0.004);
    expect(
      service.state.distanceAlongRouteMeters,
      greaterThan(valid.distanceAlongRouteMeters!),
    );
  });

  test('a fix crossing several short maneuvers commits the final step', () {
    final active = MapboxRouteResult(
      coordinates: [
        [0, 0],
        [0.001, 0],
        [0.002, 0],
        [0.003, 0],
        [0.004, 0],
      ],
      distanceMeters: 444,
      durationSeconds: 40,
      steps: List.generate(
        4,
        (index) =>
            MapboxStep(instruction: 'Step $index', distance: 111, duration: 10),
      ),
    );
    start(active);
    source.send(0.0032, 1);
    expect(service.state.currentStepIndex, 3);
    expect(service.state.currentStep!.instruction, 'Step 3');
    expect(service.state.activeRoute, same(active));
  });
}
