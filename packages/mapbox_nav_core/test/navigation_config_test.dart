import 'package:flutter_test/flutter_test.dart';
import 'package:mapbox_nav_core/navigation.dart';

void main() {
  group('NavigationConfig', () {
    test('instantiates with expected default values', () {
      const config = NavigationConfig();

      expect(config.tracking.offRouteMeters, 80.0);
      expect(config.arrival.destinationRadiusMeters, 30.0);
      expect(config.freshness.staleTimeout, const Duration(seconds: 5));
      expect(config.rerouting.autoRerouteEnabled, isTrue);
      expect(config.rerouting.minRerouteInterval, const Duration(seconds: 8));
      expect(config.rerouting.routeRequestTimeout, const Duration(seconds: 15));
    });

    test('validates assertion constraints on tracking', () {
      expect(
        () => TrackingConfig(offRouteMeters: 0),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => TrackingConfig(offRouteMeters: -5),
        throwsA(isA<AssertionError>()),
      );
    });

    test('validates assertion constraints on arrival', () {
      expect(
        () => ArrivalConfig(destinationRadiusMeters: 0),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => ArrivalConfig(destinationRadiusMeters: -1),
        throwsA(isA<AssertionError>()),
      );
    });

    test('validates constraints via validate()', () {
      const valid = NavigationConfig();
      expect(() => valid.validate(), returnsNormally);

      const invalidFreshness = NavigationConfig(
        freshness: FreshnessConfig(staleTimeout: Duration.zero),
      );
      expect(
        () => invalidFreshness.validate(),
        throwsA(isA<InvalidConfigurationException>()),
      );

      const invalidInterval = NavigationConfig(
        rerouting: ReroutingConfig(minRerouteInterval: Duration(seconds: -1)),
      );
      expect(
        () => invalidInterval.validate(),
        throwsA(isA<InvalidConfigurationException>()),
      );

      const invalidTimeout = NavigationConfig(
        rerouting: ReroutingConfig(routeRequestTimeout: Duration.zero),
      );
      expect(
        () => invalidTimeout.validate(),
        throwsA(isA<InvalidConfigurationException>()),
      );
    });

    test('supports value equality', () {
      const c1 = NavigationConfig();
      const c2 = NavigationConfig();
      const c3 = NavigationConfig(tracking: TrackingConfig(offRouteMeters: 50));

      expect(c1, equals(c2));
      expect(c1.hashCode, equals(c2.hashCode));
      expect(c1, isNot(equals(c3)));
    });
  });
}
