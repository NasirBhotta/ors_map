import 'package:meta/meta.dart';
import '../errors/navigation_errors.dart';
import '../models/geo_point.dart';
import '../models/location_fix.dart';
import '../models/navigation_step.dart';

/// Sealed base class for discrete, one-time navigation events.
///
/// Use these events for transient side-effects (e.g. speech synthesis, haptics,
/// toast messages, analytics) that should trigger once per occurrence.
@immutable
sealed class NavigationEvent {
  const NavigationEvent();
}

/// Dispatched when the active maneuver step advances or instruction text updates.
@immutable
final class InstructionChangedEvent extends NavigationEvent {
  /// The new active step index within the active route.
  final int stepIndex;

  /// The maneuver step and instruction.
  final NavigationStep step;

  const InstructionChangedEvent({required this.stepIndex, required this.step});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is InstructionChangedEvent &&
          runtimeType == other.runtimeType &&
          stepIndex == other.stepIndex &&
          step == other.step;

  @override
  int get hashCode => Object.hash(stepIndex, step);

  @override
  String toString() =>
      'InstructionChangedEvent(stepIndex: $stepIndex, step: "$step")';
}

/// Dispatched when deviation from the route corridor triggers an automated reroute request.
@immutable
final class RerouteStartedEvent extends NavigationEvent {
  /// The GPS fix that confirmed the off-route status and triggered recalculation.
  final LocationFix triggerFix;

  const RerouteStartedEvent({required this.triggerFix});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RerouteStartedEvent &&
          runtimeType == other.runtimeType &&
          triggerFix == other.triggerFix;

  @override
  int get hashCode => triggerFix.hashCode;

  @override
  String toString() => 'RerouteStartedEvent(triggerFix: $triggerFix)';
}

/// Dispatched when an automated reroute attempt fails and navigation falls back to the current route.
@immutable
final class RerouteFailedEvent extends NavigationEvent {
  /// Human-readable explanation of the reroute failure.
  final String reason;

  const RerouteFailedEvent({required this.reason});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RerouteFailedEvent &&
          runtimeType == other.runtimeType &&
          reason == other.reason;

  @override
  int get hashCode => reason.hashCode;

  @override
  String toString() => 'RerouteFailedEvent("$reason")';
}

/// Dispatched once when the device enters the arrival threshold of the destination.
@immutable
final class DestinationReachedEvent extends NavigationEvent {
  /// The target destination coordinate that was reached.
  final GeoPoint destination;

  const DestinationReachedEvent({required this.destination});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DestinationReachedEvent &&
          runtimeType == other.runtimeType &&
          destination == other.destination;

  @override
  int get hashCode => destination.hashCode;

  @override
  String toString() => 'DestinationReachedEvent($destination)';
}

/// Dispatched when an unexpected or non-fatal navigation error occurs.
@immutable
final class NavigationErrorEvent extends NavigationEvent {
  /// The typed navigation exception.
  final NavigationException error;

  const NavigationErrorEvent({required this.error});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NavigationErrorEvent &&
          runtimeType == other.runtimeType &&
          error == other.error;

  @override
  int get hashCode => error.hashCode;

  @override
  String toString() => 'NavigationErrorEvent($error)';
}
