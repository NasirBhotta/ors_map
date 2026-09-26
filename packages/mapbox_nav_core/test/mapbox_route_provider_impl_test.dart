import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mapbox_nav_core/mapbox_nav_core.dart';

class FakeHttpClient extends http.BaseClient {
  final Future<http.Response> Function(http.BaseRequest request) handler;
  FakeHttpClient(this.handler);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await handler(request);
    return http.StreamedResponse(
      Stream.value(response.bodyBytes),
      response.statusCode,
      headers: response.headers,
    );
  }
}

void main() {
  group('MapboxRouteProvider', () {
    test(
      'L: empty access token throws typed RouteException immediately',
      () async {
        final provider = MapboxRouteProvider(accessToken: '   ');

        expect(
          () => provider.calculateRoute(
            origin: const GeoPoint(latitude: 33.0, longitude: 73.0),
            destination: const GeoPoint(latitude: 33.1, longitude: 73.1),
          ),
          throwsA(
            isA<RouteException>().having(
              (e) => e.reason,
              'reason',
              RouteErrorReason.missingOrInvalidCredentials,
            ),
          ),
        );
      },
    );

    test(
      'L: parses valid Mapbox directions response into generic NavigationRoute',
      () async {
        final fakeJson = '''
      {
        "routes": [
          {
            "distance": 1500.5,
            "duration": 180.0,
            "geometry": {
              "coordinates": [
                [73.0, 33.0],
                [73.05, 33.05]
              ]
            },
            "legs": [
              {
                "steps": [
                  {
                    "distance": 1500.5,
                    "duration": 180.0,
                    "maneuver": {
                      "instruction": "Continue on Main Street",
                      "type": "turn",
                      "modifier": "straight",
                      "location": [73.0, 33.0]
                    },
                    "max_speed": {
                      "speed": 60,
                      "unit": "km/h"
                    }
                  }
                ]
              }
            ]
          }
        ]
      }
      ''';

        final client = FakeHttpClient((request) async {
          return http.Response(fakeJson, 200);
        });

        final provider = MapboxRouteProvider(
          accessToken: 'pk.valid_test_token',
          httpClient: client,
        );

        final route = await provider.calculateRoute(
          origin: const GeoPoint(latitude: 33.0, longitude: 73.0),
          destination: const GeoPoint(latitude: 33.05, longitude: 73.05),
        );

        expect(route.totalDistanceMeters, equals(1500.5));
        expect(route.totalDurationSeconds, equals(180.0));
        expect(route.geometry.length, equals(2));
        expect(
          route.geometry.first,
          equals(const GeoPoint(latitude: 33.0, longitude: 73.0)),
        );
        expect(route.steps.length, equals(1));
        expect(
          route.steps.first.instruction,
          equals('Continue on Main Street'),
        );
        expect(route.steps.first.speedLimitKmh, equals(60));
      },
    );

    test('L: maps HTTP 401/403 to missingOrInvalidCredentials', () async {
      final client = FakeHttpClient((request) async {
        return http.Response('{"message": "Not Authorized"}', 401);
      });

      final provider = MapboxRouteProvider(
        accessToken: 'pk.invalid',
        httpClient: client,
      );

      expect(
        () => provider.calculateRoute(
          origin: const GeoPoint(latitude: 33.0, longitude: 73.0),
          destination: const GeoPoint(latitude: 33.1, longitude: 73.1),
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
  });
}
