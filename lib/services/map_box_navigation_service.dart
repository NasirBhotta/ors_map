// meri file
import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;

import 'mapbox_route_service.dart';
import '../models/navigation_state.dart';
import 'navigation_location_source.dart';

typedef NavigationRouteFetcher =
    Future<MapboxRouteResult?> Function({
      required double fromLng,
      required double fromLat,
      required double toLng,
      required double toLat,
    });

/// Opaque ownership captured before asynchronous work. Tokens are service-local.
final class NavigationOwnership {
  final Object _owner;
  final int sessionId;
  final int routeRequestId;
  final int routeRevision;

  const NavigationOwnership._(
    this._owner,
    this.sessionId,
    this.routeRequestId,
    this.routeRevision,
  );
}

// ---------------------------------------------------------------------------
// Internal matcher mode — drives search-window width.
// ---------------------------------------------------------------------------
enum _MatcherMode {
  /// Normal tracking: prefer a local forward search window.
  tracking,

  /// Reacquisition: search the entire route; accept the globally best match.
  reacquisition,
}

class MapboxNavigationService {
  final NavigationLocationSource locationSource;
  StreamSubscription<NavigationFix>? _locationSub;
  int _locationGeneration = 0;

  /// Repeated calls, including after a style reload, keep the same subscription.
  void attachLocationSource() {
    if (_disposed || _locationSub != null) return;
    final generation = ++_locationGeneration;
    _locationSub = locationSource.fixes.listen(
      (fix) {
        if (_disposed || generation != _locationGeneration) return;
        _onLocationUpdate(fix);
      },
      onError: (Object error, StackTrace stackTrace) {
        // A failed fix leaves the last measured state intact. The stream may
        // recover and deliver a later fix; freshness policy is a later step.
      },
      onDone: () {
        if (!_disposed && generation == _locationGeneration) {
          _locationSub = null;
        }
      },
    );
  }

  final Object _owner = Object();
  int _sessionId = 0;
  int _routeRequestId = 0;
  int _routeRevision = 0;
  bool _disposed = false;
  NavigationStatus _status = NavigationStatus.idle;
  RouteRequestStatus _requestStatus = RouteRequestStatus.idle;
  NavigationCoordinate? _matchedLocation;
  double? _measuredDistance;
  double? _remainingDistance;
  double? _remainingDuration;
  TrackingStatus _trackingStatus = TrackingStatus.unmatched;
  final _states = StreamController<NavigationState>.broadcast();
  NavigationState _state = const NavigationState(
    sessionId: 0,
    status: NavigationStatus.idle,
    routeRevision: 0,
  );

  NavigationState get state => _state;
  Stream<NavigationState> get states => _states.stream;

  NavigationOwnership captureOwnership() => NavigationOwnership._(
    _owner,
    _sessionId,
    _routeRequestId,
    _routeRevision,
  );

  bool _ownsRequest(NavigationOwnership ownership) =>
      !_disposed &&
      identical(ownership._owner, _owner) &&
      ownership.sessionId == _sessionId &&
      ownership.routeRequestId == _routeRequestId &&
      (_status == NavigationStatus.starting ||
          _status == NavigationStatus.preview ||
          _status == NavigationStatus.navigating);

  bool isCurrent(NavigationOwnership ownership) =>
      _ownsRequest(ownership) && ownership.routeRevision == _routeRevision;

  /// Starts ownership without opening GPS. startNavigation uses this same path.
  void beginSession({required NavigationCoordinate destination}) {
    if (_disposed) throw StateError('Navigation service is disposed');
    stopNavigation();
    _destination = mapbox.Position(destination.longitude, destination.latitude);
    _status = NavigationStatus.starting;
    _publishState();
  }

  NavigationOwnership beginRouteRequest({bool rerouting = false}) {
    if (_disposed ||
        (_status != NavigationStatus.starting &&
            _status != NavigationStatus.preview &&
            _status != NavigationStatus.navigating)) {
      throw StateError('No active navigation session');
    }
    _routeRequestId++;
    _isRerouting = rerouting;
    _requestStatus =
        rerouting ? RouteRequestStatus.rerouting : RouteRequestStatus.loading;
    _publishState();
    return captureOwnership();
  }

  /// A token can commit only once: commitment advances the route revision.
  bool commitRoute(
    NavigationOwnership ownership,
    MapboxRouteResult route, {
    NavigationStatus status = NavigationStatus.navigating,
  }) {
    if (!isCurrent(ownership)) return false;
    final metrics = _buildRouteMetrics(route);
    _setRoute(route, metrics);
    _routeRevision++;
    _requestStatus = RouteRequestStatus.idle;
    _isRerouting = false;
    _status = status;
    _publishState();
    return true;
  }

  /// Starts a destination selection. A later selection invalidates this request
  /// before its response can install or draw a route.
  Future<NavigationOwnership?> requestPreviewRoute({
    required NavigationCoordinate origin,
    required NavigationCoordinate destination,
  }) => _requestSelectedRoute(
    origin: origin,
    destination: destination,
    status: NavigationStatus.preview,
  );

  /// Fetches a route from the current position and activates it on commitment.
  Future<NavigationOwnership?> requestNavigationRoute({
    required NavigationCoordinate origin,
    required NavigationCoordinate destination,
  }) => _requestSelectedRoute(
    origin: origin,
    destination: destination,
    status: NavigationStatus.navigating,
  );

  Future<NavigationOwnership?> _requestSelectedRoute({
    required NavigationCoordinate origin,
    required NavigationCoordinate destination,
    required NavigationStatus status,
  }) async {
    beginSession(destination: destination);
    final ownership = beginRouteRequest();
    try {
      final route = await _fetchRoute(origin, destination);
      if (!isCurrent(ownership)) return null;
      if (route == null || route.coordinates.length < 2) {
        _requestStatus = RouteRequestStatus.failed;
        _publishState();
        return null;
      }
      if (!commitRoute(ownership, route, status: status)) return null;
      if (status == NavigationStatus.navigating) attachLocationSource();
      return captureOwnership();
    } catch (error) {
      if (isCurrent(ownership)) {
        _requestStatus = RouteRequestStatus.failed;
        _publishState();
      }
      return null;
    }
  }

  Future<MapboxRouteResult?> _fetchRoute(
    NavigationCoordinate origin,
    NavigationCoordinate destination,
  ) => routeFetcher(
    fromLng: origin.longitude,
    fromLat: origin.latitude,
    toLng: destination.longitude,
    toLat: destination.latitude,
  ).timeout(routeRequestTimeout);

