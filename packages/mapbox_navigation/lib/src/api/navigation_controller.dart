import '../config/navigation_config.dart';
import '../events/navigation_events.dart';
import '../location/location_source.dart';
import '../models/geo_point.dart';
import '../models/navigation_route.dart';
import '../models/navigation_state.dart';
import '../routing/route_provider.dart';
import 'navigation_controller_impl.dart';

/// Abstract contract defining the public interface for the navigation engine controller.
///
/// Coordinates route calculation, location fix matching, progress tracking, and session lifecycle.
abstract interface class NavigationController {
  /// Creates a default [NavigationController] instance with the given dependencies and configuration.
  factory NavigationController({
    required RouteProvider routeProvider,
    required LocationSource locationSource,
    NavigationConfig config,
    DateTime Function()? clock,
  }) = NavigationControllerImpl;

  /// Current authoritative snapshot of the navigation session.
  NavigationState get state;

  /// Continuous stream of authoritative navigation state updates.
  Stream<NavigationState> get states;

  /// Stream of discrete, transient navigation events.
  Stream<NavigationEvent> get events;

  /// Calculates a route between [origin] and [destination] using the configured route provider.
  ///
  /// Throws [RouteException] if route calculation fails or times out.
  /// Throws [NavigationLifecycleException] if called after [dispose].
  Future<NavigationRoute> calculateRoute({
    required GeoPoint origin,
    required GeoPoint destination,
  });

  /// Starts a route preview session without initiating live GPS matching.
  ///
  /// Updates [state.status] to [NavigationStatus.preview] and publishes initial route geometry.
  /// Throws [NavigationLifecycleException] if called after [dispose].
  Future<void> startPreview({
    required NavigationRoute route,
    required GeoPoint destination,
  });

  /// Starts active turn-by-turn navigation with live GPS tracking and progress updates.
  ///
  /// Attaches to [locationSource], monitors fix freshness, advances maneuvers, and
  /// triggers automatic rerouting upon persistent corridor deviation.
  /// Throws [NavigationLifecycleException] if called after [dispose].
  Future<void> startNavigation({
    required NavigationRoute route,
    required GeoPoint destination,
  });

  /// Stops the active navigation session and returns the controller to idle status.
  ///
  /// Clears active tracking metrics, resets session state, and stops the freshness monitor.
  /// Safe and idempotent to call multiple times.
  void stopNavigation();

  /// Immediately re-evaluates GPS fix freshness against real elapsed wall-clock time.
  ///
  /// Useful upon app lifecycle resume (e.g. background to foreground) to instantly detect
  /// whether the last fix aged past [NavigationConfig.freshness.staleTimeout] without waiting
  /// for periodic timer ticks.
  void evaluateFreshness();

  /// Cancels internal timers, unsubscribes location feeds, closes streams, and marks status as disposed.
  ///
  /// Once disposed, all subsequent method calls (except [dispose] itself) throw [NavigationLifecycleException].
  void dispose();
}
