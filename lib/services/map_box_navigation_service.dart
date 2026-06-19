// meri file
import 'dart:async';
import 'dart:math';

import 'package:geolocator/geolocator.dart' as geolocator;
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;

import 'mapbox_route_service.dart';

class MapboxNavigationService {
  final mapbox.MapboxMap mapboxMap;

  StreamSubscription<geolocator.Position>? _gpsSub;
  MapboxRouteResult? _route;
  mapbox.Position? _destination;

  final List<double> _routeDistanceAtIndex = [];
  final List<int> _stepEndIndices = [];

  int _currentStepIndex = 0;
  int _lastRouteIndex = 0;
  int _offRouteCount = 0;
  double _lastRouteDistanceMeters = 0;
  double _lastBearing = 0;
  bool _hasBearing = false;
  bool _isRerouting = false;
  DateTime? _startTime;
  geolocator.Position? _lastPosition;
  mapbox.Position? _lastVisualPosition;

  static const _offRouteMeters = 80.0;
  static const _stepAdvanceMeters = 35.0;
  static const _lookAheadMeters = 45.0;
  static const _maxBackwardSnapMeters = 25.0;
  static const _minForwardSnapWindowMeters = 90.0;

  final double? Function()? compassHeadingProvider;

  final void Function(
    geolocator.Position position,
    double speedKmh,
    double bearing,
    mapbox.Position visualPosition,
    double? visualDistanceAlongRouteMeters,
  )?
  onLocationUpdate;
  final void Function(int stepIndex, MapboxStep step)? onStepChanged;
  final void Function(String message)? onReroute;
  final Future<void> Function(MapboxRouteResult route)? onRouteChanged;
  final Future<void> Function(
    MapboxRouteResult route,
    int closestRouteIndex,
    double remainingDistanceMeters,
    double remainingDurationSeconds,
  )?
  onRouteProgress;
  final void Function()? onDestinationReached;

  MapboxNavigationService({
    required this.mapboxMap,
    this.compassHeadingProvider,
    this.onLocationUpdate,
    this.onStepChanged,
    this.onReroute,
    this.onRouteChanged,
    this.onRouteProgress,
    this.onDestinationReached,
  });

  void startNavigation({
    required MapboxRouteResult route,
    required mapbox.Position destination,
  }) {
    _destination = destination;
    _setRoute(route);
    _startTime = DateTime.now();

    _gpsSub?.cancel();
    _gpsSub = geolocator.Geolocator.getPositionStream(
      locationSettings: const geolocator.LocationSettings(
        accuracy: geolocator.LocationAccuracy.bestForNavigation,
        distanceFilter: 1,
      ),
    ).listen(_onLocationUpdate);
  }

  void stopNavigation() {
    _gpsSub?.cancel();
    _gpsSub = null;
    _route = null;
    _destination = null;
    _routeDistanceAtIndex.clear();
    _stepEndIndices.clear();
    _currentStepIndex = 0;
    _lastRouteIndex = 0;
    _offRouteCount = 0;
    _lastRouteDistanceMeters = 0;
    _lastBearing = 0;
    _hasBearing = false;
    _isRerouting = false;
    _startTime = null;
    _lastPosition = null;
    _lastVisualPosition = null;
  }

  void setFollowModeEnabled(bool enabled) {}

  void _setRoute(MapboxRouteResult route) {
    _route = route;
    _currentStepIndex = 0;
    _lastRouteIndex = 0;
    _offRouteCount = 0;
    _lastRouteDistanceMeters = 0;
    _buildRouteMetrics(route);
  }

  void _buildRouteMetrics(MapboxRouteResult route) {
    _routeDistanceAtIndex
      ..clear()
      ..add(0);
    for (var i = 1; i < route.coordinates.length; i++) {
      final prev = route.coordinates[i - 1];
      final current = route.coordinates[i];
      _routeDistanceAtIndex.add(
        _routeDistanceAtIndex.last +
            _haversine(prev[1], prev[0], current[1], current[0]),
      );
    }

    _stepEndIndices.clear();
    var distanceToStepEnd = 0.0;
    for (final step in route.steps) {
      distanceToStepEnd += step.distance;
      _stepEndIndices.add(_indexForRouteDistance(distanceToStepEnd));
    }
  }

