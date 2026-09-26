import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:mapbox_navigation/src/models/geo_point.dart';
import 'package:mapbox_navigation/src/models/navigation_enums.dart';
import 'package:mapbox_navigation/src/models/navigation_route.dart';
import 'package:mapbox_navigation/src/models/navigation_state.dart';

/// Computed display pose for rendering the vehicle on the map.
@immutable
final class DisplayVehiclePose {
  final GeoPoint position;
  final double bearing;
  final double? routeDistanceMeters;

  const DisplayVehiclePose({
    required this.position,
    required this.bearing,
    this.routeDistanceMeters,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DisplayVehiclePose &&
          runtimeType == other.runtimeType &&
          position == other.position &&
          bearing == other.bearing &&
          routeDistanceMeters == other.routeDistanceMeters;

  @override
  int get hashCode => Object.hash(position, bearing, routeDistanceMeters);

  @override
  String toString() =>
      'DisplayVehiclePose(pos: $position, bearing: $bearing, dist: $routeDistanceMeters)';
}

/// Internal visual animator that smooths GPS fixes into 60fps display poses.
/// Strictly display-only: cannot mutate authoritative [NavigationState].
class NavigationVehicleAnimator {
  final void Function(DisplayVehiclePose pose) onPoseUpdated;
  final Duration predictionHorizon;

  Timer? _animationTimer;
  bool _running = false;
  DateTime? _lastTickAt;
  DateTime? _lastFixAt;

  // Current display state
  GeoPoint? _displayPosition;
  double? _displayBearing;
  double? _displayRouteDistance;

  // Target received from authoritative state
  GeoPoint? _targetPosition;
  double _targetBearing = 0.0;
  double? _targetRouteDistance;
  double _targetSpeedMps = 0.0;

  // Active route polyline metrics for along-route animation
  final List<double> _routeCumulativeDistances = [];
  List<GeoPoint> _routeCoordinates = const [];
  int _cachedSegmentIndex = 0;

  NavigationVehicleAnimator({
    required this.onPoseUpdated,
    this.predictionHorizon = const Duration(seconds: 5),
  });

  bool get isRunning => _running;
  DisplayVehiclePose? get currentPose => _displayPosition != null
      ? DisplayVehiclePose(
          position: _displayPosition!,
          bearing: _displayBearing ?? _targetBearing,
          routeDistanceMeters: _displayRouteDistance,
        )
      : null;

  /// Updates polyline geometry when the route revision changes.
  void setRoute(NavigationRoute? route) {
    _routeCumulativeDistances.clear();
    _cachedSegmentIndex = 0;
    if (route == null || route.geometry.length < 2) {
      _routeCoordinates = const [];
      return;
    }

    _routeCoordinates = route.geometry;
    _routeCumulativeDistances.add(0.0);
    for (var i = 1; i < route.geometry.length; i++) {
      final prev = route.geometry[i - 1];
      final curr = route.geometry[i];
      final d = _haversine(
        prev.latitude,
        prev.longitude,
        curr.latitude,
        curr.longitude,
      );
      _routeCumulativeDistances.add(_routeCumulativeDistances.last + d);
    }
  }

  /// Consumes an authoritative [NavigationState] update.
  void onStateUpdated(NavigationState state) {
    final raw = state.rawFix?.coordinate;
    final matched = state.matchedPoint;
    final targetPos = matched ?? raw;
    if (targetPos == null) return;

    final now = DateTime.now();
    final elapsedSinceLastFixMs =
        _lastFixAt == null ? 700 : now.difference(_lastFixAt!).inMilliseconds;
    _lastFixAt = now;

    final currentPos = _displayPosition;
    final jumpDistance = currentPos == null
        ? 0.0
        : _haversine(
            currentPos.latitude,
            currentPos.longitude,
            targetPos.latitude,
            targetPos.longitude,
          );

    final plausibleMaxJump = max(
      80.0,
      (elapsedSinceLastFixMs / 1000.0) * 60.0,
    ).clamp(80.0, 500.0);

    // Hard teleport if jump exceeds plausible bounds
    if (currentPos == null || jumpDistance > plausibleMaxJump) {
      _displayPosition = targetPos;
      _displayBearing = state.bearingDegrees;
      _displayRouteDistance = state.distanceAlongRouteMeters;
      onPoseUpdated(
        DisplayVehiclePose(
          position: targetPos,
          bearing: state.bearingDegrees,
          routeDistanceMeters: state.distanceAlongRouteMeters,
        ),
      );
    }

    _targetPosition = targetPos;
    _targetBearing = state.bearingDegrees;
    _targetRouteDistance = state.distanceAlongRouteMeters;
    _targetSpeedMps = max(0.0, state.speedMps);

    _ensureAnimationLoop();
  }

  /// Reseeds the display pose to the given point along the current route.
  void reseed(GeoPoint position, {double? bearing}) {
    _displayPosition = position;
    _targetPosition = position;
    _cachedSegmentIndex = 0;
    if (bearing != null) {
      _displayBearing = bearing;
      _targetBearing = bearing;
    }
    _lastTickAt = DateTime.now();
    _ensureAnimationLoop();
  }

  void _ensureAnimationLoop() {
    if (_running) return;
    _running = true;
    _lastTickAt = DateTime.now();

    _animationTimer?.cancel();
    _animationTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      _tick();
    });
  }

