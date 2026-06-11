import 'package:flutter/material.dart';
import 'package:flutter_google_places_sdk/flutter_google_places_sdk.dart';

class PlacesSearch extends StatefulWidget {
  const PlacesSearch({super.key, required this.onPlaceSelected});
  final Function(LatLng) onPlaceSelected;

  @override
  State<PlacesSearch> createState() => _PlacesSearchState();
}

class _PlacesSearchState extends State<PlacesSearch> {
  final TextEditingController _controller = TextEditingController();
  late FlutterGooglePlacesSdk _places;
  List<AutocompletePrediction> _predictions = [];
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
    }
    setState(() => _isLoading = true);

    try {
      final result = await _places.findAutocompletePredictions(
        query,
        locationBias: LatLngBounds(
          southwest: const LatLng(
            lat: 23.6345,
            lng: 60.8729,
          ), // Pakistan ka SW corner
          northeast: const LatLng(
            lat: 37.0841,
            lng: 77.8374,
          ), // Pakistan ka NE corner
        ),
        placeTypesFilter: [PlaceTypeFilter.CITIES],

        countries: ['pk'], // Pakistan ke liye filter
      );
      setState(() {
        _predictions = result.predictions ?? [];
        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
      print('Autocomplete error: $e');
    }
  }

  Future<void> _onPlaceTapped(AutocompletePrediction prediction) async {
    // Search bar band karo
    _controller.clear();
    setState(() => _predictions = []);

    // placeId se actual coordinates lo
    final details = await _places.fetchPlace(
      prediction.placeId,
      fields: [PlaceField.Location], // sirf location chahiye
    );

    final location = details.place?.latLng;

    if (location != null) {
      // Parent ko coordinates do
      widget.onPlaceSelected(LatLng(lat: location.lat, lng: location.lng));
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
              hintText: 'Kahan jaana hai?',
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
                  title: Text(
                    p.fullText ?? '',
                    style: const TextStyle(fontSize: 14),
                  ),
                  onTap: () => _onPlaceTapped(p),
                );
              },
            ),
          ),
      ],
    );
  }
}
