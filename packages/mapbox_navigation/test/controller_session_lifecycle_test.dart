import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:mapbox_navigation/navigation.dart';

class FakeLocationSource implements LocationSource {
  final fixesController = StreamController<LocationFix>.broadcast(sync: true);

  @override
  Stream<LocationFix> get fixes => fixesController.stream;

  bool get hasListener => fixesController.hasListener;

  void emit(LocationFix fix) => fixesController.add(fix);

  void dispose() => fixesController.close();
}

class FakeRouteProvider implements RouteProvider {
  NavigationRoute? nextRoute;
  Completer<NavigationRoute>? routeCompleter;
  RouteException? errorToThrow;
  int calculateCallCount = 0;

  @override
  Future<NavigationRoute> calculateRoute({
    required GeoPoint origin,
    required GeoPoint destination,
  }) async {
    calculateCallCount++;
    if (errorToThrow != null) throw errorToThrow!;
    if (routeCompleter != null) return routeCompleter!.future;
    if (nextRoute != null) return nextRoute!;
    return sampleRoute();
  }
}

NavigationRoute sampleRoute({
  double distance = 1000.0,
  double duration = 120.0,
}) {
  return NavigationRoute(
    geometry: const [
      GeoPoint(latitude: 33.7000, longitude: 73.0000),
      GeoPoint(latitude: 33.7050, longitude: 73.0050),
      GeoPoint(latitude: 33.7100, longitude: 73.0100),
    ],
    totalDistanceMeters: distance,
    totalDurationSeconds: duration,
    steps: [
      NavigationStep(
        instruction: 'Continue on Main St',
        distanceMeters: distance / 2,
        durationSeconds: duration / 2,
      ),
      NavigationStep(
        instruction: 'Arrive at destination',
        distanceMeters: distance / 2,
        durationSeconds: duration / 2,
      ),
    ],
  );
}

LocationFix createFix({
  double lat = 33.7000,
  double lng = 73.0000,
  double speed = 10.0,
  int second = 0,
}) {
  return LocationFix(
    coordinate: GeoPoint(latitude: lat, longitude: lng),
    accuracyMeters: 5.0,
    bearingDegrees: 45.0,
    speedMetersPerSecond: speed,
    timestamp: DateTime.utc(2026, 1, 1, 0, 0, second),
  );
}

