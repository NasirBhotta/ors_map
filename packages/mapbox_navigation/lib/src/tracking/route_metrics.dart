import 'dart:math';
import 'package:meta/meta.dart';
import '../models/geo_point.dart';
import '../models/navigation_route.dart';

/// Precomputed geometric metrics for a committed [NavigationRoute].
///
/// Built once per route revision to support O(1) or O(log N) geometric lookups
/// during high-frequency location fix processing.
@immutable
final class RouteMetrics {
  final NavigationRoute route;

  /// Cumulative distance along the route at each geometry vertex in meters.
  final List<double> vertexDistances;

  /// Index of the geometry vertex closest to the end of each step.
  final List<int> stepEndIndices;

  /// Total geometric length of the route polyline in meters.
  double get totalLengthMeters =>
      vertexDistances.isNotEmpty ? vertexDistances.last : route.totalDistanceMeters;

  const RouteMetrics._({
    required this.route,
    required this.vertexDistances,
    required this.stepEndIndices,
  });

  /// Builds metrics from [route] by calculating segment-by-segment haversine lengths.
  factory RouteMetrics.build(NavigationRoute route) {
    final coords = route.geometry;
    final distances = <double>[0.0];

    for (var i = 1; i < coords.length; i++) {
      final prev = coords[i - 1];
      final curr = coords[i];
      final segDist = haversine(
        prev.latitude,
        prev.longitude,
        curr.latitude,
        curr.longitude,
      );
      distances.add(distances.last + segDist);
    }

    final stepEndIndices = <int>[];
    var cumulativeStepDistance = 0.0;
    for (final step in route.steps) {
      cumulativeStepDistance += step.distanceMeters;
      stepEndIndices.add(_indexForDistance(distances, cumulativeStepDistance));
    }

    return RouteMetrics._(
      route: route,
      vertexDistances: List<double>.unmodifiable(distances),
      stepEndIndices: List<int>.unmodifiable(stepEndIndices),
    );
  }

  /// Fast binary search finding the first index whose vertex distance is >= [targetMeters].
  ///
  /// Matches the exact semantics of `for (var i = 0; i < distances.length; i++) if (distances[i] >= targetMeters) return i;`
  /// but operates in O(log N) time instead of O(N).
  static int _indexForDistance(List<double> distances, double targetMeters) {
    if (distances.isEmpty) return 0;
    if (targetMeters <= distances.first) return 0;
    if (targetMeters > distances.last) return distances.length - 1;

    var low = 0;
    var high = distances.length - 1;
    var result = distances.length - 1;

    while (low <= high) {
      final mid = (low + high) >> 1;
      if (distances[mid] >= targetMeters) {
        result = mid;
        high = mid - 1;
      } else {
        low = mid + 1;
      }
    }

    return result;
  }

  /// Finds the segment index [i] such that vertexDistances[i] <= distanceMeters <= vertexDistances[i+1].
  int segmentIndexForDistance(double distanceMeters) {
    if (vertexDistances.length <= 1) return 0;
    final clamped = distanceMeters.clamp(0.0, totalLengthMeters);
    final nextIdx = _indexForDistance(vertexDistances, clamped);
    return (nextIdx == 0 ? 0 : nextIdx - 1).clamp(0, vertexDistances.length - 2);
  }

  /// Interpolates the exact [GeoPoint] along the route at [distanceMeters] using O(log N) binary search.
  GeoPoint? coordinateAtDistance(double distanceMeters) {
    final coords = route.geometry;
    if (coords.isEmpty || vertexDistances.length != coords.length) {
      return null;
    }

    final clampedDistance = distanceMeters.clamp(0.0, totalLengthMeters);
    final i = segmentIndexForDistance(clampedDistance);

    if (i >= vertexDistances.length - 1) {
      return coords.last;
    }

    final startDist = vertexDistances[i];
    final endDist = vertexDistances[i + 1];
    final segLength = max(endDist - startDist, 0.0);
    final fraction =
        segLength == 0.0 ? 0.0 : ((clampedDistance - startDist) / segLength).clamp(0.0, 1.0);

    final a = coords[i];
    final b = coords[i + 1];

    final lng = a.longitude + (b.longitude - a.longitude) * fraction;
    final lat = a.latitude + (b.latitude - a.latitude) * fraction;
    return GeoPoint(latitude: lat, longitude: lng);
  }

  /// Calculates the tangent bearing along the route at [distanceMeters].
  double bearingAtDistance({
    required double distanceMeters,
    required double fallbackBearing,
    double lookAheadMeters = 5.0,
  }) {
    final coords = route.geometry;
    if (coords.length < 2 || vertexDistances.length != coords.length) {
      return fallbackBearing;
    }

    final from = coordinateAtDistance(distanceMeters);
    final to = coordinateAtDistance(
      min(totalLengthMeters, distanceMeters + lookAheadMeters),
    );
    if (from == null || to == null) return fallbackBearing;

    final dist = haversine(
      from.latitude,
      from.longitude,
      to.latitude,
      to.longitude,
    );
    if (dist < 1.0 && distanceMeters > 5.0) {
      final behind = coordinateAtDistance(max(0.0, distanceMeters - lookAheadMeters));
      if (behind != null) {
        return bearingBetween(
          behind.latitude,
          behind.longitude,
          from.latitude,
          from.longitude,
        );
      }
    }

    return bearingBetween(
      from.latitude,
      from.longitude,
      to.latitude,
      to.longitude,
    );
  }

  /// Computes the great-circle distance between two coordinates in meters.
  static double haversine(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const r = 6371000.0; // Earth radius in meters
    final dLat = (lat2 - lat1) * pi / 180.0;
    final dLon = (lon2 - lon1) * pi / 180.0;
    final a = pow(sin(dLat / 2.0), 2) +
        cos(lat1 * pi / 180.0) * cos(lat2 * pi / 180.0) * pow(sin(dLon / 2.0), 2);
    return 2.0 * r * asin(sqrt(a.toDouble().clamp(0.0, 1.0)));
  }

  /// Computes initial bearing from (lat1, lon1) to (lat2, lon2) in degrees [0, 360).
  static double bearingBetween(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    final lat1Rad = lat1 * pi / 180.0;
    final lat2Rad = lat2 * pi / 180.0;
    final dLon = (lon2 - lon1) * pi / 180.0;
    final y = sin(dLon) * cos(lat2Rad);
    final x = cos(lat1Rad) * sin(lat2Rad) - sin(lat1Rad) * cos(lat2Rad) * cos(dLon);
    return ((atan2(y, x) * 180.0 / pi % 360.0) + 360.0) % 360.0;
  }

  /// Normalizes any bearing to the range [0.0, 360.0).
  static double normalizeBearing(double bearing) => ((bearing % 360.0) + 360.0) % 360.0;

  /// Calculates the shortest angular difference from [from] to [to] in degrees [-180, 180].
  static double shortestBearingDelta(double from, double to) {
    return ((to - from + 540.0) % 360.0) - 180.0;
  }
}
