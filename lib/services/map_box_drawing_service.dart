import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;

import 'mapbox_route_service.dart';

class MapboxDrawingService {
  final mapbox.MapboxMap mapboxMap;

  static const _routeSourceId = 'route-source';
  static const _traveledSourceId = 'traveled-source';
  static const _routeCasingLayerId = 'route-casing-layer';
  static const _routeLayerId = 'route-layer';
  static const _traveledLayerId = 'traveled-layer';

  MapboxDrawingService({required this.mapboxMap});

  Future<void> drawRoute(
    MapboxRouteResult route, {
    String? belowLayerId,
  }) async {
    await clearRoute();

    await mapboxMap.style.addSource(
      mapbox.GeoJsonSource(id: _traveledSourceId, data: _lineGeoJson([])),
    );
    await mapboxMap.style.addSource(
      mapbox.GeoJsonSource(
        id: _routeSourceId,
        data: _lineGeoJson(route.coordinates),
      ),
    );

    await _addRouteLayer(
      mapbox.LineLayer(
        id: _routeCasingLayerId,
        sourceId: _routeSourceId,
        slot: 'top',
        lineColor: Colors.black.withValues(alpha: 0.55).toARGB32(),
        lineWidth: 14.0,
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
          14.0,
          20,
          17.1,
        ],
      ),
      belowLayerId: belowLayerId,
    );

