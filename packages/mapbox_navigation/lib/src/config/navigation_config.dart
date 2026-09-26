import 'package:meta/meta.dart';
import '../errors/navigation_errors.dart';

/// Configuration for route corridor tracking and deviation detection.
@immutable
final class TrackingConfig {
  /// Distance from the route in meters beyond which a location fix is marked off-route.
  final double offRouteMeters;

  const TrackingConfig({
    this.offRouteMeters = 80.0,
  }) : assert(offRouteMeters > 0.0, 'offRouteMeters must be positive');

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TrackingConfig &&
          runtimeType == other.runtimeType &&
          offRouteMeters == other.offRouteMeters;

  @override
  int get hashCode => offRouteMeters.hashCode;

  @override
  String toString() => 'TrackingConfig(offRoute: ${offRouteMeters}m)';
}

/// Configuration for destination arrival detection.
@immutable
final class ArrivalConfig {
  /// Distance in meters from destination within which arrival is triggered.
  final double destinationRadiusMeters;

  const ArrivalConfig({
    this.destinationRadiusMeters = 30.0,
  }) : assert(destinationRadiusMeters > 0.0, 'destinationRadiusMeters must be positive');

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ArrivalConfig &&
          runtimeType == other.runtimeType &&
          destinationRadiusMeters == other.destinationRadiusMeters;

  @override
  int get hashCode => destinationRadiusMeters.hashCode;

  @override
  String toString() => 'ArrivalConfig(radius: ${destinationRadiusMeters}m)';
}

/// Configuration for GPS timeliness and staleness timeouts.
@immutable
final class FreshnessConfig {
  /// Time without a fresh GPS fix before navigation progress is frozen.
  final Duration staleTimeout;

  const FreshnessConfig({
    this.staleTimeout = const Duration(seconds: 5),
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FreshnessConfig &&
          runtimeType == other.runtimeType &&
          staleTimeout == other.staleTimeout;

  @override
  int get hashCode => staleTimeout.hashCode;

  @override
  String toString() => 'FreshnessConfig(staleTimeout: ${staleTimeout.inSeconds}s)';
}

/// Configuration for automated off-route recalculation.
@immutable
final class ReroutingConfig {
  /// Whether the navigation engine automatically recalculates routes when off-route.
  final bool autoRerouteEnabled;

  /// Minimum interval between consecutive automatic reroute requests.
  final Duration minRerouteInterval;

  /// Maximum time allowed for route network requests before timing out.
  final Duration routeRequestTimeout;

  const ReroutingConfig({
    this.autoRerouteEnabled = true,
    this.minRerouteInterval = const Duration(seconds: 8),
    this.routeRequestTimeout = const Duration(seconds: 15),
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ReroutingConfig &&
          runtimeType == other.runtimeType &&
          autoRerouteEnabled == other.autoRerouteEnabled &&
          minRerouteInterval == other.minRerouteInterval &&
          routeRequestTimeout == other.routeRequestTimeout;

  @override
  int get hashCode => Object.hash(autoRerouteEnabled, minRerouteInterval, routeRequestTimeout);

  @override
  String toString() =>
      'ReroutingConfig(enabled: $autoRerouteEnabled, minInterval: ${minRerouteInterval.inSeconds}s, '
      'timeout: ${routeRequestTimeout.inSeconds}s)';
}

/// Root configuration for a navigation session.
@immutable
final class NavigationConfig {
  final TrackingConfig tracking;
  final ArrivalConfig arrival;
  final FreshnessConfig freshness;
  final ReroutingConfig rerouting;

  const NavigationConfig({
    this.tracking = const TrackingConfig(),
    this.arrival = const ArrivalConfig(),
    this.freshness = const FreshnessConfig(),
    this.rerouting = const ReroutingConfig(),
  });

  /// Validates configuration parameters and throws [InvalidConfigurationException] if invalid.
  void validate() {
    if (tracking.offRouteMeters <= 0.0 || !tracking.offRouteMeters.isFinite) {
      throw const InvalidConfigurationException('offRouteMeters must be positive');
    }
    if (arrival.destinationRadiusMeters <= 0.0 || !arrival.destinationRadiusMeters.isFinite) {
      throw const InvalidConfigurationException('destinationRadiusMeters must be positive');
    }
    if (freshness.staleTimeout.inMicroseconds <= 0) {
      throw const InvalidConfigurationException('staleTimeout must be positive');
    }
    if (rerouting.minRerouteInterval.inMicroseconds < 0) {
      throw const InvalidConfigurationException('minRerouteInterval must be non-negative');
    }
    if (rerouting.routeRequestTimeout.inMicroseconds <= 0) {
      throw const InvalidConfigurationException('routeRequestTimeout must be positive');
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NavigationConfig &&
          runtimeType == other.runtimeType &&
          tracking == other.tracking &&
          arrival == other.arrival &&
          freshness == other.freshness &&
          rerouting == other.rerouting;

  @override
  int get hashCode => Object.hash(tracking, arrival, freshness, rerouting);

  @override
  String toString() =>
      'NavigationConfig(tracking: $tracking, arrival: $arrival, '
      'freshness: $freshness, rerouting: $rerouting)';
}
