import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;
import 'package:mapbox_nav_core/src/models/geo_point.dart';
import 'package:meta/meta.dart';

/// Coordinates Mapbox camera movements during navigation: follow-mode,
/// bearing tracking, recenter timers, gestures, and route overview.
///
/// **Experimental**: This controller directly references [mapbox.MbxEdgeInsets]
/// and Mapbox camera animation durations. Its public surface may evolve in future pre-releases.
@experimental
class NavigationCameraController {
  mapbox.MapboxMap? _mapboxMap;
  final ValueNotifier<bool> isFollowingNotifier = ValueNotifier<bool>(true);
  final ValueNotifier<bool> isOverviewNotifier = ValueNotifier<bool>(false);

  /// Camera viewport edge insets used for follow, recenter, and exit-overview animations.
  mapbox.MbxEdgeInsets cameraPadding;

  bool _suppressFollow = false;
  bool _cameraFollowInFlight = false;
  DateTime? _lastFollowAt;
  Timer? _recenterTimer;
  GeoPoint? _lastFollowPosition;
  double? _lastFollowBearing;

  static const double navigationZoom = 18.0;
  static const double navigationPitch = 60.0;
  static const int followAnimationDurationMs = 150;
  static const int recenterAnimationDurationMs = 1500;
  static const int overviewAnimationDurationMs = 2200;
  static const int overviewReturnAnimationDurationMs = 1700;

  NavigationCameraController({mapbox.MbxEdgeInsets? cameraPadding})
    : cameraPadding =
          cameraPadding ??
          mapbox.MbxEdgeInsets(top: 80, left: 0, bottom: 200, right: 0);

  bool get isFollowing => isFollowingNotifier.value;
  bool get isOverview => isOverviewNotifier.value;

  void attachMap(mapbox.MapboxMap map) {
    _mapboxMap = map;
  }

  void detachMap() {
    _mapboxMap = null;
    _recenterTimer?.cancel();
    _recenterTimer = null;
    _lastFollowPosition = null;
    _lastFollowBearing = null;
  }

  /// Follows the vehicle smoothly if follow mode is active.
  Future<void> followVehicle({
    required GeoPoint position,
    required double bearing,
  }) async {
    final map = _mapboxMap;
    if (map == null ||
        !isFollowing ||
        _suppressFollow ||
        isOverview ||
        _cameraFollowInFlight) {
      return;
    }

    final now = DateTime.now();
    final lastFollow = _lastFollowAt;
    if (lastFollow != null && now.difference(lastFollow).inMilliseconds < 70) {
      return;
    }

    final lastPos = _lastFollowPosition;
    final lastBrg = _lastFollowBearing;
    if (lastPos != null && lastBrg != null) {
      final dLat = (position.latitude - lastPos.latitude).abs();
      final dLng = (position.longitude - lastPos.longitude).abs();
      final dBrg = ((bearing - lastBrg).abs() % 360.0);
      final shortestBrg = dBrg > 180.0 ? 360.0 - dBrg : dBrg;
      // Skip redundant camera animations if vehicle has not moved noticeably (< 0.1m, < 0.5 deg)
      if (dLat < 0.000001 && dLng < 0.000001 && shortestBrg < 0.5) {
        return;
      }
    }

    _lastFollowAt = now;
    _cameraFollowInFlight = true;
    try {
      await map.easeTo(
        mapbox.CameraOptions(
          center: mapbox.Point(
            coordinates: mapbox.Position(position.longitude, position.latitude),
          ),
          zoom: navigationZoom,
          pitch: navigationPitch,
          bearing: bearing,
          padding: cameraPadding,
        ),
        mapbox.MapAnimationOptions(duration: followAnimationDurationMs),
      );
      _lastFollowPosition = position;
      _lastFollowBearing = bearing;
    } finally {
      _cameraFollowInFlight = false;
    }
  }

