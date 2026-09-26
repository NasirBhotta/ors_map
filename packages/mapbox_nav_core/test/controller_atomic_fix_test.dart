import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:mapbox_nav_core/navigation.dart';

class TestLocationSource implements LocationSource {
  final _ctrl = StreamController<LocationFix>.broadcast(sync: true);
  @override
  Stream<LocationFix> get fixes => _ctrl.stream;
  void emit(LocationFix fix) => _ctrl.add(fix);
  void dispose() => _ctrl.close();
}

class TestRouteProvider implements RouteProvider {
  @override
  Future<NavigationRoute> calculateRoute({
    required GeoPoint origin,
    required GeoPoint destination,
  }) async {
    return NavigationRoute(
      geometry: [origin, destination],
      totalDistanceMeters: 500,
      totalDurationSeconds: 60,
      steps: const [],
    );
  }
}

NavigationRoute multiStepRoute() {
  return NavigationRoute(
    geometry: const [
      GeoPoint(latitude: 33.7000, longitude: 73.0000), // start
      GeoPoint(latitude: 33.7010, longitude: 73.0010), // step 1 end (~140m)
      GeoPoint(latitude: 33.7020, longitude: 73.0020), // step 2 end (~280m)
      GeoPoint(latitude: 33.7030, longitude: 73.0030), // step 3 end (~420m)
      GeoPoint(latitude: 33.7040, longitude: 73.0040), // final dest (~560m)
    ],
    totalDistanceMeters: 560.0,
    totalDurationSeconds: 120.0,
    steps: const [
      NavigationStep(
        instruction: 'Step 1: Continue',
        distanceMeters: 140.0,
        durationSeconds: 30.0,
      ),
      NavigationStep(
        instruction: 'Step 2: Turn slightly right',
        distanceMeters: 140.0,
        durationSeconds: 30.0,
      ),
      NavigationStep(
        instruction: 'Step 3: Continue straight',
        distanceMeters: 140.0,
        durationSeconds: 30.0,
      ),
      NavigationStep(
        instruction: 'Step 4: Arrive at destination',
        distanceMeters: 140.0,
        durationSeconds: 30.0,
      ),
    ],
  );
}

LocationFix makeFix({
  required double lat,
  required double lng,
  required int second,
  double accuracy = 5.0,
  double speed = 10.0,
}) {
  return LocationFix(
    coordinate: GeoPoint(latitude: lat, longitude: lng),
    accuracyMeters: accuracy,
    bearingDegrees: 45.0,
    speedMetersPerSecond: speed,
    timestamp: DateTime.utc(2026, 1, 1, 0, 0, second),
  );
}

