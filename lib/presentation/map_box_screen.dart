// import 'dart:async';
// import 'dart:math';
// import 'dart:typed_data';
// import 'dart:ui' as ui;

// import 'package:flutter/material.dart';
// import 'package:flutter/services.dart';
// import 'package:flutter_compass/flutter_compass.dart';
// import 'package:geolocator/geolocator.dart' as geolocator;
// import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;
// import 'package:ors_map_test/services/ors_service.dart';
// import 'package:ors_map_test/services/tts_service.dart';
// import 'package:ors_map_test/widgets/places_search.dart';

// // NOTE: google_maps_flutter import NAHI karo — conflict hoga

// class MapboxScreen extends StatefulWidget {
//   const MapboxScreen({super.key});

//   @override
//   State<MapboxScreen> createState() => _MapboxScreenState();
// }

// class _MapboxScreenState extends State<MapboxScreen> {
//   // ── Map ───────────────────────────────────────
//   mapbox.MapboxMap? _mapboxMap;

//   // Annotation managers
//   mapbox.PolylineAnnotationManager? _polylineManager;
//   mapbox.PointAnnotationManager? _pointManager;

//   // Annotations
//   mapbox.PointAnnotation? _carAnnotation;
//   mapbox.PointAnnotation? _destAnnotation;
//   mapbox.PolylineAnnotation? _routeAnnotation;
//   mapbox.PolylineAnnotation? _traveledAnnotation;

//   // ── Location ──────────────────────────────────
//   mapbox.Position? _currentPos;
//   double _heading = 0;

//   // ── Route ─────────────────────────────────────
//   List<mapbox.Position> _fullRoute = [];
//   RouteResult? _routeResult;
//   mapbox.Position? _destinationPos;

//   // ── Navigation State ──────────────────────────
//   bool _isNavigating = false;
//   bool _startNavigation = false;
//   bool _isLoading = false;
//   int _currentStepIndex = 0;
//   int _offRouteCount = 0;
//   bool _isRerouting = false;
//   DateTime? _navigationStartTime;

//   // ── Live Stats ────────────────────────────────
//   double _currentSpeedKmh = 0;
//   double _remainingDistanceM = 0;
//   String _arrivalTime = '';

//   // ── UI ────────────────────────────────────────
//   bool _isNightMode = false;

//   // ── Streams ───────────────────────────────────
//   StreamSubscription<geolocator.Position>? _gpsSub;
//   StreamSubscription<CompassEvent>? _compassSub;

//   // ── Services ──────────────────────────────────
//   final TtsService _tts = TtsService();

//   // ── Defaults ──────────────────────────────────
//   // Islamabad — lon, lat order (Mapbox convention)
//   static final _defaultPos = mapbox.Position(73.0479, 33.6844);

//   mapbox.PointAnnotation? _locationAnnotation; // add this field

//   // ─────────────────────────────────────────────
//   @override
//   void initState() {
//     super.initState();
//     _initLocation();
//     _startCompass();
//   }

//   @override
//   void dispose() {
//     _gpsSub?.cancel();
//     _compassSub?.cancel();
//     _tts.stop();
//     super.dispose();
//   }

//   // ══════════════════════════════════════════════
//   // COMPASS
//   // ══════════════════════════════════════════════

//   void _startCompass() {
//     _compassSub = FlutterCompass.events?.listen((CompassEvent event) {
//       if (event.heading == null) return;
//       // Sirf tab compass use karo jab GPS heading nahi aa rahi
//       // (gaadi ruki ho ya GPS stream band ho)
//       if (_gpsSub == null && mounted) {
//         setState(() => _heading = event.heading!);
//       }
//     });
//   }

//   Future<void> _updateLocationMarker(mapbox.Position pos) async {
//     if (_pointManager == null) return;
//     if (_locationAnnotation == null) {
//       _locationAnnotation = await _pointManager!.create(
//         mapbox.PointAnnotationOptions(
//           geometry: mapbox.Point(coordinates: pos),
//           iconImage: 'location_puck', // register this icon below
//           iconSize: 1.5,
//         ),
//       );
//     } else {
//       _locationAnnotation!.geometry = mapbox.Point(coordinates: pos);
//       await _pointManager!.update(_locationAnnotation!);
//     }
//   }
//   // ══════════════════════════════════════════════
//   // LOCATION PERMISSION + INIT
//   // ══════════════════════════════════════════════

//   Future<void> _initLocation() async {
//     geolocator.LocationPermission permission =
//         await geolocator.Geolocator.checkPermission();

//     if (permission == geolocator.LocationPermission.denied) {
//       permission = await geolocator.Geolocator.requestPermission();
//       if (permission == geolocator.LocationPermission.denied) {
//         if (mounted) setState(() => _currentPos = _defaultPos);
//         return;
//       }
//     }

//     if (permission == geolocator.LocationPermission.deniedForever) {
//       if (mounted) setState(() => _currentPos = _defaultPos);
//       return;
//     }