  void _publishState() {
    final position = _lastPosition;
    final steps = _route?.steps;
    final stepIndex =
        steps != null && _currentStepIndex < steps.length
            ? _currentStepIndex
            : null;
    _state = NavigationState(
      sessionId: _sessionId,
      status: _status,
      routeRevision: _routeRevision,
      activeRoute: _route,
      destination:
          _destination == null
              ? null
              : NavigationCoordinate(
                _destination!.lng.toDouble(),
                _destination!.lat.toDouble(),
              ),
      routeRequestStatus: _requestStatus,
      rawLocation:
          position == null
              ? null
              : NavigationCoordinate(position.longitude, position.latitude),
      matchedLocation: _matchedLocation,
      bearing: _lastBearing,
      speedMetersPerSecond:
          position == null ? 0 : max(0, position.speedMetersPerSecond),
      distanceAlongRouteMeters: _measuredDistance,
      remainingDistanceMeters: _remainingDistance,
      remainingDurationSeconds: _remainingDuration,
      currentStepIndex: stepIndex,
      currentStep: stepIndex == null ? null : steps![stepIndex],
      trackingStatus: _trackingStatus,
      locationQuality: LocationQuality(
        timestamp: _lastUsableFixTimestamp,
        accuracyMeters: position?.accuracy,
        freshness: _locationFreshness,
      ),
      arrived: _status == NavigationStatus.arrived,
    );
    _states.add(_state);
  }

  MapboxRouteResult? _route;
  mapbox.Position? _destination;

  List<double> _routeDistanceAtIndex = const [];
  List<int> _stepEndIndices = const [];

  // ---------------------------------------------------------------------------
  // Step/announcement tracking
  // ---------------------------------------------------------------------------
  static const _voiceLeadSeconds = 4.0;
  int _lastAnnouncedStepIndex = -1;
  int _currentStepIndex = 0;

  // ---------------------------------------------------------------------------
  // Committed route-progress state — authoritative, never mutated by a
  // candidate that has not been accepted.
  // ---------------------------------------------------------------------------
  /// The vertex index of the last accepted match (≥ this value advances step).
  int _lastAcceptedRouteIndex = 0;

  /// The continuous distanceAlongRoute of the last accepted match.
  double _lastRouteDistanceMeters = 0;

  // ---------------------------------------------------------------------------
  // Off-route evidence
  // ---------------------------------------------------------------------------
  int _offRouteCount = 0;

  // ---------------------------------------------------------------------------
  // Bearing / visual state
  // ---------------------------------------------------------------------------
  double _lastBearing = 0;

  // ---------------------------------------------------------------------------
  // Reacquisition mode
  // ---------------------------------------------------------------------------
  _MatcherMode _matcherMode = _MatcherMode.reacquisition;

  // ---------------------------------------------------------------------------
  // Rerouting guard
  // ---------------------------------------------------------------------------
  bool _isRerouting = false;

  // ---------------------------------------------------------------------------
  // Session clock & last position
  // ---------------------------------------------------------------------------
  DateTime? _startTime;
  NavigationFix? _lastPosition;

  // ---------------------------------------------------------------------------
  // Thresholds / constants
  // ---------------------------------------------------------------------------

  /// Base cross-track threshold to be considered on-route (meters).
  static const _offRouteMeters = 80.0;

  /// Cap on the accuracy-expanded on-route corridor (meters).
  /// Prevents poor GPS accuracy from making the corridor arbitrarily wide.
  /// Without this cap, accuracy=200m → corridor=500m, which is clearly wrong.
  static const _accuracyCapMeters = 150.0;

  /// Step-advance / announcement lead (meters).
  static const _stepAdvanceMeters = 35.0;

  /// Route-bearing lookahead (meters along route).
  static const _lookAheadMeters = 5.0;

  /// A candidate that is this many meters *behind* the committed progress is
  /// treated as backward movement (Phase-1 policy: clamp, not rewind).
  /// Must be > 0.  Chosen conservatively: GPS jitter radius is typically <10 m.
  static const _maxBackwardMeters = 25.0;

  /// A backward relocation larger than this triggers reacquisition instead of
  /// clamping, because it is more likely a legitimate large reposition.
  static const _largeBackwardMeters = 100.0;

  /// Minimum forward search window in tracking mode (meters ahead of committed
  /// progress).  Keeps the window large enough for normal driving.
  static const _minForwardSnapWindowMeters = 90.0;

  /// Multiplier on speed (m/s) to scale the forward search window (seconds).
  static const _forwardWindowSpeedSeconds = 8.0;

  /// Multiplier on GPS accuracy to contribute to forward window.
  static const _forwardWindowAccuracyFactor = 2.0;

  /// Heading is only used as a signal when speed exceeds this threshold.
  /// Below this speed the heading is noisy / meaningless.
  static const _headingMinSpeedMps = 1.5;

  /// Maximum heading-consistency penalty weight in candidate scoring.
  /// 0 = heading is ignored entirely; 1 = heading fully determines outcome.
  static const _headingMaxWeight = 0.3;

  /// A heading delta (degrees) beyond this fully penalises the candidate.
  static const _headingFullPenaltyDeg = 90.0;

  /// Number of consecutive unaccepted fixes before entering reacquisition.
  static const _reacquisitionThreshold = 3;

  /// Consecutive unaccepted fixes counter (separate from off-route rerouting).
  int _consecutiveUnmatchedCount = 0;

  // ---------------------------------------------------------------------------
  // Freshness / staleness
  // ---------------------------------------------------------------------------

  /// Timestamp of the last fix that passed _isUsableFix AND whose own timestamp
  /// was within staleLocationTimeout at the moment of delivery.
  /// This is the authoritative "last known fresh fix" time.
  DateTime? _lastUsableFixTimestamp;

  /// Current freshness, kept in a field so _onFreshnessTimerTick can detect
  /// transitions and publish a state update only when it actually changes.
  LocationFreshness _locationFreshness = LocationFreshness.unknown;

  /// Periodic 1-second timer that detects staleness even when no GPS arrives.
  Timer? _freshnessTimer;

  final double? Function()? compassHeadingProvider;
  final NavigationRouteFetcher routeFetcher;
  final Duration routeRequestTimeout;
  final DateTime Function() now;

