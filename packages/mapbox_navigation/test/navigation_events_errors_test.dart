import 'package:flutter_test/flutter_test.dart';
import 'package:mapbox_navigation/navigation.dart';

void main() {
  group('NavigationEvent & NavigationException', () {
    test('supports exhaustive sealed pattern matching on NavigationEvent', () {
      final events = <NavigationEvent>[
        const InstructionChangedEvent(
          stepIndex: 1,
          step: NavigationStep(
            instruction: 'Turn left',
            distanceMeters: 200,
            durationSeconds: 20,
          ),
        ),
        LocationFix(
          coordinate: const GeoPoint(latitude: 33.7, longitude: 73.0),
          accuracyMeters: 5,
          bearingDegrees: 90,
          speedMetersPerSecond: 10,
          timestamp: DateTime.utc(2026, 1, 1),
        ).let((fix) => RerouteStartedEvent(triggerFix: fix)),
        const RerouteFailedEvent(reason: 'Network unreachable'),
        const DestinationReachedEvent(
          destination: GeoPoint(latitude: 33.8, longitude: 73.1),
        ),
        const NavigationErrorEvent(
          error: LocationUnavailableException(
            'GPS disabled',
            reason: LocationErrorReason.serviceDisabled,
          ),
        ),
      ];

      final descriptions = <String>[];
      for (final event in events) {
        final desc = switch (event) {
          InstructionChangedEvent(:final stepIndex, :final step) =>
            'step_$stepIndex:${step.instruction}',
          RerouteStartedEvent(:final triggerFix) =>
            'reroute_at:${triggerFix.coordinate.latitude}',
          RerouteFailedEvent(:final reason) => 'reroute_fail:$reason',
          DestinationReachedEvent(:final destination) =>
            'arrived_at:${destination.latitude}',
          NavigationErrorEvent(:final error) => 'error:${error.message}',
        };
        descriptions.add(desc);
      }

      expect(descriptions, [
        'step_1:Turn left',
        'reroute_at:33.7',
        'reroute_fail:Network unreachable',
        'arrived_at:33.8',
        'error:GPS disabled',
      ]);
    });

    test('verifies NavigationException types and reasons', () {
      const routeErr = RouteException(
        'Host 404',
        reason: RouteErrorReason.serverError,
      );
      expect(routeErr.reason, RouteErrorReason.serverError);
      expect(routeErr.toString(), contains('RouteException: Host 404'));

      const locErr = LocationUnavailableException(
        'Permission denied by user',
        reason: LocationErrorReason.permissionDenied,
      );
      expect(locErr.reason, LocationErrorReason.permissionDenied);

      const cfgErr = InvalidConfigurationException('Invalid radius');
      expect(cfgErr.message, 'Invalid radius');

      const lifeErr = NavigationLifecycleException(
        'Already navigating',
        reason: LifecycleErrorReason.alreadyNavigating,
      );
      expect(lifeErr.reason, LifecycleErrorReason.alreadyNavigating);
    });
  });
}

extension<T> on T {
  R let<R>(R Function(T it) block) => block(this);
}
