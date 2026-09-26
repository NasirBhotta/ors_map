import 'dart:convert';
import 'dart:math';

import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;
import 'package:mapbox_navigation/src/mapbox/models/mapbox_route_theme.dart';
import 'package:mapbox_navigation/src/models/geo_point.dart';
import 'package:mapbox_navigation/src/models/navigation_route.dart';

/// Low-level renderer that translates [NavigationRoute] geometries and measured
/// progress into Mapbox GeoJSON sources and LineLayers.
final class MapboxRouteRenderer {
  final mapbox.MapboxMap mapboxMap;
  final MapboxRouteTheme theme;

  static const String routeSourceId = 'mapbox-nav-route-source';
  static const String traveledSourceId = 'mapbox-nav-traveled-source';
  static const String routeCasingLayerId = 'mapbox-nav-route-casing-layer';
  static const String routeLayerId = 'mapbox-nav-route-layer';
  static const String traveledLayerId = 'mapbox-nav-traveled-layer';

  NavigationRoute? _cachedRoute;
  List<List<double>> _cachedCoords = const [];
  List<double> _cachedCumulativeDistances = const [];

  MapboxRouteRenderer({
    required this.mapboxMap,
    this.theme = const MapboxRouteTheme(),
  });

  void _ensureRouteCached(NavigationRoute route) {
    if (identical(route, _cachedRoute)) return;
    _cachedRoute = route;
    final coords = <List<double>>[];
    final distances = <double>[0.0];
    for (var i = 0; i < route.geometry.length; i++) {
      final p = route.geometry[i];
      coords.add([p.longitude, p.latitude]);
      if (i > 0) {
        final prev = coords[i - 1];
        final curr = coords[i];
        final d = _haversine(prev[1], prev[0], curr[1], curr[0]);
        distances.add(distances.last + d);
      }
    }
    _cachedCoords = coords;
    _cachedCumulativeDistances = distances;
  }

  /// Draws the complete route lines onto the Mapbox map.
  Future<void> drawRoute(
    NavigationRoute route, {
    String? belowLayerId,
  }) async {
    await clearRoute();
    _ensureRouteCached(route);

    final coords = _cachedCoords;

    await mapboxMap.style.addSource(
      mapbox.GeoJsonSource(id: traveledSourceId, data: _lineGeoJson([])),
    );
    await mapboxMap.style.addSource(
      mapbox.GeoJsonSource(id: routeSourceId, data: _lineGeoJson(coords)),
    );

    // Casing line layer (bottom of route stack)
    await _addRouteLayer(
      mapbox.LineLayer(
        id: routeCasingLayerId,
        sourceId: routeSourceId,
        slot: 'top',
        lineColor: theme.casingColor.toARGB32(),
        lineWidth: theme.casingWidth,
        lineCap: mapbox.LineCap.ROUND,
        lineJoin: mapbox.LineJoin.ROUND,
        lineZOffset: 0.0,
        lineDepthOcclusionFactor: 1.0,
        lineWidthExpression: [
          'interpolate',
          ['linear'],
          ['zoom'],
          10,
          4.7,
          15,
          9.3,
          18,
          theme.casingWidth,
          20,
          17.1,
        ],
      ),
      belowLayerId: belowLayerId,
    );

    // Traveled line layer (middle of route stack)
    await _addRouteLayer(
      mapbox.LineLayer(
        id: traveledLayerId,
        sourceId: traveledSourceId,
        slot: 'top',
        lineColor: theme.traveledColor.toARGB32(),
        lineWidth: theme.traveledWidth,
        lineCap: mapbox.LineCap.ROUND,
        lineJoin: mapbox.LineJoin.ROUND,
        lineZOffset: 0.0,
        lineDepthOcclusionFactor: 1.0,
        lineWidthExpression: [
          'interpolate',
          ['linear'],
          ['zoom'],
          10,
          3.3,
          15,
          6.7,
          18,
          theme.traveledWidth,
          20,
          12.2,
        ],
      ),
      belowLayerId: belowLayerId,
    );

    // Active remaining route line layer (top of route line stack)
    await _addRouteLayer(
      mapbox.LineLayer(
        id: routeLayerId,
        sourceId: routeSourceId,
        slot: 'top',
        lineColor: theme.routeColor.toARGB32(),
        lineWidth: theme.routeWidth,
        lineCap: mapbox.LineCap.ROUND,
        lineJoin: mapbox.LineJoin.ROUND,
        lineZOffset: 0.0,
        lineDepthOcclusionFactor: 1.0,
        lineWidthExpression: [
          'interpolate',
          ['linear'],
          ['zoom'],
          10,
          3.0,
          15,
          6.0,
          18,
          theme.routeWidth,
          20,
          11.0,
        ],
      ),
      belowLayerId: belowLayerId,
    );
  }

  /// Removes all route layers and sources from the Mapbox style.
  Future<void> clearRoute() async {
    _cachedRoute = null;
    _cachedCoords = const [];
    _cachedCumulativeDistances = const [];

    for (final id in [routeLayerId, traveledLayerId, routeCasingLayerId]) {
      try {
        await mapboxMap.style.removeStyleLayer(id);
      } catch (_) {}
    }
    for (final id in [routeSourceId, traveledSourceId]) {
      try {
        await mapboxMap.style.removeStyleSource(id);
      } catch (_) {}
    }
  }

