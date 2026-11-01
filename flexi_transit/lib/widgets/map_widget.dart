import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../models/models.dart';
import '../core/theme.dart';
import '../services/mtc_service.dart';
import '../services/cmrl_service.dart';
import '../services/feeder_service.dart';

class MapWidget extends StatefulWidget {
  final List<RouteOption> routeOptions;
  final int? selectedRouteIndex;
  final Function(LatLng)? onMapTap;
  final LatLng? originPoint;
  final LatLng? destPoint;
  final LatLng? currentLocationPoint;
  /// If true, MTC bus stops are visible on the map (default: true)
  final bool showMtcStops;
  /// If true, CMRL Metro stations are visible on the map (default: true)
  final bool showCmrlStops;

  const MapWidget({
    super.key,
    required this.routeOptions,
    this.selectedRouteIndex,
    this.onMapTap,
    this.originPoint,
    this.destPoint,
    this.currentLocationPoint,
    this.showMtcStops = true,
    this.showCmrlStops = true,
  });

  @override
  State<MapWidget> createState() => _MapWidgetState();
}

class _MapWidgetState extends State<MapWidget>
    with SingleTickerProviderStateMixin {
  final MapController _mapController = MapController();

  // Viewport tracking for efficient MTC stop rendering
  double _currentZoom = AppConstants.mapInitialZoom;
  double _viewMinLat = 12.6;
  double _viewMaxLat = 13.5;
  double _viewMinLon = 79.8;
  double _viewMaxLon = 80.4;

  // Local toggle states for 4 layers
  bool _walkVisible = true;
  bool _feederVisible = true;
  bool _cmrlVisible = true;
  bool _virtualStopsVisible = true;
  bool _mtcVisible = true;
  bool _layersExpanded = false;

  // Concentric circle pulse animation for Transfer Hubs
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  // Cached visible stops for current viewport
  List<MtcStop> _visibleMtcStops = [];

  @override
  void initState() {
    super.initState();
    _mtcVisible = widget.showMtcStops;
    _cmrlVisible = widget.showCmrlStops;

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat();
    _pulseAnimation = CurvedAnimation(
      parent: _pulseController,
      curve: Curves.easeOut,
    );

    if (MtcService.isLoaded) {
      _updateVisibleStops();
    }
    FeederService.loadData().then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  List<TransferHub> get _transferHubsToRender {
    final hubs = <TransferHub>[];
    if (widget.routeOptions.isNotEmpty) {
      final selected = widget.selectedRouteIndex != null &&
              widget.selectedRouteIndex! < widget.routeOptions.length
          ? widget.routeOptions[widget.selectedRouteIndex!]
          : widget.routeOptions.first;
      hubs.addAll(selected.transferHubs);
    }
    if (hubs.isEmpty && FeederService.isLoaded && CmrlService.isLoaded) {
      hubs.addAll(FeederService.findTransferHubs(CmrlService.stops, maxDistMeters: 450.0));
    }
    return hubs;
  }

  void _updateVisibleStops() {
    if (!_mtcVisible || !MtcService.isLoaded) {
      setState(() => _visibleMtcStops = []);
      return;
    }

    // At low zoom levels, show fewer stops to avoid clutter
    List<MtcStop> visible;
    if (_currentZoom < 13) {
      final all = MtcService.getStopsInBounds(
        minLat: _viewMinLat,
        maxLat: _viewMaxLat,
        minLon: _viewMinLon,
        maxLon: _viewMaxLon,
      );
      visible = [
        for (int i = 0; i < all.length; i += 8) all[i],
      ];
    } else if (_currentZoom < 14.5) {
      final all = MtcService.getStopsInBounds(
        minLat: _viewMinLat,
        maxLat: _viewMaxLat,
        minLon: _viewMinLon,
        maxLon: _viewMaxLon,
      );
      visible = [
        for (int i = 0; i < all.length; i += 3) all[i],
      ];
    } else {
      visible = MtcService.getStopsInBounds(
        minLat: _viewMinLat,
        maxLat: _viewMaxLat,
        minLon: _viewMinLon,
        maxLon: _viewMaxLon,
      );
    }

    if (mounted) setState(() => _visibleMtcStops = visible);
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: const LatLng(
              AppConstants.mapCenterLat,
              AppConstants.mapCenterLon,
            ),
            initialZoom: AppConstants.mapInitialZoom,
            minZoom: 10,
            maxZoom: 18,
            onTap: widget.onMapTap != null
                ? (_, latlng) => widget.onMapTap!(latlng)
                : null,
            onPositionChanged: (pos, _) {
              final zoom = pos.zoom;
              final bounds = pos.visibleBounds;
              _viewMinLat = bounds.southWest.latitude;
              _viewMaxLat = bounds.northEast.latitude;
              _viewMinLon = bounds.southWest.longitude;
              _viewMaxLon = bounds.northEast.longitude;
              _currentZoom = zoom;
              _updateVisibleStops();
            },
          ),
          children: [
            // ── Base Map: OpenStreetMap standard tiles ───────────────────────
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.flexitransit.app',
            ),

            // ── Layer 3: CMRL Metro Line Polylines (Blue: #00529B, Green: #008000) ──
            if (_cmrlVisible && CmrlService.isLoaded)
              PolylineLayer(
                polylines: CmrlService.shapes.map((shape) {
                  return Polyline(
                    points: shape.polyline.map((p) => LatLng(p[0], p[1])).toList(),
                    color: Color(shape.parsedColorHex).withValues(alpha: 0.8),
                    strokeWidth: 6.0,
                  );
                }).toList(),
              ),

            // ── Multi-Modal Route Polylines (Walk: #4A5568, Feeder: #ED8936, Metro) ──
            ..._buildRoutePolylines(),

            // ── Transfer Hubs: Concentric Pulsing Rings ───────────────────────
            if (_transferHubsToRender.isNotEmpty)
              MarkerLayer(
                markers: _transferHubsToRender.map((hub) {
                  return Marker(
                    point: LatLng(hub.lat, hub.lon),
                    width: 60,
                    height: 60,
                    child: _PulsingTransferHubMarker(
                      hub: hub,
                      animation: _pulseAnimation,
                    ),
                  );
                }).toList(),
              ),

            // ── Layer 2: Mined Feeder Terminus Stands & Intermediate VSTOPs ─────
            if (_virtualStopsVisible && FeederService.isLoaded)
              MarkerLayer(
                markers: [
                  // Primary Origin Stand and Destination Stand for each mined route
                  ...FeederService.getPrimaryStands().map((stand) {
                    return Marker(
                      point: stand.point,
                      width: 80,
                      height: 56,
                      child: GestureDetector(
                        onTap: () => _showStandPopup(context, stand),
                        child: _FeederStandMarker(stand: stand),
                      ),
                    );
                  }),

                  // Intermediate virtual stops (VSTOP) rendered as subtle small dots (radius: 3px, low opacity)
                  ...FeederService.stops
                      .where((s) => !s.stopType.contains('TERMINAL'))
                      .map((stop) {
                    return Marker(
                      point: LatLng(stop.lat, stop.lon),
                      width: 14,
                      height: 14,
                      child: GestureDetector(
                        onTap: () => _showFeederStopInfo(context, stop),
                        child: _IntermediateVirtualStopMarker(stop: stop),
                      ),
                    );
                  }),

                  // Post-Search / Route Result: Highlight specific boarding and alighting stop on feeder corridor
                  ..._buildActiveFeederLegMarkers(),
                ],
              ),

            // ── Layer 3: CMRL Metro Station Markers (Prominent Diamond Markers) ──
            if (_cmrlVisible && CmrlService.isLoaded)
              MarkerLayer(
                markers: CmrlService.stops.map((stop) {
                  return Marker(
                    point: LatLng(stop.lat, stop.lon),
                    width: stop.isInterchange ? 40 : 34,
                    height: stop.isInterchange ? 40 : 34,
                    child: GestureDetector(
                      onTap: () => _showCmrlStopInfo(context, stop),
                      child: _CmrlStopMarker(stop: stop),
                    ),
                  );
                }).toList(),
              ),

            // ── MTC Bus Stop Markers ──────────────────────────────────────────
            if (_mtcVisible && _visibleMtcStops.isNotEmpty)
              MarkerLayer(
                markers: _visibleMtcStops.map((stop) {
                  return Marker(
                    point: LatLng(stop.lat, stop.lon),
                    width: _currentZoom < 13 ? 10 : (_currentZoom < 15 ? 18 : 28),
                    height: _currentZoom < 13 ? 10 : (_currentZoom < 15 ? 18 : 28),
                    child: GestureDetector(
                      onTap: () => _showMtcStopInfo(context, stop),
                      child: _MtcStopMarker(
                        stop: stop,
                        zoom: _currentZoom,
                      ),
                    ),
                  );
                }).toList(),
              ),

            // ── Current Location (GPS) Marker ─────────────────────────────────
            if (widget.currentLocationPoint != null)
              MarkerLayer(
                markers: [
                  Marker(
                    point: widget.currentLocationPoint!,
                    width: 32,
                    height: 32,
                    child: Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFF29B6F6).withValues(alpha: 0.25),
                        shape: BoxShape.circle,
                        border: Border.all(color: const Color(0xFF0288D1), width: 2),
                      ),
                      child: Center(
                        child: Container(
                          width: 14,
                          height: 14,
                          decoration: const BoxDecoration(
                            color: Color(0xFF0288D1),
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),

            // ── Origin & Destination Pins ─────────────────────────────────────
            if (widget.originPoint != null || widget.destPoint != null)
              MarkerLayer(
                markers: [
                  if (widget.originPoint != null)
                    Marker(
                      point: widget.originPoint!,
                      width: 44,
                      height: 44,
                      child: const _PinMarker(
                        color: AppTheme.accentTeal,
                        icon: Icons.my_location,
                        label: 'A',
                      ),
                    ),
                  if (widget.destPoint != null)
                    Marker(
                      point: widget.destPoint!,
                      width: 44,
                      height: 44,
                      child: const _PinMarker(
                        color: AppTheme.accentRed,
                        icon: Icons.location_on,
                        label: 'B',
                      ),
                    ),
                ],
              ),

            const RichAttributionWidget(
              attributions: [
                TextSourceAttribution('© OpenStreetMap contributors'),
              ],
            ),
          ],
        ),

        // ── Floating Top-Right Layer Switch Widget ───────────────────────────
        Positioned(
          top: 16,
          right: 16,
          child: SafeArea(
            child: _buildLayerSwitchWidget(),
          ),
        ),
      ],
    );
  }

  Widget _buildLayerSwitchWidget() {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.cardDark.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.borderDark, width: 1.5),
        boxShadow: const [
          BoxShadow(
            color: Colors.black45,
            blurRadius: 16,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: () => setState(() => _layersExpanded = !_layersExpanded),
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.layers_rounded, color: AppTheme.accentTeal, size: 20),
                  const SizedBox(width: 8),
                  const Text(
                    'Layers',
                    style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Icon(
                    _layersExpanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                    color: AppTheme.textMuted,
                    size: 18,
                  ),
                ],
              ),
            ),
          ),
          if (_layersExpanded) ...[
            const Divider(height: 1, color: AppTheme.borderDark),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _layerCheckbox(
                    title: 'Walking Network',
                    subtitle: '1.2 m/s transfer links',
                    color: const Color(0xFF4A5568),
                    value: _walkVisible,
                    icon: Icons.directions_walk_rounded,
                    onChanged: (v) => setState(() => _walkVisible = v ?? true),
                  ),
                  _layerCheckbox(
                    title: 'Informal Feeder Routes',
                    subtitle: 'Shared Auto corridors',
                    color: const Color(0xFFED8936),
                    value: _feederVisible,
                    icon: Icons.electric_rickshaw_rounded,
                    onChanged: (v) => setState(() => _feederVisible = v ?? true),
                  ),
                  _layerCheckbox(
                    title: 'CMRL Metro Network',
                    subtitle: 'Blue & Green lines',
                    color: const Color(0xFF00529B),
                    value: _cmrlVisible,
                    icon: Icons.subway_rounded,
                    onChanged: (v) => setState(() => _cmrlVisible = v ?? true),
                  ),
                  _layerCheckbox(
                    title: 'Mined Virtual Stops',
                    subtitle: 'GPS clustered VSTOPs',
                    color: const Color(0xFFED8936),
                    value: _virtualStopsVisible,
                    icon: Icons.pin_drop_rounded,
                    onChanged: (v) => setState(() => _virtualStopsVisible = v ?? true),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _layerCheckbox({
    required String title,
    required String subtitle,
    required Color color,
    required bool value,
    required IconData icon,
    required ValueChanged<bool?> onChanged,
  }) {
    return InkWell(
      onTap: () => onChanged(!value),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Checkbox(
              value: value,
              onChanged: onChanged,
              activeColor: color,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
            Icon(icon, color: color, size: 16),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: value ? AppTheme.textPrimary : AppTheme.textMuted,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  subtitle,
                  style: const TextStyle(
                    color: AppTheme.textMuted,
                    fontSize: 9.5,
                  ),
                ),
              ],
            ),
            const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildRoutePolylines() {
    if (widget.routeOptions.isEmpty) return [];

    final layers = <Widget>[];

    for (int i = 0; i < widget.routeOptions.length; i++) {
      final route = widget.routeOptions[i];
      final isSelected =
          widget.selectedRouteIndex == null || widget.selectedRouteIndex == i;
      final opacity = isSelected ? 1.0 : 0.25;

      if (route.steps.isNotEmpty) {
        for (final step in route.steps) {
          if (step.polyline.isEmpty) continue;
          final pts =
              step.polyline.map((p) => LatLng(p[0], p[1])).toList();

          Color color;
          double width;
          StrokePattern pattern;

          switch (step.mode) {
            case 'walk':
              if (!_walkVisible) continue;
              color = const Color(0xFF4A5568).withValues(alpha: opacity);
              width = isSelected ? 3.5 : 2.0;
              pattern = const StrokePattern.dotted();
              break;
            case 'feeder':
              if (!_feederVisible) continue;
              color = const Color(0xFFED8936).withValues(alpha: opacity);
              width = isSelected ? 5.5 : 3.0;
              pattern = const StrokePattern.solid();
              break;
            case 'metro':
              if (!_cmrlVisible) continue;
              final isGreen = step.instruction.toLowerCase().contains('green');
              color = (isGreen
                      ? const Color(0xFF008000)
                      : const Color(0xFF00529B))
                  .withValues(alpha: opacity);
              width = isSelected ? 6.0 : 3.5;
              pattern = const StrokePattern.solid();
              break;
            case 'bus':
              color = const Color(0xFFFFB800).withValues(alpha: opacity);
              width = isSelected ? 4.5 : 2.5;
              pattern = const StrokePattern.dotted();
              break;
            case 'cab':
              color = const Color(0xFFEF4444).withValues(alpha: opacity);
              width = isSelected ? 4.5 : 2.5;
              pattern = const StrokePattern.solid();
              break;
            default:
              color = const Color(0xFF00D4AA).withValues(alpha: opacity);
              width = 3.5;
              pattern = const StrokePattern.solid();
          }

          layers.add(
            PolylineLayer(
              polylines: [
                Polyline(
                  points: pts,
                  color: color,
                  strokeWidth: width,
                  pattern: pattern,
                ),
              ],
            ),
          );
        }
      } else if (route.polyline.isNotEmpty) {
        final points = route.polyline.map((p) => LatLng(p[0], p[1])).toList();
        Color color;
        switch (route.optionType) {
          case 'multimodal':
            color = const Color(0xFF00D4AA).withValues(alpha: opacity);
            break;
          case 'bus':
            color = const Color(0xFFFFB800).withValues(alpha: opacity);
            break;
          case 'cab':
            color = const Color(0xFFEF4444).withValues(alpha: opacity);
            break;
          default:
            color = Colors.white.withValues(alpha: opacity);
        }
        layers.add(
          PolylineLayer(
            polylines: [
              Polyline(
                points: points,
                color: color,
                strokeWidth: isSelected ? 5.0 : 2.5,
                pattern: route.optionType == 'bus'
                    ? const StrokePattern.dotted()
                    : const StrokePattern.solid(),
              ),
            ],
          ),
        );
      }
    }

    return layers;
  }

  List<Marker> _buildActiveFeederLegMarkers() {
    if (widget.routeOptions.isEmpty) return [];
    final selected = widget.selectedRouteIndex != null &&
            widget.selectedRouteIndex! < widget.routeOptions.length
        ? widget.routeOptions[widget.selectedRouteIndex!]
        : widget.routeOptions.first;

    final markers = <Marker>[];
    for (final step in selected.steps) {
      if (step.mode == 'feeder') {
        if (step.fromCoords.length >= 2) {
          final boardPt = LatLng(step.fromCoords[0], step.fromCoords[1]);
          markers.add(
            Marker(
              point: boardPt,
              width: 130,
              height: 48,
              child: _FeederStopBadgeMarker(
                stopName: step.fromStop,
                isBoarding: true,
              ),
            ),
          );
        }
        if (step.toCoords.length >= 2) {
          final alightPt = LatLng(step.toCoords[0], step.toCoords[1]);
          markers.add(
            Marker(
              point: alightPt,
              width: 130,
              height: 48,
              child: _FeederStopBadgeMarker(
                stopName: step.toStop,
                isBoarding: false,
              ),
            ),
          );
        }
      }
    }
    return markers;
  }

  // ── MTC Stop Bottom Sheet ─────────────────────────────────────────────────
  void _showMtcStopInfo(BuildContext context, MtcStop stop) {
    final routes = MtcService.getRoutesForStop(stop.stopId);
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.cardDark,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.45,
        minChildSize: 0.25,
        maxChildSize: 0.75,
        builder: (_, controller) => SingleChildScrollView(
          controller: controller,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 6, 20, 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Drag handle
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color: AppTheme.borderDark,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),

                // Header
                Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: const Color(0xFF00C853).withValues(alpha: 0.15),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: const Color(0xFF00C853),
                          width: 1.5,
                        ),
                      ),
                      child: const Center(
                        child: Text('🚌', style: TextStyle(fontSize: 20)),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            stop.stopName,
                            style: const TextStyle(
                              color: AppTheme.textPrimary,
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Text(
                            'Stop ID: ${stop.stopId}  •  ${stop.tripCount} trips/day',
                            style: const TextStyle(
                              color: AppTheme.textMuted,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Frequency badge
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Color(stop.freqColorHex).withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: Color(stop.freqColorHex).withValues(alpha: 0.5),
                        ),
                      ),
                      child: Text(
                        stop.freq.toUpperCase(),
                        style: TextStyle(
                          color: Color(stop.freqColorHex),
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.8,
                        ),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 20),
                const Divider(color: AppTheme.borderDark),
                const SizedBox(height: 14),

                // Routes section
                const Text(
                  'Routes Serving This Stop',
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),

                if (routes.isEmpty)
                  const Text(
                    'No route data available',
                    style: TextStyle(
                      color: AppTheme.textMuted,
                      fontSize: 13,
                    ),
                  )
                else
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: routes.take(30).map((routeName) {
                      return Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: AppTheme.accentAmber.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: AppTheme.accentAmber.withValues(alpha: 0.4),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text('🚌',
                                style: TextStyle(fontSize: 11)),
                            const SizedBox(width: 4),
                            Text(
                              routeName,
                              style: const TextStyle(
                                color: AppTheme.accentAmber,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      );
                    }).toList(),
                  ),

                const SizedBox(height: 20),

                // Quick-action buttons
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.radio_button_checked,
                            size: 15, color: AppTheme.accentTeal),
                        label: const Text(
                          'Set as Origin',
                          style: TextStyle(
                              color: AppTheme.accentTeal, fontSize: 12),
                        ),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: AppTheme.accentTeal),
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.location_on,
                            size: 15, color: AppTheme.accentRed),
                        label: const Text(
                          'Set as Dest.',
                          style: TextStyle(
                              color: AppTheme.accentRed, fontSize: 12),
                        ),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: AppTheme.accentRed),
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── CMRL Metro Station Bottom Sheet ────────────────────────────────────────
  void _showCmrlStopInfo(BuildContext context, CmrlStop stop) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.cardDark,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: AppTheme.borderDark,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: Color(stop.parsedColorHex).withValues(alpha: 0.18),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: Color(stop.parsedColorHex),
                      width: 2,
                    ),
                  ),
                  child: const Center(
                    child: Text('🚇', style: TextStyle(fontSize: 22)),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        stop.stopName,
                        style: const TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        'CMRL Station • ${stop.stopId}',
                        style: const TextStyle(
                          color: AppTheme.textMuted,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: Color(stop.parsedColorHex).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: Color(stop.parsedColorHex).withValues(alpha: 0.6),
                    ),
                  ),
                  child: Text(
                    stop.isInterchange ? 'INTERCHANGE' : stop.line.toUpperCase(),
                    style: TextStyle(
                      color: Color(stop.parsedColorHex),
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Divider(color: AppTheme.borderDark),
            const SizedBox(height: 12),
            _StopInfoRow(
              icon: Icons.subway_rounded,
              label: 'Line',
              value: stop.isInterchange ? 'Blue & Green Line Junction' : stop.line,
            ),
            const SizedBox(height: 8),
            _StopInfoRow(
              icon: Icons.access_time_rounded,
              label: 'Operating Hours',
              value: '${stop.firstTrain} - ${stop.lastTrain}',
            ),
            const SizedBox(height: 8),
            _StopInfoRow(
              icon: Icons.timer_rounded,
              label: 'Peak Headway',
              value: 'Every ${stop.peakFreqMin} mins',
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.radio_button_checked,
                        size: 15, color: AppTheme.accentTeal),
                    label: const Text(
                      'Set as Origin',
                      style: TextStyle(color: AppTheme.accentTeal, fontSize: 12),
                    ),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: AppTheme.accentTeal),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.location_on,
                        size: 15, color: AppTheme.accentRed),
                    label: const Text(
                      'Set as Dest.',
                      style: TextStyle(color: AppTheme.accentRed, fontSize: 12),
                    ),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: AppTheme.accentRed),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ── Feeder Stand Terminus Bottom Sheet (Prompt 2.A) ───────────────────────
  void _showStandPopup(BuildContext context, FeederStand stand) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.cardDark,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: AppTheme.borderDark,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: const Color(0xFFED8936).withValues(alpha: 0.18),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: const Color(0xFFED8936),
                      width: 2.2,
                    ),
                  ),
                  child: const Center(
                    child: Text('🛺', style: TextStyle(fontSize: 24)),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        stand.standName,
                        style: const TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Shared Auto Stand: ${stand.routeName} (Frequent departures)',
                        style: const TextStyle(
                          color: Color(0xFFED8936),
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: const Color(0xFFED8936).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: const Color(0xFFED8936).withValues(alpha: 0.6),
                    ),
                  ),
                  child: Text(
                    stand.isOrigin ? 'ORIGIN STAND' : 'DEST STAND',
                    style: const TextStyle(
                      color: Color(0xFFED8936),
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Divider(color: AppTheme.borderDark),
            const SizedBox(height: 12),
            _StopInfoRow(
              icon: Icons.alt_route_rounded,
              label: 'Mined Corridor',
              value: stand.routeName,
            ),
            const SizedBox(height: 8),
            const _StopInfoRow(
              icon: Icons.access_time_rounded,
              label: 'Operating Frequency',
              value: 'Frequent departures (every 3-5 mins)',
            ),
            const SizedBox(height: 8),
            const _StopInfoRow(
              icon: Icons.currency_rupee_rounded,
              label: 'Informal Stage Fare',
              value: '₹15 (≤2km) • ₹25 (2-6km) • ₹35 (>6km)',
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () {
                      Navigator.pop(context);
                      if (widget.onMapTap != null) {
                        widget.onMapTap!(stand.point);
                      }
                    },
                    icon: const Icon(Icons.touch_app_rounded,
                        size: 15, color: AppTheme.accentTeal),
                    label: const Text(
                      'Select on Map',
                      style: TextStyle(color: AppTheme.accentTeal, fontSize: 12),
                    ),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: AppTheme.accentTeal),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ── Feeder Virtual Stop Bottom Sheet ──────────────────────────────────────
  void _showFeederStopInfo(BuildContext context, VirtualFeederStop stop) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.cardDark,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: AppTheme.borderDark,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Row(
              children: [
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    color: const Color(0xFFED8936).withValues(alpha: 0.18),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: const Color(0xFFED8936),
                      width: 2,
                    ),
                  ),
                  child: const Center(
                    child: Text('🛺', style: TextStyle(fontSize: 22)),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        stop.stopName,
                        style: const TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        'Virtual Feeder Stop • ${stop.stopId}',
                        style: const TextStyle(
                          color: AppTheme.textMuted,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: const Color(0xFFED8936).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: const Color(0xFFED8936).withValues(alpha: 0.6),
                    ),
                  ),
                  child: Text(
                    stop.stopType.replaceAll('_', ' '),
                    style: const TextStyle(
                      color: Color(0xFFED8936),
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Divider(color: AppTheme.borderDark),
            const SizedBox(height: 12),
            _StopInfoRow(
              icon: Icons.alt_route_rounded,
              label: 'Corridor',
              value: stop.corridorName,
            ),
            const SizedBox(height: 8),
            _StopInfoRow(
              icon: Icons.timer_outlined,
              label: 'Avg Dwell Time',
              value: '${stop.avgDwellTimeSec.toStringAsFixed(0)}s',
            ),
            const SizedBox(height: 8),
            const _StopInfoRow(
              icon: Icons.schedule_rounded,
              label: 'Dynamic Wait (Headway/2)',
              value: '3.0 mins (Peak headway 6 min)',
            ),
            const SizedBox(height: 8),
            const _StopInfoRow(
              icon: Icons.currency_rupee_rounded,
              label: 'Informal Stage Fare',
              value: '₹15 (≤2km) • ₹25 (2-6km) • ₹35 (>6km)',
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// MTC STOP MARKER
// ─────────────────────────────────────────────────────────────────────────────
class _MtcStopMarker extends StatelessWidget {
  final MtcStop stop;
  final double zoom;

  const _MtcStopMarker({required this.stop, required this.zoom});

  @override
  Widget build(BuildContext context) {
    final color = Color(stop.freqColorHex);

    if (zoom < 13) {
      // Tiny dot at low zoom
      return Container(
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.8),
          shape: BoxShape.circle,
        ),
      );
    }

    if (zoom < 15) {
      // Small marker with border
      return Tooltip(
        message: stop.stopName,
        child: Container(
          decoration: BoxDecoration(
            color: AppTheme.backgroundDark,
            shape: BoxShape.circle,
            border: Border.all(color: color, width: 2),
          ),
          child: Center(
            child: Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
              ),
            ),
          ),
        ),
      );
    }

    // Full marker with bus icon at high zoom
    return Tooltip(
      message: '🚌 ${stop.stopName}',
      child: Container(
        decoration: BoxDecoration(
          color: AppTheme.cardDark,
          shape: BoxShape.circle,
          border: Border.all(color: color, width: 2),
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: 0.4),
              blurRadius: 6,
              spreadRadius: 1,
            ),
          ],
        ),
        child: Center(
          child: Text(
            'B',
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.bold,
              fontSize: 11,
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ORIGIN / DESTINATION PIN
// ─────────────────────────────────────────────────────────────────────────────
class _PinMarker extends StatelessWidget {
  final Color color;
  final IconData icon;
  final String label;

  const _PinMarker({
    required this.color,
    required this.icon,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: color.withValues(alpha: 0.5),
                blurRadius: 10,
                spreadRadius: 2,
              ),
            ],
          ),
          child: Center(
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: 14,
              ),
            ),
          ),
        ),
        Container(
          width: 2,
          height: 10,
          color: color,
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// STOP INFO ROW
// ─────────────────────────────────────────────────────────────────────────────
class _StopInfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _StopInfoRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: AppTheme.accentTeal, size: 18),
        const SizedBox(width: 10),
        Text(
          '$label: ',
          style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
        ),
        Text(
          value,
          style: const TextStyle(
            color: AppTheme.textPrimary,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// LAYER 3: CMRL METRO STATION PROMINENT DIAMOND MARKER
// ─────────────────────────────────────────────────────────────────────────────
class _CmrlStopMarker extends StatelessWidget {
  final CmrlStop stop;

  const _CmrlStopMarker({required this.stop});

  @override
  Widget build(BuildContext context) {
    final color = Color(stop.parsedColorHex);
    final size = stop.isInterchange ? 26.0 : 22.0;

    return Tooltip(
      message: '🚇 ${stop.stopName} (${stop.line})',
      child: Center(
        child: Transform.rotate(
          angle: 0.785398, // 45 degrees -> Diamond shape
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: AppTheme.cardDark,
              border: Border.all(
                color: color,
                width: stop.isInterchange ? 3.0 : 2.0,
              ),
              borderRadius: BorderRadius.circular(4),
              boxShadow: [
                BoxShadow(
                  color: color.withValues(alpha: 0.7),
                  blurRadius: stop.isInterchange ? 12 : 8,
                  spreadRadius: 1,
                ),
              ],
            ),
            child: Center(
              child: Transform.rotate(
                angle: -0.785398, // Rotate text back upright
                child: Text(
                  stop.isInterchange ? '⚡' : 'M',
                  style: TextStyle(
                    color: color,
                    fontWeight: FontWeight.w900,
                    fontSize: stop.isInterchange ? 12 : 10,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// LAYER 2: MINED VIRTUAL STOP MARKER (Auto-Rickshaw Badge)
// ─────────────────────────────────────────────────────────────────────────────
// ─────────────────────────────────────────────────────────────────────────────
// LAYER 2: FEEDER TERMINUS STAND MARKER (Custom Auto Rickshaw Stand Badge)
// ─────────────────────────────────────────────────────────────────────────────
class _FeederStandMarker extends StatelessWidget {
  final FeederStand stand;

  const _FeederStandMarker({required this.stand});

  @override
  Widget build(BuildContext context) {
    const color = Color(0xFFED8936);

    return Tooltip(
      message: 'Shared Auto Stand: ${stand.routeName} (Frequent departures)',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: AppTheme.cardDark,
              shape: BoxShape.circle,
              border: Border.all(
                color: color,
                width: 2.2,
              ),
              boxShadow: [
                BoxShadow(
                  color: color.withValues(alpha: 0.5),
                  blurRadius: 8,
                  spreadRadius: 1,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: const Center(
              child: Text(
                '🛺',
                style: TextStyle(fontSize: 17),
              ),
            ),
          ),
          Container(
            margin: const EdgeInsets.only(top: 2),
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: AppTheme.cardDark.withValues(alpha: 0.92),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: color.withValues(alpha: 0.6), width: 1),
            ),
            child: Text(
              stand.standName.replaceAll(' Feeder Stand', ''),
              style: const TextStyle(
                color: color,
                fontSize: 9,
                fontWeight: FontWeight.w700,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Subtle Intermediate Virtual Stop Dot (Radius 3px, Low Opacity) ─────────
class _IntermediateVirtualStopMarker extends StatelessWidget {
  final VirtualFeederStop stop;

  const _IntermediateVirtualStopMarker({required this.stop});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Virtual Stop: ${stop.stopName}',
      child: Center(
        child: Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(
            color: const Color(0xFFED8936).withValues(alpha: 0.35),
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }
}

// ── Active Route: Boarding & Alighting Highlights on Feeder Corridor ────────
class _FeederStopBadgeMarker extends StatelessWidget {
  final String stopName;
  final bool isBoarding;

  const _FeederStopBadgeMarker({
    required this.stopName,
    required this.isBoarding,
  });

  @override
  Widget build(BuildContext context) {
    const color = Color(0xFFED8936);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
          decoration: BoxDecoration(
            color: AppTheme.cardDark,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: color, width: 2),
            boxShadow: [
              BoxShadow(
                color: color.withValues(alpha: 0.65),
                blurRadius: 8,
                spreadRadius: 1,
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                isBoarding ? '🛺 BOARD' : '🛺 ALIGHT',
                style: const TextStyle(
                  color: color,
                  fontSize: 9,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  stopName,
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 9,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        Icon(
          Icons.arrow_drop_down_rounded,
          color: color,
          size: 14,
        ),
      ],
    );
  }
}


// ─────────────────────────────────────────────────────────────────────────────
// TRANSFER HUB MARKER: PULSING CONCENTRIC RINGS
// ─────────────────────────────────────────────────────────────────────────────
class _PulsingTransferHubMarker extends StatelessWidget {
  final TransferHub hub;
  final Animation<double> animation;

  const _PulsingTransferHubMarker({
    required this.hub,
    required this.animation,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        final progress = animation.value;
        return Tooltip(
          message: '🔄 Transfer Hub: ${hub.hubName}',
          child: Center(
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Outer pulsing ring
                Container(
                  width: 24 + (progress * 28),
                  height: 24 + (progress * 28),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: const Color(0xFF00D4AA)
                          .withValues(alpha: (1.0 - progress) * 0.8),
                      width: 2.0,
                    ),
                    color: const Color(0xFF00D4AA)
                        .withValues(alpha: (1.0 - progress) * 0.2),
                  ),
                ),
                // Inner solid hub badge
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: AppTheme.cardDark,
                    shape: BoxShape.circle,
                    border:
                        Border.all(color: const Color(0xFF00D4AA), width: 2),
                    boxShadow: [
                      BoxShadow(
                        color:
                            const Color(0xFF00D4AA).withValues(alpha: 0.6),
                        blurRadius: 8,
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                  child: const Center(
                    child: Text(
                      '⇄',
                      style: TextStyle(
                        color: Color(0xFF00D4AA),
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}