//     try {
//       final position = await geolocator.Geolocator.getCurrentPosition(
//         locationSettings: const geolocator.LocationSettings(
//           accuracy: geolocator.LocationAccuracy.high,
//         ),
//       );

//       if (!mounted) return;
//       setState(() {
//         _currentPos = mapbox.Position(position.longitude, position.latitude);
//         _updateLocationMarker(_currentPos!);
//       });

//       _mapboxMap?.setCamera(
//         mapbox.CameraOptions(
//           center: mapbox.Point(coordinates: _currentPos!),
//           zoom: 15,
//         ),
//       );
//     } catch (e) {
//       if (mounted) setState(() => _currentPos = _defaultPos);
//     }
//   }

//   // ══════════════════════════════════════════════
//   // GPS LIVE TRACKING
//   // ══════════════════════════════════════════════

//   void _startLiveTracking() {
//     _gpsSub?.cancel();

//     _gpsSub = geolocator.Geolocator.getPositionStream(
//       locationSettings: const geolocator.LocationSettings(
//         accuracy: geolocator.LocationAccuracy.high,
//         distanceFilter: 10, // har 10 meter par update
//       ),
//     ).listen((position) {
//       final newPos = mapbox.Position(position.longitude, position.latitude);
//       final speedKmh = (position.speed * 3.6).clamp(0.0, 300.0);

//       if (!mounted) return;
//       setState(() {
//         _currentPos = newPos;
//         _currentSpeedKmh = speedKmh;
//         // GPS heading sirf tab use karo jab gaadi chal rahi ho
//         if (position.speed > 0.5 && !position.heading.isNaN) {
//           _heading = position.heading;
//         }
//       });

//       // Car marker — sirf navigation mein update karo
//       if (_isNavigating) {
//         _updateCarMarker(newPos);
//       }

//       // Route progress update
//       if (_fullRoute.isNotEmpty) {
//         _updateProgress(newPos);
//       }

//       // Navigation camera — car ke saath move kare
//       if (_isNavigating && _fullRoute.isNotEmpty) {
//         _mapboxMap?.setCamera(
//           mapbox.CameraOptions(
//             center: mapbox.Point(coordinates: newPos),
//             zoom: 19,
//             pitch: 60,
//             bearing: _heading,
//           ),
//         );
//       }
//     });
//   }

//   // ══════════════════════════════════════════════
//   // CAR MARKER — sirf navigation mein dikhao
//   // ══════════════════════════════════════════════

//   Future<void> _updateCarMarker(mapbox.Position pos) async {
//     if (_pointManager == null) return;

//     // Sirf _isNavigating mein hi car dikhao
//     if (!_isNavigating) {
//       // Navigation band ho gayi — car hata do
//       if (_carAnnotation != null) {
//         await _pointManager!.delete(_carAnnotation!);
//         _carAnnotation = null;
//       }
//       return;
//     }

//     if (_carAnnotation == null) {
//       // Pehli baar banao
//       _carAnnotation = await _pointManager!.create(
//         mapbox.PointAnnotationOptions(
//           geometry: mapbox.Point(coordinates: pos),
//           iconImage: 'car_icon', // style mein register hona chahiye
//           iconSize: 0.5,
//           iconRotate: _heading,
//         ),
//       );
//     } else {
//       // Update karo position + rotation
//       _carAnnotation!.geometry = mapbox.Point(coordinates: pos);
//       _carAnnotation!.iconRotate = _heading;
//       await _pointManager!.update(_carAnnotation!);
//     }
//   }

//   // Car icon ko Mapbox style mein register karo (PNG asset se)
//   Future<void> _registerCarIcon(mapbox.MapboxMap map) async {
//     try {
//       // Asset se bytes load karo
//       final ByteData data = await rootBundle.load('assets/car_icon.png');
//       final Uint8List bytes = data.buffer.asUint8List();

//       // Image decode karo dimensions ke liye
//       final ui.Codec codec = await ui.instantiateImageCodec(bytes);
//       final ui.FrameInfo fi = await codec.getNextFrame();
//       final int w = fi.image.width;
//       final int h = fi.image.height;

//       // Mapbox style mein register karo
//       await map.style.addStyleImage(
//         'car_icon',
//         1.0, // scale
//         mapbox.MbxImage(width: w, height: h, data: bytes),
//         false, // sdf
//         [], // stretchX
//         [], // stretchY
//         null, // content
//       );
//     } catch (e) {
//       debugPrint('Car icon register error: $e');
//     }
//   }

//   // Destination icon bhi register karo
//   Future<void> _registerDestinationIcon(mapbox.MapboxMap map) async {
//     try {
//       final ByteData data = await rootBundle.load(
//         'assets/destination_icon.png',
//       );
//       final Uint8List bytes = data.buffer.asUint8List();

//       final ui.Codec codec = await ui.instantiateImageCodec(bytes);
//       final ui.FrameInfo fi = await codec.getNextFrame();

//       await map.style.addStyleImage(
//         'destination_icon',
//         1.0,
//         mapbox.MbxImage(
//           width: fi.image.width,
//           height: fi.image.height,
//           data: bytes,
//         ),
//         false,
//         [],
//         [],
//         null,
//       );
//     } catch (e) {
//       debugPrint('Destination icon register error: $e');
//     }
//   }

