import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart' as geolocator;
import 'package:mapbox_nav_core/mapbox_nav_core.dart';
import 'package:mapbox_nav_core/src/mapbox/animation/navigation_vehicle_animator.dart';
import 'package:mapbox_nav_core/src/mapbox/rendering/mapbox_route_render_coordinator.dart';

// Test mock route provider
class _MockRouteProvider implements RouteProvider {
  NavigationRoute? nextRoute;
  Object? nextError;

  @override
  Future<NavigationRoute> calculateRoute({
    required GeoPoint origin,
    required GeoPoint destination,
  }) async {
    if (nextError != null) {
      throw nextError!;
    }
    return nextRoute ??
        NavigationRoute(
          geometry: [origin, destination],
          totalDistanceMeters: 1000.0,
          totalDurationSeconds: 120.0,
          steps: [
            const NavigationStep(
              instruction: 'Drive straight',
              distanceMeters: 1000.0,
              durationSeconds: 120.0,
            ),
          ],
        );
  }
}

// Test mock location source
class _MockLocationSource implements LocationSource {
  final _controller = StreamController<LocationFix>.broadcast();

  @override
  Stream<LocationFix> get fixes => _controller.stream;

  void emitFix(LocationFix fix) => _controller.add(fix);
  void emitError(Object error) => _controller.addError(error);

  void dispose() => _controller.close();
}

// Test mock render delegate
class _MockRenderDelegate implements RouteRenderDelegate {
  int drawCount = 0;
  int clearCount = 0;
  int progressCount = 0;
  double? lastProgress;

  @override
  Future<void> drawRoute(NavigationRoute route) async {
    drawCount++;
  }

  @override
  Future<void> clearRoute() async {
    clearCount++;
  }