  void _tick() {
    final target = _targetPosition;
    final display = _displayPosition;
    final now = DateTime.now();
    final lastTick = _lastTickAt;
    _lastTickAt = now;

    if (target == null || display == null) return;

    final dtSeconds = lastTick == null
        ? 1 / 60
        : (now.difference(lastTick).inMilliseconds / 1000.0).clamp(0.0, 0.12);
    if (dtSeconds <= 0) return;

    final speedMps = max(0.0, _targetSpeedMps);
    var desiredPosition = target;
    var desiredRouteDistance = _targetRouteDistance;

    // Check prediction horizon expiration
    final lastFix = _lastFixAt;
    final predictionExpired =
        lastFix != null && now.difference(lastFix) > predictionHorizon;

    // Extrapolate position if moving and within prediction horizon
    if (speedMps > 0 && !predictionExpired) {
      if (desiredRouteDistance != null && _routeCumulativeDistances.isNotEmpty) {
        final totalLength = _routeCumulativeDistances.last;
        desiredRouteDistance =
            (desiredRouteDistance + speedMps * dtSeconds).clamp(0.0, totalLength);
        _targetRouteDistance = desiredRouteDistance;
        desiredPosition =
            _positionAtRouteDistance(desiredRouteDistance) ?? target;
        _targetPosition = desiredPosition;
      }
    }

    final nextRouteDistance = _nextDisplayedRouteDistance(
      currentDistance: _displayRouteDistance,
      desiredDistance: desiredRouteDistance,
      dtSeconds: dtSeconds,
      speedMps: speedMps,
    );

    final routePosition = nextRouteDistance == null
        ? null
        : _positionAtRouteDistance(nextRouteDistance);

    final nextPosition = routePosition ??
        _lerpPosition(
          from: display,
          to: desiredPosition,
          t: (dtSeconds * 8.0).clamp(0.0, 1.0),
        );

    final bearingT = (dtSeconds * 5.0).clamp(0.0, 1.0);
    final nextBearing = _lerpBearing(
      _displayBearing ?? _targetBearing,
      _targetBearing,
      bearingT,
    );

    _displayPosition = nextPosition;
    _displayBearing = nextBearing;
    _displayRouteDistance = nextRouteDistance;

    onPoseUpdated(
      DisplayVehiclePose(
        position: nextPosition,
        bearing: nextBearing,
        routeDistanceMeters: nextRouteDistance,
      ),
    );
  }

  double? _nextDisplayedRouteDistance({
    required double? currentDistance,
    required double? desiredDistance,
    required double dtSeconds,
    required double speedMps,
  }) {
    if (desiredDistance == null) return null;
    if (currentDistance == null) return desiredDistance;

    final delta = desiredDistance - currentDistance;
    final maxTravelDistance = max(speedMps * dtSeconds * 1.5, 0.5);

    if (delta.abs() <= maxTravelDistance) {
      return desiredDistance;
    }

    return currentDistance + delta.sign * maxTravelDistance;
  }

  int _findSegmentIndex(double targetMeters) {
    final distances = _routeCumulativeDistances;
    if (distances.length <= 1) return 0;

    // Check cached segment and immediate forward segment first (O(1) fast path)
    final cached = _cachedSegmentIndex;
    if (cached >= 0 && cached < distances.length - 1) {
      if (targetMeters >= distances[cached] && targetMeters <= distances[cached + 1]) {
        return cached;
      }
      final next = cached + 1;
      if (next < distances.length - 1 &&
          targetMeters >= distances[next] &&
          targetMeters <= distances[next + 1]) {
        _cachedSegmentIndex = next;
        return next;
      }
    }

    // Binary search fallback for arbitrary seeks / jumps (O(log N))
    var low = 0;
    var high = distances.length - 1;
    var result = distances.length - 1;

    while (low <= high) {
      final mid = (low + high) >> 1;
      if (distances[mid] >= targetMeters) {
        result = mid;
        high = mid - 1;
      } else {
        low = mid + 1;
      }
    }

    final segIdx = (result == 0 ? 0 : result - 1).clamp(0, distances.length - 2);
    _cachedSegmentIndex = segIdx;
    return segIdx;
  }

