import 'package:meta/meta.dart';

/// Base class for all navigation-related exceptions.
@immutable
sealed class NavigationException implements Exception {
  /// A descriptive message explaining the error condition.
  final String message;

  /// Underlying cause or original error, if available.
  final Object? cause;

  const NavigationException(this.message, {this.cause});

  @override
  String toString() =>
      cause != null ? '$runtimeType: $message (cause: $cause)' : '$runtimeType: $message';
}

/// Categorized failure reasons for route calculation.
enum RouteErrorReason {
  /// Network connectivity failure or unreachable endpoint.
  networkError,

  /// Origin or destination coordinates are invalid or out of bounds.
  invalidCoordinates,

  /// Routing service found no feasible route between points.
  noRouteFound,

  /// Access token or API key is missing, expired, or unauthorized.
  missingOrInvalidCredentials,

  /// The routing server returned an internal 5xx error.
  serverError,

  /// The route calculation request timed out.
  timeout,

  /// The route request was canceled or superseded by a newer request.
  canceled,
}

/// Exception thrown when calculating or fetching a navigation route fails.
@immutable
final class RouteException extends NavigationException {
  final RouteErrorReason reason;

  const RouteException(
    super.message, {
    required this.reason,
    super.cause,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RouteException &&
          runtimeType == other.runtimeType &&
          message == other.message &&
          reason == other.reason;

  @override
  int get hashCode => Object.hash(message, reason);
}

/// Categorized failure reasons for GPS location availability.
enum LocationErrorReason {
  /// Location permissions were denied by the user.
  permissionDenied,

  /// Location services (GPS) are disabled on the device.
  serviceDisabled,

  /// No location update was received within the expected window.
  timeout,

  /// Location data was corrupted, impossible, or unparseable.
  invalidData,
}

/// Exception thrown when location fixes are unavailable or interrupted.
@immutable
final class LocationUnavailableException extends NavigationException {
  final LocationErrorReason reason;

  const LocationUnavailableException(
    super.message, {
    required this.reason,
    super.cause,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LocationUnavailableException &&
          runtimeType == other.runtimeType &&
          message == other.message &&
          reason == other.reason;

  @override
  int get hashCode => Object.hash(message, reason);
}

/// Exception thrown when an invalid configuration is provided to the navigation engine.
@immutable
final class InvalidConfigurationException extends NavigationException {
  const InvalidConfigurationException(super.message, {super.cause});
}

/// Exception thrown when an invalid navigation route is provided.
@immutable
final class InvalidRouteException extends NavigationException {
  const InvalidRouteException(super.message, {super.cause});
}

/// Categorized lifecycle violations.
enum LifecycleErrorReason {
  /// Attempted an operation while already in an active navigation session.
  alreadyNavigating,

  /// Attempted an operation that requires an active navigation session.
  notNavigating,

  /// Navigation controller or session has already been disposed.
  sessionDisposed,

  /// Illegal lifecycle transition attempted.
  invalidTransition,
}

/// Exception thrown when a navigation session method is invoked in an invalid state.
@immutable
final class NavigationLifecycleException extends NavigationException {
  final LifecycleErrorReason reason;

  const NavigationLifecycleException(
    super.message, {
    required this.reason,
    super.cause,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NavigationLifecycleException &&
          runtimeType == other.runtimeType &&
          message == other.message &&
          reason == other.reason;

  @override
  int get hashCode => Object.hash(message, reason);
}
