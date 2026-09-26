import 'dart:math';
import 'package:meta/meta.dart';
import '../models/geo_point.dart';
import '../models/location_fix.dart';
import '../models/navigation_route.dart';
import 'route_metrics.dart';

/// Operational mode of the route matching engine.
enum MatcherMode {
  /// Normal tracking: restrict search to a local forward window around committed progress.
  tracking,

  /// Reacquisition: search the entire route without window restrictions.
  reacquisition,
}

/// A coherent, single-source projection of a [LocationFix] onto a route polyline.
@immutable
final class RouteMatchCandidate {
  final int closestRouteIndex;
  final double crossTrackMeters;
  final double distanceAlongRouteMeters;
  final double segmentFraction;
  final int segmentIndex;
  final double segmentBearing;
  final GeoPoint snappedPoint;
  final int routeRevision;

  const RouteMatchCandidate({
    required this.closestRouteIndex,
    required this.crossTrackMeters,
    required this.distanceAlongRouteMeters,
    required this.segmentFraction,
    required this.segmentIndex,
    required this.segmentBearing,
    required this.snappedPoint,
    required this.routeRevision,
  });

  RouteMatchCandidate withDistance(double clampedDistance) {
    return RouteMatchCandidate(
      closestRouteIndex: closestRouteIndex,
      crossTrackMeters: crossTrackMeters,
      distanceAlongRouteMeters: clampedDistance,
      segmentFraction: segmentFraction,
      segmentIndex: segmentIndex,
      segmentBearing: segmentBearing,
      snappedPoint: snappedPoint,
      routeRevision: routeRevision,
    );
  }
}

/// Algorithmic route projection and candidate evaluation engine.
class RouteMatcher {
  static const double offRouteBaseMeters = 80.0;
  static const double accuracyCapMeters = 150.0;
  static const double maxBackwardClampingMeters = 25.0;
  static const double largeBackwardMeters = 100.0;
  static const double minForwardSnapWindowMeters = 90.0;
  static const double forwardWindowSpeedSeconds = 8.0;
  static const double forwardWindowAccuracyFactor = 2.0;
  static const double headingMinSpeedMps = 1.5;
  static const double headingMaxWeight = 0.3;
  static const double headingFullPenaltyDeg = 90.0;
  static const int reacquisitionThreshold = 3;

  const RouteMatcher();

