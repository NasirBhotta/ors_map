import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:ors_map_test/services/ors_service.dart';
import 'package:ors_map_test/services/tts_service.dart';
import 'package:ors_map_test/widgets/places_search.dart';

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

  // Navigation Start
  bool _startNavigation = false;

  // Islamabad default location — agar GPS nahi mila
  static const LatLng _defaultLocation = LatLng(33.6844, 73.0479);

  int _currentStepIndex = 0; // abhi konsa step chal raha hai
  bool _isNavigating = false;

  // Compass stream — phone rotate hone par
  StreamSubscription<CompassEvent>? _compassSub;

  final TtsService _tts = TtsService();
  @override
  void initState() {
    super.initState();
    // App shuru hote hi yeh 3 kaam karo
    _buildCarIcon(); // car icon banao
    _initLocation(); // location lo
    _startCompass(); // compass start karo
  }

  @override
  void dispose() {
    _gpsSub?.cancel(); // GPS band karo jab screen close ho
    _tts.stop();
    _compassSub?.cancel(); // Compass band karo jab screen close ho
    _mapController?.dispose();
    super.dispose();
  }

  void _startCompass() {
    // FlutterCompass.events — ek stream hai
    // har baar phone rotate hoga, naya event aayega
    _compassSub = FlutterCompass.events?.listen((CompassEvent event) {
      // event.heading — degrees mein direction
      // null bhi aa sakta hai agar sensor nahi hai device mein
      if (event.heading == null) return;

      setState(() {
        // Sirf tab compass use karo
        // jab GPS heading nahi aa rahi (gaadi ruki ho)
        // Agar gaadi chal rahi hai toh GPS heading better hai
        if (_gpsSub == null) {
          _heading = event.heading!;
        }
      });
    });
  }

  // Baaki functions yahan aayenge...
  Future<void> _buildCarIcon() async {
    // Assets se PNG lo, size do 80x80 (adjust kar sakte ho)
    final icon = await BitmapDescriptor.fromAssetImage(
      const ImageConfiguration(size: Size(80, 80)),
      'assets/car_icon.png',
    );

    if (!mounted) return;

    setState(() {
      _carIcon = icon;
    });
  }

  Future<void> _initLocation() async {
    // ─── Step 1: Permission check ───────────────
    // Pehle dekho permission hai ya nahi

    print("checking location permission");
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

    print("live tracking started");

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
        if (position.speed > 0.5 && !position.heading.isNaN) {
          _heading = position.heading; // GPS se
        }
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
    _checkStepAdvance(carPos);
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
          color: Colors.yellow,
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
          color: Colors.yellow,
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

            myLocationButtonEnabled: true,
            zoomControlsEnabled: true,

            compassEnabled: true,
          ),

          // ─── Layer 2: Top instruction bar ─────────
          if (!_isNavigating)
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

          // Navigation chal raha hai toh nav card dikhao
          if (_isNavigating &&
              _routeResult != null &&
              _routeResult!.steps.isNotEmpty)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(child: _buildNavCard()),
            ),

          // ─── Layer 3: Loading indicator ────────────
          if (!_isNavigating)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                child: PlacesSearch(
                  onPlaceSelected: (latLng) {
                    // Bilkul waise hi jaise tap se destination set hota tha
                    _onMapTapped(latLng);
                  },
                ),
              ),
            ),
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
                    // "Route clear karo" button ke UPAR yeh add karo:
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: () {
                          setState(() {
                            _startNavigation = !_startNavigation;
                            _currentStepIndex =
                                0; // navigation start hone par step index reset karo
                            _isNavigating = _startNavigation;
                          });
                          if (_startNavigation) {
                            _startLiveTracking();
                            if (_routeResult!.steps.isNotEmpty) {
                              _tts.speak(_routeResult!.steps[0].instruction);
                            }
                          } else {
                            _getRoute(_currentLocation!, _destination!);
                          }
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Navigation shuru ho gaya!'),
                              backgroundColor: Colors.green,
                              duration: Duration(seconds: 2),
                            ),
                          );
                        },
                        icon: const Icon(Icons.navigation_rounded),
                        label:
                            _startNavigation
                                ? const Text('Stop Navigation')
                                : const Text('Start Navigation'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF4285F4),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(
                      height: 8,
                    ), // thoda gap "Route clear" se pehle
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

                            _mapController?.animateCamera(
                              CameraUpdate.newLatLngZoom(
                                _currentLocation ?? _defaultLocation,
                                15,
                              ),
                            );
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

  Widget _buildNavCard() {
    final steps = _routeResult!.steps;

    // Abhi konsa step? — _currentStepIndex se lo
    final current = steps[_currentStepIndex];

    // Agla step hai? — preview ke liye
    final hasNext = _currentStepIndex + 1 < steps.length;
    final next = hasNext ? steps[_currentStepIndex + 1] : null;

    return Container(
      margin: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A2E), // dark blue
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.black38, blurRadius: 12)],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ─── Current Step ──────────────────────
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                // Turn icon
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white12,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    current.icon, // RouteStep ka icon getter ✅
                    color: Colors.white,
                    size: 32,
                  ),
                ),
                const SizedBox(width: 14),

                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Distance
                      Text(
                        current
                            .distanceText, // RouteStep ka distanceText getter ✅
                        style: const TextStyle(
                          color: Color(0xFF4FC3F7),
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      // Instruction
                      Text(
                        current.instruction,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // ─── Next Step Preview ─────────────────
          if (next != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: const BoxDecoration(
                color: Colors.white10,
                borderRadius: BorderRadius.vertical(
                  bottom: Radius.circular(16),
                ),
              ),
              child: Row(
                children: [
                  Icon(next.icon, color: Colors.white60, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Then: ${next.instruction}',
                      style: const TextStyle(
                        color: Colors.white60,
                        fontSize: 12,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  void _checkStepAdvance(LatLng carPos) {
    // Navigation nahi chal raha toh kuch mat karo
    if (!_isNavigating) return;
    if (_routeResult == null || _routeResult!.steps.isEmpty) return;

    // Last step par hain toh advance mat karo
    if (_currentStepIndex >= _routeResult!.steps.length - 1) {
      // Destination check karo
      if (_destination != null) {
        final dist = _haversineMeters(carPos, _destination!);
        if (dist < 30) _onDestinationReached(); // 30m ke andar = pahunch gaye
      }
      return;
    }

    // Current step ka end point nikalo
    final endPoint = _getStepEndPoint(_currentStepIndex);

    // Car kitni door hai us point se?
    final distance = _haversineMeters(carPos, endPoint);

    // 25 meter se kam → next step!
    if (distance < 25) {
      setState(() {
        _currentStepIndex++;
      });

      final newInstruction = _routeResult!.steps[_currentStepIndex].instruction;
      _tts.speak(newInstruction);
    }
  }

  LatLng _getStepEndPoint(int stepIndex) {
    if (_fullRoute.isEmpty) return _currentLocation ?? _defaultLocation;

    // Ab tak kitni distance cover hui — sab steps ki
    double cumulative = 0;
    for (int i = 0; i <= stepIndex; i++) {
      cumulative += _routeResult!.steps[i].distance;
    }

    // Yeh distance poori route mein kahan hai? — ratio nikalo
    // Jaise 1200m / 5400m = 0.22 → route ka 22% point
    final ratio = (cumulative / _routeResult!.distanceMeters).clamp(0.0, 1.0);

    // Route array mein us ratio ka index
    final index = (ratio * (_fullRoute.length - 1)).toInt();
    return _fullRoute[index];
  }

  void _onDestinationReached() {
    _tts.speak('You have reached your destination'); // ← ADD KARO
    _gpsSub?.cancel();

    setState(() {
      _isNavigating = false;
      _currentStepIndex = 0;
    });

    showDialog(
      context: context,
      builder:
          (_) => AlertDialog(
            title: const Text('🎉 Pahunch Gaye!'),
            content: const Text('Aap apni destination par pahunch gaye.'),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.pop(context);
                  setState(() {
                    _destination = null;
                    _markers = {};
                    _polylines = {};
                    _fullRoute = [];
                    _routeResult = null;
                  });
                },
                child: const Text('Done'),
              ),
            ],
          ),
    );
  }
}