//   // ══════════════════════════════════════════════
//   // ROUTE PROGRESS
//   // ══════════════════════════════════════════════

//   void _updateProgress(mapbox.Position carPos) {
//     if (_fullRoute.isEmpty) return;

//     // Sabse nazdik route point dhundo
//     int closestIndex = 0;
//     double minDist = double.infinity;

//     for (int i = 0; i < _fullRoute.length; i++) {
//       final d = _haversineMeters(carPos, _fullRoute[i]);
//       if (d < minDist) {
//         minDist = d;
//         closestIndex = i;
//       }
//     }

//     // ── Off route check ──────────────────────────
//     if (minDist > 50 && _destinationPos != null) {
//       if (_isRerouting) return;

//       // Navigation abhi shuru hua — 8 seconds wait karo GPS settle hone do
//       if (_navigationStartTime != null) {
//         final elapsed = DateTime.now().difference(_navigationStartTime!);
//         if (elapsed.inSeconds < 8) return;
//       }

//       _offRouteCount++;
//       if (_offRouteCount < 3) return; // 3 consecutive off-route = reroute

//       _offRouteCount = 0;
//       _isRerouting = true;
//       _getRoute(carPos, _destinationPos!).then((_) => _isRerouting = false);
//       return;
//     }

//     _offRouteCount = 0;

//     // ── Remaining distance ───────────────────────
//     double remaining = 0;
//     for (int i = closestIndex; i < _fullRoute.length - 1; i++) {
//       remaining += _haversineMeters(_fullRoute[i], _fullRoute[i + 1]);
//     }

//     // ── Arrival time ─────────────────────────────
//     String arrival = '';
//     if (_currentSpeedKmh > 5) {
//       // Gaadi chal rahi hai — actual speed se calculate karo
//       final speedMs = _currentSpeedKmh / 3.6;
//       final secondsLeft = remaining / speedMs;
//       final arrivalDateTime = DateTime.now().add(
//         Duration(seconds: secondsLeft.toInt()),
//       );
//       final h = arrivalDateTime.hour;
//       final m = arrivalDateTime.minute.toString().padLeft(2, '0');
//       final period = h >= 12 ? 'PM' : 'AM';
//       final displayH = h % 12 == 0 ? 12 : h % 12;
//       arrival = '$displayH:$m $period';
//     } else {
//       // Gaadi ruki hai — ORS duration se estimate karo
//       if (_routeResult != null && _routeResult!.distanceMeters > 0) {
//         final secondsLeft =
//             (_routeResult!.durationSeconds *
//                     (remaining / _routeResult!.distanceMeters))
//                 .toInt();
//         final arrivalDateTime = DateTime.now().add(
//           Duration(seconds: secondsLeft),
//         );
//         final h = arrivalDateTime.hour;
//         final m = arrivalDateTime.minute.toString().padLeft(2, '0');
//         final period = h >= 12 ? 'PM' : 'AM';
//         final displayH = h % 12 == 0 ? 12 : h % 12;
//         arrival = '$displayH:$m $period';
//       }
//     }

//     if (mounted) {
//       setState(() {
//         _remainingDistanceM = remaining;
//         _arrivalTime = arrival;
//       });
//     }

//     // Step advance check — sirf navigation mein
//     if (_isNavigating) _checkStepAdvance(carPos);

//     // Polyline update — gray + yellow
//     _updateRoutePolyline(closestIndex);
//   }

//   // ══════════════════════════════════════════════
//   // POLYLINE UPDATE
//   // ══════════════════════════════════════════════

//   Future<void> _updateRoutePolyline(int closestIndex) async {
//     if (_polylineManager == null || _fullRoute.isEmpty) return;

//     // Traveled portion — gray
//     if (_traveledAnnotation != null) {
//       _traveledAnnotation!.geometry = mapbox.LineString(
//         coordinates: _fullRoute.sublist(0, closestIndex + 1),
//       );
//       await _polylineManager!.update(_traveledAnnotation!);
//     }

//     // Remaining portion — yellow
//     if (_routeAnnotation != null) {
//       _routeAnnotation!.geometry = mapbox.LineString(
//         coordinates: _fullRoute.sublist(closestIndex),
//       );
//       await _polylineManager!.update(_routeAnnotation!);
//     }
//   }

//   // ══════════════════════════════════════════════
//   // GET ROUTE
//   // ══════════════════════════════════════════════

//   Future<void> _getRoute(mapbox.Position from, mapbox.Position to) async {
//     if (mounted) setState(() => _isLoading = true);

//     // OrsService ab sirf doubles leta hai — koi LatLng wrapper nahi chahiye
//     final result = await OrsService.getRoute(
//       fromLat: from.lat as double,
//       fromLng: from.lng as double,
//       toLat: to.lat as double,
//       toLng: to.lng as double,
//     );

