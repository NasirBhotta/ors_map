import '../services/mapbox_route_service.dart';

enum NavigationStatus {
  idle,
  starting,
  preview,
  navigating,
  stopped,
  arrived,
  disposed,
}

enum RouteRequestStatus { idle, loading, rerouting, failed }

enum TrackingStatus { unmatched, onRoute, offRoute }

enum LocationFreshness {
  /// No fix has been received yet in this session.
  unknown,

  /// Fix timestamp is within the stale timeout; measurements are authoritative.
  fresh,

  /// A valid fix was received but no fresh fix has arrived within the stale
  /// timeout. Authoritative progress is frozen at the last known values.
  stale,

  /// The fix data itself was invalid (bad coordinates, timestamp already stale
  /// on delivery, impossible accuracy). Must not advance any authoritative state.
  unusable,
}

/// Coordinates in degrees, independent of a map SDK.
final class NavigationCoordinate {
  final double longitude;
  final double latitude;

  const NavigationCoordinate(this.longitude, this.latitude);
}

final class LocationQuality {
  final DateTime? timestamp;
  final double? accuracyMeters;
  final LocationFreshness freshness;

  const LocationQuality({
    this.timestamp,
    this.accuracyMeters,
    this.freshness = LocationFreshness.unknown,
  });

  /// Age of the last fix from the perspective of [now]. Returns null when there
  /// is no timestamp (i.e. no fix received yet).
  Duration? age(DateTime now) {
    final ts = timestamp;
    if (ts == null) return null;
    final a = now.difference(ts);
    return a.isNegative ? Duration.zero : a;
  }
}

/// A measured snapshot. No predicted/display position belongs in this state.
/// LocationQuality.freshness is set by the freshness policy in the service.
/// Stale state means authoritative measured progress is frozen at last-known
/// values; the vehicle display may continue briefly until the prediction
/// horizon is reached.
final class NavigationState {
  final int sessionId;
  final NavigationStatus status;
  final int routeRevision;
  final MapboxRouteResult? activeRoute;
  final NavigationCoordinate? destination;
  final RouteRequestStatus routeRequestStatus;
  final NavigationCoordinate? rawLocation;
  final NavigationCoordinate? matchedLocation;
  final double bearing;
  final double speedMetersPerSecond;
  final double? distanceAlongRouteMeters;
  final double? remainingDistanceMeters;
  final double? remainingDurationSeconds;
  final int? currentStepIndex;
  final MapboxStep? currentStep;
  final TrackingStatus trackingStatus;
  final LocationQuality locationQuality;
  final bool arrived;

  const NavigationState({
    required this.sessionId,
    required this.status,
    required this.routeRevision,
    this.activeRoute,
    this.destination,
    this.routeRequestStatus = RouteRequestStatus.idle,
    this.rawLocation,
    this.matchedLocation,
    this.bearing = 0,
    this.speedMetersPerSecond = 0,
    this.distanceAlongRouteMeters,
    this.remainingDistanceMeters,
    this.remainingDurationSeconds,
    this.currentStepIndex,
    this.currentStep,
    this.trackingStatus = TrackingStatus.unmatched,
    this.locationQuality = const LocationQuality(),
    this.arrived = false,
  });
}