    await _addRouteLayer(
      mapbox.LineLayer(
        id: _traveledLayerId,
        sourceId: _traveledSourceId,
        slot: 'top',
        lineColor: Colors.grey.shade500.toARGB32(),
        lineWidth: 10.0,
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
          10.0,
          20,
          12.2,
        ],
      ),
      belowLayerId: belowLayerId,
    );

    await _addRouteLayer(
      mapbox.LineLayer(
        id: _routeLayerId,
        sourceId: _routeSourceId,
        slot: 'top',
        lineColor: Colors.amberAccent.toARGB32(),
        lineWidth: 9.0,
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
          9.0,
          20,
          11.0,
        ],
      ),
      belowLayerId: belowLayerId,
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

  Future<void> updateRouteProgress(
    MapboxRouteResult route,
    int closestRouteIndex,
  ) async {
    if (route.coordinates.isEmpty) return;

    final safeIndex = closestRouteIndex.clamp(0, route.coordinates.length - 1);
    final traveled =
        safeIndex <= 0
            ? <List<double>>[]
            : route.coordinates.sublist(0, safeIndex + 1);
    final remaining = route.coordinates.sublist(safeIndex);

    try {
      final traveledSource =
          await mapboxMap.style.getSource(_traveledSourceId)
              as mapbox.GeoJsonSource;
      await traveledSource.updateGeoJSON(_lineGeoJson(traveled));
    } catch (_) {}

    try {
      final routeSource =
          await mapboxMap.style.getSource(_routeSourceId)
              as mapbox.GeoJsonSource;
      await routeSource.updateGeoJSON(_lineGeoJson(remaining));
    } catch (_) {}
  }

  Future<void> updateRouteProgressByDistance(
    MapboxRouteResult route,
    double distanceAlongRouteMeters,
  ) async {
    if (route.coordinates.length < 2) return;

    final split = _splitRouteAtDistance(route, distanceAlongRouteMeters);

    try {
      final traveledSource =
          await mapboxMap.style.getSource(_traveledSourceId)
              as mapbox.GeoJsonSource;
      await traveledSource.updateGeoJSON(_lineGeoJson(split.traveled));
    } catch (_) {}

    try {
      final routeSource =
          await mapboxMap.style.getSource(_routeSourceId)
              as mapbox.GeoJsonSource;
      await routeSource.updateGeoJSON(_lineGeoJson(split.remaining));
    } catch (_) {}
  }

  Future<void> clearRoute() async {
    for (final id in [_routeLayerId, _traveledLayerId, _routeCasingLayerId]) {
      try {
        await mapboxMap.style.removeStyleLayer(id);
      } catch (_) {}
    }
    for (final id in [_routeSourceId, _traveledSourceId]) {
      try {
        await mapboxMap.style.removeStyleSource(id);
      } catch (_) {}
    }
  }

  Future<double> fitRouteBounds({
    required double fromLng,
    required double fromLat,
    required double toLng,
    required double toLat,
  }) async {
    final bounds = mapbox.CoordinateBounds(
      southwest: mapbox.Point(
        coordinates: mapbox.Position(
          fromLng < toLng ? fromLng : toLng,
          fromLat < toLat ? fromLat : toLat,
        ),
      ),
      northeast: mapbox.Point(
        coordinates: mapbox.Position(
          fromLng > toLng ? fromLng : toLng,
          fromLat > toLat ? fromLat : toLat,
        ),
      ),
      infiniteBounds: false,
    );

    final camera = await mapboxMap.cameraForCoordinateBounds(
      bounds,
      mapbox.MbxEdgeInsets(top: 100, left: 50, bottom: 250, right: 50),
      0.0, // bearing — north-up
      0.0,
      null,
      null,
    );
    await mapboxMap.flyTo(camera, mapbox.MapAnimationOptions(duration: 1500));

    return camera.zoom ?? 14.0;
  }

  String _lineGeoJson(List<List<double>> coordinates) {
    return jsonEncode({
      'type': 'Feature',
      'geometry': {
        'type': 'LineString',
        'coordinates': coordinates.length >= 2 ? coordinates : [],
      },
      'properties': {},
    });
  }

  Future<mapbox.CameraOptions> computeOverviewCamera({
    required double fromLng,
    required double fromLat,
    required double toLng,
    required double toLat,
  }) async {
    final bounds = mapbox.CoordinateBounds(
      southwest: mapbox.Point(
        coordinates: mapbox.Position(
          fromLng < toLng ? fromLng : toLng,
          fromLat < toLat ? fromLat : toLat,
        ),
      ),
      northeast: mapbox.Point(
        coordinates: mapbox.Position(
          fromLng > toLng ? fromLng : toLng,
          fromLat > toLat ? fromLat : toLat,
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

  _RouteSplit _splitRouteAtDistance(
    MapboxRouteResult route,
    double distanceAlongRouteMeters,
  ) {
    final coords = route.coordinates;
    final totalDistance = _routeLength(coords);
    final targetDistance = distanceAlongRouteMeters.clamp(0.0, totalDistance);
    final traveled = <List<double>>[];
    final remaining = <List<double>>[];

    var cumulative = 0.0;
    for (var i = 0; i < coords.length - 1; i++) {
      final a = coords[i];
      final b = coords[i + 1];
      final segmentLength = _haversine(a[1], a[0], b[1], b[0]);

      if (cumulative + segmentLength < targetDistance) {
        if (traveled.isEmpty) traveled.add(a);
        traveled.add(b);
        cumulative += segmentLength;
        continue;
      }

      final fraction =
          segmentLength == 0
              ? 0.0
              : ((targetDistance - cumulative) / segmentLength).clamp(0.0, 1.0);
      final splitPoint = <double>[
        a[0] + (b[0] - a[0]) * fraction,
        a[1] + (b[1] - a[1]) * fraction,
      ];

      if (traveled.isEmpty) traveled.add(a);
      traveled.add(splitPoint);
      remaining
        ..add(splitPoint)
        ..addAll(coords.sublist(i + 1));
      return _RouteSplit(traveled: traveled, remaining: remaining);
    }

    return _RouteSplit(traveled: coords, remaining: [coords.last]);
  }

  double _routeLength(List<List<double>> coords) {
    var total = 0.0;
    for (var i = 0; i < coords.length - 1; i++) {
      total += _haversine(
        coords[i][1],
        coords[i][0],
        coords[i + 1][1],
        coords[i + 1][0],
      );
    }
    return total;
  }

  double _haversine(double lat1, double lng1, double lat2, double lng2) {
    const r = 6371000.0;
    final dLat = (lat2 - lat1) * 0.017453292519943295;
    final dLng = (lng2 - lng1) * 0.017453292519943295;
    final lat1Rad = lat1 * 0.017453292519943295;
    final lat2Rad = lat2 * 0.017453292519943295;
    final a =
        _sinSquared(dLat / 2) +
        cos(lat1Rad) * cos(lat2Rad) * _sinSquared(dLng / 2);
    return 2 * r * asin(sqrt(a));
  }

  double _sinSquared(double value) {
    final sinValue = sin(value);
    return sinValue * sinValue;
  }
}

class _RouteSplit {
  final List<List<double>> traveled;
  final List<List<double>> remaining;

  const _RouteSplit({required this.traveled, required this.remaining});
}