  @override
  Future<void> updateRouteProgress(
    NavigationRoute route,
    double distanceAlongRouteMeters,
  ) async {
    progressCount++;
    lastProgress = distanceAlongRouteMeters;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Platform Normalization (GeolocatorLocationSource)', () {
    test('normalizes iOS negative speed (-1.0) to 0.0 m/s', () {
      final pos = geolocator.Position(
        longitude: 73.0,
        latitude: 33.0,
        timestamp: DateTime.utc(2026, 1, 1),
        accuracy: 5.0,
        altitude: 500.0,
        heading: 90.0,
        speed: -1.0, // iOS sentinel for invalid/unavailable speed
        speedAccuracy: 0.0,
        altitudeAccuracy: 0.0,
        headingAccuracy: 0.0,
      );

      final fix = GeolocatorLocationSource.normalizePosition(pos);
      expect(fix.speedMetersPerSecond, 0.0);
    });

    test('normalizes iOS negative heading (-1.0) to 0.0 degrees', () {
      final pos = geolocator.Position(
        longitude: 73.0,
        latitude: 33.0,
        timestamp: DateTime.utc(2026, 1, 1),
        accuracy: 5.0,
        altitude: 500.0,
        heading: -1.0, // iOS sentinel for invalid/unavailable course
        speed: 10.0,
        speedAccuracy: 0.0,
        altitudeAccuracy: 0.0,
        headingAccuracy: 0.0,
      );

      final fix = GeolocatorLocationSource.normalizePosition(pos);
      expect(fix.bearingDegrees, 0.0);
    });

    test(
      'normalizes iOS invalid accuracy (-1.0) to high uncertainty (100.0m) rather than 1.0m',
      () {
        final pos = geolocator.Position(
          longitude: 73.0,
          latitude: 33.0,
          timestamp: DateTime.utc(2026, 1, 1),
          accuracy: -1.0, // iOS sentinel for invalid accuracy
          altitude: 500.0,
          heading: 90.0,
          speed: 10.0,
          speedAccuracy: 0.0,
          altitudeAccuracy: 0.0,
          headingAccuracy: 0.0,
        );

        final fix = GeolocatorLocationSource.normalizePosition(pos);
        expect(fix.accuracyMeters, 100.0);
      },
    );

    test('wraps positive heading values to [0.0, 360.0)', () {
      final pos = geolocator.Position(
        longitude: 73.0,
        latitude: 33.0,
        timestamp: DateTime.utc(2026, 1, 1),
        accuracy: 5.0,
        altitude: 500.0,
        heading: 450.0,
        speed: 10.0,
        speedAccuracy: 0.0,
        altitudeAccuracy: 0.0,
        headingAccuracy: 0.0,
      );

      final fix = GeolocatorLocationSource.normalizePosition(pos);
      expect(fix.bearingDegrees, 90.0);
    });

    test('converts timestamp to UTC', () {
      final localTime = DateTime(2026, 5, 10, 15, 30);
      final pos = geolocator.Position(
        longitude: 73.0,
        latitude: 33.0,
        timestamp: localTime,
        accuracy: 5.0,
        altitude: 500.0,
        heading: 0.0,
        speed: 0.0,
        speedAccuracy: 0.0,
        altitudeAccuracy: 0.0,
        headingAccuracy: 0.0,
      );

      final fix = GeolocatorLocationSource.normalizePosition(pos);
      expect(fix.timestamp.isUtc, isTrue);
      expect(fix.timestamp, localTime.toUtc());
    });
  });

  group('Location Interruptions & Error Resilience', () {
    late _MockRouteProvider routeProvider;
    late _MockLocationSource locationSource;
    late NavigationController controller;

    setUp(() {
      routeProvider = _MockRouteProvider();
      locationSource = _MockLocationSource();
      controller = NavigationController(
        routeProvider: routeProvider,
        locationSource: locationSource,
      );
    });

    tearDown(() {
      controller.dispose();
      locationSource.dispose();
    });

    test(
      'GPS service disabled or permission error emits NavigationErrorEvent without corrupting route',
      () async {
        final route = await controller.calculateRoute(
          origin: const GeoPoint(latitude: 33.0, longitude: 73.0),
          destination: const GeoPoint(latitude: 33.01, longitude: 73.01),
        );

        await controller.startNavigation(
          route: route,
          destination: const GeoPoint(latitude: 33.01, longitude: 73.01),
        );

        expect(controller.state.status, NavigationStatus.navigating);
        expect(controller.state.activeRoute, isNotNull);

        final errorEvents = <NavigationErrorEvent>[];
        final sub = controller.events.listen((e) {
          if (e is NavigationErrorEvent) errorEvents.add(e);
        });

        // Emit service disabled error on stream
        locationSource.emitError(
          const LocationUnavailableException(
            'Location services are disabled',
            reason: LocationErrorReason.serviceDisabled,
          ),
        );

        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(errorEvents, hasLength(1));
        expect(errorEvents.first.error, isA<LocationUnavailableException>());
        expect(
          (errorEvents.first.error as LocationUnavailableException).reason,
          LocationErrorReason.serviceDisabled,
        );

        // Route and session must remain valid!
        expect(controller.state.status, NavigationStatus.navigating);
        expect(controller.state.activeRoute, equals(route));
        expect(controller.state.isArrived, isFalse);

        await sub.cancel();
      },
    );

    test(
      'recovers smoothly when valid GPS fix arrives after location error',
      () async {
        final route = await controller.calculateRoute(
          origin: const GeoPoint(latitude: 33.0, longitude: 73.0),
          destination: const GeoPoint(latitude: 33.01, longitude: 73.01),
        );

        await controller.startNavigation(
          route: route,
          destination: const GeoPoint(latitude: 33.01, longitude: 73.01),
        );

        // Send error
        locationSource.emitError(
          const LocationUnavailableException(
            'GPS interrupted',
            reason: LocationErrorReason.serviceDisabled,
          ),
        );

        await Future<void>.delayed(const Duration(milliseconds: 10));

        // Now send valid fix
        locationSource.emitFix(
          LocationFix(
            coordinate: const GeoPoint(latitude: 33.001, longitude: 73.001),
            accuracyMeters: 5.0,
            bearingDegrees: 45.0,
            speedMetersPerSecond: 12.0,
            timestamp: DateTime.now().toUtc(),
          ),
        );

        await Future<void>.delayed(const Duration(milliseconds: 10));

        expect(controller.state.status, NavigationStatus.navigating);
        expect(controller.state.rawFix?.coordinate.latitude, 33.001);
        expect(controller.state.speedMps, 12.0);
      },
    );
  });

  group('Lifecycle & Wall-Clock Freshness Evaluation', () {
    test(
      'evaluateFreshness immediately marks fix stale after pause without waiting for periodic timer',
      () async {
        var simulatedTime = DateTime.utc(2026, 1, 1, 12, 0, 0);
        final routeProvider = _MockRouteProvider();
        final locationSource = _MockLocationSource();

        final controller = NavigationController(
          routeProvider: routeProvider,
          locationSource: locationSource,
          config: const NavigationConfig(
            freshness: FreshnessConfig(staleTimeout: Duration(seconds: 4)),
          ),
          clock: () => simulatedTime,
        );

        final route = await controller.calculateRoute(
          origin: const GeoPoint(latitude: 33.0, longitude: 73.0),
          destination: const GeoPoint(latitude: 33.01, longitude: 73.01),
        );

        await controller.startNavigation(
          route: route,
          destination: const GeoPoint(latitude: 33.01, longitude: 73.01),
        );

        // Deliver fresh fix at t = 12:00:00
        locationSource.emitFix(
          LocationFix(
            coordinate: const GeoPoint(latitude: 33.0, longitude: 73.0),
            accuracyMeters: 5.0,
            bearingDegrees: 0.0,
            speedMetersPerSecond: 10.0,
            timestamp: simulatedTime,
          ),
        );

        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(
          controller.state.locationQuality.freshness,
          LocationFreshness.fresh,
        );

        // App is paused in background for 15 seconds: wall clock advances to 12:00:15
        simulatedTime = simulatedTime.add(const Duration(seconds: 15));

        // On resume, evaluateFreshness is called immediately
        controller.evaluateFreshness();

        expect(
          controller.state.locationQuality.freshness,
          LocationFreshness.stale,
        );

        controller.dispose();
        locationSource.dispose();
      },
    );
  });

  group('Vehicle Animator Lifecycle (Pause / Resume)', () {
    test(
      'pause cancels timer and resume reseeds directly without backlog jump',
      () {
        final poses = <DisplayVehiclePose>[];
        final animator = NavigationVehicleAnimator(
          onPoseUpdated: poses.add,
          predictionHorizon: const Duration(seconds: 3),
        );

        final state = NavigationState(
          status: NavigationStatus.navigating,
          matchedPoint: const GeoPoint(latitude: 33.0, longitude: 73.0),
          bearingDegrees: 45.0,
          speedMps: 15.0,
          locationQuality: LocationQuality(
            timestamp: DateTime.now(),
            accuracyMeters: 5.0,
            freshness: LocationFreshness.fresh,
          ),
        );

        animator.onStateUpdated(state);
        expect(animator.isRunning, isTrue);

        // Pause during background transition
        animator.pause();
        expect(animator.isRunning, isFalse);

        final countBeforeResume = poses.length;

        // Resume from background
        animator.resume(state);

        // A pose update is immediately emitted with authoritative state
        expect(poses.length, greaterThan(countBeforeResume));
        final lastPose = poses.last;
        expect(
          lastPose.position,
          const GeoPoint(latitude: 33.0, longitude: 73.0),
        );
        expect(lastPose.bearing, 45.0);

        animator.dispose();
      },
    );

    test(
      'resume freezes extrapolation when GPS fix is older than prediction horizon',
      () {
        final poses = <DisplayVehiclePose>[];
        final animator = NavigationVehicleAnimator(
          onPoseUpdated: poses.add,
          predictionHorizon: const Duration(seconds: 2),
        );

        // State with a fix from 10 seconds ago
        final staleState = NavigationState(
          status: NavigationStatus.navigating,
          matchedPoint: const GeoPoint(latitude: 33.0, longitude: 73.0),
          bearingDegrees: 90.0,
          speedMps: 20.0,
          locationQuality: LocationQuality(
            timestamp: DateTime.now().subtract(const Duration(seconds: 10)),
            accuracyMeters: 5.0,
            freshness: LocationFreshness.stale,
          ),
        );

        animator.resume(staleState);

        // Animation loop should NOT run extrapolation because fix is stale
        expect(animator.isRunning, isFalse);
        expect(
          animator.currentPose?.position,
          const GeoPoint(latitude: 33.0, longitude: 73.0),
        );

        animator.dispose();
      },
    );
  });

  group('MapboxRouteRenderCoordinator Lifecycle & Recreation', () {
    test(
      'style reload restores active route and ignores obsolete generations',
      () async {
        final delegate = _MockRenderDelegate();
        final coordinator = MapboxRouteRenderCoordinator(delegate: delegate);

        final route = NavigationRoute(
          geometry: const [
            GeoPoint(latitude: 33.0, longitude: 73.0),
            GeoPoint(latitude: 33.01, longitude: 73.01),
          ],
          totalDistanceMeters: 1000.0,
          totalDurationSeconds: 60.0,
          steps: const [],
        );

        final activeState = NavigationState(
          status: NavigationStatus.navigating,
          activeRoute: route,
        );

        await coordinator.onStyleReloaded(activeState);
        expect(delegate.drawCount, 1);

        // On stopped session, style reload clears and does NOT redraw
        final stoppedState = const NavigationState(
          status: NavigationStatus.stopped,
        );
        await coordinator.onStyleReloaded(stoppedState);
        expect(delegate.clearCount, 1);
        expect(delegate.drawCount, 1); // Not incremented

        coordinator.dispose();
      },
    );

    test(
      'disposing coordinator prevents late callbacks from invoking delegate',
      () async {
        final delegate = _MockRenderDelegate();
        final coordinator = MapboxRouteRenderCoordinator(delegate: delegate);

        final route = NavigationRoute(
          geometry: const [
            GeoPoint(latitude: 33.0, longitude: 73.0),
            GeoPoint(latitude: 33.01, longitude: 73.01),
          ],
          totalDistanceMeters: 500.0,
          totalDurationSeconds: 30.0,
          steps: const [],
        );

        coordinator.dispose();

        await coordinator.scheduleDraw(
          sessionId: 1,
          routeRevision: 1,
          route: route,
        );
        await coordinator.scheduleClear(1);
        coordinator.scheduleProgressUpdate(
          sessionId: 1,
          routeRevision: 1,
          route: route,
          distanceAlongRouteMeters: 100.0,
        );

        expect(delegate.drawCount, 0);
        expect(delegate.clearCount, 0);
        expect(delegate.progressCount, 0);
      },
    );
  });

  group('Network Transition Handling During Rerouting', () {
    test(
      'failed reroute due to network error preserves active route and leaves controller responsive',
      () async {
        final routeProvider = _MockRouteProvider();
        final locationSource = _MockLocationSource();
        final controller = NavigationController(
          routeProvider: routeProvider,
          locationSource: locationSource,
        );

        final initialRoute = await controller.calculateRoute(
          origin: const GeoPoint(latitude: 33.0, longitude: 73.0),
          destination: const GeoPoint(latitude: 33.05, longitude: 73.05),
        );

        await controller.startNavigation(
          route: initialRoute,
          destination: const GeoPoint(latitude: 33.05, longitude: 73.05),
        );

        expect(controller.state.activeRoute, equals(initialRoute));

        // Configure route provider to fail next request (simulating lost internet)
        routeProvider.nextError = const RouteException(
          'Network unreachable',
          reason: RouteErrorReason.networkError,
        );

        // Route calculation fails with typed error
        expect(
          () => controller.calculateRoute(
            origin: const GeoPoint(latitude: 33.01, longitude: 73.01),
            destination: const GeoPoint(latitude: 33.05, longitude: 73.05),
          ),
          throwsA(isA<RouteException>()),
        );

        // Existing active route in controller remains intact!
        expect(controller.state.activeRoute, equals(initialRoute));
        expect(controller.state.status, NavigationStatus.navigating);

        // Future requests succeed once network recovers
        routeProvider.nextError = null;
        final recoveredRoute = await controller.calculateRoute(
          origin: const GeoPoint(latitude: 33.01, longitude: 73.01),
          destination: const GeoPoint(latitude: 33.05, longitude: 73.05),
        );
        expect(recoveredRoute, isNotNull);

        controller.dispose();
        locationSource.dispose();
      },
    );
  });

  group('NavigationMapView Lifecycle & Ownership', () {
    testWidgets(
      'caller owns controller: unmounting NavigationMapView does not dispose controller',
      (tester) async {
        final routeProvider = _MockRouteProvider();
        final locationSource = _MockLocationSource();
        final controller = NavigationController(
          routeProvider: routeProvider,
          locationSource: locationSource,
        );

        final showMap = ValueNotifier<bool>(true);

        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: ValueListenableBuilder<bool>(
              valueListenable: showMap,
              builder: (context, visible, _) {
                if (!visible) return const SizedBox();
                return NavigationMapView(
                  controller: controller,
                  accessToken: 'pk.mock',
                );
              },
            ),
          ),
        );

        expect(find.byType(NavigationMapView), findsOneWidget);
        expect(controller.state.status, isNot(NavigationStatus.disposed));

        // Simulate screen leave / unmount
        showMap.value = false;
        await tester.pumpAndSettle();

        expect(find.byType(NavigationMapView), findsNothing);

        // Caller-owned controller MUST survive!
        expect(controller.state.status, isNot(NavigationStatus.disposed));

        // Re-mount a new view on the surviving controller (Screen A -> unmount -> Screen B)
        showMap.value = true;
        await tester.pumpAndSettle();

        expect(find.byType(NavigationMapView), findsOneWidget);
        expect(controller.state.status, isNot(NavigationStatus.disposed));

        // Clean up
        showMap.dispose();
        controller.dispose();
        locationSource.dispose();
      },
    );

    testWidgets(
      'handles app background and resume lifecycle transitions without crashing',
      (tester) async {
        final routeProvider = _MockRouteProvider();
        final locationSource = _MockLocationSource();
        final controller = NavigationController(
          routeProvider: routeProvider,
          locationSource: locationSource,
        );

        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: NavigationMapView(
              controller: controller,
              accessToken: 'pk.mock',
            ),
          ),
        );

        // App transitions to paused / background
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump();

        // App transitions to resumed / foreground
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();

        expect(controller.state.status, isNot(NavigationStatus.disposed));

        controller.dispose();
        locationSource.dispose();
      },
    );
  });
}
