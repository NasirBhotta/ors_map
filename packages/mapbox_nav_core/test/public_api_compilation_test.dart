import 'dart:async';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:mapbox_nav_core/mapbox_nav_core.dart';

/// Consumer-side implementation of [RouteProvider] using purely public API types.
class ConsumerMockRouteProvider implements RouteProvider {
  final NavigationRoute cannedRoute;

  ConsumerMockRouteProvider(this.cannedRoute);

  @override
  Future<NavigationRoute> calculateRoute({
    required GeoPoint origin,
    required GeoPoint destination,
  }) async {
    return cannedRoute;
  }
}

/// Consumer-side implementation of [LocationSource] using purely public API types.
class ConsumerMockLocationSource implements LocationSource {
  final StreamController<LocationFix> _controller =
      StreamController<LocationFix>.broadcast();

  @override
  Stream<LocationFix> get fixes => _controller.stream;

  void emitFix(LocationFix fix) {
    _controller.add(fix);
  }

  void close() {
    _controller.close();
  }
}

void main() {
  group('Public API Consumer Integration Test', () {
    test(
      'full consumer lifecycle works using exclusively public exports',
      () async {
        // 1. Prepare route and location contracts
        const origin = GeoPoint(latitude: 33.5651, longitude: 73.0169);
        const destination = GeoPoint(latitude: 33.5700, longitude: 73.0200);

        final route = NavigationRoute(
          geometry: const [origin, destination],
          totalDistanceMeters: 600.0,
          totalDurationSeconds: 60.0,
          steps: const [
            NavigationStep(
              instruction: 'Head northeast on Main St',
              distanceMeters: 600.0,
              durationSeconds: 60.0,
            ),
          ],
        );

        final routeProvider = ConsumerMockRouteProvider(route);
        final locationSource = ConsumerMockLocationSource();

        // 2. Controller creation with custom config
        final controller = NavigationController(
          routeProvider: routeProvider,
          locationSource: locationSource,
          config: const NavigationConfig(
            arrival: ArrivalConfig(destinationRadiusMeters: 25.0),
            rerouting: ReroutingConfig(autoRerouteEnabled: false),
          ),
        );

        expect(controller.state.status, NavigationStatus.idle);
        expect(controller.state.status == NavigationStatus.navigating, isFalse);

        // 3. State & Event subscriptions
        final receivedStates = <NavigationState>[];
        final receivedEvents = <NavigationEvent>[];

        final stateSub = controller.states.listen(receivedStates.add);
        final eventSub = controller.events.listen(receivedEvents.add);

        // 4. Route calculation
        final calculatedRoute = await controller.calculateRoute(
          origin: origin,
          destination: destination,
        );
        expect(calculatedRoute.totalDistanceMeters, 600.0);
        expect(controller.state.activeRoute, isNull);

        // 5. Start navigation
        await controller.startNavigation(
          route: calculatedRoute,
          destination: destination,
        );
        expect(controller.state.activeRoute, route);
        expect(controller.state.status, NavigationStatus.navigating);

        // 6. Ingest location fixes and observe state updates
        final fix = LocationFix(
          coordinate: origin,
          accuracyMeters: 4.0,
          bearingDegrees: 45.0,
          speedMetersPerSecond: 10.0,
          timestamp: DateTime.now(),
        );
        locationSource.emitFix(fix);

        // Wait a microtask for stream processing
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(controller.state.rawFix, isNotNull);
        expect(controller.state.speedMps, 10.0);
        expect(controller.state.matchedPoint, isNotNull);
        expect(controller.state.locationQuality.isFresh, isTrue);

        // 7. Instantiate public Mapbox presentation widget
        final mapView = NavigationMapView(
          controller: controller,
          accessToken: 'dummy_pk_for_testing',
          vehicle: const VehicleAppearance.model3D(
            modelUri: 'asset://assets/lowpoly_car.glb',
            scale: 0.05,
            bearingOffset: 180.0,
          ),
          routeTheme: const MapboxRouteTheme(
            routeColor: Color(0xFF1E88E5),
            routeWidth: 9.0,
            casingColor: Color(0xFF0D47A1),
            casingWidth: 14.0,
          ),
          initialCenter: origin,
          initialZoom: 18.0,
        );
        expect(mapView.initialZoom, 18.0);
        expect(mapView.vehicle.scale, 0.05);

        // 8. Stop navigation
        controller.stopNavigation();
        expect(controller.state.status, NavigationStatus.stopped);

        // 9. Disposal
        await stateSub.cancel();
        await eventSub.cancel();
        locationSource.close();
        controller.dispose();

        expect(
          () => controller.startNavigation(
            route: route,
            destination: destination,
          ),
          throwsA(isA<NavigationLifecycleException>()),
        );
      },
    );
  });
}
