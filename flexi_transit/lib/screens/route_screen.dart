import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:latlong2/latlong.dart';
import '../core/theme.dart';
import '../models/models.dart';
import '../services/api_service.dart';
import '../services/mtc_service.dart';
import '../services/cmrl_service.dart';
import '../widgets/map_widget.dart';

class RouteScreen extends StatefulWidget {
  final double originLat;
  final double originLon;
  final double destLat;
  final double destLon;
  final String originLabel;
  final String destLabel;

  const RouteScreen({
    super.key,
    required this.originLat,
    required this.originLon,
    required this.destLat,
    required this.destLon,
    required this.originLabel,
    required this.destLabel,
  });

  @override
  State<RouteScreen> createState() => _RouteScreenState();
}

class _RouteScreenState extends State<RouteScreen> {
  List<RouteOption> _routes = [];
  int _selectedRouteIndex = 0;
  bool _loading = true;
  final DraggableScrollableController _sheetController =
      DraggableScrollableController();

  RouteOption? get _route =>
      _routes.isNotEmpty && _selectedRouteIndex < _routes.length
          ? _routes[_selectedRouteIndex]
          : null;

  @override
  void initState() {
    super.initState();
    MtcService.loadData().then((_) => _loadRoute());
    CmrlService.loadData();
  }