  /// Handles user map interactions (pan, pinch, zoom). Pauses follow mode and
  /// schedules a 4-second auto-recenter.
  void onUserGesture() {
    if (isOverview) return;

    _recenterTimer?.cancel();
    _recenterTimer = Timer(const Duration(seconds: 4), () {
      recenter();
    });

    if (isFollowing) {
      isFollowingNotifier.value = false;
    }
  }

  /// Smoothly recenters the camera onto the vehicle and resumes follow mode.
  Future<void> recenter({
    GeoPoint? currentPosition,
    double? currentBearing,
  }) async {
    _recenterTimer?.cancel();
    _recenterTimer = null;

    final map = _mapboxMap;
    if (map == null) return;

    _suppressFollow = true;
    try {
      if (currentPosition != null) {
        await map.easeTo(
          mapbox.CameraOptions(
            center: mapbox.Point(
              coordinates: mapbox.Position(
                currentPosition.longitude,
                currentPosition.latitude,
              ),
            ),
            zoom: navigationZoom,
            pitch: navigationPitch,
            bearing: currentBearing ?? 0.0,
            padding: cameraPadding,
          ),
          mapbox.MapAnimationOptions(duration: recenterAnimationDurationMs),
        );
      }
      isFollowingNotifier.value = true;
      isOverviewNotifier.value = false;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    } finally {
      _suppressFollow = false;
      _lastFollowAt = null;
      _lastFollowPosition = null;
      _lastFollowBearing = null;
    }
  }

  /// Flies or eases camera to show the complete route overview.
  Future<void> showOverview(mapbox.CameraOptions overviewCamera) async {
    final map = _mapboxMap;
    if (map == null) return;

    _recenterTimer?.cancel();
    _recenterTimer = null;
    _suppressFollow = true;
    _lastFollowPosition = null;
    _lastFollowBearing = null;

    try {
      await map.easeTo(
        overviewCamera,
        mapbox.MapAnimationOptions(duration: overviewAnimationDurationMs),
      );
      isFollowingNotifier.value = false;
      isOverviewNotifier.value = true;
    } finally {
      _suppressFollow = false;
    }
  }

  /// Calculates bounding box for origin/destination and eases camera to overview.
  Future<void> showRouteOverview({
    required GeoPoint from,
    required GeoPoint to,
  }) async {
    final map = _mapboxMap;
    if (map == null) return;

    final bounds = mapbox.CoordinateBounds(
      southwest: mapbox.Point(
        coordinates: mapbox.Position(
          min(from.longitude, to.longitude),
          min(from.latitude, to.latitude),
        ),
      ),
      northeast: mapbox.Point(
        coordinates: mapbox.Position(
          max(from.longitude, to.longitude),
          max(from.latitude, to.latitude),
        ),
      ),
      infiniteBounds: false,
    );

    final overviewCamera = await map.cameraForCoordinateBounds(
      bounds,
      mapbox.MbxEdgeInsets(top: 100, left: 50, bottom: 250, right: 50),
      0.0,
      0.0,
      null,
      null,
    );
    await showOverview(overviewCamera);
  }

  /// Returns from overview back to vehicle follow mode.
  Future<void> exitOverview({
    required GeoPoint currentPosition,
    required double currentBearing,
  }) async {
    final map = _mapboxMap;
    if (map == null) return;

    _suppressFollow = true;
    try {
      await map.easeTo(
        mapbox.CameraOptions(
          center: mapbox.Point(
            coordinates: mapbox.Position(
              currentPosition.longitude,
              currentPosition.latitude,
            ),
          ),
          zoom: navigationZoom,
          pitch: navigationPitch,
          bearing: currentBearing,
          padding: cameraPadding,
        ),
        mapbox.MapAnimationOptions(duration: overviewReturnAnimationDurationMs),
      );
      isOverviewNotifier.value = false;
      isFollowingNotifier.value = true;
    } finally {
      _suppressFollow = false;
      _lastFollowAt = null;
    }
  }

  void dispose() {
    detachMap();
    isFollowingNotifier.dispose();
    isOverviewNotifier.dispose();
  }
}