//     if (result == null) {
//       if (mounted) {
//         setState(() => _isLoading = false);
//         ScaffoldMessenger.of(context).showSnackBar(
//           const SnackBar(
//             content: Text('Route nahi mila — internet check karo'),
//             backgroundColor: Colors.red,
//           ),
//         );
//       }
//       return;
//     }

//     // ORS LatLng → Mapbox Position
//     final routePositions =
//         result.points
//             .map((p) => mapbox.Position(p.longitude, p.latitude))
//             .toList();

//     if (mounted) {
//       setState(() {
//         _isLoading = false;
//         _routeResult = result;
//         _fullRoute = routePositions;
//       });
//     }

//     // Purani polylines hatao
//     await _polylineManager?.deleteAll();
//     _routeAnnotation = null;
//     _traveledAnnotation = null;

//     // Traveled (gray) — initially sirf ek point
//     _traveledAnnotation = await _polylineManager?.create(
//       mapbox.PolylineAnnotationOptions(
//         geometry: mapbox.LineString(coordinates: routePositions.sublist(0, 1)),
//         lineColor: Colors.grey.shade400.value,
//         lineWidth: 5,
//       ),
//     );

//     // Remaining (yellow) — poori route
//     _routeAnnotation = await _polylineManager?.create(
//       mapbox.PolylineAnnotationOptions(
//         geometry: mapbox.LineString(coordinates: routePositions),
//         lineColor: Colors.yellow.value,
//         lineWidth: 6,
//       ),
//     );

//     _fitBounds(from, to);
//   }

//   // ══════════════════════════════════════════════
//   // FIT BOUNDS
//   // ══════════════════════════════════════════════

//   Future<void> _fitBounds(mapbox.Position a, mapbox.Position b) async {
//     final minLng = min(a.lng as double, b.lng as double);
//     final maxLng = max(a.lng as double, b.lng as double);
//     final minLat = min(a.lat as double, b.lat as double);
//     final maxLat = max(a.lat as double, b.lat as double);

//     await _mapboxMap
//         ?.cameraForCoordinateBounds(
//           mapbox.CoordinateBounds(
//             southwest: mapbox.Point(
//               coordinates: mapbox.Position(minLng, minLat),
//             ),
//             northeast: mapbox.Point(
//               coordinates: mapbox.Position(maxLng, maxLat),
//             ),
//             infiniteBounds: false,
//           ),
//           mapbox.MbxEdgeInsets(top: 80, left: 80, bottom: 200, right: 80),
//           null,
//           null,
//           null,
//           null,
//         )
//         .then((camera) => _mapboxMap?.setCamera(camera));
//   }

//   // ══════════════════════════════════════════════
//   // MAP TAP — destination set
//   // ══════════════════════════════════════════════

//   void _onMapTapped(mapbox.Position tappedPos) async {
//     if (_currentPos == null) return;
//     if (_pointManager == null) return;
//     _destinationPos = tappedPos;

//     // Destination marker lagao
//     if (_pointManager != null) {
//       if (_destAnnotation != null) {
//         await _pointManager!.delete(_destAnnotation!);
//         _destAnnotation = null;
//       }
//       _destAnnotation = await _pointManager!.create(
//         mapbox.PointAnnotationOptions(
//           geometry: mapbox.Point(coordinates: tappedPos),
//           iconImage: 'marker',
//           iconSize: 0.5,
//         ),
//       );
//     }

//     if (mounted) {
//       setState(() {
//         _fullRoute = [];
//         _routeResult = null;
//       });
//     }

//     await _getRoute(_currentPos!, tappedPos);
//   }

//   // ══════════════════════════════════════════════
//   // STEP ADVANCE — navigation turn-by-turn
//   // ══════════════════════════════════════════════

//   void _checkStepAdvance(mapbox.Position carPos) {
//     if (!_isNavigating) return;
//     if (_routeResult == null || _routeResult!.steps.isEmpty) return;

//     // Last step — destination check karo
//     if (_currentStepIndex >= _routeResult!.steps.length - 1) {
//       if (_destinationPos != null) {
//         final dist = _haversineMeters(carPos, _destinationPos!);
//         if (dist < 30) _onDestinationReached(); // 30m ke andar = pahunch gaye
//       }
//       return;
//     }

//     final endPoint = _getStepEndPoint(_currentStepIndex);
//     final distance = _haversineMeters(carPos, endPoint);

//     // 25 meter se kam → next step
//     if (distance < 25) {
//       if (mounted) setState(() => _currentStepIndex++);
//       _tts.speak(_routeResult!.steps[_currentStepIndex].instruction);
//     }
//   }

//   mapbox.Position _getStepEndPoint(int stepIndex) {
//     if (_fullRoute.isEmpty) return _currentPos ?? _defaultPos;

//     double cumulative = 0;
//     for (int i = 0; i <= stepIndex; i++) {
//       cumulative += _routeResult!.steps[i].distance;
//     }

//     final ratio = (cumulative / _routeResult!.distanceMeters).clamp(0.0, 1.0);
//     final index = (ratio * (_fullRoute.length - 1)).toInt();
//     return _fullRoute[index];
//   }

