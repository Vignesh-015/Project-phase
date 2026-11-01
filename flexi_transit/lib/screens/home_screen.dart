import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:latlong2/latlong.dart';
import '../core/theme.dart';
import '../services/mtc_service.dart';
import '../services/cmrl_service.dart';
import '../services/feeder_service.dart';
import '../services/geocoding_service.dart';
import '../services/location_service.dart';
import '../widgets/map_widget.dart';
import 'route_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TextEditingController _originCtrl = TextEditingController();
  final TextEditingController _destCtrl = TextEditingController();
  final FocusNode _originFocus = FocusNode();
  final FocusNode _destFocus = FocusNode();

  bool _isSearching = false;
  bool _isGpsTracking = false;

  LatLng? _originPoint;
  LatLng? _destPoint;
  LatLng? _currentGpsPoint;

  bool _selectingOrigin = false;
  bool _selectingDest = false;
  String _activeSearchField = ''; // 'origin' or 'dest' or ''
  List<_SearchSuggestion> _suggestions = [];
  Timer? _debounceTimer;

  @override
  void initState() {
    super.initState();
    _loadMtcData();
    _loadCmrlData();
    _loadFeederData();

    _originCtrl.addListener(() => _onTextChanged('origin', _originCtrl.text));
    _destCtrl.addListener(() => _onTextChanged('dest', _destCtrl.text));
    // Note: AI query controller removed

    _originFocus.addListener(() {
      if (_originFocus.hasFocus) {
        setState(() {
          _activeSearchField = 'origin';
          _selectingOrigin = true;
          _selectingDest = false;
        });
        _onTextChanged('origin', _originCtrl.text);
      }
    });

    _destFocus.addListener(() {
      if (_destFocus.hasFocus) {
        setState(() {
          _activeSearchField = 'dest';
          _selectingDest = true;
          _selectingOrigin = false;
        });
        _onTextChanged('dest', _destCtrl.text);
      }
    });
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _originCtrl.dispose();
    _destCtrl.dispose();
    _originFocus.dispose();
    _destFocus.dispose();
    super.dispose();
  }

  Future<void> _loadCmrlData() async {
    await CmrlService.loadData();
  }

  Future<void> _loadMtcData() async {
    await MtcService.loadData();
  }

  Future<void> _loadFeederData() async {
    await FeederService.loadData();
  }

  /// Interactive Map Click Selection with Automatic Reverse Geocoding
  void _onMapTap(LatLng point) async {
    final address = await GeocodingService.reverseGeocode(point.latitude, point.longitude);
    if (!mounted) return;

    if (_selectingOrigin) {
      setState(() {
        _originPoint = point;
        _originCtrl.text = address;
        _selectingOrigin = false;
        _activeSearchField = '';
      });
    } else if (_selectingDest) {
      setState(() {
        _destPoint = point;
        _destCtrl.text = address;
        _selectingDest = false;
        _activeSearchField = '';
      });
    }
  }

  /// Debounced Search (250-400ms delay) preventing stale requests
  void _onTextChanged(String field, String text) {
    if (_activeSearchField != field) return;

    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 300), () async {
      if (!mounted) return;

      if (text.trim().isEmpty) {
        final list = <_SearchSuggestion>[
          _SearchSuggestion(
            name: 'Ashok Nagar',
            subtitle: 'Ashok Nagar Metro / Market • Chennai',
            icon: '🚇',
            lat: 13.035411,
            lon: 80.211422,
          ),
          _SearchSuggestion(
            name: 'Sairam College',
            subtitle: 'Sri Sairam Engineering College • West Tambaram',
            icon: '🛺',
            lat: 12.960249,
            lon: 80.057778,
          ),
          _SearchSuggestion(
            name: 'Tambaram',
            subtitle: 'Tambaram Railway & Feeder Terminal',
            icon: '🛺',
            lat: 12.9249,
            lon: 80.1265,
          ),
          _SearchSuggestion(
            name: 'Ekattuthangal Metro',
            subtitle: 'CMRL Green Line • Feeder Interchange',
            icon: '⚡',
            lat: 13.017128,
            lon: 80.205302,
          ),
        ];
        if (mounted) setState(() => _suggestions = list);
        return;
      }

      setState(() => _isSearching = true);
      final q = text.toLowerCase().trim();
      final results = <_SearchSuggestion>[];

      // Key POI Direct Shortcuts
      if ('ashok nagar'.contains(q) || 'ashok nagar metro'.contains(q)) {
        results.add(_SearchSuggestion(
          name: 'Ashok Nagar',
          subtitle: 'Ashok Nagar Metro / Market • Green Line',
          icon: '🚇',
          lat: 13.035411,
          lon: 80.211422,
        ));
      }
      if ('sairam college'.contains(q) || 'sairam'.contains(q)) {
        results.add(_SearchSuggestion(
          name: 'Sairam College',
          subtitle: 'Sri Sairam Engineering College Terminal',
          icon: '🛺',
          lat: 12.960249,
          lon: 80.057778,
        ));
      }
      if ('tambaram'.contains(q)) {
        results.add(_SearchSuggestion(
          name: 'Tambaram Terminal',
          subtitle: 'Tambaram Trunk Feeder Hub',
          icon: '🛺',
          lat: 12.9249,
          lon: 80.1265,
        ));
      }
      if ('ekattuthangal'.contains(q) || 'ekatuthangal'.contains(q)) {
        results.add(_SearchSuggestion(
          name: 'Ekattuthangal Metro',
          subtitle: 'CMRL Green Line • Paratransit Interchange',
          icon: '⚡',
          lat: 13.017128,
          lon: 80.205302,
        ));
      }

      // Paratransit Mined Virtual Stops Search (Layer 2)
      if (FeederService.isLoaded) {
        for (final s in FeederService.stops) {
          if (s.stopName.toLowerCase().contains(q) || s.stopId.toLowerCase().contains(q)) {
            if (!results.any((r) => r.name.toLowerCase() == s.stopName.toLowerCase())) {
              results.add(_SearchSuggestion(
                name: s.stopName,
                subtitle: 'Feeder Virtual Stop • ${s.corridorName}',
                icon: '🛺',
                lat: s.lat,
                lon: s.lon,
              ));
            }
          }
        }
      }

      // Local CMRL Metro search (Layer 3)
      if (CmrlService.isLoaded) {
        for (final s in CmrlService.stops) {
          if (s.stopName.toLowerCase().contains(q)) {
            if (!results.any((r) => r.name.toLowerCase() == s.stopName.toLowerCase())) {
              results.add(_SearchSuggestion(
                name: s.stopName,
                subtitle: 'CMRL Metro Station • ${s.line}',
                icon: '🚇',
                lat: s.lat,
                lon: s.lon,
              ));
            }
          }
        }
      }

      // Local MTC Bus Stop search
      if (MtcService.isLoaded) {
        for (final s in MtcService.stops) {
          if (s.stopName.toLowerCase().contains(q)) {
            if (!results.any((r) => r.name.toLowerCase() == s.stopName.toLowerCase())) {
              results.add(_SearchSuggestion(
                name: s.stopName,
                subtitle: 'MTC Bus Stop',
                icon: '🚌',
                lat: s.lat,
                lon: s.lon,
              ));
              if (results.length >= 8) break;
            }
          }
        }
      }

      // Dynamic Photon Geocoder (OSM places, streets, areas, buildings, addresses)
      final geoLocations = await GeocodingService.searchPlaces(text);
      if (_activeSearchField == field && mounted) {
        for (final loc in geoLocations) {
          if (!results.any((r) => r.name.toLowerCase() == loc.name.toLowerCase())) {
            results.add(_SearchSuggestion(
              name: loc.name,
              subtitle: loc.address,
              icon: loc.type == 'building' ? '🏢' : (loc.type == 'highway' ? '🛣️' : '📍'),
              lat: loc.lat,
              lon: loc.lon,
            ));
          }
        }
        setState(() {
          _suggestions = results.take(15).toList();
          _isSearching = false;
        });
      }
    });
  }

  void _selectSuggestion(_SearchSuggestion s) {
    setState(() {
      if (_activeSearchField == 'origin') {
        _originCtrl.text = s.name;
        _originPoint = LatLng(s.lat, s.lon);
        _originFocus.unfocus();
      } else if (_activeSearchField == 'dest') {
        _destCtrl.text = s.name;
        _destPoint = LatLng(s.lat, s.lon);
        _destFocus.unfocus();
      }
      _activeSearchField = '';
      _suggestions = [];
    });
  }

  /// GPS Current Location Handler
  void _useCurrentGpsLocation() async {
    setState(() => _isGpsTracking = true);
    final pos = await LocationService.getCurrentPosition();
    if (pos != null) {
      final address = await GeocodingService.reverseGeocode(pos.latitude, pos.longitude);
      if (mounted) {
        setState(() {
          _currentGpsPoint = pos;
          _originPoint = pos;
          _originCtrl.text = 'Current Location ($address)';
          _isGpsTracking = false;
        });
      }
    } else {
      if (mounted) setState(() => _isGpsTracking = false);
    }
  }

  void _swapLocations() {
    setState(() {
      final tmpPoint = _originPoint;
      final tmpText = _originCtrl.text;
      _originPoint = _destPoint;
      _originCtrl.text = _destCtrl.text;
      _destPoint = tmpPoint;
      _destCtrl.text = tmpText;
    });
  }

  void _clearRoute() {
    setState(() {
      _originPoint = null;
      _destPoint = null;
      _originCtrl.clear();
      _destCtrl.clear();
      _selectingOrigin = false;
      _selectingDest = false;
      _activeSearchField = '';
      _suggestions.clear();
    });
  }

  void _searchRoutes() async {
    if (_originPoint == null && _originCtrl.text.isNotEmpty) {
      final res = await GeocodingService.searchPlaces(_originCtrl.text);
      if (res.isNotEmpty) _originPoint = LatLng(res.first.lat, res.first.lon);
    }
    if (_destPoint == null && _destCtrl.text.isNotEmpty) {
      final res = await GeocodingService.searchPlaces(_destCtrl.text);
      if (res.isNotEmpty) _destPoint = LatLng(res.first.lat, res.first.lon);
    }

    if (_originPoint == null || _destPoint == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select both origin and destination.')),
      );
      return;
    }

    if (!mounted) return;
    final cleared = await Navigator.push<bool>(
      context,
      PageRouteBuilder(
        pageBuilder: (_, animation, __) => RouteScreen(
          originLat: _originPoint!.latitude,
          originLon: _originPoint!.longitude,
          destLat: _destPoint!.latitude,
          destLon: _destPoint!.longitude,
          originLabel: _originCtrl.text.isEmpty ? 'Origin' : _originCtrl.text,
          destLabel: _destCtrl.text.isEmpty ? 'Destination' : _destCtrl.text,
        ),
        transitionsBuilder: (_, animation, __, child) {
          return FadeTransition(opacity: animation, child: child);
        },
        transitionDuration: const Duration(milliseconds: 300),
      ),
    );

    if (cleared == true && mounted) {
      _clearRoute();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.backgroundDark,
      body: Stack(
        children: [
          // ── Full Screen OSM Map ─────────────────────────────────────────
          MapWidget(
            routeOptions: const [],
            originPoint: _originPoint,
            destPoint: _destPoint,
            currentLocationPoint: _currentGpsPoint,
            onMapTap: _onMapTap,
          ),

          // ── Top Search Panel (Source, Destination, Swap, GPS) ───────────
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Animate(
                effects: [
                  FadeEffect(duration: 350.ms),
                  SlideEffect(begin: const Offset(0, -0.2), end: Offset.zero, duration: 350.ms),
                ],
                child: _buildSearchPanel(),
              ),
            ),
          ),

          // ── Map-tap instruction toast ───────────────────────────────────
          if (_selectingOrigin || _selectingDest)
            Positioned(
              bottom: 90,
              left: 20,
              right: 20,
              child: Animate(
                effects: [FadeEffect(duration: 200.ms)],
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: AppTheme.accentTeal.withValues(alpha: 0.94),
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 12)],
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.touch_app_rounded, color: Colors.white, size: 18),
                      const SizedBox(width: 8),
                      Text(
                        _selectingOrigin
                            ? 'Tap map to set starting location'
                            : 'Tap map to set destination location',
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSearchPanel() {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: AppTheme.surfaceDark.withValues(alpha: 0.97),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: AppTheme.borderDark),
        boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 20, offset: Offset(0, 6))],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildBrandRow(),
          const SizedBox(height: 12),

          // From / To inputs with swap & GPS button
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Column(
                children: [
                  const Icon(Icons.radio_button_checked, color: AppTheme.accentTeal, size: 16),
                  Container(
                    width: 2,
                    height: 18,
                    margin: const EdgeInsets.symmetric(vertical: 3),
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        colors: [AppTheme.accentTeal, AppTheme.accentRed],
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                      ),
                    ),
                  ),
                  const Icon(Icons.location_on_rounded, color: AppTheme.accentRed, size: 16),
                ],
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  children: [
                    _LocationField(
                      controller: _originCtrl,
                      focusNode: _originFocus,
                      hint: 'Source: search place, street, area...',
                      isActive: _selectingOrigin,
                      onTapField: () => setState(() {
                        _activeSearchField = 'origin';
                        _selectingOrigin = true;
                        _selectingDest = false;
                      }),
                    ),
                    const SizedBox(height: 6),
                    _LocationField(
                      controller: _destCtrl,
                      focusNode: _destFocus,
                      hint: 'Destination: search place, building...',
                      isActive: _selectingDest,
                      onTapField: () => setState(() {
                        _activeSearchField = 'dest';
                        _selectingDest = true;
                        _selectingOrigin = false;
                      }),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                children: [
                  // Swap button
                  GestureDetector(
                    onTap: _swapLocations,
                    child: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: AppTheme.cardDark,
                        shape: BoxShape.circle,
                        border: Border.all(color: AppTheme.borderDark),
                      ),
                      child: const Icon(Icons.swap_vert_rounded, color: AppTheme.textSecondary, size: 18),
                    ),
                  ),
                  const SizedBox(height: 6),
                  // Current GPS Location button
                  GestureDetector(
                    onTap: _useCurrentGpsLocation,
                    child: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: _isGpsTracking ? AppTheme.accentTeal.withValues(alpha: 0.2) : AppTheme.cardDark,
                        shape: BoxShape.circle,
                        border: Border.all(color: _isGpsTracking ? AppTheme.accentTeal : AppTheme.borderDark),
                      ),
                      child: Icon(
                        Icons.my_location_rounded,
                        color: _isGpsTracking ? AppTheme.accentTeal : AppTheme.textSecondary,
                        size: 17,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),

          // Autocomplete Dropdown List
          if (_activeSearchField.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              constraints: const BoxConstraints(maxHeight: 200),
              decoration: BoxDecoration(
                color: AppTheme.backgroundDark,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.accentTeal.withValues(alpha: 0.5)),
              ),
              child: _isSearching
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: Row(
                        children: [
                          SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.accentTeal)),
                          SizedBox(width: 10),
                          Text('Searching OpenStreetMap...', style: TextStyle(color: AppTheme.textMuted, fontSize: 12)),
                        ],
                      ),
                    )
                  : _suggestions.isEmpty
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: Text('No matching places found', style: TextStyle(color: AppTheme.textMuted, fontSize: 12)),
                        )
                      : ListView.separated(
                          shrinkWrap: true,
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          itemCount: _suggestions.length,
                          separatorBuilder: (_, __) => const Divider(height: 1, color: AppTheme.borderDark),
                          itemBuilder: (context, i) {
                            final item = _suggestions[i];
                            return ListTile(
                              dense: true,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
                              leading: Text(item.icon, style: const TextStyle(fontSize: 15)),
                              title: Text(item.name, style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13, fontWeight: FontWeight.w600)),
                              subtitle: Text(item.subtitle, style: const TextStyle(color: AppTheme.textMuted, fontSize: 11), maxLines: 1, overflow: TextOverflow.ellipsis),
                              onTap: () => _selectSuggestion(item),
                            );
                          },
                        ),
            ),
          ],

          const SizedBox(height: 12),

          // Route Action Buttons
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _searchRoutes,
                  icon: const Icon(Icons.route_rounded, size: 17),
                  label: const Text('Find Transit Route'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.accentTeal,
                    foregroundColor: AppTheme.backgroundDark,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
              if (_originPoint != null || _destPoint != null || _originCtrl.text.isNotEmpty || _destCtrl.text.isNotEmpty) ...[
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _clearRoute,
                  icon: const Icon(Icons.clear_rounded, size: 16, color: AppTheme.accentRed),
                  label: const Text('Clear', style: TextStyle(color: AppTheme.accentRed, fontSize: 13)),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: AppTheme.accentRed.withValues(alpha: 0.6)),
                    padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildBrandRow() {
    return Row(
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            gradient: const LinearGradient(colors: [AppTheme.accentTeal, AppTheme.accentBlue]),
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Center(child: Text('🗺️', style: TextStyle(fontSize: 16))),
        ),
        const SizedBox(width: 10),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('FlexiTransit', style: TextStyle(color: AppTheme.textPrimary, fontSize: 14, fontWeight: FontWeight.w700)),
            Text(
              (!CmrlService.isLoaded || !FeederService.isLoaded)
                  ? 'Loading transit network...'
                  : '${CmrlService.stopCount} CMRL stations • ${FeederService.stops.length} Feeder VSTOPs • ${MtcService.stopCount} MTC stops',
              style: const TextStyle(color: AppTheme.accentTeal, fontSize: 10),
            ),
          ],
        ),
      ],
    );
  }
}

