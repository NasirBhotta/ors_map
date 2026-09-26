import 'dart:async';
import '../models/navigation_enums.dart';

/// Monitors elapsed wall time since the last usable GPS fix to detect staleness.
class FreshnessMonitor {
  final Duration staleTimeout;
  final DateTime Function() clock;
  final void Function(LocationFreshness freshness) onFreshnessChanged;

  Timer? _timer;
  LocationFreshness _currentFreshness = LocationFreshness.unknown;

  FreshnessMonitor({
    required this.staleTimeout,
    required this.onFreshnessChanged,
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now;

  LocationFreshness get currentFreshness => _currentFreshness;

  /// Pure computation of freshness state based on the current clock.
  static LocationFreshness computeFreshness({
    required DateTime now,
    required DateTime? lastUsableFixTimestamp,
    required Duration staleTimeout,
  }) {
    if (lastUsableFixTimestamp == null) return LocationFreshness.unknown;
    final age = now.difference(lastUsableFixTimestamp);
    return age <= staleTimeout
        ? LocationFreshness.fresh
        : LocationFreshness.stale;
  }

  /// Starts the 1-second periodic timer to detect staleness during GPS silence.
  void start(DateTime? Function() getLastUsableFixTimestamp) {
    stop();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      final now = clock();
      final lastFixTime = getLastUsableFixTimestamp();
      final updated = computeFreshness(
        now: now,
        lastUsableFixTimestamp: lastFixTime,
        staleTimeout: staleTimeout,
      );

      if (updated != _currentFreshness) {
        _currentFreshness = updated;
        onFreshnessChanged(updated);
      }
    });
  }

  /// Immediately evaluates freshness against current wall clock time without waiting for the timer.
  void checkNow(DateTime? Function() getLastUsableFixTimestamp) {
    final now = clock();
    final lastFixTime = getLastUsableFixTimestamp();
    final updated = computeFreshness(
      now: now,
      lastUsableFixTimestamp: lastFixTime,
      staleTimeout: staleTimeout,
    );

    if (updated != _currentFreshness) {
      _currentFreshness = updated;
      onFreshnessChanged(updated);
    }
  }

  /// Directly updates the monitor's freshness status on incoming fixes.
  void updateOnFix(LocationFreshness newFreshness) {
    _currentFreshness = newFreshness;
  }

  /// Stops and cancels the periodic timer.
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Disposes the monitor and clears state.
  void dispose() {
    stop();
    _currentFreshness = LocationFreshness.unknown;
  }
}