//   // ══════════════════════════════════════════════
//   // DESTINATION REACHED
//   // ══════════════════════════════════════════════

//   void _onDestinationReached() {
//     _tts.speak('You have reached your destination');
//     _gpsSub?.cancel();
//     _gpsSub = null;

//     if (!mounted) return;
//     setState(() {
//       _isNavigating = false;
//       _startNavigation = false;
//       _currentStepIndex = 0;
//     });

//     // Car annotation hata do
//     if (_carAnnotation != null) {
//       _pointManager?.delete(_carAnnotation!);
//       _carAnnotation = null;
//     }

//     showDialog(
//       context: context,
//       builder:
//           (_) => AlertDialog(
//             title: const Text('🎉 Pahunch Gaye!'),
//             content: const Text('Aap apni destination par pahunch gaye.'),
//             actions: [
//               TextButton(
//                 onPressed: () {
//                   Navigator.pop(context);
//                   if (!mounted) return;
//                   setState(() {
//                     _destinationPos = null;
//                     _fullRoute = [];
//                     _routeResult = null;
//                   });
//                   _polylineManager?.deleteAll();
//                   _routeAnnotation = null;
//                   _traveledAnnotation = null;
//                   if (_destAnnotation != null) {
//                     _pointManager?.delete(_destAnnotation!);
//                     _destAnnotation = null;
//                   }
//                 },
//                 child: const Text('Done'),
//               ),
//             ],
//           ),
//     );
//   }

//   // ══════════════════════════════════════════════
//   // NIGHT MODE
//   // ══════════════════════════════════════════════

//   Future<void> _applyMapStyle() async {
//     final uri =
//         _isNightMode ? mapbox.MapboxStyles.DARK : mapbox.MapboxStyles.STANDARD;
//     await _mapboxMap?.loadStyleURI(uri);
//     // Style reload hone ke baad icons phir se register karne honge
//     if (_mapboxMap != null) {
//       await _registerCarIcon(_mapboxMap!);
//       await _registerDestinationIcon(_mapboxMap!);

//       _polylineManager =
//           await _mapboxMap!.annotations.createPolylineAnnotationManager();
//       _pointManager =
//           await _mapboxMap!.annotations.createPointAnnotationManager();

//       if (_fullRoute.isNotEmpty &&
//           _currentPos != null &&
//           _destinationPos != null) {
//         await _getRoute(_currentPos!, _destinationPos!);
//       }
//     }
//   }

//   // ══════════════════════════════════════════════
//   // HELPERS
//   // ══════════════════════════════════════════════

//   double _haversineMeters(mapbox.Position a, mapbox.Position b) {
//     const R = 6371000.0;
//     final dLat = ((b.lat as double) - (a.lat as double)) * pi / 180;
//     final dLng = ((b.lng as double) - (a.lng as double)) * pi / 180;
//     final h =
//         pow(sin(dLat / 2), 2) +
//         cos((a.lat as double) * pi / 180) *
//             cos((b.lat as double) * pi / 180) *
//             pow(sin(dLng / 2), 2);
//     return 2 * R * asin(sqrt(h.toDouble()));
//   }

//   // ══════════════════════════════════════════════
//   // MAP CREATED CALLBACK
//   // ══════════════════════════════════════════════

//   Future<void> _onMapCreated(mapbox.MapboxMap map) async {
//     _mapboxMap = map;

//     await map.location.updateSettings(
//       mapbox.LocationComponentSettings(enabled: true, pulsingEnabled: true),
//     );
//     // 3D buildings on
//     await map.style.setStyleImportConfigProperty(
//       'basemap',
//       'show3dObjects',
//       true,
//     );

//     // Custom icons register karo
//     await _registerCarIcon(map);
//     await _registerDestinationIcon(map);

//     // Annotation managers
//     _polylineManager = await map.annotations.createPolylineAnnotationManager();
//     _pointManager = await map.annotations.createPointAnnotationManager();

//     // Agar location pehle se aa gayi thi — camera wahan le jao
//     if (_currentPos != null) {
//       map.setCamera(
//         mapbox.CameraOptions(
//           center: mapbox.Point(coordinates: _currentPos!),
//           zoom: 15,
//         ),
//       );
//     }
//   }

//   // ══════════════════════════════════════════════
//   // BUILD
//   // ══════════════════════════════════════════════

//   @override
//   Widget build(BuildContext context) {
//     return Scaffold(
//       body: Stack(
//         children: [
//           // ── Mapbox Map ────────────────────────────
//           mapbox.MapWidget(
//             cameraOptions: mapbox.CameraOptions(
//               center: mapbox.Point(coordinates: _currentPos ?? _defaultPos),
//               zoom: 15,
//               pitch: 0,
//             ),
//             styleUri: mapbox.MapboxStyles.STANDARD,
//             onMapCreated: _onMapCreated,
//             onTapListener: (context) {
//               // Navigation chal rahi ho toh tap se destination change nahi hona chahiye
//               if (_isNavigating) return;
//               final pos = mapbox.Position(
//                 context.point.coordinates.lng as double,
//                 context.point.coordinates.lat as double,
//               );
//               _onMapTapped(pos);
//             },
//           ),

