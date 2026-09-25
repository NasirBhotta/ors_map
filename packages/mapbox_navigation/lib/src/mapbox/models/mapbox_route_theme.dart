import 'package:flutter/material.dart';

/// Styling configuration for route lines on the Mapbox map.
@immutable
final class MapboxRouteTheme {
  /// Color for the route outline/casing.
  final Color casingColor;

  /// Color for the active (remaining) portion of the route.
  final Color routeColor;

  /// Color for the traveled (completed) portion of the route.
  final Color traveledColor;

  /// Width of the casing line at zoom 18.
  final double casingWidth;

  /// Width of the active route line at zoom 18.
  final double routeWidth;

  /// Width of the traveled route line at zoom 18.
  final double traveledWidth;

  const MapboxRouteTheme({
    this.casingColor = const Color(0x8C000000), // Colors.black with alpha 0.55
    this.routeColor = Colors.amberAccent,
    this.traveledColor = const Color(0xFF9E9E9E), // Colors.grey.shade500
    this.casingWidth = 14.0,
    this.routeWidth = 9.0,
    this.traveledWidth = 10.0,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MapboxRouteTheme &&
          runtimeType == other.runtimeType &&
          casingColor == other.casingColor &&
          routeColor == other.routeColor &&
          traveledColor == other.traveledColor &&
          casingWidth == other.casingWidth &&
          routeWidth == other.routeWidth &&
          traveledWidth == other.traveledWidth;

  @override
  int get hashCode => Object.hash(
        casingColor,
        routeColor,
        traveledColor,
        casingWidth,
        routeWidth,
        traveledWidth,
      );
}
