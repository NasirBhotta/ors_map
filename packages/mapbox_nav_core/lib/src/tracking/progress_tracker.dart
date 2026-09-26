import 'dart:math';
import '../models/geo_point.dart';
import '../models/location_fix.dart';
import '../models/navigation_route.dart';
import 'route_matcher.dart';
import 'route_metrics.dart';

/// Progress computation result for maneuver advancement.
typedef ManeuverAdvanceResult =
    ({int stepIndex, int? upcomingInstructionIndex});

/// Computes authoritative travel progress, maneuver advancement, and arrival status.
class ProgressTracker {
  static const double stepAdvanceMeters = 35.0;
  static const double voiceLeadSeconds = 4.0;

  const ProgressTracker();

  /// Advances the active step index based on continuous distance along the route.
  ///
  /// Can advance across multiple short steps in a single fix update if required.
  ManeuverAdvanceResult advanceStep({
    required LocationFix fix,
    required NavigationRoute route,
    required RouteMetrics metrics,
    required RouteMatchCandidate accepted,
    required int currentStepIndex,
    required int lastAnnouncedStepIndex,
  }) {
    var stepIndex = currentStepIndex;
    int? upcomingInstructionIndex;

    if (route.steps.length < 2) {
      return (stepIndex: stepIndex, upcomingInstructionIndex: null);
    }

    final speedMps = max(fix.speedMetersPerSecond, 3.0);
    final announceLeadMeters = max(
      stepAdvanceMeters,
      speedMps * voiceLeadSeconds,
    );

    while (stepIndex < route.steps.length - 1 &&
        stepIndex < metrics.stepEndIndices.length) {
      final endIndex = metrics.stepEndIndices[stepIndex];
      final endCoord = route.geometry[endIndex];

      final stepEndDist =
          endIndex < metrics.vertexDistances.length
              ? metrics.vertexDistances[endIndex]
              : 0.0;
      final distancePastStepEnd =
          accepted.distanceAlongRouteMeters - stepEndDist;

      final distanceToEnd = RouteMetrics.haversine(
        fix.coordinate.latitude,
        fix.coordinate.longitude,
        endCoord.latitude,
        endCoord.longitude,
      );

      final nextIndex = stepIndex + 1;
      if (distancePastStepEnd >= 0.0 ||
          accepted.closestRouteIndex >= endIndex ||
          distanceToEnd < stepAdvanceMeters) {
        stepIndex = nextIndex;
        continue;
      }

      if (lastAnnouncedStepIndex != nextIndex &&
          distanceToEnd <= announceLeadMeters) {
        upcomingInstructionIndex = nextIndex;
      }
      break;
    }

    return (
      stepIndex: stepIndex,
      upcomingInstructionIndex: upcomingInstructionIndex,
    );
  }

  /// Determines whether the vehicle has arrived within the destination threshold.
  bool isDestinationReached({
    required LocationFix fix,
    required GeoPoint destination,
    double thresholdMeters = 30.0,
  }) {
    final dist = RouteMetrics.haversine(
      fix.coordinate.latitude,
      fix.coordinate.longitude,
      destination.latitude,
      destination.longitude,
    );
    return dist < thresholdMeters;
  }

  /// Determines the authoritative vehicle bearing from the match or GPS fix.
  double resolveBearing({
    required LocationFix fix,
    required RouteMatchCandidate? accepted,
    required LocationFix? previousFix,
    required double fallbackBearing,
  }) {
    if (accepted != null) {
      return RouteMetrics.normalizeBearing(accepted.segmentBearing);
    }

    if (fix.speedMetersPerSecond > 1.0 &&
        fix.bearingDegrees >= 0.0 &&
        fix.bearingDegrees <= 360.0) {
      return RouteMetrics.normalizeBearing(fix.bearingDegrees);
    }

    if (previousFix != null) {
      final moved = RouteMetrics.haversine(
        previousFix.coordinate.latitude,
        previousFix.coordinate.longitude,
        fix.coordinate.latitude,
        fix.coordinate.longitude,
      );
      if (moved > 3.0) {
        return RouteMetrics.normalizeBearing(
          RouteMetrics.bearingBetween(
            previousFix.coordinate.latitude,
            previousFix.coordinate.longitude,
            fix.coordinate.latitude,
            fix.coordinate.longitude,
          ),
        );
      }
    }

    return fallbackBearing;
  }
}