void main() {
  group('NavigationController Atomic Fix Processing', () {
    late TestLocationSource locationSource;
    late TestRouteProvider routeProvider;
    late DateTime currentTime;
    late NavigationController controller;

    setUp(() {
      currentTime = DateTime.utc(2026, 1, 1, 0, 0, 0);
      locationSource = TestLocationSource();
      routeProvider = TestRouteProvider();
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

    // Requirement G: Rapid fixes processed consistently (atomic commit)
    test('G: rapid fixes commit all state fields together atomically', () async {
      final route = multiStepRoute();
      const dest = GeoPoint(latitude: 33.7040, longitude: 73.0040);
      await controller.startNavigation(route: route, destination: dest);

      final publishedStates = <NavigationState>[];
      final sub = controller.states.listen(publishedStates.add);

      for (var i = 1; i <= 5; i++) {
        currentTime = DateTime.utc(2026, 1, 1, 0, 0, i);
        locationSource.emit(
          makeFix(
            lat: 33.7000 + i * 0.0005,
            lng: 73.0000 + i * 0.0005,
            second: i,
          ),
        );
      }
      await Future<void>.delayed(Duration.zero);

      expect(publishedStates.length, 5);

      for (final st in publishedStates) {
        // In every state snapshot, matchedPoint, speed, distanceAlongRoute, and trackingStatus are consistent
        expect(st.status, NavigationStatus.navigating);
        expect(st.trackingStatus, TrackingStatus.onRoute);
        expect(st.matchedPoint, isNotNull);
        expect(st.distanceAlongRouteMeters, isNotNull);
        expect(st.remainingDistanceMeters, isNotNull);
        expect(st.remainingDurationSeconds, isNotNull);
        expect(st.rawFix, isNotNull);
      }

      await sub.cancel();
    });

    // Requirement H: Out-of-order fixes rejected safely
    test(
      'H: out-of-order or duplicate timestamp fix is rejected without mutating state',
      () async {
        final route = multiStepRoute();
        const dest = GeoPoint(latitude: 33.7040, longitude: 73.0040);
        await controller.startNavigation(route: route, destination: dest);

        currentTime = DateTime.utc(2026, 1, 1, 0, 0, 10);
        locationSource.emit(makeFix(lat: 33.7010, lng: 73.0010, second: 10));

        final stateAt10 = controller.state;
        expect(stateAt10.distanceAlongRouteMeters, isNotNull);

        // Now deliver an older fix (timestamp second: 5)
        locationSource.emit(makeFix(lat: 33.7000, lng: 73.0000, second: 5));
        expect(controller.state, equals(stateAt10));

        // Deliver duplicate timestamp fix (timestamp second: 10)
        locationSource.emit(makeFix(lat: 33.7005, lng: 73.0005, second: 10));
        expect(controller.state, equals(stateAt10));
      },
    );

    // Requirement P: Multiple maneuver boundaries crossed in a single fix
    test(
      'P: large progress jump cleanly advances across multiple maneuver boundaries',
      () async {
        final route = multiStepRoute();
        const dest = GeoPoint(latitude: 33.7040, longitude: 73.0040);
        await controller.startNavigation(route: route, destination: dest);

        final events = <NavigationEvent>[];
        final eventSub = controller.events.listen(events.add);

        // Fix 1 starts on step 0
        currentTime = DateTime.utc(2026, 1, 1, 0, 0, 1);
        locationSource.emit(makeFix(lat: 33.7001, lng: 73.0001, second: 1));
        expect(controller.state.currentStepIndex, 0);

        // Next fix jumps directly to near end of step 2 (~350m along route)
        currentTime = DateTime.utc(2026, 1, 1, 0, 0, 5);
        locationSource.emit(makeFix(lat: 33.7025, lng: 73.0025, second: 5));

        // Current step cleanly caught up across multiple boundaries
        expect(controller.state.currentStepIndex, 3);

        // Event stream emitted instruction updates
        expect(events.whereType<InstructionChangedEvent>().isNotEmpty, isTrue);

        await eventSub.cancel();
      },
    );

    // Requirement Q: Arrival requires valid fresh measured state
    test(
      'Q: destination reached triggers arrived status and event only when within arrival threshold',
      () async {
        final route = multiStepRoute();
        const dest = GeoPoint(latitude: 33.7040, longitude: 73.0040);
        await controller.startNavigation(route: route, destination: dest);

        final events = <NavigationEvent>[];
        final eventSub = controller.events.listen(events.add);

        // Fix halfway along route (~150m from dest) does not arrive
        currentTime = DateTime.utc(2026, 1, 1, 0, 0, 1);
        locationSource.emit(makeFix(lat: 33.7020, lng: 73.0020, second: 1));
        expect(controller.state.isArrived, isFalse);
        expect(controller.state.status, NavigationStatus.navigating);

        // Fix within 10 meters of destination commits arrival
        currentTime = DateTime.utc(2026, 1, 1, 0, 0, 2);
        locationSource.emit(makeFix(lat: 33.70405, lng: 73.00405, second: 2));

        expect(controller.state.isArrived, isTrue);
        expect(controller.state.status, NavigationStatus.arrived);
        expect(events.whereType<DestinationReachedEvent>().length, 1);

        await eventSub.cancel();
      },
    );
  });
}