//           // ── Search Bar (navigation mein nahi dikhega) ─
//           if (!_isNavigating)
//             Positioned(
//               top: 0,
//               left: 0,
//               right: 0,
//               child: SafeArea(
//                 child: PlacesSearch(
//                   onPlaceSelected: (latLng) {
//                     _onMapTapped(
//                       mapbox.Position(latLng.longitude, latLng.latitude),
//                     );
//                   },
//                 ),
//               ),
//             ),

//           // ── Navigation HUD ────────────────────────
//           if (_isNavigating &&
//               _routeResult != null &&
//               _routeResult!.steps.isNotEmpty)
//             Positioned(
//               top: 0,
//               left: 0,
//               right: 0,
//               child: SafeArea(child: _buildNavCard()),
//             ),

//           // ── Loading Overlay ───────────────────────
//           if (_isLoading)
//             Container(
//               color: Colors.black.withOpacity(0.3),
//               child: const Center(
//                 child: Card(
//                   child: Padding(
//                     padding: EdgeInsets.all(20),
//                     child: Column(
//                       mainAxisSize: MainAxisSize.min,
//                       children: [
//                         CircularProgressIndicator(color: Colors.yellow),
//                         SizedBox(height: 12),
//                         Text('Route dhoondh raha hun...'),
//                       ],
//                     ),
//                   ),
//                 ),
//               ),
//             ),

//           // ── Clear Destination Marker FAB ──────────
//           // Google Maps jaise — destination marker hata do
//           if (_destAnnotation != null && !_isNavigating)
//             Positioned(
//               bottom: _routeResult != null ? 250 : 230,
//               left: 16,
//               child: FloatingActionButton.small(
//                 heroTag: 'clearMarker',
//                 backgroundColor: Colors.red,
//                 onPressed: () async {
//                   if (_destAnnotation != null) {
//                     await _pointManager?.delete(_destAnnotation!);
//                     setState(() {
//                       _destAnnotation = null;
//                       _destinationPos = null;
//                     });
//                   }
//                 },
//                 child: const Icon(Icons.clear, color: Colors.white),
//               ),
//             ),

//           // ── My Location FAB ───────────────────────
//           Positioned(
//             bottom: _routeResult != null ? 220 : 180,
//             left: 16,
//             child: FloatingActionButton.small(
//               heroTag: 'myLocation',
//               backgroundColor:
//                   _isNightMode ? const Color(0xFF1A1A2E) : Colors.white,
//               onPressed: () async {
//                 try {
//                   final pos = await geolocator.Geolocator.getCurrentPosition();
//                   _mapboxMap?.setCamera(
//                     mapbox.CameraOptions(
//                       center: mapbox.Point(
//                         coordinates: mapbox.Position(
//                           pos.longitude,
//                           pos.latitude,
//                         ),
//                       ),
//                       zoom: 17,
//                     ),
//                   );
//                 } catch (e) {
//                   debugPrint('Location error: $e');
//                 }
//               },
//               child: Icon(
//                 Icons.my_location,
//                 color: _isNightMode ? Colors.white : Colors.black87,
//               ),
//             ),
//           ),

//           // ── Night Mode FAB ────────────────────────
//           Positioned(
//             left: 16,
//             bottom: _routeResult != null ? 170 : 130,
//             child: FloatingActionButton.small(
//               heroTag: 'nightMode',
//               backgroundColor:
//                   _isNightMode ? const Color(0xFF1A1A2E) : Colors.white,
//               onPressed: () {
//                 setState(() => _isNightMode = !_isNightMode);
//                 _applyMapStyle();
//               },
//               child: Icon(
//                 _isNightMode ? Icons.wb_sunny_rounded : Icons.nightlight_round,
//                 color: _isNightMode ? Colors.yellow : Colors.indigo,
//               ),
//             ),
//           ),

//           // ── Bottom Card ───────────────────────────
//           if (_routeResult != null)
//             Positioned(bottom: 0, left: 0, right: 0, child: _buildBottomCard()),
//         ],
//       ),
//     );
//   }

//   // ══════════════════════════════════════════════
//   // NAV CARD — turn-by-turn instruction
//   // ══════════════════════════════════════════════

//   Widget _buildNavCard() {
//     final steps = _routeResult!.steps;
//     final current = steps[_currentStepIndex];
//     final hasNext = _currentStepIndex + 1 < steps.length;
//     final next = hasNext ? steps[_currentStepIndex + 1] : null;