  /// How long after the last usable fix timestamp the state is considered stale.
  /// Configurable for future package use. Default 5 s is a conservative value
  /// that handles normal 1-Hz GPS and brief tunnel/building occlusion.
  final Duration staleLocationTimeout;

  /// Maximum time the display prediction is allowed to continue without a fresh
  /// GPS fix. Exposed so the presentation layer can read it without coupling to
  /// the service internals. Defaults to staleLocationTimeout.
  Duration get predictionHorizon => staleLocationTimeout;

  final void Function(
    NavigationFix position,
    double speedKmh,
    double bearing,
    mapbox.Position visualPosition,
    double? visualDistanceAlongRouteMeters,
  )?
  onLocationUpdate;
  final void Function(int stepIndex, MapboxStep step)? onStepChanged;
  final void Function(int stepIndex, MapboxStep step)? onUpcomingInstruction;
  final void Function(String message)? onReroute;
  final Future<void> Function(
    MapboxRouteResult route,
    NavigationFix currentPosition,
  )?
  onRouteChanged;
  final Future<void> Function(
    MapboxRouteResult route,
    int closestRouteIndex,
    double remainingDistanceMeters,
    double remainingDurationSeconds,
  )?
  onRouteProgress;
  final void Function()? onDestinationReached;

  MapboxNavigationService({
    NavigationLocationSource? locationSource,
    NavigationRouteFetcher? routeFetcher,
    this.routeRequestTimeout = const Duration(seconds: 15),
    this.staleLocationTimeout = const Duration(seconds: 5),
    DateTime Function()? now,
    this.compassHeadingProvider,
    this.onLocationUpdate,
    this.onStepChanged,
    this.onReroute,
    this.onRouteChanged,
    this.onRouteProgress,
    this.onDestinationReached,
    this.onUpcomingInstruction,
  }) : locationSource =
           locationSource ?? const GeolocatorNavigationLocationSource(),
       routeFetcher = routeFetcher ?? MapboxRouteService.getRoute,
       now = now ?? DateTime.now;

  void startNavigation({
    required MapboxRouteResult route,
    required NavigationCoordinate destination,
  }) {
    beginSession(destination: destination);
    commitRoute(captureOwnership(), route);
    _startTime = now();

    attachLocationSource();
    // Start the periodic freshness check. This runs even when GPS is silent,
    // detecting staleness from elapsed wall time alone.
    _startFreshnessTimer();
  }

  void stopNavigation() {
    if (_disposed) return;
    _cancelFreshnessTimer();
    _sessionId++;
    _routeRequestId++;
    _status = NavigationStatus.stopped;
    _requestStatus = RouteRequestStatus.idle;
    _route = null;
    _destination = null;
    _routeDistanceAtIndex = const [];
    _stepEndIndices = const [];
    _currentStepIndex = 0;
    _lastAcceptedRouteIndex = 0;
    _offRouteCount = 0;
    _consecutiveUnmatchedCount = 0;
    _lastRouteDistanceMeters = 0;
    _lastBearing = 0;
    _isRerouting = false;
    _startTime = null;
    _lastAnnouncedStepIndex = -1;
    _matchedLocation = null;
    _measuredDistance = null;
    _remainingDistance = null;
    _remainingDuration = null;
    _trackingStatus = TrackingStatus.unmatched;
    _matcherMode = _MatcherMode.reacquisition;
    _lastUsableFixTimestamp = null;
    _locationFreshness = LocationFreshness.unknown;
    _publishState();
  }

  void setFollowModeEnabled(bool enabled) {}

  void _setRoute(MapboxRouteResult route, _RouteMetrics metrics) {
    _route = route;
    _routeDistanceAtIndex = metrics.distances;
    _stepEndIndices = metrics.stepEndIndices;
    _currentStepIndex = 0;
    _lastAcceptedRouteIndex = 0;
    _offRouteCount = 0;
    _consecutiveUnmatchedCount = 0;
    _lastRouteDistanceMeters = 0;
    _lastAnnouncedStepIndex = -1;
    _startTime = now();
    _matchedLocation = null;
    _measuredDistance = 0;
    _remainingDistance = route.distanceMeters;
    _remainingDuration = route.durationSeconds;
    _trackingStatus = TrackingStatus.unmatched;
    // A fresh route always starts in reacquisition mode so the first fix
    // searches the whole route rather than a stale narrow window.
    _matcherMode = _MatcherMode.reacquisition;
    // Freshness is unknown at route start — no fix has been received yet for
    // this session. The freshness timer starts once navigation is navigating.
    // Do NOT reset _lastUsableFixTimestamp here if a fix was already received
    // during a reroute — the existing fix timestamp carries over.
    if (_locationFreshness == LocationFreshness.unknown) {
      // Already unknown — leave it.
    } else {
      // A route change while navigating: preserve the fix timestamp (the GPS
      // hasn't changed) but let _computeFreshness re-evaluate on next publish.
    }
  }

  // ---------------------------------------------------------------------------
  // Freshness timer — fires even when no GPS event arrives.
  // ---------------------------------------------------------------------------