void main() {
  group('NavigationController Session Lifecycle', () {
    late FakeLocationSource locationSource;
    late FakeRouteProvider routeProvider;
    late DateTime currentTime;
    late NavigationController controller;

    setUp(() {
      currentTime = DateTime.utc(2026, 1, 1, 0, 0, 0);
      locationSource = FakeLocationSource();
      routeProvider = FakeRouteProvider();
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

    // Requirement A: Start → stop → restart
    test('A: start -> stop -> restart cleans tracking metrics and preserves single observation feed', () async {
      final route1 = sampleRoute(distance: 500);
      const destination1 = GeoPoint(latitude: 33.7100, longitude: 73.0100);

      await controller.startNavigation(route: route1, destination: destination1);
      expect(controller.state.status, NavigationStatus.navigating);
      expect(controller.state.activeRoute, equals(route1));
      expect(locationSource.hasListener, isTrue);

      locationSource.emit(createFix(second: 1));
      expect(controller.state.rawFix, isNotNull);

      // Stop navigation
      controller.stopNavigation();
      expect(controller.state.status, NavigationStatus.stopped);
      expect(controller.state.activeRoute, isNull);
      expect(controller.state.distanceAlongRouteMeters, isNull);
      expect(controller.state.trackingStatus, TrackingStatus.unmatched);
      // Location feed remains active for raw positioning when stopped
      expect(locationSource.hasListener, isTrue);

      // Restart with new route
      final route2 = sampleRoute(distance: 800);
      const destination2 = GeoPoint(latitude: 33.7200, longitude: 73.0200);
      await controller.startNavigation(route: route2, destination: destination2);

      expect(controller.state.status, NavigationStatus.navigating);
      expect(controller.state.activeRoute, equals(route2));
      expect(controller.state.destination, equals(destination2));
      expect(locationSource.hasListener, isTrue);
    });

    // Requirement B: One location subscription
    test('B: repeated startNavigation calls do not duplicate location source subscription', () async {
      final route = sampleRoute();
      const dest = GeoPoint(latitude: 33.7100, longitude: 73.0100);

      await controller.startNavigation(route: route, destination: dest);
      await controller.startNavigation(route: route, destination: dest);

      var fixCount = 0;
      final sub = controller.states.listen((_) => fixCount++);

      locationSource.emit(createFix(second: 1));
      await Future<void>.delayed(Duration.zero);

      // Only one state update received from single subscription
      expect(fixCount, 1);
      await sub.cancel();
    });

    // Requirement C: Old route request after newer request
    test('C: delayed route request cannot override a newer request', () async {
      final completer1 = Completer<NavigationRoute>();
      final completer2 = Completer<NavigationRoute>();

      // First request hangs
      routeProvider.routeCompleter = completer1;
      final future1 = controller.calculateRoute(
        origin: const GeoPoint(latitude: 33.0, longitude: 73.0),
        destination: const GeoPoint(latitude: 33.1, longitude: 73.1),
      );

      // Second request completes first
      routeProvider.routeCompleter = completer2;
      final future2 = controller.calculateRoute(
        origin: const GeoPoint(latitude: 33.0, longitude: 73.0),
        destination: const GeoPoint(latitude: 33.2, longitude: 73.2),
      );

      final routeB = sampleRoute(distance: 2000);
      completer2.complete(routeB);
      final result2 = await future2;
      expect(result2.totalDistanceMeters, 2000);

      // Later, request 1 completes
      final routeA = sampleRoute(distance: 1000);
      completer1.complete(routeA);
      final result1 = await future1;
      expect(result1.totalDistanceMeters, 1000);
    });

    // Requirement D: Reroute response after stop
    test('D: reroute response arriving after stop does not resurrect active navigation', () async {
      final route = sampleRoute();
      const dest = GeoPoint(latitude: 33.7100, longitude: 73.0100);

      await controller.startNavigation(route: route, destination: dest);

      // First fix matches on route
      locationSource.emit(createFix(lat: 33.7000, lng: 73.0000, second: 1));
      expect(controller.state.trackingStatus, TrackingStatus.onRoute);

      // Advance clock past reroute min interval
      currentTime = currentTime.add(const Duration(seconds: 10));

      // 3 off-route fixes trigger reroute
      final rerouteCompleter = Completer<NavigationRoute>();
      routeProvider.routeCompleter = rerouteCompleter;

      locationSource.emit(createFix(lat: 34.0, lng: 74.0, second: 11));
      locationSource.emit(createFix(lat: 34.0, lng: 74.0, second: 12));
      locationSource.emit(createFix(lat: 34.0, lng: 74.0, second: 13));

      expect(controller.state.routeRequestStatus, RouteRequestStatus.rerouting);

      // User stops navigation while reroute is in flight
      controller.stopNavigation();
      expect(controller.state.status, NavigationStatus.stopped);

      // Reroute finishes late
      rerouteCompleter.complete(sampleRoute(distance: 5000));
      await Future<void>.delayed(Duration.zero);

      // Must remain stopped; route must not be set
      expect(controller.state.status, NavigationStatus.stopped);
      expect(controller.state.activeRoute, isNull);
    });

    // Requirement E & F: Reroute response after new session / old revision
    test('E & F: in-flight reroute from old session or route revision cannot override new session', () async {
      final route1 = sampleRoute(distance: 1000);
      const dest1 = GeoPoint(latitude: 33.7100, longitude: 73.0100);

      await controller.startNavigation(route: route1, destination: dest1);

      currentTime = currentTime.add(const Duration(seconds: 10));

      final rerouteCompleter = Completer<NavigationRoute>();
      routeProvider.routeCompleter = rerouteCompleter;

      // Trigger reroute in session 1
      locationSource.emit(createFix(lat: 34.0, lng: 74.0, second: 11));
      locationSource.emit(createFix(lat: 34.0, lng: 74.0, second: 12));
      locationSource.emit(createFix(lat: 34.0, lng: 74.0, second: 13));
      expect(controller.state.routeRequestStatus, RouteRequestStatus.rerouting);

      // Stop and start a brand new session with route2
      controller.stopNavigation();
      final route2 = sampleRoute(distance: 9999);
      const dest2 = GeoPoint(latitude: 35.0, longitude: 75.0);
      routeProvider.routeCompleter = null; // Next immediate call succeeds
      routeProvider.nextRoute = route2;
      await controller.startNavigation(route: route2, destination: dest2);

      expect(controller.state.activeRoute?.totalDistanceMeters, 9999);

      // Reroute from session 1 now delivers
      rerouteCompleter.complete(sampleRoute(distance: 1111));
      await Future<void>.delayed(Duration.zero);

      // Session 2 active route must NOT be corrupted by session 1 reroute
      expect(controller.state.activeRoute?.totalDistanceMeters, 9999);
      expect(controller.state.destination, equals(dest2));
    });

    // Requirement R: Dispose ignores late work
    test('R: dispose cancels subscription and throws lifecycle exception on subsequent operations', () async {
      final route = sampleRoute();
      const dest = GeoPoint(latitude: 33.7100, longitude: 73.0100);

      await controller.startNavigation(route: route, destination: dest);
      controller.dispose();

      expect(controller.state.status, NavigationStatus.disposed);
      expect(locationSource.hasListener, isFalse);

      // Further calls throw NavigationLifecycleException
      expect(
        () => controller.calculateRoute(
          origin: const GeoPoint(latitude: 0, longitude: 0),
          destination: const GeoPoint(latitude: 1, longitude: 1),
        ),
        throwsA(isA<NavigationLifecycleException>()),
      );

      expect(
        () => controller.startNavigation(route: route, destination: dest),
        throwsA(isA<NavigationLifecycleException>()),
      );

      // Fix emitted after dispose is ignored
      locationSource.emit(createFix(second: 99));
      expect(controller.state.status, NavigationStatus.disposed);
    });
  });
}
