import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;
import 'package:mapbox_navigation/src/api/navigation_controller.dart';
import 'package:mapbox_navigation/src/mapbox/animation/navigation_vehicle_animator.dart';
import 'package:mapbox_navigation/src/mapbox/camera/navigation_camera_controller.dart';
import 'package:mapbox_navigation/src/mapbox/models/mapbox_route_theme.dart';
import 'package:mapbox_navigation/src/mapbox/models/vehicle_appearance.dart';
import 'package:mapbox_navigation/src/mapbox/rendering/mapbox_route_render_coordinator.dart';
import 'package:mapbox_navigation/src/mapbox/rendering/mapbox_route_renderer.dart';
import 'package:mapbox_navigation/src/mapbox/rendering/mapbox_vehicle_renderer.dart';
import 'package:mapbox_navigation/src/models/navigation_enums.dart';
import 'package:mapbox_navigation/src/models/navigation_route.dart';
import 'package:mapbox_navigation/src/models/navigation_state.dart';

/// Reusable Flutter widget providing Mapbox navigation map rendering, active route
/// visualization, 3D GLB vehicle animation, and camera tracking.
class NavigationMapView extends StatefulWidget {
  final NavigationController controller;
  final String? accessToken;
  final VehicleAppearance vehicle;
  final MapboxRouteTheme routeTheme;
  final String styleUri;
  final NavigationCameraController? cameraController;
  final void Function(mapbox.MapboxMap map)? onMapCreated;
  final void Function(mapbox.Position tappedPoint)? onMapTap;
  final void Function(mapbox.StyleLoadedEventData event)? onStyleLoaded;

  const NavigationMapView({
    super.key,
    required this.controller,
    this.accessToken,
    this.vehicle = const VehicleAppearance.model3D(),
    this.routeTheme = const MapboxRouteTheme(),
    this.styleUri = mapbox.MapboxStyles.STANDARD,
    this.cameraController,
    this.onMapCreated,
    this.onMapTap,
    this.onStyleLoaded,
  });

  @override
  State<NavigationMapView> createState() => _NavigationMapViewState();
}

class _MapboxRouteDrawingDelegate implements RouteRenderDelegate {
  final MapboxRouteRenderer Function() getRenderer;
  final Future<void> Function() onPostDraw;

  _MapboxRouteDrawingDelegate({
    required this.getRenderer,
    required this.onPostDraw,
  });

  @override
  Future<void> drawRoute(NavigationRoute route) async {
    await getRenderer().drawRoute(route);
    await onPostDraw();
  }

  @override
  Future<void> clearRoute() async {
    await getRenderer().clearRoute();
  }

  @override
  Future<void> updateRouteProgress(
    NavigationRoute route,
    double distanceAlongRouteMeters,
  ) async {
    await getRenderer().updateRouteProgressByDistance(
      route,
      distanceAlongRouteMeters,
    );
  }
}

class _NavigationMapViewState extends State<NavigationMapView> {
  mapbox.MapboxMap? _mapboxMap;
  late final NavigationCameraController _cameraController;
  bool _ownsCameraController = false;

  MapboxRouteRenderer? _routeRenderer;
  MapboxRouteRenderCoordinator? _routeCoordinator;
  MapboxVehicleRenderer? _vehicleRenderer;
  NavigationVehicleAnimator? _animator;

  StreamSubscription<NavigationState>? _stateSubscription;
  NavigationRoute? _lastRenderedRoute;
  int _renderSessionId = 1;
  int _renderRouteRevision = 0;

  @override
  void initState() {
    super.initState();
    if (widget.accessToken != null && widget.accessToken!.isNotEmpty) {
      mapbox.MapboxOptions.setAccessToken(widget.accessToken!);
    }

    if (widget.cameraController != null) {
      _cameraController = widget.cameraController!;
    } else {
      _cameraController = NavigationCameraController();
      _ownsCameraController = true;
    }

    _animator = NavigationVehicleAnimator(
      onPoseUpdated: _onVehiclePoseUpdated,
    );

    _stateSubscription =
        widget.controller.states.listen(_onNavigationStateChanged);
  }

