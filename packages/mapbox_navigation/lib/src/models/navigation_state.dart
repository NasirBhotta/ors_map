import 'package:meta/meta.dart';
import 'geo_point.dart';
import 'location_fix.dart';
import 'location_quality.dart';
import 'navigation_enums.dart';
import 'navigation_route.dart';
import 'navigation_step.dart';

/// An immutable, authoritative snapshot of measured navigation state.
///
/// Contains strictly verified sensor, tracking, and route-progress metrics.
/// Does not contain predicted visual coordinates, renderer tokens, or internal session revisions.
@immutable
final class NavigationState {
  /// Overall lifecycle status of the navigation session.
  final NavigationStatus status;

  /// Status of in-flight route or reroute calculations.
  final RouteRequestStatus routeRequestStatus;

  /// Relationship between current position and the active route corridor.
  final TrackingStatus trackingStatus;

  /// The active navigation route, if one has been calculated and activated.
  final NavigationRoute? activeRoute;

  /// The target destination coordinate for this session.
  final GeoPoint? destination;

  /// The most recent raw GPS fix accepted by the engine.
  final LocationFix? rawFix;

  /// The authoritative projection of the current location onto the route geometry.
  ///
  /// Represents measured, snapped route progress metrics derived directly from GPS fixes.
  /// Does NOT represent smoothed, interpolated visual animation poses.
  /// Null if position has not yet been matched or is off-route.
  final GeoPoint? matchedPoint;

  /// Current navigation bearing in degrees [0.0, 360.0).
  final double bearingDegrees;

  /// Measured travel speed in meters per second.
  final double speedMps;

  /// Cumulative measured travel distance along the active route in meters.
  final double? distanceAlongRouteMeters;

  /// Estimated distance remaining to the destination in meters.
  final double? remainingDistanceMeters;

  /// Estimated time remaining to the destination in seconds.
  final double? remainingDurationSeconds;

  /// Zero-based index of the current active step within [activeRoute.steps].
  final int? currentStepIndex;

  /// The current active maneuver step.
  final NavigationStep? currentStep;

  /// GPS timeliness and accuracy indicators.
  final LocationQuality locationQuality;

  /// True when arrival at the final destination has been confirmed.
  final bool isArrived;

  const NavigationState({
    this.status = NavigationStatus.idle,
    this.routeRequestStatus = RouteRequestStatus.idle,
    this.trackingStatus = TrackingStatus.unmatched,
    this.activeRoute,
    this.destination,
    this.rawFix,
    this.matchedPoint,
    this.bearingDegrees = 0.0,
    this.speedMps = 0.0,
    this.distanceAlongRouteMeters,
    this.remainingDistanceMeters,
    this.remainingDurationSeconds,
    this.currentStepIndex,
    this.currentStep,
    this.locationQuality = const LocationQuality(),
    this.isArrived = false,
  });

  /// Convenience getter for speed in km/h.
  double get speedKmh => speedMps * 3.6;

  /// Creates a copy with the given fields replaced.
  NavigationState copyWith({
    NavigationStatus? status,
    RouteRequestStatus? routeRequestStatus,
    TrackingStatus? trackingStatus,
    NavigationRoute? activeRoute,
    GeoPoint? destination,
    LocationFix? rawFix,
    GeoPoint? matchedPoint,
    double? bearingDegrees,
    double? speedMps,
    double? distanceAlongRouteMeters,
    double? remainingDistanceMeters,
    double? remainingDurationSeconds,
    int? currentStepIndex,
    NavigationStep? currentStep,
    LocationQuality? locationQuality,
    bool? isArrived,
  }) {
    return NavigationState(
      status: status ?? this.status,
      routeRequestStatus: routeRequestStatus ?? this.routeRequestStatus,
      trackingStatus: trackingStatus ?? this.trackingStatus,
      activeRoute: activeRoute ?? this.activeRoute,
      destination: destination ?? this.destination,
      rawFix: rawFix ?? this.rawFix,
      matchedPoint: matchedPoint ?? this.matchedPoint,
      bearingDegrees: bearingDegrees ?? this.bearingDegrees,
      speedMps: speedMps ?? this.speedMps,
      distanceAlongRouteMeters:
          distanceAlongRouteMeters ?? this.distanceAlongRouteMeters,
      remainingDistanceMeters:
          remainingDistanceMeters ?? this.remainingDistanceMeters,
      remainingDurationSeconds:
          remainingDurationSeconds ?? this.remainingDurationSeconds,
      currentStepIndex: currentStepIndex ?? this.currentStepIndex,
      currentStep: currentStep ?? this.currentStep,
      locationQuality: locationQuality ?? this.locationQuality,
      isArrived: isArrived ?? this.isArrived,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NavigationState &&
          runtimeType == other.runtimeType &&
          status == other.status &&
          routeRequestStatus == other.routeRequestStatus &&
          trackingStatus == other.trackingStatus &&
          activeRoute == other.activeRoute &&
          destination == other.destination &&
          rawFix == other.rawFix &&
          matchedPoint == other.matchedPoint &&
          bearingDegrees == other.bearingDegrees &&
          speedMps == other.speedMps &&
          distanceAlongRouteMeters == other.distanceAlongRouteMeters &&
          remainingDistanceMeters == other.remainingDistanceMeters &&
          remainingDurationSeconds == other.remainingDurationSeconds &&
          currentStepIndex == other.currentStepIndex &&
          currentStep == other.currentStep &&
          locationQuality == other.locationQuality &&
          isArrived == other.isArrived;

  @override
  int get hashCode => Object.hash(
        status,
        routeRequestStatus,
        trackingStatus,
        activeRoute,
        destination,
        rawFix,
        matchedPoint,
        bearingDegrees,
        speedMps,
        distanceAlongRouteMeters,
        remainingDistanceMeters,
        remainingDurationSeconds,
        currentStepIndex,
        currentStep,
        locationQuality,
        isArrived,
      );

  @override
  String toString() =>
      'NavigationState(status: $status, tracking: $trackingStatus, '
      'distRemaining: ${remainingDistanceMeters?.toStringAsFixed(0)}m, '
      'step: $currentStepIndex, arrived: $isArrived)';
}
