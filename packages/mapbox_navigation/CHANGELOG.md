# Changelog

All notable changes to `mapbox_navigation` will be documented in this file.

## 0.1.0-dev.1

- Initial extracted pure navigation core:
  - Immutable models: `GeoPoint`, `LocationFix`, `LocationQuality`, `NavigationRoute`, `NavigationStep`, `NavigationState`.
  - Core abstractions: `NavigationController`, `LocationSource`, `RouteProvider`.
  - Authoritative flat-earth route matching, reacquisition search window, monotonic progress tracking.
  - Multi-boundary maneuver advancement and arrival detection.
  - Off-route detection with automatic rerouting coordination.
  - GPS staleness detection with timer-based elapsed monitoring and prediction horizon gating.
  - Sealed typed event stream (`NavigationEvent`) and exception hierarchy (`NavigationException`).
- Mapbox presentation layer:
  - `MapboxRouteProvider` implementing `RouteProvider` with explicit token injection.
  - `MapboxRouteRenderer` managing casing, traveled, and remaining lines with zoom-scaled widths.
  - `MapboxRouteRenderCoordinator` ensuring FIFO structural order and progress coalescing.
  - `MapboxVehicleRenderer` and `VehicleAppearance` for 3D GLB model rendering (`assets/lowpoly_car.glb`).
  - `NavigationVehicleAnimator` providing 60fps display pose smoothing without mutating authoritative state.
  - `NavigationCameraController` providing camera follow (pitch $80^\circ$, zoom $19.3$), gesture suppression, auto-recenter, and route overview.
  - `NavigationMapView` composite widget.
  - `GeolocatorLocationSource` adapter.
- Example application in `example/`.
