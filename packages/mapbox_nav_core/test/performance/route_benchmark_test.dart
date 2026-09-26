// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mapbox_nav_core/mapbox_nav_core.dart';
import 'package:mapbox_nav_core/src/tracking/route_matcher.dart';
import 'package:mapbox_nav_core/src/tracking/route_metrics.dart';

/// Helper generating a deterministic synthetic route with [pointCount] vertices.
NavigationRoute createSyntheticRoute(
  int pointCount, {
  double totalDistanceMeters = 50000.0,
}) {
  assert(pointCount >= 2);
  final coords = <GeoPoint>[];
  const startLat = 33.7000;
  const startLng = 73.0000;
  // ~0.0001 deg lat is ~11.1 meters
  final latDelta = (totalDistanceMeters / 111320.0) / (pointCount - 1);

  for (var i = 0; i < pointCount; i++) {
    coords.add(
      GeoPoint(latitude: startLat + (i * latDelta), longitude: startLng),
    );
  }

  // Create steps every 10% of route
  final steps = <NavigationStep>[];
  final stepCount = min(10, pointCount - 1);
  final distPerStep = totalDistanceMeters / stepCount;
  for (var s = 0; s < stepCount; s++) {
    steps.add(
      NavigationStep(
        instruction: 'Step $s: continue straight',
        distanceMeters: distPerStep,
        durationSeconds: distPerStep / 15.0, // ~54 km/h
      ),
    );
  }

  return NavigationRoute(
    geometry: coords,
    totalDistanceMeters: totalDistanceMeters,
    totalDurationSeconds: totalDistanceMeters / 15.0,
    steps: steps,
  );
}

void main() {
  group('Route Performance & Long Route Benchmarks', () {
    const pointSizes = [100, 1000, 5000, 10000];

    for (final size in pointSizes) {
      test('Synthetic route ($size points): metrics construction timing', () {
        final route = createSyntheticRoute(size);
        final sw = Stopwatch()..start();
        final metrics = RouteMetrics.build(route);
        sw.stop();

        expect(metrics.vertexDistances.length, size);
        expect(metrics.totalLengthMeters, greaterThan(0.0));
        // Verify timing completes reasonably (deterministic ceiling for test harness)
        // Note: Report timing as environment-specific benchmark.
        print(
          'Benchmark: RouteMetrics.build for $size points took ${sw.elapsedMicroseconds} µs (${sw.elapsedMilliseconds} ms)',
        );
      });

      test(
        'Synthetic route ($size points): normal forward matching (100 sequential fixes)',
        () {
          final route = createSyntheticRoute(size);
          final metrics = RouteMetrics.build(route);
          const matcher = RouteMatcher();

          var committedDistance = 0.0;
          final sw = Stopwatch()..start();

          for (var i = 0; i < 100; i++) {
            final targetDist = (i + 1) * 20.0; // 20m increments
            final coord = metrics.coordinateAtDistance(targetDist)!;
            final fix = LocationFix(
              coordinate: coord,
              accuracyMeters: 5.0,
              bearingDegrees: 0.0,
              speedMetersPerSecond: 15.0,
              timestamp: DateTime.utc(2026, 1, 1).add(Duration(seconds: i)),
            );

            final candidate = matcher.findCandidateMatch(
              fix: fix,
              route: route,
              metrics: metrics,
              committedDistance: committedDistance,
              mode: MatcherMode.tracking,
              lastBearing: 0.0,
              routeRevision: 1,
            );
            final accepted = matcher.evaluateCandidate(
              fix: fix,
              candidate: candidate,
              lastRouteDistance: committedDistance,
            );
            expect(accepted, isNotNull);
            committedDistance = accepted!.distanceAlongRouteMeters;
          }

          sw.stop();
          final avgMicros = sw.elapsedMicroseconds / 100;
          print(
            'Benchmark: Normal tracking match ($size points, windowed) avg: ${avgMicros.toStringAsFixed(1)} µs/fix (total: ${sw.elapsedMilliseconds} ms for 100 fixes)',
          );
        },
      );

      test(
        'Synthetic route ($size points): reacquisition full scan (10 off-route fixes)',
        () {
          final route = createSyntheticRoute(size);
          final metrics = RouteMetrics.build(route);
          const matcher = RouteMatcher();

          final sw = Stopwatch()..start();
          for (var i = 0; i < 10; i++) {
            final fix = LocationFix(
              coordinate: const GeoPoint(latitude: 33.7500, longitude: 73.0005),
              accuracyMeters: 5.0,
              bearingDegrees: 0.0,
              speedMetersPerSecond: 10.0,
              timestamp: DateTime.utc(2026, 1, 1).add(Duration(seconds: i)),
            );

            final candidate = matcher.findCandidateMatch(
              fix: fix,
              route: route,
              metrics: metrics,
              committedDistance: 0.0,
              mode: MatcherMode.reacquisition,
              lastBearing: 0.0,
              routeRevision: 1,
            );

            expect(candidate.snappedPoint, isNotNull);
          }
          sw.stop();
          final avgMicros = sw.elapsedMicroseconds / 10;
          print(
            'Benchmark: Reacquisition full scan ($size points) avg: ${avgMicros.toStringAsFixed(1)} µs/scan',
          );
        },
      );

      test(
        'Synthetic route ($size points): 1,000 distance-to-coordinate lookups',
        () {
          final route = createSyntheticRoute(size);
          final metrics = RouteMetrics.build(route);
          final totalDist = metrics.totalLengthMeters;

          final sw = Stopwatch()..start();
          for (var i = 0; i < 1000; i++) {
            final targetDist = (i / 1000.0) * totalDist;
            final point = metrics.coordinateAtDistance(targetDist);
            expect(point, isNotNull);
          }
          sw.stop();

          final avgMicros = sw.elapsedMicroseconds / 1000;
          print(
            'Benchmark: coordinateAtDistance ($size points, binary search) avg: ${avgMicros.toStringAsFixed(2)} µs/lookup',
          );
        },
      );
    }

    test(
      'Route parsing benchmark: short vs large (5,000 points) vs many steps',
      () {
        // Create synthetic Mapbox Directions JSON response with 5,000 coordinates and 50 steps
        final coords = <List<double>>[];
        for (var i = 0; i < 5000; i++) {
          coords.add([73.0000, 33.7000 + (i * 0.00002)]);
        }
        final stepsJson = <Map<String, dynamic>>[];
        for (var s = 0; s < 50; s++) {
          stepsJson.add({
            'maneuver': {'instruction': 'Step $s'},
            'distance': 200.0,
            'duration': 20.0,
          });
        }

        final jsonPayload = jsonEncode({
          'code': 'Ok',
          'routes': [
            {
              'geometry': {'type': 'LineString', 'coordinates': coords},
              'distance': 10000.0,
              'duration': 1000.0,
              'legs': [
                {'steps': stepsJson},
              ],
            },
          ],
        });

        final sw = Stopwatch()..start();
        final decoded = jsonDecode(jsonPayload) as Map<String, dynamic>;
        final provider = MapboxRouteProvider(accessToken: 'pk.test');
        final route = provider.parseRouteResponse(decoded);
        sw.stop();

        expect(route.geometry.length, 5000);
        expect(route.steps.length, 50);
        print(
          'Benchmark: Mapbox route parsing (5,000 points, 50 steps) took ${sw.elapsedMilliseconds} ms',
        );
      },
    );
  });
}