  int _indexForRouteDistance(double distanceMeters) {
    if (_routeDistanceAtIndex.isEmpty) return 0;
    for (var i = 0; i < _routeDistanceAtIndex.length; i++) {
      if (_routeDistanceAtIndex[i] >= distanceMeters) return i;
    }
    return _routeDistanceAtIndex.length - 1;
  }

  void _onLocationUpdate(geolocator.Position position) {
    final route = _route;
    final rawSnap =
        route == null ? null : _findNearestRoutePoint(position, route);

    // Pehle forward-correction apply karo, PHIR bearing nikalo
    final snap = rawSnap == null ? null : _keepProgressForward(rawSnap);
    final bearing = _resolveBearing(position, snap);
    final visualPosition = _resolveVisualPosition(position, snap);

    final speedKmh = (position.speed * 3.6).clamp(0.0, 300.0);

    onLocationUpdate?.call(
      position,
      speedKmh,
      bearing,
      visualPosition,
      snap?.distanceAlongRouteMeters,
    );
    if (route != null && snap != null) {
      _checkProgress(
        position,
        route,
        snap,
      ); // ab yeh already-corrected snap milega
    }

    _lastPosition = position;
  }

  Future<void> _checkProgress(
    geolocator.Position position,
    MapboxRouteResult route,
    _RouteSnap snap,
  ) async {
    final allowedDistance = max(_offRouteMeters, position.accuracy * 2.5);

    if (snap.distanceMeters > allowedDistance) {
      if (_isRerouting) return;
      final elapsed = DateTime.now().difference(_startTime ?? DateTime.now());
      if (elapsed.inSeconds < 8) return;

      _offRouteCount++;
      if (_offRouteCount >= 3) {
        await _reroute(position);
      }
      return;
    }

    _offRouteCount = 0;
    // final effectiveSnap = _keepProgressForward(snap);

    final routeLength =
        _routeDistanceAtIndex.isNotEmpty
            ? _routeDistanceAtIndex.last
            : route.distanceMeters;
    final remainingDistance = (routeLength - snap.distanceAlongRouteMeters)
        .clamp(0.0, route.distanceMeters);
    final remainingDuration =
        route.durationSeconds *
        (remainingDistance / max(routeLength, 1.0)).clamp(0.0, 1.0);

    await onRouteProgress?.call(
      route,
      snap.closestRouteIndex,
      remainingDistance,
      remainingDuration,
    );

    _checkStepAdvance(position, route, snap);
    _checkDestination(position);
  }

  _RouteSnap _keepProgressForward(_RouteSnap snap) {
    if (snap.distanceAlongRouteMeters + 25 < _lastRouteDistanceMeters) {
      final lastAcceptedCoord = _coordinateAtRouteDistance(
        _lastRouteDistanceMeters,
      );
      return _RouteSnap(
        closestRouteIndex: _lastRouteIndex,
        distanceMeters: snap.distanceMeters,
        distanceAlongRouteMeters: _lastRouteDistanceMeters,
        segmentBearing: _lastBearing,
        snappedLng: lastAcceptedCoord?[0] ?? snap.snappedLng,
        snappedLat: lastAcceptedCoord?[1] ?? snap.snappedLat,
      );
    }

    _lastRouteIndex = max(_lastRouteIndex, snap.closestRouteIndex);
    _lastRouteDistanceMeters = max(
      _lastRouteDistanceMeters,
      snap.distanceAlongRouteMeters,
    );
    return snap;
  }

  Future<void> _reroute(geolocator.Position position) async {
    final destination = _destination;
    if (destination == null) return;

    _offRouteCount = 0;
    _isRerouting = true;
    onReroute?.call('Rerouting...');

    try {
      final newRoute = await MapboxRouteService.getRoute(
        fromLng: position.longitude,
        fromLat: position.latitude,
        toLng: destination.lng.toDouble(),
        toLat: destination.lat.toDouble(),
      );
      if (newRoute != null && newRoute.coordinates.length >= 2) {
        _setRoute(newRoute);
        await onRouteChanged?.call(newRoute);
        if (newRoute.steps.isNotEmpty) {
          onStepChanged?.call(0, newRoute.steps.first);
        }
      } else {
        onReroute?.call('Reroute failed. Staying on current route.');
      }
    } finally {
      _isRerouting = false;
    }
  }

