import '../models/location_fix.dart';

/// An abstract interface providing a stream of normalized [LocationFix] updates.
///
/// Consumers can implement this interface for custom GPS sources, simulator replay,
/// or platform vehicle integration (e.g. CarPlay, Android Auto).
abstract interface class LocationSource {
  /// Continuous stream of incoming GPS location fixes.
  Stream<LocationFix> get fixes;
}