  @override
  void didUpdateWidget(NavigationMapView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _stateSubscription?.cancel();
      _stateSubscription =
          widget.controller.states.listen(_onNavigationStateChanged);
    }
  }

  void _onNavigationStateChanged(NavigationState state) {
    if (!mounted || _mapboxMap == null) return;

    final activeRoute = state.activeRoute;
    if (activeRoute != null) {
      if (!identical(activeRoute, _lastRenderedRoute)) {
        _lastRenderedRoute = activeRoute;
        _renderRouteRevision++;
        _animator?.setRoute(activeRoute);
        _routeCoordinator?.scheduleDraw(
          sessionId: _renderSessionId,
          routeRevision: _renderRouteRevision,
          route: activeRoute,
        );
      }

      if (state.status == NavigationStatus.navigating &&
          state.distanceAlongRouteMeters != null) {
        _routeCoordinator?.scheduleProgressUpdate(
          sessionId: _renderSessionId,
          routeRevision: _renderRouteRevision,
          route: activeRoute,
          distanceAlongRouteMeters: state.distanceAlongRouteMeters!,
        );
      }
    } else {
      if (_lastRenderedRoute != null) {
        _lastRenderedRoute = null;
        _renderSessionId++;
        _renderRouteRevision = 0;
        _routeCoordinator?.scheduleClear(_renderSessionId);
        _animator?.setRoute(null);
      }
    }

    if (state.status == NavigationStatus.navigating) {
      _animator?.onStateUpdated(state);
    } else if (state.status == NavigationStatus.stopped ||
        state.status == NavigationStatus.arrived ||
        state.status == NavigationStatus.disposed) {
      _animator?.stop();
    }
  }

  void _onVehiclePoseUpdated(DisplayVehiclePose pose) {
    if (!mounted || _mapboxMap == null) return;
    unawaited(_vehicleRenderer?.updatePose(
      position: pose.position,
      bearing: pose.bearing,
    ));
    unawaited(_cameraController.followVehicle(
      position: pose.position,
      bearing: pose.bearing,
    ));
  }

  void _onMapCreated(mapbox.MapboxMap controller) async {
    _mapboxMap = controller;
    _cameraController.attachMap(controller);

    _routeRenderer = MapboxRouteRenderer(
      mapboxMap: controller,
      theme: widget.routeTheme,
    );
    _vehicleRenderer = MapboxVehicleRenderer(
      mapboxMap: controller,
      appearance: widget.vehicle,
    );

    _routeCoordinator?.dispose();
    _routeCoordinator = MapboxRouteRenderCoordinator(
      delegate: _MapboxRouteDrawingDelegate(
        getRenderer: () => _routeRenderer!,
        onPostDraw: () => _vehicleRenderer?.keepVehicleAboveRoute() ?? Future.value(),
      ),
      onError: (err) => debugPrint('Route rendering error: $err'),
    );

    // Initial camera placement
    final initialPos = widget.controller.state.rawFix?.coordinate ??
        widget.controller.state.matchedPoint;
    if (initialPos != null) {
      await controller.setCamera(
        mapbox.CameraOptions(
          center: mapbox.Point(
            coordinates: mapbox.Position(initialPos.longitude, initialPos.latitude),
          ),
          zoom: 17.0,
          pitch: 60.0,
          bearing: 0.0,
        ),
      );
    }

    // Map tap interaction
    controller.addInteraction(
      mapbox.TapInteraction.onMap((context) {
        final point = context.point.coordinates;
        widget.onMapTap?.call(point);
      }),
    );

    widget.onMapCreated?.call(controller);
  }

  void _onStyleLoaded(mapbox.StyleLoadedEventData event) async {
    if (_mapboxMap == null) return;
    widget.onStyleLoaded?.call(event);

    await _routeCoordinator?.onStyleReloaded(widget.controller.state);
    final currentPose = _animator?.currentPose;
    if (currentPose != null &&
        widget.controller.state.status == NavigationStatus.navigating) {
      await _vehicleRenderer?.setupVehicle(
        position: currentPose.position,
        bearing: currentPose.bearing,
      );
    }
  }

  void _handleUserGesture(mapbox.MapContentGestureContext context) {
    _cameraController.onUserGesture();
  }

  @override
  Widget build(BuildContext context) {
    final rawLoc = widget.controller.state.rawFix?.coordinate;
    final centerCoord = rawLoc != null
        ? mapbox.Position(rawLoc.longitude, rawLoc.latitude)
        : mapbox.Position(73.0551, 33.7215);

    // ignore: deprecated_member_use
    return mapbox.MapWidget(
      // ignore: deprecated_member_use
      cameraOptions: mapbox.CameraOptions(
        center: mapbox.Point(coordinates: centerCoord),
        zoom: 17.0,
        pitch: 60.0,
      ),
      styleUri: widget.styleUri,
      onMapCreated: _onMapCreated,
      onStyleLoadedListener: _onStyleLoaded,
      onScrollListener: _handleUserGesture,
      onZoomListener: _handleUserGesture,
      mapOptions: mapbox.MapOptions(
        pixelRatio: MediaQuery.of(context).devicePixelRatio,
      ),
    );
  }

  @override
  void dispose() {
    _stateSubscription?.cancel();
    _animator?.dispose();
    _routeCoordinator?.dispose();
    _cameraController.detachMap();
    if (_ownsCameraController) {
      _cameraController.dispose();
    }
    super.dispose();
  }
}