  void _checkStepAdvance(
    geolocator.Position position,
    MapboxRouteResult route,
    _RouteSnap snap,
  ) {
    if (_currentStepIndex >= route.steps.length - 1) return;
    if (_currentStepIndex >= _stepEndIndices.length) return;

    final stepEndIndex = _stepEndIndices[_currentStepIndex];
    final endCoord = route.coordinates[stepEndIndex];
    final distanceToStepEnd = _haversine(
      position.latitude,
      position.longitude,
      endCoord[1],
      endCoord[0],
    );

    if (snap.closestRouteIndex >= stepEndIndex ||
        distanceToStepEnd < _stepAdvanceMeters) {
      _currentStepIndex++;
      onStepChanged?.call(_currentStepIndex, route.steps[_currentStepIndex]);
    }
  }

  void _checkDestination(geolocator.Position position) {
    final destination = _destination;
    if (destination == null) return;

    final destDist = _haversine(
      position.latitude,
      position.longitude,
      destination.lat.toDouble(),
      destination.lng.toDouble(),
    );
    if (destDist < 30) {
      onDestinationReached?.call();
      stopNavigation();
    }
  }

  double _resolveBearing(geolocator.Position position, _RouteSnap? snap) {
    if (snap != null) {
      return _acceptBearing(snap.segmentBearing);
    }

    final gpsHeading = position.heading;
    if (position.speed > 1.0 && gpsHeading >= 0 && gpsHeading <= 360) {
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
    if (compassHeading != null && !compassHeading.isNaN) {
      return _acceptBearing((compassHeading + 360) % 360);
    }

    return _lastBearing;
  }

  mapbox.Position _resolveVisualPosition(
    geolocator.Position position,
    _RouteSnap? snap,
  ) {
    final target =
        snap != null &&
                snap.distanceMeters <=
                    max(_offRouteMeters, position.accuracy * 2.5)
            ? mapbox.Position(snap.snappedLng, snap.snappedLat)
            : mapbox.Position(position.longitude, position.latitude);
    final previous = _lastVisualPosition;
    if (previous == null) {
      _lastVisualPosition = target;
      return target;
    }

    final distance = _haversine(
      previous.lat.toDouble(),
      previous.lng.toDouble(),
      target.lat.toDouble(),
      target.lng.toDouble(),
    );
    if (distance > 60) {
      _lastVisualPosition = target;
      return target;
    }

    final factor = position.speed > 2.0 ? 0.45 : 0.3;
    final smoothed = mapbox.Position(
      previous.lng.toDouble() +
          (target.lng.toDouble() - previous.lng.toDouble()) * factor,
      previous.lat.toDouble() +
          (target.lat.toDouble() - previous.lat.toDouble()) * factor,
    );
    _lastVisualPosition = smoothed;
    return smoothed;
  }

  double _acceptBearing(double targetBearing) {
    final normalizedTarget = _normalizeBearing(targetBearing);
    if (!_hasBearing) {
      _hasBearing = true;
      _lastBearing = normalizedTarget;
      return _lastBearing;
    }

    final delta = _shortestBearingDelta(_lastBearing, normalizedTarget);
    final maxStep = delta.abs() > 120 ? 18.0 : 32.0;
    final smoothedDelta = (delta * 0.28).clamp(-maxStep, maxStep).toDouble();
    _lastBearing = _normalizeBearing(_lastBearing + smoothedDelta);
    return _lastBearing;
  }

  _RouteSnap _findNearestRoutePoint(
    geolocator.Position position,
    MapboxRouteResult route,
  ) {
    final coords = route.coordinates;
    if (coords.length < 2) {
      return _RouteSnap(
        closestRouteIndex: 0,
        distanceMeters: double.infinity,
        distanceAlongRouteMeters: 0,
        segmentBearing: _lastBearing,
        snappedLng: coords.isEmpty ? position.longitude : coords.first[0],
        snappedLat: coords.isEmpty ? position.latitude : coords.first[1],
      );
    }

    final originLatRad = position.latitude * pi / 180;
    const earthRadius = 6371000.0;
    var bestDistance = double.infinity;
    var bestIndex = 0;
    var bestAlongRoute = 0.0;
    var bestBearing = _lastBearing;
    var bestSnappedLng = coords.first[0];
    var bestSnappedLat = coords.first[1];
    var fallbackDistance = double.infinity;
    var fallbackIndex = 0;
    var fallbackAlongRoute = 0.0;
    var fallbackBearing = _lastBearing;
    var fallbackSnappedLng = coords.first[0];
    var fallbackSnappedLat = coords.first[1];
    final forwardWindowMeters = max(
      _minForwardSnapWindowMeters,
      position.speed * 8 + position.accuracy * 2,
    );

    for (var i = 0; i < coords.length - 1; i++) {
      final a = coords[i];
      final b = coords[i + 1];
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
      final distance = sqrt(px * px + py * py);

      if (distance < bestDistance) {
        final segmentDistance =
            i + 1 < _routeDistanceAtIndex.length
                ? _routeDistanceAtIndex[i + 1] - _routeDistanceAtIndex[i]
                : _haversine(a[1], a[0], b[1], b[0]);
        final distanceAlongRoute =
            (_routeDistanceAtIndex.isNotEmpty ? _routeDistanceAtIndex[i] : 0) +
            segmentDistance * clampedT;
        final snappedLng = a[0] + (b[0] - a[0]) * clampedT;
        final snappedLat = a[1] + (b[1] - a[1]) * clampedT;
        final routeBearing = _routeBearingAtDistance(
          coords: coords,
          distanceAlongRouteMeters: distanceAlongRoute,
        );

        if (distance < fallbackDistance) {
          fallbackDistance = distance;
          fallbackIndex = clampedT >= 0.5 ? i + 1 : i;
          fallbackAlongRoute = distanceAlongRoute;
          fallbackSnappedLng = snappedLng;
          fallbackSnappedLat = snappedLat;
          fallbackBearing = routeBearing;
        }

        if (_lastRouteDistanceMeters > 0 &&
            (distanceAlongRoute <
                    _lastRouteDistanceMeters - _maxBackwardSnapMeters ||
                distanceAlongRoute >
                    _lastRouteDistanceMeters + forwardWindowMeters)) {
          continue;
        }

        bestDistance = distance;
        bestIndex = clampedT >= 0.5 ? i + 1 : i;
        bestAlongRoute = distanceAlongRoute;
        bestSnappedLng = snappedLng;
        bestSnappedLat = snappedLat;
        bestBearing = routeBearing;
      }
    }

    if (bestDistance == double.infinity) {
      bestDistance = fallbackDistance;
      bestIndex = fallbackIndex;
      bestAlongRoute = fallbackAlongRoute;
      bestBearing = fallbackBearing;
      bestSnappedLng = fallbackSnappedLng;
      bestSnappedLat = fallbackSnappedLat;
    }

    return _RouteSnap(
      closestRouteIndex: bestIndex,
      distanceMeters: bestDistance,
      distanceAlongRouteMeters: bestAlongRoute,
      segmentBearing: bestBearing,
      snappedLng: bestSnappedLng,
      snappedLat: bestSnappedLat,
    );
  }

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

  void dispose() => stopNavigation();
}

class _RouteSnap {
  final int closestRouteIndex;
  final double distanceMeters;
  final double distanceAlongRouteMeters;
  final double segmentBearing;
  final double snappedLng;
  final double snappedLat;

  const _RouteSnap({
    required this.closestRouteIndex,
    required this.distanceMeters,
    required this.distanceAlongRouteMeters,
    required this.segmentBearing,
    required this.snappedLng,
    required this.snappedLat,
  });
}