  /// Projects [fix] onto [route] using flat-earth projection.
  RouteMatchCandidate findCandidateMatch({
    required LocationFix fix,
    required NavigationRoute route,
    required RouteMetrics metrics,
    required MatcherMode mode,
    required double lastBearing,
    required double committedDistance,
    required int routeRevision,
  }) {
    final coords = route.geometry;
    if (coords.length < 2) {
      return RouteMatchCandidate(
        closestRouteIndex: 0,
        crossTrackMeters: double.infinity,
        distanceAlongRouteMeters: 0.0,
        segmentFraction: 0.0,
        segmentIndex: 0,
        segmentBearing: lastBearing,
        snappedPoint: coords.isEmpty ? fix.coordinate : coords.first,
        routeRevision: routeRevision,
      );
    }

    final originLatRad = fix.coordinate.latitude * pi / 180.0;
    const earthRadius = 6371000.0;

    final inTracking = mode == MatcherMode.tracking;
    final forwardWindowMeters = max(
      minForwardSnapWindowMeters,
      fix.speedMetersPerSecond * forwardWindowSpeedSeconds +
          fix.accuracyMeters * forwardWindowAccuracyFactor,
    );

    final threshold = min(
      max(offRouteBaseMeters, fix.accuracyMeters * 2.5),
      accuracyCapMeters,
    );

    var bestCross = double.infinity;
    var bestIndex = 0;
    var bestAlongRoute = 0.0;
    var bestFraction = 0.0;
    var bestSegIndex = 0;
    var bestBearing = lastBearing;
    var bestLat = coords.first.latitude;
    var bestLng = coords.first.longitude;

    var fallCross = double.infinity;
    var fallIndex = 0;
    var fallAlongRoute = 0.0;
    var fallFraction = 0.0;
    var fallSegIndex = 0;
    var fallBearing = lastBearing;
    var fallLat = coords.first.latitude;
    var fallLng = coords.first.longitude;

    int scanStart = 0;
    int scanEnd = coords.length - 1;
    double? backLimit;
    double? fwdLimit;

    if (inTracking && committedDistance > 0.0) {
      backLimit = committedDistance - maxBackwardClampingMeters;
      fwdLimit = committedDistance + forwardWindowMeters;
      scanStart = max(0, metrics.segmentIndexForDistance(backLimit) - 1);
      scanEnd = min(
        coords.length - 1,
        metrics.segmentIndexForDistance(fwdLimit) + 2,
      );
    }

    void evaluateSegment(int i) {
      final a = coords[i];
      final b = coords[i + 1];

      final ax =
          (a.longitude - fix.coordinate.longitude) *
          pi /
          180.0 *
          earthRadius *
          cos(originLatRad);
      final ay =
          (a.latitude - fix.coordinate.latitude) * pi / 180.0 * earthRadius;
      final bx =
          (b.longitude - fix.coordinate.longitude) *
          pi /
          180.0 *
          earthRadius *
          cos(originLatRad);
      final by =
          (b.latitude - fix.coordinate.latitude) * pi / 180.0 * earthRadius;

      final abx = bx - ax;
      final aby = by - ay;
      final ab2 = abx * abx + aby * aby;
      final t = ab2 == 0.0 ? 0.0 : ((-ax * abx) + (-ay * aby)) / ab2;
      final clampedT = t.clamp(0.0, 1.0);
      final px = ax + abx * clampedT;
      final py = ay + aby * clampedT;
      final cross = sqrt(px * px + py * py);

      final segmentStartDist =
          i < metrics.vertexDistances.length ? metrics.vertexDistances[i] : 0.0;
      final segmentLength =
          i + 1 < metrics.vertexDistances.length
              ? metrics.vertexDistances[i + 1] - metrics.vertexDistances[i]
              : RouteMetrics.haversine(
                a.latitude,
                a.longitude,
                b.latitude,
                b.longitude,
              );
      final candidateAlongRoute = segmentStartDist + segmentLength * clampedT;
      final candidateIndex = clampedT >= 0.5 ? i + 1 : i;

      final snappedLng = a.longitude + (b.longitude - a.longitude) * clampedT;
      final snappedLat = a.latitude + (b.latitude - a.latitude) * clampedT;
      final segBearing = RouteMetrics.bearingBetween(
        a.latitude,
        a.longitude,
        b.latitude,
        b.longitude,
      );

      // Global candidate tracking
      if (cross < fallCross) {
        fallCross = cross;
        fallIndex = candidateIndex;
        fallAlongRoute = candidateAlongRoute;
        fallFraction = clampedT;
        fallSegIndex = i;
        fallBearing = segBearing;
        fallLat = snappedLat;
        fallLng = snappedLng;
      }

      // Window filter candidate tracking
      if (backLimit != null && fwdLimit != null) {
        if (candidateAlongRoute < backLimit || candidateAlongRoute > fwdLimit) {
          return;
        }
      }

      if (cross < bestCross) {
        bestCross = cross;
        bestIndex = candidateIndex;
        bestAlongRoute = candidateAlongRoute;
        bestFraction = clampedT;
        bestSegIndex = i;
        bestBearing = segBearing;
        bestLat = snappedLat;
        bestLng = snappedLng;
      }
    }

    // Pass 1: local tracking window (or entire route if not tracking with committed distance)
    for (var i = scanStart; i < scanEnd; i++) {
      evaluateSegment(i);
    }

    // Pass 2: only if tracking window failed to match within threshold and there are unscanned segments
    if (inTracking && committedDistance > 0.0 && bestCross > threshold) {
      for (var i = 0; i < scanStart; i++) {
        evaluateSegment(i);
      }
      for (var i = scanEnd; i < coords.length - 1; i++) {
        evaluateSegment(i);
      }
    }

    // Prefer candidate within forward tracking window; only fall back to global candidate
    // if no segment within the forward tracking window matched within acceptable cross-track threshold.
    if ((bestCross > threshold || bestCross.isInfinite) && fallCross.isFinite) {
      bestCross = fallCross;
      bestIndex = fallIndex;
      bestAlongRoute = fallAlongRoute;
      bestFraction = fallFraction;
      bestSegIndex = fallSegIndex;
      bestBearing = fallBearing;
      bestLat = fallLat;
      bestLng = fallLng;
    }

    final finalBearing = metrics.bearingAtDistance(
      distanceMeters: bestAlongRoute,
      fallbackBearing: bestBearing,
    );

    return RouteMatchCandidate(
      closestRouteIndex: bestIndex,
      crossTrackMeters: bestCross,
      distanceAlongRouteMeters: bestAlongRoute,
      segmentFraction: bestFraction,
      segmentIndex: bestSegIndex,
      segmentBearing: finalBearing,
      snappedPoint: GeoPoint(latitude: bestLat, longitude: bestLng),
      routeRevision: routeRevision,
    );
  }

  /// Evaluates whether [candidate] should be accepted as the authoritative route progress.
  RouteMatchCandidate? evaluateCandidate({
    required LocationFix fix,
    required RouteMatchCandidate candidate,
    required double lastRouteDistance,
    double? customOffRouteMeters,
  }) {
    if (!candidate.crossTrackMeters.isFinite) return null;

    final baseOffRoute = customOffRouteMeters ?? offRouteBaseMeters;
    final threshold = min(
      max(baseOffRoute, fix.accuracyMeters * 2.5),
      accuracyCapMeters,
    );

    // 1. Cross-track gate
    if (candidate.crossTrackMeters > threshold) {
      return null;
    }

    // 2. Backward-movement policy
    final delta = candidate.distanceAlongRouteMeters - lastRouteDistance;
    if (lastRouteDistance > 0.0 && delta < -largeBackwardMeters) {
      // Large backward relocation: reject candidate to signal reacquisition
      return null;
    }

    if (lastRouteDistance > 0.0 &&
        delta < 0.0 &&
        delta >= -maxBackwardClampingMeters) {
      // Small backward jitter: clamp distance to committed progress
      return candidate.withDistance(lastRouteDistance);
    }

    if (lastRouteDistance > 0.0 && delta < 0.0) {
      // Moderate backward movement (between 25m and 100m): reject candidate
      return null;
    }

    // 3. Heading consistency gate (soft signal)
    if (fix.speedMetersPerSecond >= headingMinSpeedMps &&
        fix.bearingDegrees >= 0.0 &&
        fix.bearingDegrees <= 360.0) {
      final headingDelta =
          RouteMetrics.shortestBearingDelta(
            fix.bearingDegrees,
            candidate.segmentBearing,
          ).abs();
      if (headingDelta > headingFullPenaltyDeg) {
        final headingPenalty =
            min((headingDelta - headingFullPenaltyDeg) / 90.0, 1.0) *
            headingMaxWeight;
        final penalisedThreshold = threshold * (1.0 - headingPenalty);
        if (candidate.crossTrackMeters > penalisedThreshold) {
          return null;
        }
      }
    }

    return candidate;
  }
}