  GeoPoint? _positionAtRouteDistance(double distanceMeters) {
    if (_routeCoordinates.length < 2 || _routeCumulativeDistances.length < 2) {
      return null;
    }

    final clampedDistance =
        distanceMeters.clamp(0.0, _routeCumulativeDistances.last);

    final i = _findSegmentIndex(clampedDistance);
    final startDist = _routeCumulativeDistances[i];
    final endDist = _routeCumulativeDistances[i + 1];
    final segLength = endDist - startDist;
    final t = segLength <= 0 ? 0.0 : (clampedDistance - startDist) / segLength;

    return _lerpPosition(
      from: _routeCoordinates[i],
      to: _routeCoordinates[i + 1],
      t: t.clamp(0.0, 1.0),
    );
  }

  GeoPoint _lerpPosition({
    required GeoPoint from,
    required GeoPoint to,
    required double t,
  }) {
    return GeoPoint(
      latitude: from.latitude + (to.latitude - from.latitude) * t,
      longitude: from.longitude + (to.longitude - from.longitude) * t,
    );
  }

  double _lerpBearing(double from, double to, double t) {
    final delta = ((to - from + 540) % 360) - 180;
    return (from + delta * t + 360) % 360;
  }

  double _haversine(double lat1, double lng1, double lat2, double lng2) {
    const r = 6371000.0;
    const toRad = 0.017453292519943295;
    final dLat = (lat2 - lat1) * toRad;
    final dLng = (lng2 - lng1) * toRad;
    final lat1Rad = lat1 * toRad;
    final lat2Rad = lat2 * toRad;
    final sinDLat = sin(dLat / 2);
    final sinDLng = sin(dLng / 2);
    final a = sinDLat * sinDLat + cos(lat1Rad) * cos(lat2Rad) * sinDLng * sinDLng;
    return 2 * r * asin(sqrt(a.clamp(0.0, 1.0)));
  }

  /// Temporarily pauses the animation loop during background or inactive lifecycle states.
  ///
  /// Cancels the 16ms periodic timer to eliminate background CPU and battery drain,
  /// preserving existing display pose without resetting target state.
  void pause() {
    _animationTimer?.cancel();
    _animationTimer = null;
    _running = false;
    _lastTickAt = null;
  }

  /// Resumes the animation loop upon returning to foreground.
  ///
  /// Evaluates real elapsed time against [predictionHorizon] to prevent timer backlog
  /// replaying and large artificial jumps. If GPS fix is stale, extrapolation is frozen.
  void resume(NavigationState? state) {
    _lastTickAt = DateTime.now();
    if (state == null || state.status != NavigationStatus.navigating) {
      pause();
      return;
    }

    final targetPos = state.matchedPoint ?? state.rawFix?.coordinate;
    if (targetPos != null) {
      final fixTime = state.locationQuality.timestamp ?? state.rawFix?.timestamp;
      final isStale = fixTime == null ||
          DateTime.now().difference(fixTime) > predictionHorizon;

      _targetPosition = targetPos;
      _targetBearing = state.bearingDegrees;
      _targetRouteDistance = state.distanceAlongRouteMeters;
      _targetSpeedMps = isStale ? 0.0 : max(0.0, state.speedMps);

      // Reseed display directly from authoritative state to avoid visual jumps
      _displayPosition = targetPos;
      _displayBearing = state.bearingDegrees;
      _displayRouteDistance = state.distanceAlongRouteMeters;

      onPoseUpdated(
        DisplayVehiclePose(
          position: targetPos,
          bearing: state.bearingDegrees,
          routeDistanceMeters: state.distanceAlongRouteMeters,
        ),
      );

      if (!isStale) {
        _ensureAnimationLoop();
      }
    }
  }

  /// Cancels the animation timer and resets internal animator state.
  void stop() {
    pause();
    _displayPosition = null;
    _displayBearing = null;
    _displayRouteDistance = null;
    _targetPosition = null;
    _targetBearing = 0.0;
    _targetRouteDistance = null;
    _targetSpeedMps = 0.0;
    _lastFixAt = null;
    _cachedSegmentIndex = 0;
  }

  void dispose() {
    stop();
  }
}
