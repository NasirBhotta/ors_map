import 'package:flutter/foundation.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;
import 'package:mapbox_nav_core/src/mapbox/models/vehicle_appearance.dart';
import 'package:mapbox_nav_core/src/models/geo_point.dart';

/// Low-level renderer that manages the 3D GLB vehicle model layer and source on the Mapbox map.
final class MapboxVehicleRenderer {
  final mapbox.MapboxMap mapboxMap;
  final VehicleAppearance appearance;

  static const String carModelSourceId = 'mapbox-nav-car-model-source';
  static const String carModelLayerId = 'mapbox-nav-car-model-layer';

  GeoPoint? _lastRenderedPosition;
  double? _lastRenderedBearing;
  bool _modelActive = false;
  bool _setupInFlight = false;
  bool _setupFailed = false;

  bool get isModelActive => _modelActive;
  bool get isSetupInFlight => _setupInFlight;

  MapboxVehicleRenderer({
    required this.mapboxMap,
    this.appearance = const VehicleAppearance.model3D(),
  });

  /// Sets up or recreates the 3D vehicle model source and layer at the given pose.
  Future<void> setupVehicle({
    required GeoPoint position,
    required double bearing,
  }) async {
    _lastRenderedPosition = null;
    _lastRenderedBearing = null;
    if (!appearance.enabled) return;
    if (_setupInFlight) return;
    _setupInFlight = true;

    try {
      await removeVehicle();

      // Register the 3D model in Mapbox style
      if (appearance.modelUri.isNotEmpty) {
        try {
          await mapboxMap.style.addStyleModel(
            appearance.modelUri,
            appearance.modelUri,
          );
        } catch (_) {}
      }

      await mapboxMap.style.addSource(
        mapbox.GeoJsonSource(
          id: carModelSourceId,
          data: _carPointGeoJson(position, bearing),
        ),
      );

      final layer = mapbox.ModelLayer(
        id: carModelLayerId,
        sourceId: carModelSourceId,
        slot: 'top',
        modelId: appearance.modelUri,
        modelScale: [appearance.scale, appearance.scale, appearance.scale],
        modelRotation: [0.0, 0.0, _carModelRotation(bearing)],
        modelType: mapbox.ModelType.COMMON_3D,
        modelCastShadows: false,
        modelReceiveShadows: false,
        modelEmissiveStrength: appearance.emissiveStrength,
        modelOpacity: 1.0,
      );

      await mapboxMap.style.addLayer(layer);

      // Disable 2D puck ONLY after 3D model was successfully added
      try {
        await mapboxMap.location.updateSettings(
          mapbox.LocationComponentSettings(enabled: false),
        );
      } catch (_) {}

      _modelActive = true;
      _setupFailed = false;
      _lastRenderedPosition = position;
      _lastRenderedBearing = bearing;

      await keepVehicleAboveRoute();
      debugPrint(
        'MapboxVehicleRenderer: 3D model successfully added to map at $position, bearing $bearing',
      );
    } catch (e) {
      debugPrint(
        'MapboxVehicleRenderer: 3D model setup failed ($e). Falling back to 2D puck.',
      );
      _modelActive = false;
      _setupFailed = true;
      try {
        await mapboxMap.location.updateSettings(
          mapbox.LocationComponentSettings(
            enabled: true,
            puckBearingEnabled: true,
          ),
        );
      } catch (_) {}
    } finally {
      _setupInFlight = false;
    }
  }

  /// Updates the vehicle model position and orientation concurrently.
  Future<void> updatePose({
    required GeoPoint position,
    required double bearing,
  }) async {
    if (!appearance.enabled) return;

    if (!_modelActive) {
      if (!_setupInFlight && !_setupFailed) {
        await setupVehicle(position: position, bearing: bearing);
      }
      return;
    }

    final lastPos = _lastRenderedPosition;
    final lastBrg = _lastRenderedBearing;
    if (lastPos != null && lastBrg != null) {
      final dLat = (position.latitude - lastPos.latitude).abs();
      final dLng = (position.longitude - lastPos.longitude).abs();
      final dBrg = ((bearing - lastBrg).abs() % 360.0);
      final shortestBrg = dBrg > 180.0 ? 360.0 - dBrg : dBrg;

      // Skip native calls if vehicle is stationary (< 0.05m and < 0.2 deg)
      if (dLat < 0.0000005 && dLng < 0.0000005 && shortestBrg < 0.2) {
        return;
      }
    }

    try {
      final source =
          await mapboxMap.style.getSource(carModelSourceId)
              as mapbox.GeoJsonSource?;
      if (source == null) {
        _modelActive = false;
        await setupVehicle(position: position, bearing: bearing);
        return;
      }

      await Future.wait<void>([
        source.updateGeoJSON(_carPointGeoJson(position, bearing))!,
        mapboxMap.style.setStyleLayerProperty(
          carModelLayerId,
          'model-rotation',
          [0.0, 0.0, _carModelRotation(bearing)],
        ),
      ]);
      _lastRenderedPosition = position;
      _lastRenderedBearing = bearing;
    } catch (e) {
      debugPrint('Vehicle pose update failed: $e');
      _modelActive = false;
    }
  }

  /// Moves the vehicle layer above the route line layer to prevent clipping.
  Future<void> keepVehicleAboveRoute({
    String targetLayerId = 'mapbox-nav-route-layer',
  }) async {
    try {
      await mapboxMap.style.moveStyleLayer(
        carModelLayerId,
        mapbox.LayerPosition(above: targetLayerId),
      );
    } catch (_) {}
  }

  /// Removes vehicle layer and source from style.
  Future<void> removeVehicle() async {
    _modelActive = false;
    _setupFailed = false;
    _lastRenderedPosition = null;
    _lastRenderedBearing = null;
    try {
      await mapboxMap.style.removeStyleLayer(carModelLayerId);
    } catch (_) {}
    try {
      await mapboxMap.style.removeStyleSource(carModelSourceId);
    } catch (_) {}
  }

  /// Sets flat scale on vehicle model layer.
  Future<void> setModelScale(double scale) async {
    try {
      await mapboxMap.style.setStyleLayerProperty(
        carModelLayerId,
        'model-scale',
        [scale, scale, scale],
      );
    } catch (_) {}
  }

  /// Applies zoom-interpolated overview scale expression.
  Future<void> setOverviewScaleExpression({
    required double overviewZoom,
    required double overviewScale,
    required double navigationZoomLevel,
  }) async {
    try {
      await mapboxMap.style.setStyleLayerProperty(
        carModelLayerId,
        'model-scale',
        [
          'interpolate',
          ['linear'],
          ['zoom'],
          overviewZoom,
          [
            'literal',
            [overviewScale, overviewScale, overviewScale],
          ],
          navigationZoomLevel,
          [
            'literal',
            [appearance.scale, appearance.scale, appearance.scale],
          ],
        ],
      );
    } catch (_) {}
  }

  double _carModelRotation(double bearing) {
    return ((bearing - appearance.bearingOffset) + 360.0) % 360.0;
  }

  String _carPointGeoJson(GeoPoint point, double bearing) {
    return '{"type":"Feature","geometry":{"type":"Point","coordinates":[${point.longitude},${point.latitude}]},"properties":{"bearing":$bearing}}';
  }
}
