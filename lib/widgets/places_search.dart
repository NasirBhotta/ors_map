import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_google_places_sdk/flutter_google_places_sdk.dart';
import 'package:http/http.dart' as http;
import 'package:google_maps_flutter/google_maps_flutter.dart' as maps;

class PlacesSearch extends StatefulWidget {
  const PlacesSearch({super.key, required this.onPlaceSelected});
  final Function(maps.LatLng) onPlaceSelected;

  @override
  State<PlacesSearch> createState() => _PlacesSearchState();
}

class _PlacesSearchState extends State<PlacesSearch> {
  final TextEditingController _controller = TextEditingController();
  late FlutterGooglePlacesSdk _places;
  List<Map<String, Object>> _predictions = [];
  bool _isLoading = false;
  @override
  void initState() {
    super.initState();
    // SDK initialize karo apni API key se
    _places = FlutterGooglePlacesSdk('AIzaSyDokWAEammXOAyow94XdZ-CC1N6u_mCJ1k');
  }

  Future<void> _onSearchChanged(String query) async {
    if (query.length < 2) {
      setState(() => _predictions = []);
      return;
    }

    setState(() => _isLoading = true);

    try {
      final uri = Uri.parse(
        'https://nominatim.openstreetmap.org/search'
        '?q=${Uri.encodeComponent(query)}'
        '&format=json&countrycodes=pk&limit=5',
      );

      final response = await http.get(
        uri,
        headers: {
          'User-Agent':
              'OrsMapApp/1.0', // zaruri hai — Nominatim require karta hai
        },
      );

      final results = jsonDecode(response.body) as List;

      setState(() {
        _predictions =
            results
                .map(
                  (r) => {
                    'name': r['display_name'] as String,
                    'lat': double.parse(r['lat']),
                    'lon': double.parse(r['lon']),
                  },
                )
                .toList();

        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
      print('Autocomplete error: $e');
    }
  }

  Future<void> _onPlaceTapped(Map<String, Object> prediction) async {
    // Search bar band karo
    _controller.clear();
    setState(() => _predictions = []);

    // placeId se actual coordinates lo
    final details = await _places.fetchPlace(
      prediction['placeId'] as String,
      fields: [PlaceField.Location], // sirf location chahiye
    );

    final location = details.place?.latLng;

    if (location != null) {
      // Parent ko coordinates do
      widget.onPlaceSelected(maps.LatLng(location.lat, location.lng));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // ─── Search Bar ────────────────────────
        Container(
          margin: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 6)],
          ),
          child: TextField(
            controller: _controller,
            // Har change par autocomplete call karo
            onChanged: _onSearchChanged,
            decoration: InputDecoration(
              hintText: 'where you want to go?',
              prefixIcon: const Icon(Icons.search),
              suffixIcon:
                  _isLoading
                      ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                      : null,
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 14,
              ),
            ),
          ),
        ),

        // ─── Suggestions List ──────────────────
        if (_predictions.isNotEmpty)
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 6)],
            ),
            child: ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _predictions.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final p = _predictions[index];
                return ListTile(
                  leading: const Icon(
                    Icons.location_on_outlined,
                    color: Color(0xFF4285F4),
                  ),
                  // Poora naam — jaise "F-6 Markaz, Islamabad, Pakistan"
                  // ListTile mein
                  title: Text(_predictions[index]['name'].toString()),
                  onTap: () {
                    final p = _predictions[index];

                    print("the predictions are $p");

                    widget.onPlaceSelected(
                      maps.LatLng(p['lat'] as double, p['lon'] as double),
                    );

                    _predictions.clear();
                    FocusScope.of(context).unfocus(); // keyboard band karo
                  },
                );
              },
            ),
          ),
      ],
    );
  }
}
