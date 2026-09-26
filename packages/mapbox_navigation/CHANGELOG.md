# Changelog

All notable changes to `mapbox_navigation` will be documented in this file.

## 0.1.0-dev.2

- Platform & Lifecycle Hardening:
  - Added platform normalization in `GeolocatorLocationSource` for iOS sentinel values (negative speed clamped to 0.0, negative course clamped to 0.0, invalid accuracy clamped to 100m instead of false 1m, UTC timestamp conversion).
  - Added typed exception mapping for location service disabled and permission denied into `LocationUnavailableException`.
  - Implemented `WidgetsBindingObserver` in `NavigationMapView` to automatically pause the 60fps vehicle animation timer during background/inactive states, eliminating background CPU/battery drain.
  - Added `evaluateFreshness()` to `NavigationController` and `FreshnessMonitor.checkNow()` to instantly evaluate fix age upon returning to the foreground.
  - Vehicle animator freeze/reseed on resume: freezes extrapolation if GPS is stale and reseeds from latest authoritative state without timer backlog visual jumps.
  - Documented and enforced caller ownership for `NavigationController` across `NavigationMapView` unmount/remount.
  - Re-anchored `MapboxVehicleRenderer.keepVehicleAboveRoute` to namespaced `'mapbox-nav-route-layer'`.
  - Added configurable `cameraPadding` to `NavigationCameraController` while preserving exact default insets (top: 80, bottom: 340).
  - Configured clean foreground-only Android and iOS setups for the example app and host app.
  - Added 15 new automated platform normalization and lifecycle tests (84 package tests passing 100%).

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