//     return Container(
//       margin: const EdgeInsets.all(12),
//       decoration: BoxDecoration(
//         color: const Color(0xFF1A1A2E),
//         borderRadius: BorderRadius.circular(16),
//         boxShadow: [BoxShadow(color: Colors.black38, blurRadius: 12)],
//       ),
//       child: Column(
//         mainAxisSize: MainAxisSize.min,
//         children: [
//           // Current step
//           Padding(
//             padding: const EdgeInsets.all(16),
//             child: Row(
//               children: [
//                 Container(
//                   padding: const EdgeInsets.all(12),
//                   decoration: BoxDecoration(
//                     color: Colors.white12,
//                     borderRadius: BorderRadius.circular(12),
//                   ),
//                   child: Icon(current.icon, color: Colors.white, size: 32),
//                 ),
//                 const SizedBox(width: 14),
//                 Expanded(
//                   child: Column(
//                     crossAxisAlignment: CrossAxisAlignment.start,
//                     children: [
//                       Text(
//                         current.distanceText,
//                         style: const TextStyle(
//                           color: Color(0xFF4FC3F7),
//                           fontSize: 22,
//                           fontWeight: FontWeight.bold,
//                         ),
//                       ),
//                       const SizedBox(height: 4),
//                       Text(
//                         current.instruction,
//                         style: const TextStyle(
//                           color: Colors.white,
//                           fontSize: 14,
//                         ),
//                         maxLines: 2,
//                         overflow: TextOverflow.ellipsis,
//                       ),
//                     ],
//                   ),
//                 ),
//               ],
//             ),
//           ),

//           // Next step preview
//           if (next != null)
//             Container(
//               padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
//               decoration: const BoxDecoration(
//                 color: Colors.white10,
//                 borderRadius: BorderRadius.vertical(
//                   bottom: Radius.circular(16),
//                 ),
//               ),
//               child: Row(
//                 children: [
//                   Icon(next.icon, color: Colors.white60, size: 18),
//                   const SizedBox(width: 8),
//                   Expanded(
//                     child: Text(
//                       'Then: ${next.instruction}',
//                       style: const TextStyle(
//                         color: Colors.white60,
//                         fontSize: 12,
//                       ),
//                       maxLines: 1,
//                       overflow: TextOverflow.ellipsis,
//                     ),
//                   ),
//                 ],
//               ),
//             ),
//         ],
//       ),
//     );
//   }

//   // ══════════════════════════════════════════════
//   // BOTTOM CARD — route info + buttons
//   // ══════════════════════════════════════════════

//   Widget _buildBottomCard() {
//     return Container(
//       decoration: const BoxDecoration(
//         color: Colors.white,
//         borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
//       ),
//       padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
//       child: Column(
//         mainAxisSize: MainAxisSize.min,
//         children: [
//           // Handle bar
//           Container(
//             width: 40,
//             height: 4,
//             decoration: BoxDecoration(
//               color: Colors.grey.shade300,
//               borderRadius: BorderRadius.circular(2),
//             ),
//           ),
//           const SizedBox(height: 16),

//           // Distance + Duration cards
//           Row(
//             children: [
//               Expanded(
//                 child: _statCard(
//                   icon: Icons.route_rounded,
//                   value: _routeResult!.distanceText,
//                   label: 'Distance',
//                   color: const Color(0xFFEFF6FF),
//                   valueColor: const Color(0xFF1E3A8A),
//                   iconColor: const Color(0xFF4285F4),
//                 ),
//               ),
//               const SizedBox(width: 12),
//               Expanded(
//                 child: _statCard(
//                   icon: Icons.timer_rounded,
//                   value: _routeResult!.durationText,
//                   label: 'Duration',
//                   color: const Color(0xFFF0FDF4),
//                   valueColor: const Color(0xFF14532D),
//                   iconColor: const Color(0xFF16A34A),
//                 ),
//               ),
//             ],
//           ),
//           const SizedBox(height: 12),

//           // Live stats — sirf navigation mein
//           if (_isNavigating)
//             Container(
//               margin: const EdgeInsets.only(bottom: 12),
//               padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
//               decoration: BoxDecoration(
//                 color: const Color(0xFF1A1A2E),
//                 borderRadius: BorderRadius.circular(14),
//               ),
//               child: Row(
//                 mainAxisAlignment: MainAxisAlignment.spaceBetween,
//                 children: [
//                   _navStat(_currentSpeedKmh.toStringAsFixed(0), 'km/h'),
//                   Container(width: 1, height: 36, color: Colors.white24),
//                   _navStat(
//                     _remainingDistanceM >= 1000
//                         ? (_remainingDistanceM / 1000).toStringAsFixed(1)
//                         : '${_remainingDistanceM.toInt()}',
//                     _remainingDistanceM >= 1000 ? 'km left' : 'm left',
//                   ),
//                   Container(width: 1, height: 36, color: Colors.white24),
//                   _navStat(
//                     _arrivalTime.isEmpty ? '--:--' : _arrivalTime,
//                     'arrival',
//                     color: const Color(0xFF4FC3F7),
//                   ),
//                 ],
//               ),
//             ),

//           // Start / Stop Navigation button
//           SizedBox(
//             width: double.infinity,
//             child: ElevatedButton.icon(
//               onPressed: () {
//                 setState(() {
//                   _startNavigation = !_startNavigation;
//                   _isNavigating = _startNavigation;
//                   _currentStepIndex = 0;
//                   _offRouteCount = 0;
//                   _isRerouting = false;
//                 });

