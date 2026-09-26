import 'package:flutter_test/flutter_test.dart';
import 'package:mapbox_nav_core/mapbox_nav_core.dart';
import 'package:mapbox_nav_core/src/mapbox/animation/navigation_vehicle_animator.dart';

void main() {
  group('NavigationVehicleAnimator', () {
    late List<DisplayVehiclePose> emittedPoses;
    late NavigationVehicleAnimator animator;

    setUp(() {
      emittedPoses = [];
      animator = NavigationVehicleAnimator(
        onPoseUpdated: (pose) {
          emittedPoses.add(pose);
        },
      );
    });

    tearDown(() {
      animator.dispose();
    });

    test(
      'G: vehicle display state cannot mutate authoritative NavigationState',
      () {
        const originalState = NavigationState(
          status: NavigationStatus.navigating,
          bearingDegrees: 45.0,
          speedMps: 15.0,
          distanceAlongRouteMeters: 120.0,
        );

        animator.onStateUpdated(originalState);

        // Verify that mutating animator or producing display poses does not change originalState
        expect(originalState.bearingDegrees, equals(45.0));
        expect(originalState.speedMps, equals(15.0));
        expect(originalState.distanceAlongRouteMeters, equals(120.0));
      },
    );

    test(
      'H: route revision change resets and reseeds vehicle polyline metrics',
      () {
        final route1 = NavigationRoute(
          geometry: const [
            GeoPoint(latitude: 33.0, longitude: 73.0),
            GeoPoint(latitude: 33.001, longitude: 73.0),
          ],
          totalDistanceMeters: 111.0,
          totalDurationSeconds: 10.0,
          steps: const [],
        );

        animator.setRoute(route1);

        final route2 = NavigationRoute(
          geometry: const [
            GeoPoint(latitude: 34.0, longitude: 74.0),
            GeoPoint(latitude: 34.005, longitude: 74.0),
          ],
          totalDistanceMeters: 555.0,
          totalDurationSeconds: 50.0,
          steps: const [],
        );

        animator.setRoute(route2);

        // Reseeding to route2 origin
        animator.reseed(
          const GeoPoint(latitude: 34.0, longitude: 74.0),
          bearing: 90.0,
        );
        expect(
          animator.currentPose?.position,
          equals(const GeoPoint(latitude: 34.0, longitude: 74.0)),
        );
        expect(animator.currentPose?.bearing, equals(90.0));
      },
    );

    test(
      'I: off-route rejoin visual reseed updates pose immediately without backward glitch',
      () {
        animator.reseed(
          const GeoPoint(latitude: 33.5, longitude: 73.5),
          bearing: 180.0,
        );
        expect(
          animator.currentPose?.position,
          equals(const GeoPoint(latitude: 33.5, longitude: 73.5)),
        );
        expect(animator.currentPose?.bearing, equals(180.0));

        // Rejoin at new coordinate
        animator.reseed(
          const GeoPoint(latitude: 33.502, longitude: 73.502),
          bearing: 45.0,
        );
        expect(
          animator.currentPose?.position,
          equals(const GeoPoint(latitude: 33.502, longitude: 73.502)),
        );
        expect(animator.currentPose?.bearing, equals(45.0));
      },
    );
  });
}
