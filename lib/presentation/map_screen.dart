import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:ors_map_test/services/ors_service.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  // Map controller — map ko control karne ke liye
  // jaise TV ka remote
  GoogleMapController? _mapController;

  // Hamaari current location
  LatLng? _currentLocation;

  // Jahan user tap kare — destination
  LatLng? _destination;

  // Map par jo line draw hogi
  Set<Polyline> _polylines = {};

  // Map par jo pins dikhenge
  Set<Marker> _markers = {};

  // Poora route store karo — progress ke liye
  List<LatLng> _fullRoute = [];

  // ORS se jo data aaya
  RouteResult? _routeResult;

  // Car icon — canvas se banayenge
  BitmapDescriptor? _carIcon;

  // Car ki current heading (direction)
  double _heading = 0;

  // GPS stream — continuously location sun'na
  StreamSubscription<Position>? _gpsSub;

  // Loading state
  bool _isLoading = false;

  // Islamabad default location — agar GPS nahi mila
  static const LatLng _defaultLocation = LatLng(33.6844, 73.0479);

  @override
  void initState() {
    super.initState();
    // App shuru hote hi yeh 3 kaam karo
    _buildCarIcon(); // car icon banao
    _initLocation(); // location lo
  }

  @override
  void dispose() {
    _gpsSub?.cancel(); // GPS band karo jab screen close ho
    _mapController?.dispose();
    super.dispose();
  }

  // Baaki functions yahan aayenge...
  Future<void> _buildCarIcon() async {
    // Ek virtual kagaz banao jis par draw karein
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    // ─── Car Body ───────────────────────────────
    // Neela rounded rectangle — car ka body
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(10, 8, 40, 52),
        const Radius.circular(10),
      ),
      Paint()..color = const Color(0xFF1E3A8A), // dark blue
    );

    // ─── Windshield ─────────────────────────────
    // Light blue rectangle — sheesha
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(15, 12, 30, 22),
        const Radius.circular(5),
      ),
      Paint()..color = const Color(0xFF93C5FD), // light blue
    );

    // ─── 4 Wheels ───────────────────────────────
    // Har wheel ke liye 2 circles — outer aur rim
    final wheelPositions = [
      const Offset(12, 20), // front left
      const Offset(48, 20), // front right
      const Offset(12, 48), // back left
      const Offset(48, 48), // back right
    ];

    for (final pos in wheelPositions) {
      // Outer wheel — kala
      canvas.drawCircle(pos, 7, Paint()..color = const Color(0xFF111111));
      // Rim — gray
      canvas.drawCircle(pos, 4, Paint()..color = const Color(0xFF888888));
    }

    // ─── Headlights ─────────────────────────────
    // Do chote yellow circles — aage
    for (final pos in [const Offset(18, 8), const Offset(42, 8)]) {
      canvas.drawCircle(
        pos,
        4,
        Paint()..color = const Color(0xFFFCD34D), // yellow
      );
    }

    // ─── Convert to PNG ─────────────────────────
    // Virtual kagaz se photo khecho
    final picture = recorder.endRecording();
    final img = await picture.toImage(60, 68);
    final data = await img.toByteData(format: ui.ImageByteFormat.png);

    // Agar widget band ho gaya toh kuch mat karo
    if (!mounted) return;

    // BitmapDescriptor banao aur save karo
    setState(() {
      _carIcon = BitmapDescriptor.fromBytes(data!.buffer.asUint8List());
    });
  }

  Future<void> _initLocation() async {
    // ─── Step 1: Permission check ───────────────
    // Pehle dekho permission hai ya nahi
    LocationPermission permission = await Geolocator.checkPermission();

    // Agar pehle kabhi nahi maangi
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();

      // User ne phir bhi deny kiya
      if (permission == LocationPermission.denied) {
        // Default location use karo — Islamabad
        setState(() {
          _currentLocation = _defaultLocation;
        });
        return;
      }
    }

    // Agar permanently deny hai
    if (permission == LocationPermission.deniedForever) {
      setState(() {
        _currentLocation = _defaultLocation;
      });
      return;
    }

    // ─── Step 2: Actual location lo ─────────────
    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );

      final myLocation = LatLng(position.latitude, position.longitude);

      setState(() {
        _currentLocation = myLocation;
      });

      // ─── Step 3: Camera wahan le jao ────────────
      // Map ko apni location par center karo
      _mapController?.animateCamera(CameraUpdate.newLatLngZoom(myLocation, 15));

      // ─── Step 4: Live tracking shuru karo ───────
      _startLiveTracking();
    } catch (e) {
      // Kuch gadbad hui toh default use karo
      print('Location error: $e');
      setState(() {
        _currentLocation = _defaultLocation;
      });
    }
  }

  void _startLiveTracking() {
    // Pehle agar pehle se chal raha hai toh band karo
    _gpsSub?.cancel();

    // GPS ko sun'na shuru karo
    _gpsSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10, // har 10 meter par update aaye
      ),
    ).listen((position) {
      final newLocation = LatLng(position.latitude, position.longitude);

      setState(() {
        _currentLocation = newLocation;
        // Heading — car kis direction mein ja rahi hai
        _heading = position.heading.isNaN ? 0 : position.heading;
      });

      // Agar route chal raha hai toh polyline update karo
      if (_fullRoute.isNotEmpty) {
        _updatePolylineProgress(newLocation);
      }

      // Camera car ke saath move kare
      // Sirf tab jab route chal raha ho
      if (_fullRoute.isNotEmpty) {
        _mapController?.animateCamera(
          CameraUpdate.newCameraPosition(
            CameraPosition(
              target: newLocation,
              zoom: 18,
              tilt: 50, // 3D effect
              bearing: _heading, // map rotate karo direction ke saath
            ),
          ),
        );
      }
    });
  }

  void _updatePolylineProgress(LatLng carPos) {
    if (_fullRoute.isEmpty) return;

    // Sabse nazdik point dhundo — haversine se
    int closestIndex = 0;
    double minDist = double.infinity;

    for (int i = 0; i < _fullRoute.length; i++) {
      final d = _haversineMeters(carPos, _fullRoute[i]);
      if (d < minDist) {
        minDist = d;
        closestIndex = i;
      }
    }

    // Off route check — 50 meter se zyada door
    if (minDist > 50 && _destination != null) {
      // Naya route fetch karo current position se
      _getRoute(carPos, _destination!);
      return;
    }

    // Do polylines — gray peeche, blue aage
    setState(() {
      _polylines = {
        Polyline(
          polylineId: const PolylineId('traveled'),
          points: _fullRoute.sublist(0, closestIndex + 1),
          color: Colors.grey.shade400,
          width: 5,
        ),
        Polyline(
          polylineId: const PolylineId('ahead'),
          points: _fullRoute.sublist(closestIndex),
          color: const Color(0xFF4285F4),
          width: 6,
        ),
      };
    });
  }

  // Yeh haversine formula hai — do points ke beech meters mein distance
  double _haversineMeters(LatLng a, LatLng b) {
    const R = 6371000.0; // earth radius meters mein

    final dLat = (b.latitude - a.latitude) * pi / 180;
    final dLng = (b.longitude - a.longitude) * pi / 180;

    final h =
        pow(sin(dLat / 2), 2) +
        cos(a.latitude * pi / 180) *
            cos(b.latitude * pi / 180) *
            pow(sin(dLng / 2), 2);

    return 2 * R * asin(sqrt(h.toDouble()));
  }

  Future<void> _getRoute(LatLng from, LatLng to) async {
    // Loading shuru
    setState(() => _isLoading = true);

    // ORS se route maango
    final result = await OrsService.getRoute(from: from, to: to);

    // Agar kuch nahi aaya
    if (result == null) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Route nahi mila — internet check karo'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }

    // Sab kuch save karo aur map update karo
    setState(() {
      _isLoading = false;
      _routeResult = result;
      _fullRoute = result.points;

      // Pehle poori blue line draw karo
      _polylines = {
        Polyline(
          polylineId: const PolylineId('route'),
          points: result.points,
          color: const Color(0xFF4285F4),
          width: 6,
        ),
      };
    });

    // Dono points screen mein fit karo
    _fitBounds(from, to);
  }

  Future<void> _fitBounds(LatLng a, LatLng b) async {
    // Dono points ka bounding box banao
    // Southwest — minimum lat aur lng
    // Northeast — maximum lat aur lng
    final bounds = LatLngBounds(
      southwest: LatLng(
        min(a.latitude, b.latitude),
        min(a.longitude, b.longitude),
      ),
      northeast: LatLng(
        max(a.latitude, b.latitude),
        max(a.longitude, b.longitude),
      ),
    );

    // Camera ko fit karo — 80 pixel padding ke saath
    await _mapController?.animateCamera(
      CameraUpdate.newLatLngBounds(bounds, 80),
    );
  }

  void _onMapTapped(LatLng tappedPoint) {
    // Agar location abhi nahi mili
    if (_currentLocation == null) return;

    setState(() {
      _destination = tappedPoint;

      // Destination par red marker lagao
      _markers = {
        Marker(
          markerId: const MarkerId('destination'),
          position: tappedPoint,
          infoWindow: const InfoWindow(
            title: 'Destination',
            snippet: 'Tap karo route dekhne ke liye',
          ),
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
        ),
      };

      // Pehla route clear karo
      _polylines = {};
      _fullRoute = [];
      _routeResult = null;
    });

    // ORS se naya route maango
    _getRoute(_currentLocation!, tappedPoint);
  }

  @override
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // ─── Layer 1: Google Map ───────────────────
          GoogleMap(
            initialCameraPosition: CameraPosition(
              target: _currentLocation ?? _defaultLocation,
              zoom: 15,
            ),
            onMapCreated: (controller) {
              _mapController = controller;

              // Jab map ready ho, location par jao
              if (_currentLocation != null) {
                _mapController?.animateCamera(
                  CameraUpdate.newLatLngZoom(_currentLocation!, 15),
                );
              }
            },

            // Map par tap karo — destination set ho
            onTap: _onMapTapped,

            // Polylines — route lines
            polylines: _polylines,

            // Markers — destination pin + car
            markers: {
              // Destination marker
              ..._markers,

              // Car marker — sirf tab dikhao jab location ho
              if (_currentLocation != null)
                Marker(
                  markerId: const MarkerId('car'),
                  position: _currentLocation!,
                  rotation: _heading,
                  flat: true,
                  anchor: const Offset(0.5, 0.5),
                  icon:
                      _carIcon ??
                      BitmapDescriptor.defaultMarkerWithHue(
                        BitmapDescriptor.hueBlue,
                      ),
                ),
            },

            myLocationButtonEnabled: false,
            zoomControlsEnabled: false,
          ),

          // ─── Layer 2: Top instruction bar ─────────
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Container(
                margin: const EdgeInsets.all(12),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.1),
                      blurRadius: 8,
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.touch_app_rounded,
                      color: Color(0xFF4285F4),
                      size: 20,
                    ),
                    const SizedBox(width: 10),
                    Text(
                      _destination == null
                          ? 'Tap on Map - Set destination'
                          : 'Route Found',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // ─── Layer 3: Loading indicator ────────────
          if (_isLoading)
            Container(
              color: Colors.black.withOpacity(0.3),
              child: const Center(
                child: Card(
                  child: Padding(
                    padding: EdgeInsets.all(20),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(color: Color(0xFF4285F4)),
                        SizedBox(height: 12),
                        Text('Fetching Route'),
                      ],
                    ),
                  ),
                ),
              ),
            ),

          // ─── Layer 4: Bottom info card ─────────────
          // Sirf tab dikhao jab route aaya ho
          if (_routeResult != null)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                decoration: const BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                ),
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Handle bar
                    Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.grey.shade300,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Distance aur Duration row
                    Row(
                      children: [
                        // Distance card
                        Expanded(
                          child: Container(
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: const Color(0xFFEFF6FF),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Column(
                              children: [
                                const Icon(
                                  Icons.route_rounded,
                                  color: Color(0xFF4285F4),
                                  size: 24,
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  _routeResult!.distanceText,
                                  style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                    color: Color(0xFF1E3A8A),
                                  ),
                                ),
                                const Text(
                                  'Distance',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),

                        const SizedBox(width: 12),

                        // Duration card
                        Expanded(
                          child: Container(
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF0FDF4),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Column(
                              children: [
                                const Icon(
                                  Icons.timer_rounded,
                                  color: Color(0xFF16A34A),
                                  size: 24,
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  _routeResult!.durationText,
                                  style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                    color: Color(0xFF14532D),
                                  ),
                                ),
                                const Text(
                                  'Duration',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 12),

                    // Route clear karne ka button
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () {
                          setState(() {
                            _destination = null;
                            _markers = {};
                            _polylines = {};
                            _fullRoute = [];
                            _routeResult = null;
                          });
                        },
                        icon: const Icon(Icons.close_rounded),
                        label: const Text('Route clear karo'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
