import 'package:flutter/foundation.dart';

/// Configuration for vehicle visualization on the map.
@immutable
final class VehicleAppearance {
  /// The URI of the 3D model asset (e.g. 'asset://assets/lowpoly_car.glb').
  final String modelUri;

  /// The baseline scale of the 3D model (default: 0.05).
  final double scale;

  /// Angular bearing offset in degrees to align the 3D model mesh (default: 180.0).
  final double bearingOffset;

  /// Emissive light strength applied to the 3D model (default: 0.7).
  final double emissiveStrength;

  /// Whether the 3D model should be displayed.
  final bool enabled;

  const VehicleAppearance.model3D({
    this.modelUri = 'asset://assets/lowpoly_car.glb',
    this.scale = 0.05,
    this.bearingOffset = 180.0,
    this.emissiveStrength = 0.7,
    this.enabled = true,
  });

  const VehicleAppearance.hidden()
    : modelUri = '',
      scale = 0.0,
      bearingOffset = 0.0,
      emissiveStrength = 0.0,
      enabled = false;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VehicleAppearance &&
          runtimeType == other.runtimeType &&
          modelUri == other.modelUri &&
          scale == other.scale &&
          bearingOffset == other.bearingOffset &&
          emissiveStrength == other.emissiveStrength &&
          enabled == other.enabled;

  @override
  int get hashCode =>
      Object.hash(modelUri, scale, bearingOffset, emissiveStrength, enabled);

  @override
  String toString() =>
      'VehicleAppearance(uri: $modelUri, scale: $scale, offset: $bearingOffset)';
}