  /// Updates traveled vs. remaining line segments based strictly on authoritative
  /// measured along-route distance in meters.
  Future<void> updateRouteProgressByDistance(
    NavigationRoute route,
    double distanceAlongRouteMeters,
  ) async {
    if (route.geometry.length < 2) return;

    _ensureRouteCached(route);
    final split = _splitRouteAtDistance(distanceAlongRouteMeters);

    try {
      final traveledSource =
          await mapboxMap.style.getSource(traveledSourceId) as mapbox.GeoJsonSource?;
      await traveledSource?.updateGeoJSON(_lineGeoJson(split.traveled));
    } catch (_) {}

    try {
      final routeSource =
          await mapboxMap.style.getSource(routeSourceId) as mapbox.GeoJsonSource?;
      await routeSource?.updateGeoJSON(_lineGeoJson(split.remaining));
    } catch (_) {}
  }

  /// Fits camera to enclose origin and destination bounds.
  Future<double> fitRouteBounds({
    required GeoPoint origin,
    required GeoPoint destination,
  }) async {
    final fromLng = origin.longitude;
    final fromLat = origin.latitude;
    final toLng = destination.longitude;
    final toLat = destination.latitude;

    final bounds = mapbox.CoordinateBounds(
      southwest: mapbox.Point(
        coordinates: mapbox.Position(
          min(fromLng, toLng),
          min(fromLat, toLat),
        ),
      ),
      northeast: mapbox.Point(
        coordinates: mapbox.Position(
          max(fromLng, toLng),
          max(fromLat, toLat),
        ),
      ),
      infiniteBounds: false,
    );

    final camera = await mapboxMap.cameraForCoordinateBounds(
      bounds,
      mapbox.MbxEdgeInsets(top: 100, left: 50, bottom: 250, right: 50),
      0.0,
      0.0,
      null,
      null,
    );
    await mapboxMap.flyTo(camera, mapbox.MapAnimationOptions(duration: 1500));
    return camera.zoom ?? 14.0;
  }

  /// Computes overview camera options for route bounds.
  Future<mapbox.CameraOptions> computeOverviewCamera({
    required GeoPoint from,
    required GeoPoint to,
  }) async {
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

    return await mapboxMap.cameraForCoordinateBounds(
      bounds,
      mapbox.MbxEdgeInsets(top: 100, left: 50, bottom: 250, right: 50),
      0.0,
      0.0,
      null,
      null,
    );
  }

  Future<void> _addRouteLayer(
    mapbox.LineLayer layer, {
    required String? belowLayerId,
  }) async {
    if (belowLayerId == null) {
      await mapboxMap.style.addLayer(layer);
      return;
    }

    try {
      await mapboxMap.style.addLayerAt(
        layer,
        mapbox.LayerPosition(below: belowLayerId),
      );
    } catch (_) {
      await mapboxMap.style.addLayer(layer);
    }
  }

  String _lineGeoJson(List<List<double>> coordinates) {
    return jsonEncode(<String, dynamic>{
      'type': 'Feature',
      'geometry': <String, dynamic>{
        'type': 'LineString',
        'coordinates': coordinates.length >= 2 ? coordinates : <List<double>>[],
      },
      'properties': <String, dynamic>{},
    });
  }

  _RouteSplit _splitRouteAtDistance(double distanceAlongRouteMeters) {
    final coords = _cachedCoords;
    final distances = _cachedCumulativeDistances;
    if (coords.length < 2 || distances.length < 2) {
      return _RouteSplit(traveled: coords, remaining: coords);
    }

    final totalDistance = distances.last;
    final targetDistance = distanceAlongRouteMeters.clamp(0.0, totalDistance);

    // Fast binary search to find segment index containing targetDistance
    var low = 0;
    var high = distances.length - 1;
    var result = distances.length - 1;

    while (low <= high) {
      final mid = (low + high) >> 1;
      if (distances[mid] >= targetDistance) {
        result = mid;
        high = mid - 1;
      } else {
        low = mid + 1;
      }
    }

    final segIdx = (result == 0 ? 0 : result - 1).clamp(0, distances.length - 2);
    final startDist = distances[segIdx];
    final endDist = distances[segIdx + 1];
    final segLength = endDist - startDist;
    final fraction = segLength <= 0.0
        ? 0.0
        : ((targetDistance - startDist) / segLength).clamp(0.0, 1.0);

    final a = coords[segIdx];
    final b = coords[segIdx + 1];
    final splitPoint = <double>[
      a[0] + (b[0] - a[0]) * fraction,
      a[1] + (b[1] - a[1]) * fraction,
    ];

    final traveled = <List<double>>[];
    for (var i = 0; i <= segIdx; i++) {
      traveled.add(coords[i]);
    }
    traveled.add(splitPoint);

    final remaining = <List<double>>[splitPoint];
    for (var i = segIdx + 1; i < coords.length; i++) {
      remaining.add(coords[i]);
    }

    return _RouteSplit(traveled: traveled, remaining: remaining);
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
    return 2 * r * asin(sqrt(a));
  }
}

final class _RouteSplit {
  final List<List<double>> traveled;
  final List<List<double>> remaining;

  const _RouteSplit({required this.traveled, required this.remaining});
}
