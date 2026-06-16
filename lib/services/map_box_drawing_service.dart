import 'dart:convert';

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

  Future<void> drawRoute(MapboxRouteResult route) async {
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

    await mapboxMap.style.addLayer(
      mapbox.LineLayer(
        id: _routeCasingLayerId,
        sourceId: _routeSourceId,
        lineColor: Colors.black.withValues(alpha: 0.55).toARGB32(),
        lineWidth: 14.0,
        lineCap: mapbox.LineCap.ROUND,
        lineJoin: mapbox.LineJoin.ROUND,
      ),
    );

    await mapboxMap.style.addLayer(
      mapbox.LineLayer(
        id: _traveledLayerId,
        sourceId: _traveledSourceId,
        lineColor: Colors.grey.shade500.toARGB32(),
        lineWidth: 10.0,
        lineCap: mapbox.LineCap.ROUND,
        lineJoin: mapbox.LineJoin.ROUND,
      ),
    );

    await mapboxMap.style.addLayer(
      mapbox.LineLayer(
        id: _routeLayerId,
        sourceId: _routeSourceId,
        lineColor: Colors.amberAccent.toARGB32(),
        lineWidth: 9.0,
        lineCap: mapbox.LineCap.ROUND,
        lineJoin: mapbox.LineJoin.ROUND,
      ),
    );
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

  Future<void> fitRouteBounds({
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
      null,
      null,
      null,
      null,
    );
    await mapboxMap.flyTo(camera, mapbox.MapAnimationOptions(duration: 1500));
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
}
