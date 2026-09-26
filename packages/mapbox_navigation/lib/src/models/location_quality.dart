import 'package:meta/meta.dart';
import 'navigation_enums.dart';

/// Summarizes the current quality and timeliness of GPS data.
@immutable
final class LocationQuality {
  /// Timestamp of the last usable fix, or null if no usable fix has been received.
  final DateTime? timestamp;

  /// Accuracy radius in meters of the last usable fix, if known.
  final double? accuracyMeters;

  /// Current freshness rating computed against the freshness policy.
  final LocationFreshness freshness;

  const LocationQuality({
    this.timestamp,
    this.accuracyMeters,
    this.freshness = LocationFreshness.unknown,
  });

  /// Whether the location fix is currently fresh.
  bool get isFresh => freshness == LocationFreshness.fresh;

  /// Whether the location fix has become stale.
  bool get isStale => freshness == LocationFreshness.stale;

  /// Elapsed age of the last usable fix relative to [now].
  ///
  /// Returns null if no fix has been received. Returns [Duration.zero] if
  /// [now] is earlier than [timestamp] (e.g. slight device clock skew).
  Duration? age(DateTime now) {
    final ts = timestamp;
    if (ts == null) return null;
    final diff = now.difference(ts);
    return diff.isNegative ? Duration.zero : diff;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LocationQuality &&
          runtimeType == other.runtimeType &&
          timestamp == other.timestamp &&
          accuracyMeters == other.accuracyMeters &&
          freshness == other.freshness;

  @override
  int get hashCode => Object.hash(timestamp, accuracyMeters, freshness);

  @override
  String toString() =>
      'LocationQuality(freshness: $freshness, acc: ${accuracyMeters?.toStringAsFixed(1)}m, time: $timestamp)';
}