  Future<void> _loadRoute() async {
    final now = TimeOfDay.now();
    final depTime =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

    final routes = await ApiService.getRoutes(
      originLat: widget.originLat,
      originLon: widget.originLon,
      destLat: widget.destLat,
      destLon: widget.destLon,
      depTime: depTime,
    );

    if (mounted) {
      setState(() {
        _routes = routes;
        _selectedRouteIndex = 0;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.backgroundDark,
      body: Stack(
        children: [
          // ── Map ──────────────────────────────────────────────────────────
          MapWidget(
            routeOptions: _routes,
            selectedRouteIndex: _selectedRouteIndex,
            originPoint: LatLng(widget.originLat, widget.originLon),
            destPoint: LatLng(widget.destLat, widget.destLon),
          ),

          // ── Back button + route header ────────────────────────────────────
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    GestureDetector(
                      onTap: () => Navigator.pop(context),
                      child: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: AppTheme.surfaceDark.withValues(alpha: 0.95),
                          shape: BoxShape.circle,
                          border: Border.all(color: AppTheme.borderDark),
                        ),
                        child: const Icon(
                          Icons.arrow_back_ios_new_rounded,
                          color: AppTheme.textPrimary,
                          size: 18,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: AppTheme.surfaceDark.withValues(alpha: 0.95),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: AppTheme.borderDark),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.radio_button_checked,
                                color: AppTheme.accentTeal, size: 14),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                widget.originLabel,
                                style: const TextStyle(
                                  color: AppTheme.textPrimary,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const Padding(
                              padding: EdgeInsets.symmetric(horizontal: 6),
                              child: Icon(Icons.arrow_forward,
                                  color: AppTheme.textMuted, size: 14),
                            ),
                            const Icon(Icons.location_on_rounded,
                                color: AppTheme.accentRed, size: 14),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                widget.destLabel,
                                style: const TextStyle(
                                  color: AppTheme.textPrimary,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Tooltip(
                      message: 'Clear Route',
                      child: GestureDetector(
                        onTap: () => Navigator.pop(context, true),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                          decoration: BoxDecoration(
                            color: AppTheme.surfaceDark.withValues(alpha: 0.95),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: AppTheme.accentRed.withValues(alpha: 0.5)),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.close_rounded, color: AppTheme.accentRed, size: 15),
                              SizedBox(width: 4),
                              Text(
                                'Clear',
                                style: TextStyle(
                                  color: AppTheme.accentRed,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // ── Bottom Draggable Sheet ─────────────────────────────────────────
          DraggableScrollableSheet(
            controller: _sheetController,
            initialChildSize: 0.48,
            minChildSize: 0.12,
            maxChildSize: 0.92,
            builder: (context, scrollController) {
              return Container(
                decoration: const BoxDecoration(
                  color: AppTheme.surfaceDark,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black54,
                      blurRadius: 30,
                      offset: Offset(0, -4),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    // Drag handle
                    const SizedBox(height: 12),
                    Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: AppTheme.borderDark,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Header
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Row(
                        children: [
                          const Text('🚌🚇',
                              style: TextStyle(fontSize: 20)),
                          const SizedBox(width: 10),
                          const Expanded(
                            child: Text(
                              'Your Journey',
                              style: TextStyle(
                                color: AppTheme.textPrimary,
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          if (_loading)
                            const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: AppTheme.accentTeal,
                              ),
                            )
                          else if (_route != null)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 5),
                              decoration: BoxDecoration(
                                color: AppTheme.accentTeal.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                _route!.totalTimeFormatted,
                                style: const TextStyle(
                                  color: AppTheme.accentTeal,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 6),
                    const Divider(height: 1, color: AppTheme.borderDark),

                    // Content
                    Expanded(
                      child: _loading
                          ? _buildLoading()
                          : _route == null
                              ? _buildNoRoute()
                              : _buildStepByStep(scrollController),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildLoading() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(color: AppTheme.accentTeal),
          const SizedBox(height: 16),
          const Text(
            'Finding best transit route...',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 14),
          ),
          const SizedBox(height: 6),
          Text(
            'Using MTC Bus + CMRL Metro data',
            style: const TextStyle(color: AppTheme.textMuted, fontSize: 12),
          ).animate().fadeIn(duration: 500.ms),
        ],
      ),
    );
  }

  Widget _buildNoRoute() {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('😕', style: TextStyle(fontSize: 36)),
          SizedBox(height: 12),
          Text(
            'No transit route found',
            style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w600),
          ),
          SizedBox(height: 6),
          Text(
            'Try a different origin or destination',
            style: TextStyle(color: AppTheme.textMuted, fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _buildStepByStep(ScrollController scrollController) {
    final route = _route!;

    return ListView(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 30),
      children: [
        // ── Mode Toggle Filters ─────────────────────────────────────────────
        if (_routes.length > 1) ...[
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: _routes.asMap().entries.map((entry) {
                final i = entry.key;
                final r = entry.value;
                final isSelected = _selectedRouteIndex == i;
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: InkWell(
                    onTap: () => setState(() => _selectedRouteIndex = i),
                    borderRadius: BorderRadius.circular(12),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? AppTheme.accentTeal.withValues(alpha: 0.18)
                            : AppTheme.cardDark,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isSelected
                              ? AppTheme.accentTeal
                              : AppTheme.borderDark,
                          width: isSelected ? 1.5 : 1.0,
                        ),
                      ),
                      child: Row(
                        children: [
                          Text(r.emoji, style: const TextStyle(fontSize: 14)),
                          const SizedBox(width: 6),
                          Text(
                            r.label,
                            style: TextStyle(
                              color: isSelected
                                  ? AppTheme.accentTeal
                                  : AppTheme.textSecondary,
                              fontSize: 12,
                              fontWeight: isSelected
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '• ${r.totalTimeFormatted}',
                            style: TextStyle(
                              color: isSelected
                                  ? AppTheme.textPrimary
                                  : AppTheme.textMuted,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 12),
        ],

        // ── Journey summary banner ──────────────────────────────────────────
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                AppTheme.accentTeal.withValues(alpha: 0.14),
                AppTheme.accentBlue.withValues(alpha: 0.08),
              ],
            ),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
                color: AppTheme.accentTeal.withValues(alpha: 0.35)),
          ),
          child: Row(
            children: [
              Text(route.emoji, style: const TextStyle(fontSize: 28)),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      route.label,
                      style: const TextStyle(
                        color: AppTheme.textPrimary,
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        _summaryChip(
                            Icons.timer_outlined, route.totalTimeFormatted),
                        _summaryChip(Icons.currency_rupee,
                            '₹${route.totalFareInr.toStringAsFixed(0)}'),
                        _summaryChip(Icons.alt_route_rounded,
                            '${route.transfers} transfers'),
                        _summaryChip(
                            Icons.eco_outlined,
                            '${(route.co2Grams / 1000).toStringAsFixed(2)}kg CO₂ saved'),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ).animate().fadeIn(duration: 300.ms),

        const SizedBox(height: 20),

        // ── Step-by-step journey ────────────────────────────────────────────
        ...route.steps.asMap().entries.map((entry) {
          final i = entry.key;
          final step = entry.value;
          final modeColor = Color(step.modeColorHex);
          final isLast = i == route.steps.length - 1;

          return Animate(
            effects: [
              FadeEffect(duration: 250.ms, delay: (i * 80).ms),
              SlideEffect(
                  begin: const Offset(0, 0.1),
                  end: Offset.zero,
                  duration: 250.ms,
                  delay: (i * 80).ms),
            ],
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── Timeline column ─────────────────────────────────────
                  SizedBox(
                    width: 48,
                    child: Column(
                      children: [
                        Container(
                          width: 38,
                          height: 38,
                          decoration: BoxDecoration(
                            color: modeColor.withValues(alpha: 0.15),
                            shape: BoxShape.circle,
                            border: Border.all(color: modeColor, width: 1.5),
                          ),
                          child: Center(
                            child: Text(step.modeIcon,
                                style: const TextStyle(fontSize: 17)),
                          ),
                        ),
                        if (!isLast)
                          Expanded(
                            child: Container(
                              width: 2,
                              margin:
                                  const EdgeInsets.symmetric(vertical: 4),
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [
                                    modeColor.withValues(alpha: 0.6),
                                    modeColor.withValues(alpha: 0.1),
                                  ],
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),

                  const SizedBox(width: 12),

                  // ── Step detail card ────────────────────────────────────
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(bottom: isLast ? 0 : 20),
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: modeColor.withValues(alpha: 0.06),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                              color: modeColor.withValues(alpha: 0.2)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Mode badge + time
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 3),
                                  decoration: BoxDecoration(
                                    color: modeColor.withValues(alpha: 0.18),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    step.modeLabel.toUpperCase(),
                                    style: TextStyle(
                                      color: modeColor,
                                      fontSize: 10,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 0.8,
                                    ),
                                  ),
                                ),
                                const Spacer(),
                                Text(
                                  '${step.departureTime} → ${step.arrivalTime}',
                                  style: const TextStyle(
                                      color: AppTheme.textMuted,
                                      fontSize: 11),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),

                            // Main instruction
                            Text(
                              step.instruction,
                              style: const TextStyle(
                                color: AppTheme.textPrimary,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),

                            // Bus numbers badge for bus mode
                            if (step.mode == 'bus' &&
                                step.busNumbers.isNotEmpty) ...[
                              const SizedBox(height: 6),
                              Wrap(
                                spacing: 4,
                                runSpacing: 4,
                                children: step.busNumbers
                                    .split(' / ')
                                    .map((num) => Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 8, vertical: 3),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFFFF6B35)
                                                .withValues(alpha: 0.15),
                                            borderRadius:
                                                BorderRadius.circular(6),
                                            border: Border.all(
                                              color: const Color(0xFFFF6B35)
                                                  .withValues(alpha: 0.5),
                                            ),
                                          ),
                                          child: Text(
                                            '🚌 $num',
                                            style: const TextStyle(
                                              color: Color(0xFFFF6B35),
                                              fontSize: 11,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ))
                                    .toList(),
                              ),
                            ],

                            const SizedBox(height: 6),

                            // From → To
                            Row(
                              children: [
                                const Icon(Icons.subdirectory_arrow_right,
                                    size: 13,
                                    color: AppTheme.textMuted),
                                const SizedBox(width: 4),
                                Expanded(
                                  child: Text(
                                    '${step.fromStop}  →  ${step.toStop}',
                                    style: const TextStyle(
                                        color: AppTheme.textMuted,
                                        fontSize: 11),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),

                            const SizedBox(height: 6),

                            // Duration + Fare chips
                            Row(
                              children: [
                                _chip(Icons.timer_outlined,
                                    '${step.durationMin.toStringAsFixed(0)} min'),
                                if (step.fareInr > 0) ...[
                                  const SizedBox(width: 8),
                                  _chip(Icons.currency_rupee,
                                      step.fareInr.toStringAsFixed(0)),
                                ],
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        }),
      ],
    );
  }

  Widget _summaryChip(IconData icon, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: AppTheme.textSecondary),
        const SizedBox(width: 3),
        Text(label,
            style: const TextStyle(
                color: AppTheme.textSecondary, fontSize: 12)),
      ],
    );
  }

  Widget _chip(IconData icon, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: AppTheme.backgroundDark,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppTheme.borderDark),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: AppTheme.textMuted),
          const SizedBox(width: 3),
          Text(label,
              style: const TextStyle(
                  color: AppTheme.textMuted, fontSize: 11)),
        ],
      ),
    );
  }
}