class _SearchSuggestion {
  final String name;
  final String subtitle;
  final String icon;
  final double lat;
  final double lon;

  _SearchSuggestion({
    required this.name,
    required this.subtitle,
    required this.icon,
    required this.lat,
    required this.lon,
  });
}

class _LocationField extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final String hint;
  final bool isActive;
  final VoidCallback onTapField;

  const _LocationField({
    required this.controller,
    required this.focusNode,
    required this.hint,
    required this.isActive,
    required this.onTapField,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      height: 38,
      decoration: BoxDecoration(
        color: AppTheme.backgroundDark,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isActive ? AppTheme.accentTeal : AppTheme.borderDark,
          width: isActive ? 1.5 : 1,
        ),
      ),
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              onTap: onTapField,
              style: const TextStyle(color: AppTheme.textPrimary, fontSize: 12, fontWeight: FontWeight.w500),
              decoration: InputDecoration(
                hintText: hint,
                hintStyle: const TextStyle(color: AppTheme.textMuted, fontSize: 12),
                isCollapsed: true,
                contentPadding: EdgeInsets.zero,
                border: InputBorder.none,
              ),
            ),
          ),
          if (controller.text.isNotEmpty)
            GestureDetector(
              onTap: () => controller.clear(),
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: Icon(Icons.clear_rounded, size: 14, color: AppTheme.textMuted),
              ),
            ),
        ],
      ),
    );
  }
}
