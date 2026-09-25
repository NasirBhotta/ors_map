import 'package:flutter_test/flutter_test.dart';
import 'package:mapbox_navigation/navigation.dart';

class MockRouteProvider implements RouteProvider {
  NavigationRoute? resultToReturn;
  RouteException? errorToThrow;

  @override
  Future<NavigationRoute> calculateRoute({
    required GeoPoint origin,
    required GeoPoint destination,
  }) async {
    if (errorToThrow != null) {
      throw errorToThrow!;
    }
    if (resultToReturn != null) {
      return resultToReturn!;
    }
    throw const RouteException(
      'No route mock configured',
      reason: RouteErrorReason.noRouteFound,
    );
  }
}

void main() {
  group('RouteProvider contract', () {
    late MockRouteProvider provider;

    setUp(() {
      provider = MockRouteProvider();
    });

    test('resolves NavigationRoute on success', () async {
      final sampleRoute = NavigationRoute(
        geometry: const [
          GeoPoint(latitude: 33.7, longitude: 73.0),
          GeoPoint(latitude: 33.8, longitude: 73.1),
        ],
        totalDistanceMeters: 1000,
        totalDurationSeconds: 120,
        steps: const [
          NavigationStep(
            instruction: 'Drive straight',
            distanceMeters: 1000,
            durationSeconds: 120,
          ),
        ],
      );
      provider.resultToReturn = sampleRoute;

      final route = await provider.calculateRoute(
        origin: const GeoPoint(latitude: 33.7, longitude: 73.0),
        destination: const GeoPoint(latitude: 33.8, longitude: 73.1),
      );

      expect(route, equals(sampleRoute));
      expect(route.steps.first.instruction, 'Drive straight');
    });

    test('throws typed RouteException with appropriate error reason', () async {
      provider.errorToThrow = const RouteException(
        'Mapbox access token is invalid or missing',
        reason: RouteErrorReason.missingOrInvalidCredentials,
      );

      expect(
        () => provider.calculateRoute(
          origin: const GeoPoint(latitude: 33.7, longitude: 73.0),
          destination: const GeoPoint(latitude: 33.8, longitude: 73.1),
        ),
        throwsA(
          isA<RouteException>().having(
            (e) => e.reason,
            'reason',
            RouteErrorReason.missingOrInvalidCredentials,
          ),
        ),
      );
    });

    test('supports network and timeout error reasons', () async {
      provider.errorToThrow = const RouteException(
        'Connection timed out after 15s',
        reason: RouteErrorReason.timeout,
      );

      expect(
        () => provider.calculateRoute(
          origin: const GeoPoint(latitude: 0, longitude: 0),
          destination: const GeoPoint(latitude: 1, longitude: 1),
        ),
        throwsA(
          isA<RouteException>()
              .having((e) => e.reason, 'reason', RouteErrorReason.timeout)
              .having((e) => e.message, 'message', contains('timed out')),
        ),
      );
    });
  });
}
