import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../models/models.dart';
import '../core/theme.dart';

// ─────────────────────────────────────────────────────────────────────────────
// ROUTE CARD
// ─────────────────────────────────────────────────────────────────────────────
class RouteCard extends StatelessWidget {
  final RouteOption route;
  final bool isSelected;
  final VoidCallback onTap;
  final int index;

  const RouteCard({
    super.key,
    required this.route,
    required this.isSelected,
    required this.onTap,
    required this.index,
  });

  @override
  Widget build(BuildContext context) {
    final borderColor = Color(route.colorHex);

    return Animate(
      effects: [
        FadeEffect(duration: 300.ms, delay: (index * 80).ms),
        SlideEffect(
          begin: const Offset(0, 0.1),
          end: Offset.zero,
          duration: 300.ms,
          delay: (index * 80).ms,
        ),
      ],
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeInOut,
          margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            color: isSelected
                ? borderColor.withValues(alpha: 0.08)
                : AppTheme.cardDark,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isSelected ? borderColor : AppTheme.borderDark,
              width: isSelected ? 2 : 1,
            ),
            boxShadow: isSelected
                ? [
                    BoxShadow(
                      color: borderColor.withValues(alpha: 0.2),
                      blurRadius: 20,
                      offset: const Offset(0, 4),
                    ),
                  ]
                : null,
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Header Row ─────────────────────────────────────────
                Row(
                  children: [
                    Text(route.emoji, style: const TextStyle(fontSize: 22)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            route.label,
                            style: const TextStyle(
                              color: AppTheme.textPrimary,
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            '${route.transfers} transfer${route.transfers != 1 ? 's' : ''}  •  ${route.co2Grams.toStringAsFixed(0)}g CO₂',
                            style: const TextStyle(
                              color: AppTheme.textMuted,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (isSelected)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: borderColor.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: borderColor, width: 1),
                        ),
                        child: Text(
                          'Selected',
                          style: TextStyle(
                            color: borderColor,
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                  ],
                ),

                const SizedBox(height: 14),
                const Divider(color: AppTheme.borderDark, height: 1),
                const SizedBox(height: 14),

                // ── Stats Row ───────────────────────────────────────────
                Row(
                  children: [
                    _StatChip(
                      icon: Icons.schedule_rounded,
                      value: route.totalTimeFormatted,
                      color: borderColor,
                    ),
                    const SizedBox(width: 10),
                    _StatChip(
                      icon: Icons.currency_rupee_rounded,
                      value: route.fareFormatted,
                      color: borderColor,
                    ),
                    const SizedBox(width: 10),
                    _ModePillRow(steps: route.steps, borderColor: borderColor),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  final IconData icon;
  final String value;
  final Color color;

  const _StatChip({
    required this.icon,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppTheme.backgroundDark,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 5),
          Text(
            value,
            style: const TextStyle(
              color: AppTheme.textPrimary,
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}

class _ModePillRow extends StatelessWidget {
  final List<JourneyStep> steps;
  final Color borderColor;

  const _ModePillRow({required this.steps, required this.borderColor});

  @override
  Widget build(BuildContext context) {
    final modes = steps.map((s) => s.modeIcon).toSet().toList();
    return Wrap(
      spacing: 4,
      children: modes
          .map(
            (icon) => Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                color: borderColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(icon, style: const TextStyle(fontSize: 14)),
            ),
          )
          .toList(),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// STEP TIMELINE WIDGET
// ─────────────────────────────────────────────────────────────────────────────
class StepTimeline extends StatelessWidget {
  final List<JourneyStep> steps;

  const StepTimeline({super.key, required this.steps});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: steps.asMap().entries.map((entry) {
        final i = entry.key;
        final step = entry.value;
        final isLast = i == steps.length - 1;
        final modeColor = Color(step.modeColorHex);

        return Animate(
          effects: [
            FadeEffect(duration: 250.ms, delay: (i * 60).ms),
          ],
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Timeline indicator ──────────────────────────────────
                SizedBox(
                  width: 44,
                  child: Column(
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: modeColor.withValues(alpha: 0.15),
                          shape: BoxShape.circle,
                          border: Border.all(color: modeColor, width: 1.5),
                        ),
                        child: Center(
                          child: Text(
                            step.modeIcon,
                            style: const TextStyle(fontSize: 16),
                          ),
                        ),
                      ),
                      if (!isLast)
                        Expanded(
                          child: Container(
                            width: 2,
                            margin: const EdgeInsets.symmetric(vertical: 4),
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  modeColor,
                                  Color(steps[i + 1].modeColorHex)
                                      .withValues(alpha: 0.5),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),

                const SizedBox(width: 12),

                // ── Step content ────────────────────────────────────────
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(bottom: isLast ? 0 : 20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Mode label + time
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: modeColor.withValues(alpha: 0.12),
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
                            Text(
                              '${step.departureTime} → ${step.arrivalTime}',
                              style: const TextStyle(
                                color: AppTheme.textMuted,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),

                        const SizedBox(height: 6),

                        // Instruction
                        Text(
                          step.instruction,
                          style: const TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),

                        const SizedBox(height: 4),

                        // Duration + fare
                        Row(
                          children: [
                            Icon(Icons.timer_outlined,
                                size: 12, color: AppTheme.textMuted),
                            const SizedBox(width: 4),
                            Text(
                              '${step.durationMin.toStringAsFixed(0)} min',
                              style: const TextStyle(
                                color: AppTheme.textMuted,
                                fontSize: 12,
                              ),
                            ),
                            if (step.fareInr > 0) ...[
                              const SizedBox(width: 12),
                              const Icon(Icons.currency_rupee,
                                  size: 12, color: AppTheme.textMuted),
                              Text(
                                step.fareInr.toStringAsFixed(0),
                                style: const TextStyle(
                                  color: AppTheme.textMuted,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }
}
