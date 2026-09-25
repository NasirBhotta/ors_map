import 'dart:async';
import 'dart:math';

import '../config/navigation_config.dart';
import '../errors/navigation_errors.dart';
import '../events/navigation_events.dart';
import '../location/location_source.dart';
import '../models/geo_point.dart';
import '../models/location_fix.dart';
import '../models/location_quality.dart';
import '../models/navigation_enums.dart';
import '../models/navigation_route.dart';
import '../models/navigation_state.dart';
import '../routing/route_provider.dart';
import '../tracking/freshness_monitor.dart';
import '../tracking/progress_tracker.dart';
import '../tracking/route_matcher.dart';
import '../tracking/route_metrics.dart';
import 'navigation_controller.dart';

/// Opaque ownership token captured before asynchronous operations.
final class _NavigationOwnership {
  final Object _owner;
  final int sessionId;
  final int routeRequestId;
  final int routeRevision;

  const _NavigationOwnership(
    this._owner,
    this.sessionId,
    this.routeRequestId,
    this.routeRevision,
  );
}

/// Concrete implementation of [NavigationController].
///
/// Orchestrates the navigation session lifecycle, location ingestion,
/// route matching, progress tracking, rerouting, and freshness monitoring.
class NavigationControllerImpl implements NavigationController {
  final RouteProvider routeProvider;
  final LocationSource locationSource;
  final NavigationConfig config;
  final DateTime Function() clock;

  final RouteMatcher _matcher = const RouteMatcher();
  final ProgressTracker _progressTracker = const ProgressTracker();
  late final FreshnessMonitor _freshnessMonitor;

  final Object _owner = Object();
  int _sessionId = 0;
  int _routeRequestId = 0;
  int _routeRevision = 0;
  bool _disposed = false;

  NavigationStatus _status = NavigationStatus.idle;
  RouteRequestStatus _requestStatus = RouteRequestStatus.idle;
  TrackingStatus _trackingStatus = TrackingStatus.unmatched;
  LocationFreshness _locationFreshness = LocationFreshness.unknown;

  NavigationRoute? _activeRoute;
  RouteMetrics? _routeMetrics;
  GeoPoint? _destination;

  LocationFix? _lastFix;
  DateTime? _lastUsableFixTimestamp;
  GeoPoint? _matchedPoint;

  double _lastBearing = 0.0;
  double? _measuredDistance;
  double? _remainingDistance;
  double? _remainingDuration;

  int _currentStepIndex = 0;
  int _lastAnnouncedStepIndex = -1;

  double _lastRouteDistanceMeters = 0.0;
  int _lastAcceptedRouteIndex = 0;
  MatcherMode _matcherMode = MatcherMode.reacquisition;
  int _offRouteCount = 0;
  int _consecutiveUnmatchedCount = 0;
  bool _isRerouting = false;
  DateTime? _startTime;

  StreamSubscription<LocationFix>? _locationSub;
  int _locationGeneration = 0;

  final _stateController = StreamController<NavigationState>.broadcast(sync: true);
  final _eventController = StreamController<NavigationEvent>.broadcast(sync: true);

  NavigationState _state = const NavigationState();

