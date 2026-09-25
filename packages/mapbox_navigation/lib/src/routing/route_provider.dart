import '../errors/navigation_errors.dart';
import '../models/geo_point.dart';
import '../models/navigation_route.dart';

/// An abstract interface for calculating navigation routes between geographic coordinates.
///
/// Implementations must resolve a feasible [NavigationRoute] or throw a typed [RouteException].
abstract interface class RouteProvider {
  /// Calculates a turn-by-turn navigation route from [origin] to [destination].
  ///
  /// Throws a [RouteException] with an appropriate [RouteErrorReason] if calculation fails
  /// (e.g. network failure, invalid coordinates, missing authentication, timeout).
  Future<NavigationRoute> calculateRoute({
    required GeoPoint origin,
    required GeoPoint destination,
  });
}