//                 if (_startNavigation) {
//                   // Navigation shuru
//                   _navigationStartTime = DateTime.now();
//                   _startLiveTracking();
//                   if (_routeResult!.steps.isNotEmpty) {
//                     _tts.speak(_routeResult!.steps[0].instruction);
//                   }
//                   ScaffoldMessenger.of(context).showSnackBar(
//                     const SnackBar(
//                       content: Text('Navigation shuru ho gaya!'),
//                       backgroundColor: Colors.green,
//                       duration: Duration(seconds: 2),
//                     ),
//                   );
//                 } else {
//                   // Navigation band
//                   _navigationStartTime = null;
//                   _gpsSub?.cancel();
//                   _gpsSub = null;

//                   // Car marker hata do
//                   if (_carAnnotation != null) {
//                     _pointManager?.delete(_carAnnotation!);
//                     _carAnnotation = null;
//                   }

//                   // Camera normal view par wapas
//                   _mapboxMap?.setCamera(
//                     mapbox.CameraOptions(
//                       center: mapbox.Point(
//                         coordinates: _currentPos ?? _defaultPos,
//                       ),
//                       zoom: 15,
//                       pitch: 0,
//                       bearing: 0,
//                     ),
//                   );

//                   // Route refresh karo
//                   if (_currentPos != null && _destinationPos != null) {
//                     _getRoute(_currentPos!, _destinationPos!);
//                   }
//                 }
//               },
//               icon: const Icon(Icons.navigation_rounded),
//               label: Text(
//                 _startNavigation ? 'Stop Navigation' : 'Start Navigation',
//               ),
//               style: ElevatedButton.styleFrom(
//                 backgroundColor: const Color(0xFF4285F4),
//                 foregroundColor: Colors.white,
//                 padding: const EdgeInsets.symmetric(vertical: 14),
//                 shape: RoundedRectangleBorder(
//                   borderRadius: BorderRadius.circular(12),
//                 ),
//               ),
//             ),
//           ),
//           const SizedBox(height: 8),

//           // Route clear button
//           SizedBox(
//             width: double.infinity,
//             child: OutlinedButton.icon(
//               onPressed: () async {
//                 // Polylines hata do
//                 await _polylineManager?.deleteAll();
//                 _routeAnnotation = null;
//                 _traveledAnnotation = null;

//                 // Destination marker hata do
//                 if (_destAnnotation != null) {
//                   await _pointManager?.delete(_destAnnotation!);
//                   _destAnnotation = null;
//                 }

//                 // Car marker hata do
//                 if (_carAnnotation != null) {
//                   await _pointManager?.delete(_carAnnotation!);
//                   _carAnnotation = null;
//                 }

//                 // GPS band karo
//                 _gpsSub?.cancel();
//                 _gpsSub = null;

//                 if (mounted) {
//                   setState(() {
//                     _destinationPos = null;
//                     _fullRoute = [];
//                     _routeResult = null;
//                     _isNavigating = false;
//                     _startNavigation = false;
//                     _currentStepIndex = 0;
//                     _remainingDistanceM = 0;
//                     _arrivalTime = '';
//                   });
//                 }

//                 // Camera wapas apni location par
//                 _mapboxMap?.setCamera(
//                   mapbox.CameraOptions(
//                     center: mapbox.Point(
//                       coordinates: _currentPos ?? _defaultPos,
//                     ),
//                     zoom: 15,
//                     pitch: 0,
//                     bearing: 0,
//                   ),
//                 );
//               },
//               icon: const Icon(Icons.close_rounded),
//               label: const Text('Route clear karo'),
//             ),
//           ),
//         ],
//       ),
//     );
//   }

//   // ══════════════════════════════════════════════
//   // HELPER WIDGETS
//   // ══════════════════════════════════════════════

//   Widget _statCard({
//     required IconData icon,
//     required String value,
//     required String label,
//     required Color color,
//     required Color valueColor,
//     required Color iconColor,
//   }) {
//     return Container(
//       padding: const EdgeInsets.all(14),
//       decoration: BoxDecoration(
//         color: color,
//         borderRadius: BorderRadius.circular(12),
//       ),
//       child: Column(
//         children: [
//           Icon(icon, color: iconColor, size: 24),
//           const SizedBox(height: 6),
//           Text(
//             value,
//             style: TextStyle(
//               fontSize: 18,
//               fontWeight: FontWeight.bold,
//               color: valueColor,
//             ),
//           ),
//           Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
//         ],
//       ),
//     );
//   }

//   Widget _navStat(String value, String label, {Color? color}) {
//     return Column(
//       children: [
//         Text(
//           value,
//           style: TextStyle(
//             color: color ?? Colors.white,
//             fontSize: 20,
//             fontWeight: FontWeight.bold,
//           ),
//         ),
//         Text(
//           label,
//           style: const TextStyle(color: Colors.white54, fontSize: 11),
//         ),
//       ],
//     );
//   }
// }

// // OrsLatLng ab ors_service.dart mein define hai
// // mapbox_screen ko koi wrapper nahi chahiye