  NavigationControllerImpl({
    required this.routeProvider,
    required this.locationSource,
    this.config = const NavigationConfig(),
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now {
    config.validate();
    _freshnessMonitor = FreshnessMonitor(
      staleTimeout: config.freshness.staleTimeout,
      clock: this.clock,
      onFreshnessChanged: _onFreshnessChanged,
    );
  }

  @override
  NavigationState get state => _state;

  @override
  Stream<NavigationState> get states => _stateController.stream;

  @override
  Stream<NavigationEvent> get events => _eventController.stream;

  _NavigationOwnership _captureOwnership() => _NavigationOwnership(
        _owner,
        _sessionId,
        _routeRequestId,
        _routeRevision,
      );

  bool _isCurrent(_NavigationOwnership token) =>
      !_disposed &&
      identical(token._owner, _owner) &&
      token.sessionId == _sessionId &&
      token.routeRequestId == _routeRequestId &&
      token.routeRevision == _routeRevision;

  bool _ownsRequest(_NavigationOwnership token) =>
      !_disposed &&
      identical(token._owner, _owner) &&
      token.sessionId == _sessionId &&
      token.routeRequestId == _routeRequestId;

  /// Attaches the location source subscription if not already active.
  void attachLocationSource() {
    if (_disposed || _locationSub != null) return;
    final generation = ++_locationGeneration;

    _locationSub = locationSource.fixes.listen(
      (fix) {
        if (_disposed || generation != _locationGeneration) return;
        _onLocationFix(fix);
      },
      onError: (Object error, StackTrace stack) {
        if (!_disposed) {
          _eventController.add(
            NavigationErrorEvent(
              error: LocationUnavailableException(
                'Location stream error: $error',
                reason: LocationErrorReason.invalidData,
                cause: error,
              ),
            ),
          );
        }
      },
      onDone: () {
        if (!_disposed && generation == _locationGeneration) {
          _locationSub = null;
        }
      },
    );
  }

  @override
  Future<NavigationRoute> calculateRoute({
    required GeoPoint origin,
    required GeoPoint destination,
  }) async {
    if (_disposed) {
      throw const NavigationLifecycleException(
        'Cannot calculate route on disposed controller',
        reason: LifecycleErrorReason.sessionDisposed,
      );
    }

    try {
      return await routeProvider
          .calculateRoute(origin: origin, destination: destination)
          .timeout(config.rerouting.routeRequestTimeout);
    } on RouteException {
      rethrow;
    } on TimeoutException catch (e) {
      throw RouteException(
        'Route calculation timed out after ${config.rerouting.routeRequestTimeout.inSeconds}s',
        reason: RouteErrorReason.timeout,
        cause: e,
      );
    } catch (e) {
      throw RouteException(
        'Route calculation failed: $e',
        reason: RouteErrorReason.networkError,
        cause: e,
      );
    }
  }

  @override
  Future<void> startPreview({
    required NavigationRoute route,
    required GeoPoint destination,
  }) async {
    if (_disposed) {
      throw const NavigationLifecycleException(
        'Cannot start preview on disposed controller',
        reason: LifecycleErrorReason.sessionDisposed,
      );
    }

    _beginSession(destination: destination);
    _status = NavigationStatus.preview;
    _setRoute(route);
    _publishState();
  }

  @override
  Future<void> startNavigation({
    required NavigationRoute route,
    required GeoPoint destination,
  }) async {
    if (_disposed) {
      throw const NavigationLifecycleException(
        'Cannot start navigation on disposed controller',
        reason: LifecycleErrorReason.sessionDisposed,
      );
    }

    _beginSession(destination: destination);
    _status = NavigationStatus.navigating;
    _setRoute(route);
    _startTime = clock();

    attachLocationSource();
    _freshnessMonitor.start(() => _lastUsableFixTimestamp);
    _publishState();
  }

  void _beginSession({required GeoPoint destination}) {
    stopNavigation();
    _destination = destination;
    _status = NavigationStatus.starting;
    _publishState();
  }

  @override
  void stopNavigation() {
    if (_disposed) return;

    _freshnessMonitor.stop();
    _sessionId++;
    _routeRequestId++;
    _status = NavigationStatus.stopped;
    _requestStatus = RouteRequestStatus.idle;
    _activeRoute = null;
    _routeMetrics = null;
    _destination = null;
    _currentStepIndex = 0;
    _lastAcceptedRouteIndex = 0;
    _offRouteCount = 0;
    _consecutiveUnmatchedCount = 0;
    _lastRouteDistanceMeters = 0.0;
    _lastBearing = 0.0;
    _isRerouting = false;
    _startTime = null;
    _lastAnnouncedStepIndex = -1;
    _matchedPoint = null;
    _measuredDistance = null;
    _remainingDistance = null;
    _remainingDuration = null;
    _trackingStatus = TrackingStatus.unmatched;
    _matcherMode = MatcherMode.reacquisition;
    _lastUsableFixTimestamp = null;
    _locationFreshness = LocationFreshness.unknown;

    _publishState();
  }

  void _setRoute(NavigationRoute route) {
    _activeRoute = route;
    _routeMetrics = RouteMetrics.build(route);
    _routeRevision++;
    _requestStatus = RouteRequestStatus.idle;
    _isRerouting = false;

    _currentStepIndex = 0;
    _lastAcceptedRouteIndex = 0;
    _offRouteCount = 0;
    _consecutiveUnmatchedCount = 0;
    _lastRouteDistanceMeters = 0.0;
    _lastAnnouncedStepIndex = -1;
    _matchedPoint = null;
    _measuredDistance = 0.0;
    _remainingDistance = route.totalDistanceMeters;
    _remainingDuration = route.totalDurationSeconds;
    _trackingStatus = TrackingStatus.unmatched;
    _matcherMode = MatcherMode.reacquisition;
  }

  void _onFreshnessChanged(LocationFreshness updated) {
    if (_status != NavigationStatus.navigating || _disposed) return;
    if (_locationFreshness == updated) return;

    _locationFreshness = updated;
    _publishState();
  }

  void _onLocationFix(LocationFix fix) {
    if (_disposed || !_isUsableFix(fix)) return;

    final previous = _lastFix;
    if (previous != null && !fix.timestamp.isAfter(previous.timestamp)) {
      // Reject out-of-order or duplicate timestamp fix
      return;
    }

    final currentTime = clock();
    final fixAge = currentTime.difference(fix.timestamp);
    if (fixAge > config.freshness.staleTimeout) {
      // Fix was already stale on delivery: ignore without mutating state
      return;
    }

    final ownership = _captureOwnership();
    final route = _activeRoute;
    final metrics = _routeMetrics;

    if (_status != NavigationStatus.navigating || route == null || metrics == null) {
      _lastFix = fix;
      _lastUsableFixTimestamp = fix.timestamp;
      _locationFreshness = FreshnessMonitor.computeFreshness(
        now: currentTime,
        lastUsableFixTimestamp: fix.timestamp,
        staleTimeout: config.freshness.staleTimeout,
      );
      _matchedPoint = null;
      _trackingStatus = TrackingStatus.unmatched;
      _publishState();
      return;
    }

    if (!_isCurrent(ownership)) return;

    try {
      // Step 1: Candidate matching
      final candidate = _matcher.findCandidateMatch(
        fix: fix,
        route: route,
        metrics: metrics,
        mode: _matcherMode,
        lastBearing: _lastBearing,
        committedDistance: _lastRouteDistanceMeters,
        routeRevision: ownership.routeRevision,
      );

      // Step 2: Quality evaluation
      final accepted = _matcher.evaluateCandidate(
        fix: fix,
        candidate: candidate,
        lastRouteDistance: _lastRouteDistanceMeters,
        customOffRouteMeters: config.tracking.offRouteMeters,
      );

      // Step 3: Compute downstream values from accepted candidate
      final bearing = _progressTracker.resolveBearing(
        fix: fix,
        accepted: accepted,
        previousFix: previous,
        fallbackBearing: _lastBearing,
      );
      final totalRouteLength = metrics.totalLengthMeters;

      var remainingDistance = _remainingDistance;
      var remainingDuration = _remainingDuration;
      var distanceAlongRoute = _measuredDistance;
      var stepIndex = _currentStepIndex;
      final previousStepIndex = _currentStepIndex;
      var announcedStep = _lastAnnouncedStepIndex;
      var offRouteCount = _offRouteCount;
      var consecutiveUnmatched = _consecutiveUnmatchedCount;
      var shouldReroute = false;
      var arrived = false;
      int? upcomingInstructionIndex;

      if (accepted != null) {
        distanceAlongRoute = accepted.distanceAlongRouteMeters;
        remainingDistance = (totalRouteLength - distanceAlongRoute)
            .clamp(0.0, route.totalDistanceMeters);
        remainingDuration = route.totalDurationSeconds *
            (remainingDistance / max(totalRouteLength, 1.0)).clamp(0.0, 1.0);
        offRouteCount = 0;
        consecutiveUnmatched = 0;

        final maneuver = _progressTracker.advanceStep(
          fix: fix,
          route: route,
          metrics: metrics,
          accepted: accepted,
          currentStepIndex: stepIndex,
          lastAnnouncedStepIndex: announcedStep,
        );
        stepIndex = maneuver.stepIndex;
        upcomingInstructionIndex = maneuver.upcomingInstructionIndex;
        if (upcomingInstructionIndex != null) {
          announcedStep = upcomingInstructionIndex;
        }

        if (_destination != null) {
          arrived = _progressTracker.isDestinationReached(
            fix: fix,
            destination: _destination!,
            thresholdMeters: config.arrival.destinationRadiusMeters,
          );
        }
      } else {
        consecutiveUnmatched++;
        if (!_isRerouting &&
            _startTime != null &&
            currentTime.difference(_startTime!).inSeconds >=
                config.rerouting.minRerouteInterval.inSeconds) {
          offRouteCount++;
          if (offRouteCount >= 3) {
            offRouteCount = 0;
            shouldReroute = true;
          }
        }
      }

      // Recheck ownership before committing
      if (!_isCurrent(ownership) || !identical(_activeRoute, route)) return;

      _lastFix = fix;
      _lastUsableFixTimestamp = fix.timestamp;
      _locationFreshness = LocationFreshness.fresh;
      _freshnessMonitor.updateOnFix(LocationFreshness.fresh);

      _matchedPoint = accepted?.snappedPoint;
      _trackingStatus =
          accepted == null ? TrackingStatus.offRoute : TrackingStatus.onRoute;
      _measuredDistance = distanceAlongRoute;
      _remainingDistance = remainingDistance;
      _remainingDuration = remainingDuration;
      _currentStepIndex = stepIndex;
      _lastAnnouncedStepIndex = announcedStep;
      _offRouteCount = offRouteCount;
      _consecutiveUnmatchedCount = consecutiveUnmatched;
      _lastBearing = bearing;

      if (accepted != null) {
        _lastAcceptedRouteIndex =
            max(_lastAcceptedRouteIndex, accepted.closestRouteIndex);
        _lastRouteDistanceMeters =
            max(_lastRouteDistanceMeters, accepted.distanceAlongRouteMeters);
        _matcherMode = MatcherMode.tracking;
      } else if (consecutiveUnmatched >= RouteMatcher.reacquisitionThreshold) {
        _matcherMode = MatcherMode.reacquisition;
      }

      if (arrived) {
        _status = NavigationStatus.arrived;
        _routeRequestId++;
        _requestStatus = RouteRequestStatus.idle;
        _isRerouting = false;
      }

      _publishState();

      // Emit discrete events
      if (stepIndex != previousStepIndex && stepIndex < route.steps.length) {
        _eventController.add(
          InstructionChangedEvent(
            stepIndex: stepIndex,
            step: route.steps[stepIndex],
          ),
        );
      }

      if (arrived && _destination != null) {
        _eventController.add(
          DestinationReachedEvent(destination: _destination!),
        );
      }

      if (shouldReroute && config.rerouting.autoRerouteEnabled) {
        unawaited(_reroute(fix));
      }
    } catch (e) {
      _eventController.add(
        NavigationErrorEvent(
          error: LocationUnavailableException(
            'Error processing location fix: $e',
            reason: LocationErrorReason.invalidData,
            cause: e,
          ),
        ),
      );
    }
  }

  Future<void> _reroute(LocationFix fix) async {
    if (_isRerouting ||
        _status != NavigationStatus.navigating ||
        _destination == null ||
        _disposed) {
      return;
    }

    _isRerouting = true;
    _routeRequestId++;
    _requestStatus = RouteRequestStatus.rerouting;
    _publishState();

    final ownership = _captureOwnership();
    _eventController.add(RerouteStartedEvent(triggerFix: fix));

    try {
      final newRoute = await routeProvider
          .calculateRoute(
            origin: fix.coordinate,
            destination: _destination!,
          )
          .timeout(config.rerouting.routeRequestTimeout);

      if (!_ownsRequest(ownership) || _disposed) return;

      _setRoute(newRoute);
      _publishState();
    } catch (e) {
      if (_ownsRequest(ownership) && !_disposed) {
        _requestStatus = RouteRequestStatus.failed;
        _publishState();
        _eventController.add(
          RerouteFailedEvent(reason: 'Reroute calculation failed: $e'),
        );
      }
    } finally {
      if (_ownsRequest(ownership)) {
        _isRerouting = false;
      }
    }
  }

  bool _isUsableFix(LocationFix fix) =>
      fix.coordinate.latitude.isFinite &&
      fix.coordinate.latitude >= -90.0 &&
      fix.coordinate.latitude <= 90.0 &&
      fix.coordinate.longitude.isFinite &&
      fix.coordinate.longitude >= -180.0 &&
      fix.coordinate.longitude <= 180.0 &&
      fix.accuracyMeters.isFinite &&
      fix.accuracyMeters >= 0.0 &&
      fix.bearingDegrees.isFinite &&
      fix.speedMetersPerSecond.isFinite;

  void _publishState() {
    final fix = _lastFix;
    final steps = _activeRoute?.steps;
    final stepIndex = steps != null && _currentStepIndex < steps.length
        ? _currentStepIndex
        : null;

    _state = NavigationState(
      status: _status,
      routeRequestStatus: _requestStatus,
      trackingStatus: _trackingStatus,
      activeRoute: _activeRoute,
      destination: _destination,
      rawFix: fix,
      matchedPoint: _matchedPoint,
      bearingDegrees: _lastBearing,
      speedMps: fix == null ? 0.0 : max(0.0, fix.speedMetersPerSecond),
      distanceAlongRouteMeters: _measuredDistance,
      remainingDistanceMeters: _remainingDistance,
      remainingDurationSeconds: _remainingDuration,
      currentStepIndex: stepIndex,
      currentStep: stepIndex == null ? null : steps![stepIndex],
      locationQuality: LocationQuality(
        timestamp: _lastUsableFixTimestamp,
        accuracyMeters: fix?.accuracyMeters,
        freshness: _locationFreshness,
      ),
      isArrived: _status == NavigationStatus.arrived,
    );

    _stateController.add(_state);
  }

  @override
  void dispose() {
    if (_disposed) return;

    _freshnessMonitor.dispose();
    stopNavigation();
    _disposed = true;
    _locationGeneration++;
    _locationSub?.cancel();
    _locationSub = null;
    _status = NavigationStatus.disposed;
    _publishState();

    unawaited(_stateController.close());
    unawaited(_eventController.close());
  }
}
