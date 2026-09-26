import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mapbox_navigation/src/models/navigation_enums.dart';
import 'package:mapbox_navigation/src/models/navigation_route.dart';
import 'package:mapbox_navigation/src/models/navigation_state.dart';

/// Delegate for platform-specific route drawing operations.
abstract interface class RouteRenderDelegate {
  Future<void> drawRoute(NavigationRoute route);
  Future<void> clearRoute();
  Future<void> updateRouteProgress(
    NavigationRoute route,
    double distanceAlongRouteMeters,
  );
}

/// Token representing a unique generation of a route rendering request.
@immutable
final class RenderGeneration {
  final int sessionId;
  final int routeRevision;
  final int token;

  const RenderGeneration({
    required this.sessionId,
    required this.routeRevision,
    required this.token,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RenderGeneration &&
          runtimeType == other.runtimeType &&
          sessionId == other.sessionId &&
          routeRevision == other.routeRevision &&
          token == other.token;

  @override
  int get hashCode => Object.hash(sessionId, routeRevision, token);

  @override
  String toString() =>
      'RenderGeneration(session: $sessionId, rev: $routeRevision, token: $token)';
}

/// Coordinates structural Mapbox route rendering, ensuring:
/// 1. Generation safety: Obsolete async draw/clear calls cannot mutate newer state.
/// 2. Serialization: Structural operations (draw, replace, clear, style rebuild) execute in FIFO order.
/// 3. Clear/Stop safety: Stopped routes cannot be resurrected; old clears cannot remove new routes.
/// 4. Authoritative progress: Progress line rendering uses only authoritative measured distance.
/// 5. Error containment: Rendering errors are caught and logged without corrupting navigation state.
class MapboxRouteRenderCoordinator {
  final RouteRenderDelegate delegate;
  final void Function(Object error)? onError;
  final double minProgressDeltaMeters;

  int _currentSessionId = 0;
  int _currentRouteRevision = 0;
  int _renderToken = 0;
  bool _disposed = false;

  Future<void> _structuralChain = Future.value();

  // Progress update coalescing
  bool _progressUpdateInFlight = false;
  double? _queuedProgressDistance;
  double? _lastRenderedProgressDistance;

  MapboxRouteRenderCoordinator({
    required this.delegate,
    this.onError,
    this.minProgressDeltaMeters = 2.0,
  });

  bool get isDisposed => _disposed;

  RenderGeneration get currentGeneration => RenderGeneration(
        sessionId: _currentSessionId,
        routeRevision: _currentRouteRevision,
        token: _renderToken,
      );

  bool isCurrent(RenderGeneration gen) {
    if (_disposed) return false;
    return gen.sessionId == _currentSessionId &&
        gen.routeRevision == _currentRouteRevision &&
        gen.token == _renderToken;
  }

  /// Schedules a structural route draw for the given [sessionId] and [routeRevision].
  Future<void> scheduleDraw({
    required int sessionId,
    required int routeRevision,
    required NavigationRoute route,
  }) {
    if (_disposed) return Future.value();

    _currentSessionId = sessionId;
    _currentRouteRevision = routeRevision;
    final token = ++_renderToken;
    final generation = RenderGeneration(
      sessionId: sessionId,
      routeRevision: routeRevision,
      token: token,
    );

    // Reset progress tracking for new route
    _lastRenderedProgressDistance = null;
    _queuedProgressDistance = null;

    return _enqueueStructural(() async {
      if (!isCurrent(generation)) return;
      await delegate.drawRoute(route);
      if (!isCurrent(generation)) return;
    });
  }

  /// Schedules a structural route clear for the given [sessionId].
  Future<void> scheduleClear(int sessionId) {
    if (_disposed) return Future.value();

    _currentSessionId = sessionId;
    _currentRouteRevision = 0;
    final token = ++_renderToken;
    final generation = RenderGeneration(
      sessionId: sessionId,
      routeRevision: 0,
      token: token,
    );

    _lastRenderedProgressDistance = null;
    _queuedProgressDistance = null;

    return _enqueueStructural(() async {
      if (!isCurrent(generation)) return;
      await delegate.clearRoute();
      if (!isCurrent(generation)) return;
    });
  }

  /// Handles Mapbox style reload by rebuilding visual resources for the
  /// authoritative [NavigationState] without mutating or resurrecting obsolete routes.
  Future<void> onStyleReloaded(NavigationState? state) {
    if (_disposed) return Future.value();

    if (state == null ||
        state.activeRoute == null ||
        state.status == NavigationStatus.stopped ||
        state.status == NavigationStatus.idle ||
        state.status == NavigationStatus.arrived ||
        state.status == NavigationStatus.disposed) {
      return scheduleClear(state != null ? _currentSessionId : _currentSessionId);
    }

    return scheduleDraw(
      sessionId: _currentSessionId,
      routeRevision: _currentRouteRevision,
      route: state.activeRoute!,
    );
  }

  /// Schedules a lightweight route progress update based purely on authoritative
  /// measured distance. Coalesces rapid updates without recreating layers or sources.
  void scheduleProgressUpdate({
    required int sessionId,
    required int routeRevision,
    required NavigationRoute route,
    required double distanceAlongRouteMeters,
  }) {
    if (_disposed) return;
    if (sessionId != _currentSessionId ||
        routeRevision != _currentRouteRevision) {
      return;
    }

    _queuedProgressDistance = distanceAlongRouteMeters;
    if (_progressUpdateInFlight) return;

    _drainProgressUpdates(sessionId, routeRevision, route);
  }

  Future<void> _drainProgressUpdates(
    int sessionId,
    int routeRevision,
    NavigationRoute route,
  ) async {
    _progressUpdateInFlight = true;
    while (_queuedProgressDistance != null && !_disposed) {
      if (sessionId != _currentSessionId ||
          routeRevision != _currentRouteRevision) {
        _queuedProgressDistance = null;
        break;
      }

      final dist = _queuedProgressDistance!;
      _queuedProgressDistance = null;

      if (dist == _lastRenderedProgressDistance) continue;
      if (_lastRenderedProgressDistance != null &&
          (dist - _lastRenderedProgressDistance!).abs() < minProgressDeltaMeters &&
          dist < route.totalDistanceMeters) {
        continue;
      }

      try {
        await delegate.updateRouteProgress(route, dist);
        _lastRenderedProgressDistance = dist;
      } catch (error) {
        onError?.call(error);
      }
    }
    _progressUpdateInFlight = false;
  }

  Future<void> _enqueueStructural(Future<void> Function() action) {
    if (_disposed) return Future.value();

    final completer = Completer<void>();
    _structuralChain = _structuralChain.then((_) async {
      if (_disposed) return;
      try {
        await action();
      } catch (error) {
        onError?.call(error);
      }
    }).whenComplete(() {
      if (!completer.isCompleted) {
        completer.complete();
      }
    });

    return completer.future;
  }

  /// Disposes coordinator, invalidates pending generations, and prevents further native operations.
  void dispose() {
    _disposed = true;
    _renderToken++;
    _queuedProgressDistance = null;
  }
}