  /// Starts (or restarts) the 1-second periodic freshness check.
  ///
  /// Frequency rationale: freshness does not need a 16 ms render tick. A 1-second
  /// check is more than sufficient to detect a 5-second stale timeout within
  /// 1 extra second of precision, with minimal CPU overhead.
  void _startFreshnessTimer() {
    _freshnessTimer?.cancel();
    final sessionId = _sessionId;
    _freshnessTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      // Ownership check: if the session changed (stopNavigation / new session)
      // this timer fires for a dead session. Cancel and do nothing.
      if (_disposed || _sessionId != sessionId) {
        _cancelFreshnessTimer();
        return;
      }
      _onFreshnessTimerTick();
    });
  }

  void _cancelFreshnessTimer() {
    _freshnessTimer?.cancel();
    _freshnessTimer = null;
  }

  /// Periodic tick — recalculates freshness and publishes a state update ONLY
  /// when freshness has actually changed. This prevents flooding the stream with
  /// identical snapshots.
  void _onFreshnessTimerTick() {
    if (_status != NavigationStatus.navigating || _disposed) return;
    final computed = _computeFreshness(now());
    if (computed == _locationFreshness) return; // no change — skip publish
    _locationFreshness = computed;
    _publishState();
  }

  /// Pure function: compute LocationFreshness from the current clock.
  ///
  /// Rules:
  /// - No usable fix timestamp → unknown
  /// - age ≤ staleLocationTimeout → fresh
  /// - age > staleLocationTimeout → stale
  ///
  /// Unusable is NOT returned here — unusable describes an individual incoming
  /// fix, not the session state. After an unusable fix the previous freshness
  /// value is preserved.
  LocationFreshness _computeFreshness(DateTime currentTime) {
    final ts = _lastUsableFixTimestamp;
    if (ts == null) return LocationFreshness.unknown;
    final age = currentTime.difference(ts);
    return age <= staleLocationTimeout
        ? LocationFreshness.fresh
        : LocationFreshness.stale;
  }

  _RouteMetrics _buildRouteMetrics(MapboxRouteResult route) {
    final distances = <double>[0];
    for (var i = 1; i < route.coordinates.length; i++) {
      final prev = route.coordinates[i - 1];
      final current = route.coordinates[i];
      distances.add(
        distances.last + _haversine(prev[1], prev[0], current[1], current[0]),
      );
    }

    final stepEndIndices = <int>[];
    var distanceToStepEnd = 0.0;
    for (final step in route.steps) {
      distanceToStepEnd += step.distance;
      stepEndIndices.add(_indexForRouteDistance(distances, distanceToStepEnd));
    }
    return _RouteMetrics(
      List<double>.unmodifiable(distances),
      List<int>.unmodifiable(stepEndIndices),
    );
  }

  int _indexForRouteDistance(List<double> distances, double distanceMeters) {
    if (distances.isEmpty) return 0;
    for (var i = 0; i < distances.length; i++) {
      if (distances[i] >= distanceMeters) return i;
    }
    return distances.length - 1;
  }

  // ---------------------------------------------------------------------------
  // Location update — main entry point
  // ---------------------------------------------------------------------------

  void _onLocationUpdate(NavigationFix fix) {
    if (_disposed || !_isUsableFix(fix)) return;
    final previous = _lastPosition;
    // A duplicate or older fix cannot replace any measured field, even across
    // a route stop/restart. The location source owns ordering, not the route.
    if (previous != null && !fix.timestamp.isAfter(previous.timestamp)) return;

    // ------------------------------------------------------------------
    // Freshness pre-check: reject a fix whose own timestamp is already older
    // than the stale timeout at the moment of delivery.
    //
    // "callback just arrived" does NOT mean the fix is fresh. The platform
    // may buffer and deliver fixes after a background pause. Use the fix's
    // own timestamp against the injected clock.
    // ------------------------------------------------------------------
    final currentTime = now();
    final fixAge = currentTime.difference(fix.timestamp);
    if (fixAge > staleLocationTimeout) {
      // Fix is already too old on delivery — reject without mutating state.
      return;
    }

    final ownership = captureOwnership();
    final route = _route;
    if (_status != NavigationStatus.navigating || route == null) {
      _lastPosition = fix;
      _lastUsableFixTimestamp = fix.timestamp;
      _locationFreshness = _computeFreshness(currentTime);
      _matchedLocation = null;
      _trackingStatus = TrackingStatus.unmatched;
      _publishState();
      return;
    }
    if (!isCurrent(ownership)) return;

    try {
      // ------------------------------------------------------------------
      // Step 1: Calculate a candidate match — pure, no state mutation yet.
      // ------------------------------------------------------------------
      final candidate = _findCandidateMatch(fix, route);

      // ------------------------------------------------------------------
      // Step 2: Evaluate candidate quality and decide accept/reject.
      // ------------------------------------------------------------------
      final accepted = _evaluateCandidate(fix, candidate);

      // ------------------------------------------------------------------
      // Step 3: Prepare downstream values from the *accepted* candidate only.
      // Rejected candidates must not touch any authoritative field.
      // ------------------------------------------------------------------
      final bearing = _resolveBearing(fix, accepted);
      final routeLength =
          _routeDistanceAtIndex.isNotEmpty
              ? _routeDistanceAtIndex.last
              : route.distanceMeters;

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
        // Accepted match: compute all derived values from this single coherent
        // result. No mixing of coordinate/distance from different candidates.
        distanceAlongRoute = accepted.distanceAlongRouteMeters;
        remainingDistance = (routeLength - distanceAlongRoute).clamp(
          0.0,
          route.distanceMeters,
        );
        remainingDuration =
            route.durationSeconds *
            (remainingDistance / max(routeLength, 1.0)).clamp(0.0, 1.0);
        offRouteCount = 0;
        consecutiveUnmatched = 0;
        final maneuver = _advanceStep(fix, route, accepted);
        stepIndex = maneuver.stepIndex;
        upcomingInstructionIndex = maneuver.upcomingInstructionIndex;
        if (upcomingInstructionIndex != null) {
          announcedStep = upcomingInstructionIndex;
        }
        // This fix passed the stale-on-delivery check, so it is fresh.
        // Arrival from a fresh accepted match is always permitted.
        arrived = _isDestinationReached(fix);
      } else {
        // Fix not accepted (off-route or backward).
        // Stale-on-delivery fixes are rejected at entry, so only fresh fixes
        // contribute off-route evidence.
        consecutiveUnmatched++;
        if (!_isRerouting &&
            now().difference(_startTime ?? now()).inSeconds >= 8) {
          offRouteCount++;
          if (offRouteCount >= 3) {
            offRouteCount = 0;
            shouldReroute = true;
          }
        }
      }

      // ------------------------------------------------------------------
      // Route/session ownership can change through a supplied heading callback.
      // No measured field is written until the whole calculation succeeds.
      // ------------------------------------------------------------------
      if (!isCurrent(ownership) || !identical(_route, route)) return;

      _lastPosition = fix;
      // Fix is fresh (passed age check). Record timestamp and update freshness
      // atomically with the rest of the commit.
      _lastUsableFixTimestamp = fix.timestamp;
      _locationFreshness = LocationFreshness.fresh;

      _matchedLocation =
          accepted == null
              ? null
              : NavigationCoordinate(accepted.snappedLng, accepted.snappedLat);
      _trackingStatus =
          accepted == null ? TrackingStatus.offRoute : TrackingStatus.onRoute;
      _measuredDistance = distanceAlongRoute;
      _remainingDistance = remainingDistance;
      _remainingDuration = remainingDuration;
      _currentStepIndex = stepIndex;
      _lastAnnouncedStepIndex = announcedStep;
      _offRouteCount = offRouteCount;
      _consecutiveUnmatchedCount = consecutiveUnmatched;
      _lastBearing = _normalizeBearing(bearing);

      if (accepted != null) {
        // Commit accepted route-progress atomically. Both index and distance
        // must be from the same accepted candidate — no mixing.
        _lastAcceptedRouteIndex = max(
          _lastAcceptedRouteIndex,
          accepted.closestRouteIndex,
        );
        _lastRouteDistanceMeters = max(
          _lastRouteDistanceMeters,
          accepted.distanceAlongRouteMeters,
        );
        // Return to normal tracking once we have a confident match.
        _matcherMode = _MatcherMode.tracking;
      } else if (consecutiveUnmatched >= _reacquisitionThreshold) {
        // Several consecutive unmatched fixes → enter reacquisition.
        _matcherMode = _MatcherMode.reacquisition;
      }

      if (arrived) {
        _status = NavigationStatus.arrived;
        _routeRequestId++;
        _requestStatus = RouteRequestStatus.idle;
        _isRerouting = false;
      }
      _publishState();

      // The state stream delivers this snapshot before these notifications.
      // A listener may stop the session; each effect rechecks ownership.
      final committed = captureOwnership();
      scheduleMicrotask(() {
        bool stillCurrent() =>
            !_disposed &&
            committed.sessionId == _sessionId &&
            committed.routeRequestId == _routeRequestId &&
            committed.routeRevision == _routeRevision &&
            identical(_route, route) &&
            (arrived || _lastPosition?.timestamp == fix.timestamp) &&
            (arrived
                ? _status == NavigationStatus.arrived
                : _status == NavigationStatus.navigating);

        if (stillCurrent()) {
          _notify(
            () => onLocationUpdate?.call(
              fix,
              (fix.speedMetersPerSecond * 3.6).clamp(0.0, 300.0),
              bearing,
              _resolveVisualPosition(fix, accepted),
              accepted?.distanceAlongRouteMeters,
            ),
          );
        }
        if (accepted != null && stillCurrent()) {
          _notifyAsync(
            () => onRouteProgress?.call(
              route,
              accepted.closestRouteIndex,
              remainingDistance!,
              remainingDuration!,
            ),
          );
        }
        if (upcomingInstructionIndex != null && stillCurrent()) {
          _notify(
            () => onUpcomingInstruction?.call(
              upcomingInstructionIndex!,
              route.steps[upcomingInstructionIndex],
            ),
          );
        }
        if (stepIndex != previousStepIndex && stillCurrent()) {
          _notify(() => onStepChanged?.call(stepIndex, route.steps[stepIndex]));
        }
        if (arrived && stillCurrent()) {
          _notify(() => onDestinationReached?.call());
        }
        if (shouldReroute && stillCurrent()) {
          unawaited(
            _reroute(fix).catchError((Object error, StackTrace stack) {
              debugPrint('Reroute error: $error');
            }),
          );
        }
      });
    } catch (error) {
      debugPrint('Navigation fix ignored: $error');
    }
  }

  bool _isUsableFix(NavigationFix fix) =>
      fix.latitude.isFinite &&
      fix.latitude >= -90 &&
      fix.latitude <= 90 &&
      fix.longitude.isFinite &&
      fix.longitude >= -180 &&
      fix.longitude <= 180 &&
      fix.accuracy.isFinite &&
      fix.accuracy >= 0 &&
      fix.heading.isFinite &&
      fix.speedMetersPerSecond.isFinite;

  void _notify(void Function() callback) {
    try {
      callback();
    } catch (error) {
      debugPrint('Navigation notification error: $error');
    }
  }

  void _notifyAsync(Future<void>? Function() callback) {
    try {
      final result = callback();
      if (result != null) {
        unawaited(
          result.catchError((Object error, StackTrace stack) {
            debugPrint('Navigation notification error: $error');
          }),
        );
      }
    } catch (error) {
      debugPrint('Navigation notification error: $error');
    }
  }

  // ---------------------------------------------------------------------------
  // Candidate match (pure — no state mutation)
  // ---------------------------------------------------------------------------

  /// Projects the fix onto the route geometry and returns a coherent candidate.
  ///
  /// In tracking mode a local forward window is used for efficiency.
  /// In reacquisition mode the full route is scanned.
  ///
  /// Complexity: O(n) where n = number of route segments searched.
  /// • Tracking mode: O(w) where w = segments inside the search window
  ///   (typically <<n for long routes).
  /// • Reacquisition mode: O(n) full scan once.
  _RouteMatchCandidate _findCandidateMatch(
    NavigationFix position,
    MapboxRouteResult route,
  ) {
    final coords = route.coordinates;
    if (coords.length < 2) {
      return _RouteMatchCandidate(
        closestRouteIndex: 0,
        crossTrackMeters: double.infinity,
        distanceAlongRouteMeters: 0,
        segmentFraction: 0,
        segmentIndex: 0,
        segmentBearing: _lastBearing,
        snappedLng: coords.isEmpty ? position.longitude : coords.first[0],
        snappedLat: coords.isEmpty ? position.latitude : coords.first[1],
        routeRevision: _routeRevision,
      );
    }

    final originLatRad = position.latitude * pi / 180;
    const earthRadius = 6371000.0;

    // In tracking mode: restrict to a window around committed progress.
    // In reacquisition mode: no window restriction — search everything.
    final inTracking = _matcherMode == _MatcherMode.tracking;
    final forwardWindowMeters = max(
      _minForwardSnapWindowMeters,
      position.speedMetersPerSecond * _forwardWindowSpeedSeconds +
          position.accuracy * _forwardWindowAccuracyFactor,
    );

    // Best candidate within the active window.
    var bestCross = double.infinity;
    var bestIndex = 0;
    var bestAlongRoute = 0.0;
    var bestFraction = 0.0;
    var bestSegIndex = 0;
    var bestBearing = _lastBearing;
    var bestSnappedLng = coords.first[0];
    var bestSnappedLat = coords.first[1];

    // Global fallback: best over the entire route (used in reacquisition or
    // when the window produces no result).
    var fallCross = double.infinity;
    var fallIndex = 0;
    var fallAlongRoute = 0.0;
    var fallFraction = 0.0;
    var fallSegIndex = 0;
    var fallBearing = _lastBearing;
    var fallSnappedLng = coords.first[0];
    var fallSnappedLat = coords.first[1];

    for (var i = 0; i < coords.length - 1; i++) {
      final a = coords[i];
      final b = coords[i + 1];

      // Local flat-earth projection (accurate within several km).
      final ax =
          (a[0] - position.longitude) *
          pi /
          180 *
          earthRadius *
          cos(originLatRad);
      final ay = (a[1] - position.latitude) * pi / 180 * earthRadius;
      final bx =
          (b[0] - position.longitude) *
          pi /
          180 *
          earthRadius *
          cos(originLatRad);
      final by = (b[1] - position.latitude) * pi / 180 * earthRadius;

      final abx = bx - ax;
      final aby = by - ay;
      final ab2 = abx * abx + aby * aby;
      final t = ab2 == 0 ? 0.0 : ((-ax * abx) + (-ay * aby)) / ab2;
      final clampedT = t.clamp(0.0, 1.0);
      final px = ax + abx * clampedT;
      final py = ay + aby * clampedT;
      final cross = sqrt(px * px + py * py);

      // Continuous distance along the route to the projected point.
      final segmentStartDist =
          _routeDistanceAtIndex.isNotEmpty ? _routeDistanceAtIndex[i] : 0.0;
      final segmentLength =
          i + 1 < _routeDistanceAtIndex.length
              ? _routeDistanceAtIndex[i + 1] - _routeDistanceAtIndex[i]
              : _haversine(a[1], a[0], b[1], b[0]);
      final distanceAlongRoute = segmentStartDist + segmentLength * clampedT;

      final snappedLng = a[0] + (b[0] - a[0]) * clampedT;
      final snappedLat = a[1] + (b[1] - a[1]) * clampedT;
      final routeBearing = _routeBearingAtDistance(
        coords: coords,
        distanceAlongRouteMeters: distanceAlongRoute,
      );
      final routeIndex = clampedT >= 0.5 ? i + 1 : i;

      // Update global fallback.
      if (cross < fallCross) {
        fallCross = cross;
        fallIndex = routeIndex;
        fallAlongRoute = distanceAlongRoute;
        fallFraction = clampedT;
        fallSegIndex = i;
        fallBearing = routeBearing;
        fallSnappedLng = snappedLng;
        fallSnappedLat = snappedLat;
      }

      // Apply window filter in tracking mode.
      if (inTracking && _lastRouteDistanceMeters > 0) {
        final backLimit = _lastRouteDistanceMeters - _maxBackwardMeters;
        final fwdLimit = _lastRouteDistanceMeters + forwardWindowMeters;
        if (distanceAlongRoute < backLimit || distanceAlongRoute > fwdLimit) {
          continue;
        }
      }

      if (cross < bestCross) {
        bestCross = cross;
        bestIndex = routeIndex;
        bestAlongRoute = distanceAlongRoute;
        bestFraction = clampedT;
        bestSegIndex = i;
        bestBearing = routeBearing;
        bestSnappedLng = snappedLng;
        bestSnappedLat = snappedLat;
      }
    }

    // If the global fallback has a better (lower) cross-track than the window
    // best, prefer it. The search window is a performance hint to keep the scan
    // local during normal tracking; it must not prevent a clearly better match
    // that lies just outside the window (e.g. a fix exactly at a vertex boundary
    // where one segment clamps to t=1.0 with high cross-track, but the next
    // segment starts at t=0.0 with cross-track=0 and is just outside the window).
    if (fallCross < bestCross) {
      bestCross = fallCross;
      bestIndex = fallIndex;
      bestAlongRoute = fallAlongRoute;
      bestFraction = fallFraction;
      bestSegIndex = fallSegIndex;
      bestBearing = fallBearing;
      bestSnappedLng = fallSnappedLng;
      bestSnappedLat = fallSnappedLat;
    }

    return _RouteMatchCandidate(
      closestRouteIndex: bestIndex,
      crossTrackMeters: bestCross,
      distanceAlongRouteMeters: bestAlongRoute,
      segmentFraction: bestFraction,
      segmentIndex: bestSegIndex,
      segmentBearing: bestBearing,
      snappedLng: bestSnappedLng,
      snappedLat: bestSnappedLat,
      routeRevision: _routeRevision,
    );
  }

  // ---------------------------------------------------------------------------
  // Candidate evaluation — returns the accepted candidate or null.
  // MUST NOT mutate any authoritative field.
  // ---------------------------------------------------------------------------

  /// Evaluates a candidate match and returns it only if it should be accepted.
  ///
  /// Acceptance criteria:
  ///   1. Cross-track distance ≤ effective on-route threshold (capped).
  ///   2. Backward-movement policy: small backward allowed (clamp); large
  ///      backward enters reacquisition (reject current fix).
  ///   3. Heading consistency (soft signal, not hard gate).
  ///   4. Route revision must match what we scanned (prevents stale leakage).
  _RouteMatchCandidate? _evaluateCandidate(
    NavigationFix fix,
    _RouteMatchCandidate candidate,
  ) {
    // Guard: candidate must be for the current route revision.
    if (candidate.routeRevision != _routeRevision) return null;

    // 1. On-route threshold.
    //    Cap the accuracy expansion so a bad GPS fix cannot open the corridor
    //    to hundreds of meters.
    final threshold = min(
      max(_offRouteMeters, fix.accuracy * 2.5),
      _accuracyCapMeters,
    );
    if (candidate.crossTrackMeters > threshold) return null;

    // 2. Backward-movement policy.
    //    We compare the candidate's distanceAlongRoute to committed progress.
    final delta = candidate.distanceAlongRouteMeters - _lastRouteDistanceMeters;

    if (_lastRouteDistanceMeters > 0 && delta < -_largeBackwardMeters) {
      // Large backward jump — likely a GPS teleport. Enter reacquisition and
      // reject this fix so we don't silently corrupt progress.
      // (Reacquisition is set after this method returns null.)
      return null;
    }

    // Small backward movement (GPS jitter): clamp to committed progress so
    // that progress never rewinds while still keeping the coordinate coherent
    // with the candidate's actual projected position.
    // We do NOT mix the coordinate from one candidate with the distance from
    // another — we keep the candidate's coordinate and only clamp the distance.
    if (_lastRouteDistanceMeters > 0 && delta < 0 && delta >= -_maxBackwardMeters) {
      // Clamp the distance; the snapped coordinate remains from this candidate
      // (it is in the right direction, just slightly behind).
      return _RouteMatchCandidate(
        closestRouteIndex: candidate.closestRouteIndex,
        crossTrackMeters: candidate.crossTrackMeters,
        distanceAlongRouteMeters: _lastRouteDistanceMeters,
        segmentFraction: candidate.segmentFraction,
        segmentIndex: candidate.segmentIndex,
        segmentBearing: candidate.segmentBearing,
        snappedLng: candidate.snappedLng,
        snappedLat: candidate.snappedLat,
        routeRevision: candidate.routeRevision,
      );
    }

    // 3. Heading consistency (soft signal).
    //    Only applied when speed is meaningful and heading is plausible.
    //    A heading mismatch raises the effective threshold slightly rather than
    //    hard-rejecting — heading alone should not override strong proximity.
    if (fix.speedMetersPerSecond >= _headingMinSpeedMps &&
        fix.heading >= 0 &&
        fix.heading <= 360) {
      final headingDelta = (_shortestBearingDelta(
        candidate.segmentBearing,
        fix.heading,
      )).abs();
      // Compute a weight in [0, _headingMaxWeight] based on heading mismatch.
      // At headingDelta == 0: weight = 0 (no penalty).
      // At headingDelta >= 90°: weight = max (full penalty).
      final headingPenaltyFactor = (headingDelta / _headingFullPenaltyDeg)
          .clamp(0.0, 1.0);
      final effectiveThreshold = threshold * (1.0 - _headingMaxWeight * headingPenaltyFactor);
      if (candidate.crossTrackMeters > effectiveThreshold) return null;
    }

    return candidate;
  }

  Future<void> _reroute(NavigationFix position) async {
    final destination = _destination;
    if (destination == null ||
        _isRerouting ||
        _status != NavigationStatus.navigating) {
      return;
    }

    final ownership = beginRouteRequest(rerouting: true);

    _offRouteCount = 0;
    _isRerouting = true;
    _notify(() => onReroute?.call('Rerouting...'));
    if (!isCurrent(ownership)) return;

    try {
      final newRoute = await _fetchRoute(
        NavigationCoordinate(position.longitude, position.latitude),
        NavigationCoordinate(
          destination.lng.toDouble(),
          destination.lat.toDouble(),
        ),
      );
      if (!isCurrent(ownership)) return;
      if (newRoute != null && newRoute.coordinates.length >= 2) {
        if (!commitRoute(ownership, newRoute)) return;
        final committedOwnership = captureOwnership();
        await onRouteChanged?.call(newRoute, position);
        if (!isCurrent(committedOwnership)) return;
        if (newRoute.steps.isNotEmpty) {
          _notify(() => onStepChanged?.call(0, newRoute.steps.first));
        }
      } else {
        _requestStatus = RouteRequestStatus.failed;
        _publishState();
        _notify(
          () => onReroute?.call('Reroute failed. Staying on current route.'),
        );
      }
    } catch (error) {
      if (isCurrent(ownership)) {
        _requestStatus = RouteRequestStatus.failed;
        _publishState();
        _notify(
          () => onReroute?.call('Reroute failed. Staying on current route.'),
        );
      }
    } finally {
      if (_ownsRequest(ownership)) _isRerouting = false;
    }
  }

  // ---------------------------------------------------------------------------
  // Step / maneuver advancement
  // ---------------------------------------------------------------------------

  /// Advances the step index based on accepted match progress.
  ///
  /// Uses continuous distanceAlongRoute (not vertex index alone) as the primary
  /// signal. A single fix may cross several short maneuvers — the while loop
  /// catches up to the correct step.
  ({int stepIndex, int? upcomingInstructionIndex}) _advanceStep(
    NavigationFix position,
    MapboxRouteResult route,
    _RouteMatchCandidate accepted,
  ) {
    var stepIndex = _currentStepIndex;
    int? upcomingInstructionIndex;
    if (route.steps.length < 2) {
      return (stepIndex: stepIndex, upcomingInstructionIndex: null);
    }
    final speedMps = max(position.speedMetersPerSecond, 3.0);
    final announceLeadMeters = max(
      _stepAdvanceMeters,
      speedMps * _voiceLeadSeconds,
    );

    // A single fix may cross several short maneuvers. Resolve the final step
    // before committing, then notify only that final step after publication.
    while (stepIndex < route.steps.length - 1 &&
        stepIndex < _stepEndIndices.length) {
      final endIndex = _stepEndIndices[stepIndex];
      final endCoord = route.coordinates[endIndex];

      // Primary: distance-based check using continuous distanceAlongRoute.
      // The step end index is the closest vertex to the step boundary; its
      // cumulative distance is the authoritative step-end distance.
      final stepEndDist =
          endIndex < _routeDistanceAtIndex.length
              ? _routeDistanceAtIndex[endIndex]
              : 0.0;
      final distancePastStepEnd =
          accepted.distanceAlongRouteMeters - stepEndDist;

      // Secondary (fallback for short segments): haversine to step-end vertex.
      final distanceToEnd = _haversine(
        position.latitude,
        position.longitude,
        endCoord[1],
        endCoord[0],
      );

      final nextIndex = stepIndex + 1;
      if (distancePastStepEnd >= 0 ||
          accepted.closestRouteIndex >= endIndex ||
          distanceToEnd < _stepAdvanceMeters) {
        stepIndex = nextIndex;
        continue;
      }
      if (_lastAnnouncedStepIndex != nextIndex &&
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

  bool _isDestinationReached(NavigationFix position) {
    final destination = _destination;
    if (destination == null) return false;
    final destDist = _haversine(
      position.latitude,
      position.longitude,
      destination.lat.toDouble(),
      destination.lng.toDouble(),
    );
    return destDist < 30;
  }

  double _resolveBearing(NavigationFix position, _RouteMatchCandidate? accepted) {
    if (accepted != null) {
      return _acceptBearing(accepted.segmentBearing);
    }

    final gpsHeading = position.heading;
    if (position.speedMetersPerSecond > 1.0 &&
        gpsHeading >= 0 &&
        gpsHeading <= 360) {
      return _acceptBearing(gpsHeading);
    }

    final previous = _lastPosition;
    if (previous != null) {
      final moved = _haversine(
        previous.latitude,
        previous.longitude,
        position.latitude,
        position.longitude,
      );
      if (moved > 3) {
        return _acceptBearing(
          _bearingBetween(
            previous.latitude,
            previous.longitude,
            position.latitude,
            position.longitude,
          ),
        );
      }
    }

    final compassHeading = compassHeadingProvider?.call();
    if (compassHeading != null && compassHeading.isFinite) {
      return _acceptBearing((compassHeading + 360) % 360);
    }

    return _lastBearing;
  }

  mapbox.Position _resolveVisualPosition(
    NavigationFix position,
    _RouteMatchCandidate? accepted,
  ) {
    // Use the accepted matched position when available.
    // Use the same threshold as the acceptance gate (with cap) for consistency.
    if (accepted != null) {
      return mapbox.Position(accepted.snappedLng, accepted.snappedLat);
    }
    return mapbox.Position(position.longitude, position.latitude);
  }

  double _acceptBearing(double targetBearing) {
    // FIX: no per-update damping here anymore. Route-segment bearing is
    // already stable (it comes from route geometry + lookahead, not raw
    // noisy GPS heading), so just pass it through as-is. ALL visual
    // smoothing now happens once, on the screen side (the 60fps tween).
    // Smoothing it here too was the "double chashni" bug — it made turns
    // feel sluggish because two dampers were stacked back to back.
    return _normalizeBearing(targetBearing);
  }

  // ---------------------------------------------------------------------------
  // Route bearing at a continuous distance
  // ---------------------------------------------------------------------------

  double _routeBearingAtDistance({
    required List<List<double>> coords,
    required double distanceAlongRouteMeters,
    double lookAheadMeters = _lookAheadMeters,
  }) {
    if (coords.length < 2 || _routeDistanceAtIndex.length != coords.length) {
      return _lastBearing;
    }

    final from = _coordinateAtRouteDistance(distanceAlongRouteMeters);
    final to = _coordinateAtRouteDistance(
      min(
        _routeDistanceAtIndex.last,
        distanceAlongRouteMeters + lookAheadMeters,
      ),
    );
    if (from == null || to == null) return _lastBearing;

    final distance = _haversine(from[1], from[0], to[1], to[0]);
    if (distance < 1 && distanceAlongRouteMeters > 5) {
      final behind = _coordinateAtRouteDistance(
        max(0, distanceAlongRouteMeters - lookAheadMeters),
      );
      if (behind != null) {
        return _bearingBetween(behind[1], behind[0], from[1], from[0]);
      }
    }

    return _bearingBetween(from[1], from[0], to[1], to[0]);
  }

  List<double>? _coordinateAtRouteDistance(double distanceMeters) {
    final route = _route;
    if (route == null ||
        route.coordinates.isEmpty ||
        _routeDistanceAtIndex.length != route.coordinates.length) {
      return null;
    }

    final clampedDistance = distanceMeters.clamp(
      0.0,
      _routeDistanceAtIndex.last,
    );
    for (var i = 0; i < _routeDistanceAtIndex.length - 1; i++) {
      final startDistance = _routeDistanceAtIndex[i];
      final endDistance = _routeDistanceAtIndex[i + 1];
      if (clampedDistance > endDistance) continue;

      final segmentLength = max(endDistance - startDistance, 0.0);
      final fraction =
          segmentLength == 0
              ? 0.0
              : (clampedDistance - startDistance) / segmentLength;
      final a = route.coordinates[i];
      final b = route.coordinates[i + 1];
      return [a[0] + (b[0] - a[0]) * fraction, a[1] + (b[1] - a[1]) * fraction];
    }

    return route.coordinates.last;
  }

  double _normalizeBearing(double bearing) => (bearing + 360) % 360;

  double _shortestBearingDelta(double from, double to) {
    return ((to - from + 540) % 360) - 180;
  }

  double _bearingBetween(double lat1, double lng1, double lat2, double lng2) {
    final lat1Rad = lat1 * pi / 180;
    final lat2Rad = lat2 * pi / 180;
    final dLng = (lng2 - lng1) * pi / 180;
    final y = sin(dLng) * cos(lat2Rad);
    final x =
        cos(lat1Rad) * sin(lat2Rad) - sin(lat1Rad) * cos(lat2Rad) * cos(dLng);
    return (atan2(y, x) * 180 / pi + 360) % 360;
  }

  double _haversine(double lat1, double lng1, double lat2, double lng2) {
    const r = 6371000.0;
    final dLat = (lat2 - lat1) * pi / 180;
    final dLng = (lng2 - lng1) * pi / 180;
    final a =
        pow(sin(dLat / 2), 2) +
        cos(lat1 * pi / 180) * cos(lat2 * pi / 180) * pow(sin(dLng / 2), 2);
    return 2 * r * asin(sqrt(a.toDouble()));
  }

  void dispose() {
    if (_disposed) return;
    _cancelFreshnessTimer();
    stopNavigation();
    _disposed = true;
    _locationGeneration++;
    _locationSub?.cancel();
    _locationSub = null;
    _status = NavigationStatus.disposed;
    _publishState();
    unawaited(_states.close());
  }
}

// ---------------------------------------------------------------------------
// _RouteMatchCandidate — a coherent single-source match result.
//
// All fields come from the same segment projection. distanceAlongRouteMeters
// and (snappedLng, snappedLat) are always consistent — never mixed from two
// different projections.
// ---------------------------------------------------------------------------
final class _RouteMatchCandidate {
  /// Closest vertex index (used for step-end comparisons).
  final int closestRouteIndex;

  /// Cross-track distance from fix to the projected point (meters).
  final double crossTrackMeters;

  /// Continuous distance along the route to the projected point (meters).
  /// = cumulative distance at segment start + segmentFraction × segmentLength
  final double distanceAlongRouteMeters;

  /// Fraction along the segment [0, 1] at which the fix was projected.
  final double segmentFraction;

  /// Index of the segment (i in coords[i]→coords[i+1]).
  final int segmentIndex;

  /// Route bearing at the projected point (degrees).
  final double segmentBearing;

  /// Matched/snapped longitude.
  final double snappedLng;

  /// Matched/snapped latitude.
  final double snappedLat;

  /// Route revision at the time this candidate was computed.
  /// Used to prevent stale candidates from leaking across a route change.
  final int routeRevision;

  const _RouteMatchCandidate({
    required this.closestRouteIndex,
    required this.crossTrackMeters,
    required this.distanceAlongRouteMeters,
    required this.segmentFraction,
    required this.segmentIndex,
    required this.segmentBearing,
    required this.snappedLng,
    required this.snappedLat,
    required this.routeRevision,
  });
}

final class _RouteMetrics {
  final List<double> distances;
  final List<int> stepEndIndices;

  const _RouteMetrics(this.distances, this.stepEndIndices);
}
