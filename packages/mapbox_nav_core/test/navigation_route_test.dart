import 'package:flutter_test/flutter_test.dart';
import 'package:mapbox_nav_core/navigation.dart';

void main() {
  group('NavigationRoute & NavigationStep', () {
    test('enforces defensive immutability for geometry and steps', () {
      final mutablePoints = [
        const GeoPoint(latitude: 33.7, longitude: 73.0),
        const GeoPoint(latitude: 33.8, longitude: 73.1),
      ];
      final mutableSteps = [
        const NavigationStep(
          instruction: 'Proceed forward',
          distanceMeters: 500,
          durationSeconds: 60,
        ),
      ];

      final route = NavigationRoute(
        geometry: mutablePoints,
        totalDistanceMeters: 500,
        totalDurationSeconds: 60,
        steps: mutableSteps,
      );

      // Mutating original input lists does not mutate route
      mutablePoints.add(const GeoPoint(latitude: 33.9, longitude: 73.2));
      mutableSteps.add(
        const NavigationStep(
          instruction: 'Turn right',
          distanceMeters: 200,
          durationSeconds: 30,
        ),
      );

      expect(route.geometry.length, 2);
      expect(route.steps.length, 1);

      // Internal lists are unmodifiable
      expect(
        () => route.geometry.add(const GeoPoint(latitude: 0, longitude: 0)),
        throwsUnsupportedError,
      );
      expect(
        () => route.steps.add(
          const NavigationStep(
            instruction: 'Another',
            distanceMeters: 10,
            durationSeconds: 5,
          ),
        ),
        throwsUnsupportedError,
      );
    });

    test('validates geometry minimum point count', () {
      expect(
        () => NavigationRoute(
          geometry: [const GeoPoint(latitude: 33.0, longitude: 73.0)],
          totalDistanceMeters: 0,
          totalDurationSeconds: 0,
          steps: const [],
        ),
        throwsA(anyOf(isA<InvalidRouteException>(), isA<AssertionError>())),
      );
    });

    test('computes distanceText and durationText accurately', () {
      final routeShort = NavigationRoute(
        geometry: const [
          GeoPoint(latitude: 33.0, longitude: 73.0),
          GeoPoint(latitude: 33.1, longitude: 73.1),
        ],
        totalDistanceMeters: 650.4,
        totalDurationSeconds: 45,
        steps: const [],
      );
      expect(routeShort.distanceText, '650 m');
      expect(routeShort.durationText, '1 min');

      final routeLong = NavigationRoute(
        geometry: const [
          GeoPoint(latitude: 33.0, longitude: 73.0),
          GeoPoint(latitude: 33.1, longitude: 73.1),
        ],
        totalDistanceMeters: 12500.0,
        totalDurationSeconds: 4920, // 82 minutes = 1 hr 22 min
        steps: const [],
      );
      expect(routeLong.distanceText, '12.5 km');
      expect(routeLong.durationText, '1 hr 22 min');
    });

    test('step validates non-negative distance and duration', () {
      expect(
        () => NavigationStep(
          instruction: 'Go',
          distanceMeters: -1,
          durationSeconds: 10,
        ),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => NavigationStep(
          instruction: 'Go',
          distanceMeters: 10,
          durationSeconds: -5,
        ),
        throwsA(isA<AssertionError>()),
      );
    });
  });
}
