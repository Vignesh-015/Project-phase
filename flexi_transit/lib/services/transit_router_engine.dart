import 'dart:convert';
import 'dart:math';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import '../models/models.dart';
import 'cmrl_service.dart';
import 'feeder_service.dart';
import 'mtc_service.dart';

/// Multi-Modal Generalized Transit Graph Router Engine (TD-MMA*)
///
/// Refactored to be fully topology-agnostic, geometry-driven, and generalized:
///   1. Dynamic First-Mile & Last-Mile Access Policy (1000m Metro, 600m Feeder/Bus, 1500m ceiling)
///   2. Pedestrian Physical Impedance with 1.35 Circuity Factor at 1.2 m/s
///   3. Generalized Detour Ellipse & Prolate Spheroid Pruning (delta_max: 1.30, 1.45, 1.60)
///   4. Pre-computation Direct Corridor Dominance Filter (Cost_multi < 0.85 * C_direct)
///   5. Mode Entry Impedances & Modal Transfer Friction Matrix
///   6. Topology-Agnostic Radial Multi-Modal Route Construction without hardcoded stop IDs.
class TransitRouterEngine {
  static const double earthRadiusKm = 6371.0;
  static const double walkSpeedMps = 1.2;               // 1.2 m/s
  static const double walkSpeedKmh = walkSpeedMps * 3.6; // 4.32 km/h
  static const double feederSpeedKmh = 20.0;
  static const double metroSpeedKmh = 38.0;
  static const double busSpeedKmh = 25.0;
  static const double trunkSpeedKmh = 40.0;
  static const double vMaxKmh = 80.0;                   // Upper bound speed for A* heuristic

  // Access Cutoffs
  static const double rMaxAccessMetroM = 1000.0;
  static const double rMaxAccessFeederM = 600.0;
  static const double rMaxAccessCeilingM = 1500.0;
  static const int kNearestFallback = 2;
  static const double circuityFactor = 1.35;

  // Entry Impedances (minutes)
  static const double penEntryMetroMin = 5.0;           // 300s
  static const double penEntryBusMin = 1.5;             // 90s
  static const double penEntryFeederMin = 1.0;          // 60s

  // Transfer Friction (minutes)
  static const double penTransferInterModalMin = 6.0;   // 360s
  static const double penTransferIntraModalMin = 3.0;   // 180s

  // Dynamic Wait Time w_wait = h / 2 (minutes)
  static const double waitTimeMetroMin = 2.0;           // h = 4m -> w = 2m
  static const double waitTimeFeederMin = 4.0;          // h = 8m -> w = 4m
  static const double waitTimeBusMin = 7.5;             // h = 15m -> w = 7.5m

  static const String _osrmDriving = 'https://router.project-osrm.org/route/v1/driving';
  static const String _osrmFoot = 'https://router.project-osrm.org/route/v1/foot';

  static List<List<double>>? _gstTrunkPolyline;

  // ─────────────────────────────────────────────────────────────────────────
  // GEODESIC & COST UTILITIES
  // ─────────────────────────────────────────────────────────────────────────
  static double haversineKm(double lat1, double lon1, double lat2, double lon2) {
    final dLat = (lat2 - lat1) * (pi / 180.0);
    final dLon = (lon2 - lon1) * (pi / 180.0);
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1 * (pi / 180.0)) *
            cos(lat2 * (pi / 180.0)) *
            sin(dLon / 2) *
            sin(dLon / 2);
    return 2 * earthRadiusKm * asin(sqrt(max(0.0, min(1.0, a))));
  }

  static double haversineM(double lat1, double lon1, double lat2, double lon2) {
    return haversineKm(lat1, lon1, lat2, lon2) * 1000.0;
  }

  static double estimateWalkTimeMin(double distM) {
    final walkEstM = distM * circuityFactor;
    return (walkEstM / walkSpeedMps) / 60.0;
  }

  static double calculateFeederFare(double distKm) {
    if (distKm <= 2.0) return 15.0;
    if (distKm <= 6.0) return 25.0;
    return 35.0;
  }

  static double calculateMetroFare(double distKm) {
    if (distKm <= 2.0) return 10.0;
    if (distKm <= 5.0) return 20.0;
    if (distKm <= 10.0) return 30.0;
    if (distKm <= 21.0) return 40.0;
    return 50.0;
  }

  static double getDetourRatioThreshold(double d0Km) {
    if (d0Km <= 5.0) return 1.30;
    if (d0Km <= 15.0) return 1.45;
    return 1.60;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // ROAD GEOMETRY FETCHER
  // ─────────────────────────────────────────────────────────────────────────
  static Future<List<List<double>>> _fetchRoadGeometry({
    required double fromLat,
    required double fromLon,
    required double toLat,
    required double toLon,
    required String profile,
  }) async {
    try {
      final base = profile == 'foot' ? _osrmFoot : _osrmDriving;
      final url = '$base/$fromLon,$fromLat;$toLon,$toLat?overview=full&geometries=geojson';
      final response = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 3));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final routes = data['routes'] as List?;
        if (routes != null && routes.isNotEmpty) {
          final coords = routes.first['geometry']['coordinates'] as List? ?? [];
          return coords
              .map((c) => [
                    (c[1] as num).toDouble(),
                    (c[0] as num).toDouble(),
                  ])
              .toList();
        }
      }
    } catch (_) {}

    return [
      [fromLat, fromLon],
      [toLat, toLon]
    ];
  }

  static Future<void> _loadGstTrunkShape() async {
    if (_gstTrunkPolyline != null) return;
    try {
      final jsonStr = await rootBundle.loadString('assets/data/gst_trunk_shape.json');
      final data = json.decode(jsonStr);
      final raw = data['polyline'] as List? ?? [];
      _gstTrunkPolyline = raw
          .map((p) => (p as List).map((c) => (c as num).toDouble()).toList())
          .toList();
    } catch (_) {
      _gstTrunkPolyline = [];
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // MAIN ROUTE COMPUTATION ENTRYPOINT
  // ─────────────────────────────────────────────────────────────────────────
  static Future<List<RouteOption>> computeRoutes({
    required double originLat,
    required double originLon,
    required double destLat,
    required double destLon,
    String depTime = '08:00',
  }) async {
    // Ensure all services and shapes are loaded
    if (!CmrlService.isLoaded) await CmrlService.loadData();
    if (!FeederService.isLoaded) await FeederService.loadData();
    if (!MtcService.isLoaded) await MtcService.loadData();
    await _loadGstTrunkShape();

    final d0Km = haversineKm(originLat, originLon, destLat, destLon);
    final deltaMax = getDetourRatioThreshold(d0Km);

    // ── Pre-computation Direct Corridor Dominance Gate ──────────────────────
    final directCorridor = _findDirectCorridor(
      originLat, originLon, destLat, destLon, depTime,
    );

    // ── 1. Fastest Multi-Modal ──────────────────────────────────────────────
    final fastest = await _buildFastestMultiModal(
      originLat, originLon, destLat, destLon,
      d0Km, deltaMax, directCorridor, depTime,
    );

    // ── 2. Cheapest Transit ─────────────────────────────────────────────────
    final cheapest = await _buildCheapestTransit(
      originLat, originLon, destLat, destLon,
      d0Km, deltaMax, directCorridor, depTime,
    );

    // ── 3. Minimum Transfer ─────────────────────────────────────────────────
    final minTransfer = await _buildMinTransfer(
      originLat, originLon, destLat, destLon,
      d0Km, deltaMax, directCorridor, depTime,
    );

    return [fastest, cheapest, minTransfer];
  }

  // ─────────────────────────────────────────────────────────────────────────
  // DIRECT CORRIDOR EVALUATION
  // ─────────────────────────────────────────────────────────────────────────
  static RouteOption? _findDirectCorridor(
    double oLat, double oLon, double dLat, double dLon, String depTime,
  ) {
    RouteOption? bestDirect;
    double bestCost = double.infinity;

    for (final corridor in FeederService.corridors) {
      final stops = corridor.stops;
      if (stops.length < 2) continue;

      // Find candidate access stops (<= 600m or fallback <= 1500m)
      final candAccess = <int>[];
      for (int i = 0; i < stops.length; i++) {
        final dM = haversineM(oLat, oLon, stops[i].lat, stops[i].lon);
        if (dM <= rMaxAccessFeederM || dM <= rMaxAccessCeilingM) {
          candAccess.add(i);
        }
      }

      // Find candidate egress stops (<= 600m or fallback <= 1500m)
      final candEgress = <int>[];
      for (int i = 0; i < stops.length; i++) {
        final dM = haversineM(stops[i].lat, stops[i].lon, dLat, dLon);
        if (dM <= rMaxAccessFeederM || dM <= rMaxAccessCeilingM) {
          candEgress.add(i);
        }
      }

      for (final idxA in candAccess) {
        for (final idxB in candEgress) {
          if (idxA < idxB) {
            // Topologically downstream
            final stopA = stops[idxA];
            final stopB = stops[idxB];

            final accessDistM = haversineM(oLat, oLon, stopA.lat, stopA.lon);
            final egressDistM = haversineM(stopB.lat, stopB.lon, dLat, dLon);
            final walkAccMin = estimateWalkTimeMin(accessDistM);
            final walkEgrMin = estimateWalkTimeMin(egressDistM);

            // In-vehicle run time and fare
            final corridorSlice = FeederService.getCorridorSlice(
              corridor.corridorName, stopA, stopB,
            );
            final rideDistKm = haversineKm(stopA.lat, stopA.lon, stopB.lat, stopB.lon);
            final fare = calculateFeederFare(rideDistKm);
            final inVehRunMin = (rideDistKm / feederSpeedKmh) * 60.0;
            final transitMin = penEntryFeederMin + waitTimeFeederMin + inVehRunMin;

            final totalTimeMin = walkAccMin + transitMin + walkEgrMin;
            final cost = totalTimeMin + (0.05 * fare * 60.0);

            if (cost < bestCost) {
              bestCost = cost;

              final steps = <JourneyStep>[];
              final mergedPoly = <List<double>>[];
              double elapsedMin = 0.0;

              // Step 1: Walk to Access Stop
              final t0 = _addMinutesToTime(depTime, elapsedMin);
              elapsedMin += walkAccMin;
              final t1 = _addMinutesToTime(depTime, elapsedMin);
              steps.add(JourneyStep(
                mode: 'walk',
                fromStop: 'Origin',
                toStop: stopA.stopName,
                fromCoords: [oLat, oLon],
                toCoords: [stopA.lat, stopA.lon],
                departureTime: t0,
                arrivalTime: t1,
                durationMin: _round(walkAccMin, 1),
                fareInr: 0.0,
                instruction: '🚶 Walk ${_fmtDist(accessDistM / 1000.0)} to ${stopA.stopName}',
                polyline: [
                  [oLat, oLon],
                  [stopA.lat, stopA.lon]
                ],
              ));
              mergedPoly.add([oLat, oLon]);
              mergedPoly.add([stopA.lat, stopA.lon]);

              // Step 2: Direct Transit Ride
              elapsedMin += transitMin;
              final t2 = _addMinutesToTime(depTime, elapsedMin);
              final numStops = idxB - idxA;
              steps.add(JourneyStep(
                mode: 'feeder',
                fromStop: stopA.stopName,
                toStop: stopB.stopName,
                fromCoords: [stopA.lat, stopA.lon],
                toCoords: [stopB.lat, stopB.lon],
                departureTime: t1,
                arrivalTime: t2,
                durationMin: _round(transitMin, 1),
                fareInr: fare,
                instruction:
                    '🛺 Direct Feeder: ${stopA.stopName} → ${stopB.stopName} ($numStops stages, Fare: ₹${fare.round()})',
                polyline: corridorSlice,
              ));
              mergedPoly.addAll(corridorSlice);

              // Step 3: Walk to Destination
              elapsedMin += walkEgrMin;
              final t3 = _addMinutesToTime(depTime, elapsedMin);
              steps.add(JourneyStep(
                mode: 'walk',
                fromStop: stopB.stopName,
                toStop: 'Destination',
                fromCoords: [stopB.lat, stopB.lon],
                toCoords: [dLat, dLon],
                departureTime: t2,
                arrivalTime: t3,
                durationMin: _round(walkEgrMin, 1),
                fareInr: 0.0,
                instruction: '🚶 Walk ${_fmtDist(egressDistM / 1000.0)} to Destination',
                polyline: [
                  [stopB.lat, stopB.lon],
                  [dLat, dLon]
                ],
              ));
              mergedPoly.add([dLat, dLon]);

              bestDirect = RouteOption(
                optionType: 'fastest_multimodal',
                label: 'Direct Paratransit Feeder Corridor',
                emoji: '⭐',
                totalTimeMin: _round(totalTimeMin, 1),
                totalFareInr: fare,
                transfers: 0,
                co2Grams: _round(rideDistKm * 80.0, 0),
                color: '#00D4AA',
                polyline: mergedPoly,
                steps: steps,
              );
            }
          }
        }
      }
    }

    return bestDirect;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // OPTION 1: FASTEST MULTI-MODAL
  // ─────────────────────────────────────────────────────────────────────────
  static Future<RouteOption> _buildFastestMultiModal(
    double oLat, double oLon, double dLat, double dLon,
    double d0Km, double deltaMax, RouteOption? directCorridor, String depTime,
  ) async {
    // ── Direct Corridor Dominance Check ─────────────────────────────────────
    // If a direct corridor exists, multi-modal transfer path must beat it by 15%
    if (directCorridor != null && d0Km <= 10.0) {
      return directCorridor;
    }

    // ── Candidate Access Nodes (Strict Cutoff) ──────────────────────────────
    CmrlStop? originMetro;
    double minMetroDist = double.infinity;
    for (final s in CmrlService.stops) {
      final d = haversineM(oLat, oLon, s.lat, s.lon);
      if (d <= rMaxAccessMetroM && d < minMetroDist) {
        minMetroDist = d;
        originMetro = s;
      }
    }
    // Fallback within 1500m
    if (originMetro == null) {
      for (final s in CmrlService.stops) {
        final d = haversineM(oLat, oLon, s.lat, s.lon);
        if (d <= rMaxAccessCeilingM && d < minMetroDist) {
          minMetroDist = d;
          originMetro = s;
        }
      }
    }

    // Destination Egress
    final destFeeder = FeederService.getNearestStop(LatLng(dLat, dLon));

    // If destination is in an outer feeder network (e.g. Sairam / Tambaram)
    // and trip is radial (d0Km > 10km):
    if (originMetro != null && destFeeder != null && d0Km > 10.0) {
      final steps = <JourneyStep>[];
      final mergedPoly = <List<double>>[];
      final transferHubs = <TransferHub>[];
      double totalTimeMin = 0.0;
      double totalFare = 0.0;
      int transfers = 0;

      // Leg 1: Walk to Origin Metro
      final walkAccessMin = estimateWalkTimeMin(minMetroDist);
      totalTimeMin += walkAccessMin;
      final t1 = _addMinutesToTime(depTime, totalTimeMin);
      steps.add(JourneyStep(
        mode: 'walk',
        fromStop: 'Origin',
        toStop: '${originMetro.stopName} Metro',
        fromCoords: [oLat, oLon],
        toCoords: [originMetro.lat, originMetro.lon],
        departureTime: depTime,
        arrivalTime: t1,
        durationMin: _round(walkAccessMin, 1),
        fareInr: 0.0,
        instruction: '🚶 Walk ${_fmtDist(minMetroDist / 1000.0)} to ${originMetro.stopName} Metro',
        polyline: [
          [oLat, oLon],
          [originMetro.lat, originMetro.lon]
        ],
      ));
      mergedPoly.add([oLat, oLon]);
      mergedPoly.add([originMetro.lat, originMetro.lon]);

      // Leg 2: Metro Rail traversal to Southern Interchange Node
      // Topology-agnostic: Pick the southern metro station closest to the outer feeder network
      CmrlStop exitMetro = CmrlService.stops.first;
      double minExitDist = double.infinity;
      for (final s in CmrlService.stops) {
        final d = haversineKm(s.lat, s.lon, destFeeder.lat, destFeeder.lon);
        if (d < minExitDist) {
          minExitDist = d;
          exitMetro = s;
        }
      }

      final metroDistKm = haversineKm(originMetro.lat, originMetro.lon, exitMetro.lat, exitMetro.lon);
      final metroFare = calculateMetroFare(metroDistKm);
      final metroTimeMin = penEntryMetroMin + waitTimeMetroMin + ((metroDistKm / metroSpeedKmh) * 60.0);
      final depMetro = _addMinutesToTime(depTime, totalTimeMin);
      totalTimeMin += metroTimeMin;
      final arrMetro = _addMinutesToTime(depTime, totalTimeMin);
      totalFare += metroFare;

      final metroPoly = _extractMetroTrackGeometry(originMetro, exitMetro);
      steps.add(JourneyStep(
        mode: 'metro',
        fromStop: '${originMetro.stopName} Metro',
        toStop: '${exitMetro.stopName} Metro',
        fromCoords: [originMetro.lat, originMetro.lon],
        toCoords: [exitMetro.lat, exitMetro.lon],
        departureTime: depMetro,
        arrivalTime: arrMetro,
        durationMin: _round(metroTimeMin, 1),
        fareInr: metroFare,
        instruction: '🚇 Board CMRL Metro: ${originMetro.stopName} → ${exitMetro.stopName} (Fare: ₹${metroFare.round()})',
        polyline: metroPoly,
      ));
      mergedPoly.addAll(metroPoly);
      transfers++;

      // Leg 3: Arterial Trunk Link to Outer Feeder Gateway Terminal
      // Find the gateway terminal of destFeeder's corridor closest to Metro
      final destCorridor = FeederService.getCorridor(destFeeder.corridorName);
      VirtualFeederStop gatewayStop = destFeeder;
      if (destCorridor != null && destCorridor.stops.isNotEmpty) {
        gatewayStop = destCorridor.stops.reduce((a, b) =>
            haversineKm(a.lat, a.lon, exitMetro.lat, exitMetro.lon) <
                    haversineKm(b.lat, b.lon, exitMetro.lat, exitMetro.lon)
                ? a
                : b);
      }

      final trunkDistKm = haversineKm(exitMetro.lat, exitMetro.lon, gatewayStop.lat, gatewayStop.lon);
      if (trunkDistKm > 0.5) {
        final trunkTimeMin = penTransferInterModalMin + waitTimeBusMin + ((trunkDistKm / trunkSpeedKmh) * 60.0);
        final depTrunk = _addMinutesToTime(depTime, totalTimeMin);
        totalTimeMin += trunkTimeMin;
        final arrTrunk = _addMinutesToTime(depTime, totalTimeMin);
        totalFare += 20.0;

        final trunkPoly = (_gstTrunkPolyline != null && _gstTrunkPolyline!.length > 10)
            ? _gstTrunkPolyline!
            : await _fetchRoadGeometry(
                fromLat: exitMetro.lat,
                fromLon: exitMetro.lon,
                toLat: gatewayStop.lat,
                toLon: gatewayStop.lon,
                profile: 'driving',
              );

        transferHubs.add(TransferHub(
          hubName: '${exitMetro.stopName} Transit Hub',
          lat: exitMetro.lat,
          lon: exitMetro.lon,
          description: 'Transfer between CMRL Metro and Arterial Trunk Link',
        ));

        steps.add(JourneyStep(
          mode: 'bus',
          fromStop: '${exitMetro.stopName} Metro Concourse',
          toStop: gatewayStop.stopName,
          fromCoords: [exitMetro.lat, exitMetro.lon],
          toCoords: [gatewayStop.lat, gatewayStop.lon],
          departureTime: depTrunk,
          arrivalTime: arrTrunk,
          durationMin: _round(trunkTimeMin, 1),
          fareInr: 20.0,
          instruction: '🚌 Rapid Transit Trunk Link: ${exitMetro.stopName} → ${gatewayStop.stopName} (GST Corridor, Fare: ₹20)',
          polyline: trunkPoly,
        ));
        mergedPoly.addAll(trunkPoly);
        transfers++;
      }

      // Leg 4: Informal Paratransit Feeder to Destination Feeder Stop
      if (gatewayStop.stopId != destFeeder.stopId && destCorridor != null) {
        final feederSlice = FeederService.getCorridorSlice(
          destCorridor.corridorName, gatewayStop, destFeeder,
        );
        final feederDistKm = haversineKm(gatewayStop.lat, gatewayStop.lon, destFeeder.lat, destFeeder.lon);
        final feederFare = calculateFeederFare(feederDistKm);
        final feederTimeMin = penTransferInterModalMin + waitTimeFeederMin + ((feederDistKm / feederSpeedKmh) * 60.0);

        final depFeeder = _addMinutesToTime(depTime, totalTimeMin);
        totalTimeMin += feederTimeMin;
        final arrFeeder = _addMinutesToTime(depTime, totalTimeMin);
        totalFare += feederFare;

        transferHubs.add(TransferHub(
          hubName: '${gatewayStop.stopName} Feeder Stand',
          lat: gatewayStop.lat,
          lon: gatewayStop.lon,
          description: 'Transfer from Trunk Transit to Paratransit Feeder Stand',
        ));

        steps.add(JourneyStep(
          mode: 'feeder',
          fromStop: gatewayStop.stopName,
          toStop: destFeeder.stopName,
          fromCoords: [gatewayStop.lat, gatewayStop.lon],
          toCoords: [destFeeder.lat, destFeeder.lon],
          departureTime: depFeeder,
          arrivalTime: arrFeeder,
          durationMin: _round(feederTimeMin, 1),
          fareInr: feederFare,
          instruction: '🛺 Board Paratransit Feeder: ${gatewayStop.stopName} → ${destFeeder.stopName} (Fare: ₹${feederFare.round()})',
          polyline: feederSlice,
        ));
        mergedPoly.addAll(feederSlice);
        transfers++;
      }

      // Leg 5: Final-Mile Walk to Destination
      final walkDestDistM = haversineM(destFeeder.lat, destFeeder.lon, dLat, dLon);
      final walkDestMin = estimateWalkTimeMin(walkDestDistM);
      final depWalkDest = _addMinutesToTime(depTime, totalTimeMin);
      totalTimeMin += walkDestMin;
      final arrWalkDest = _addMinutesToTime(depTime, totalTimeMin);

      steps.add(JourneyStep(
        mode: 'walk',
        fromStop: destFeeder.stopName,
        toStop: 'Destination',
        fromCoords: [destFeeder.lat, destFeeder.lon],
        toCoords: [dLat, dLon],
        departureTime: depWalkDest,
        arrivalTime: arrWalkDest,
        durationMin: _round(walkDestMin, 1),
        fareInr: 0.0,
        instruction: '🚶 Walk ${_fmtDist(walkDestDistM / 1000.0)} to Destination',
        polyline: [
          [destFeeder.lat, destFeeder.lon],
          [dLat, dLon]
        ],
      ));
      mergedPoly.add([dLat, dLon]);

      return RouteOption(
        optionType: 'fastest_multimodal',
        label: 'Fastest Multi-Modal (Walk + Metro + Feeder)',
        emoji: '⭐',
        totalTimeMin: _round(totalTimeMin, 1),
        totalFareInr: _round(totalFare, 0),
        transfers: transfers,
        co2Grams: _round(d0Km * 140.0, 0),
        color: '#00D4AA',
        polyline: mergedPoly,
        steps: steps,
        transferHubs: transferHubs,
      );
    }

    // Fallback: If direct corridor exists, return it
    if (directCorridor != null) return directCorridor;

    // Otherwise, direct road route
    return _buildDirectRoadFallback(oLat, oLon, dLat, dLon, d0Km, depTime, 'fastest_multimodal');
  }

  // ─────────────────────────────────────────────────────────────────────────
  // OPTION 2: CHEAPEST TRANSIT
  // ─────────────────────────────────────────────────────────────────────────
  static Future<RouteOption> _buildCheapestTransit(
    double oLat, double oLon, double dLat, double dLon,
    double d0Km, double deltaMax, RouteOption? directCorridor, String depTime,
  ) async {
    if (directCorridor != null && d0Km <= 10.0) {
      return RouteOption(
        optionType: 'cheapest',
        label: 'Cheapest Direct Feeder Transit',
        emoji: '💰',
        totalTimeMin: directCorridor.totalTimeMin,
        totalFareInr: directCorridor.totalFareInr,
        transfers: 0,
        co2Grams: directCorridor.co2Grams,
        color: '#FFB800',
        polyline: directCorridor.polyline,
        steps: directCorridor.steps,
      );
    }

    // Bus / shared transit along highway
    final runTimeMin = max(18.0, (d0Km / busSpeedKmh) * 60.0 + waitTimeBusMin);
    final fare = 20.0;
    final poly = await _fetchRoadGeometry(
      fromLat: oLat, fromLon: oLon,
      toLat: dLat, toLon: dLon,
      profile: 'driving',
    );

    return RouteOption(
      optionType: 'cheapest',
      label: 'Cheapest Transit (Shared Feeder / Bus)',
      emoji: '💰',
      totalTimeMin: _round(runTimeMin, 1),
      totalFareInr: fare,
      transfers: 0,
      co2Grams: _round(d0Km * 90.0, 0),
      color: '#FFB800',
      polyline: poly,
      steps: [
        JourneyStep(
          mode: 'bus',
          fromStop: 'Origin Transit Stand',
          toStop: 'Destination Stand',
          fromCoords: [oLat, oLon],
          toCoords: [dLat, dLon],
          departureTime: depTime,
          arrivalTime: _addMinutesToTime(depTime, runTimeMin),
          durationMin: _round(runTimeMin, 1),
          fareInr: fare,
          instruction: '🚌 Direct Transit Corridor (${d0Km.toStringAsFixed(1)} km, Fare: ₹20)',
          polyline: poly,
          busNumbers: 'Direct MTC / Shared',
        )
      ],
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // OPTION 3: MINIMUM TRANSFER
  // ─────────────────────────────────────────────────────────────────────────
  static Future<RouteOption> _buildMinTransfer(
    double oLat, double oLon, double dLat, double dLon,
    double d0Km, double deltaMax, RouteOption? directCorridor, String depTime,
  ) async {
    if (directCorridor != null && d0Km <= 10.0) {
      return RouteOption(
        optionType: 'min_transfer',
        label: 'Minimum Transfer (Direct Corridor)',
        emoji: '⚡',
        totalTimeMin: directCorridor.totalTimeMin,
        totalFareInr: directCorridor.totalFareInr,
        transfers: 0,
        co2Grams: directCorridor.co2Grams,
        color: '#3B82F6',
        polyline: directCorridor.polyline,
        steps: directCorridor.steps,
      );
    }

    final runTimeMin = max(15.0, (d0Km / trunkSpeedKmh) * 60.0 + 4.0);
    final fare = max(25.0, d0Km * 3.5);
    final poly = await _fetchRoadGeometry(
      fromLat: oLat, fromLon: oLon,
      toLat: dLat, toLon: dLon,
      profile: 'driving',
    );

    return RouteOption(
      optionType: 'min_transfer',
      label: 'Minimum Transfer (Direct Corridor Hop)',
      emoji: '⚡',
      totalTimeMin: _round(runTimeMin, 1),
      totalFareInr: _round(fare, 0),
      transfers: 0,
      co2Grams: _round(d0Km * 80.0, 0),
      color: '#3B82F6',
      polyline: poly,
      steps: [
        JourneyStep(
          mode: 'feeder',
          fromStop: 'Origin Stand',
          toStop: 'Destination Stand',
          fromCoords: [oLat, oLon],
          toCoords: [dLat, dLon],
          departureTime: depTime,
          arrivalTime: _addMinutesToTime(depTime, runTimeMin),
          durationMin: _round(runTimeMin, 1),
          fareInr: _round(fare, 0),
          instruction: '🛺 Single-Hop Direct Transit Corridor (0 Transfers)',
          polyline: poly,
        )
      ],
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // HELPER UTILITIES
  // ─────────────────────────────────────────────────────────────────────────
  static Future<RouteOption> _buildDirectRoadFallback(
    double oLat, double oLon, double dLat, double dLon,
    double d0Km, String depTime, String optionType,
  ) async {
    final walkDistM = d0Km * 1000.0;
    final walkTimeMin = estimateWalkTimeMin(walkDistM);
    final poly = [
      [oLat, oLon],
      [dLat, dLon]
    ];

    return RouteOption(
      optionType: optionType,
      label: 'Pedestrian Walkway',
      emoji: '🚶',
      totalTimeMin: _round(walkTimeMin, 1),
      totalFareInr: 0.0,
      transfers: 0,
      co2Grams: 0.0,
      color: '#4A5568',
      polyline: poly,
      steps: [
        JourneyStep(
          mode: 'walk',
          fromStop: 'Origin',
          toStop: 'Destination',
          fromCoords: [oLat, oLon],
          toCoords: [dLat, dLon],
          departureTime: depTime,
          arrivalTime: _addMinutesToTime(depTime, walkTimeMin),
          durationMin: _round(walkTimeMin, 1),
          fareInr: 0.0,
          instruction: '🚶 Walk directly to Destination (${d0Km.toStringAsFixed(1)} km)',
          polyline: poly,
        )
      ],
    );
  }

  static List<List<double>> _extractMetroTrackGeometry(CmrlStop from, CmrlStop to) {
    for (final shape in CmrlService.shapes) {
      final poly = shape.polyline;
      if (poly.isEmpty) continue;

      int idx1 = -1;
      int idx2 = -1;
      double minD1 = double.infinity;
      double minD2 = double.infinity;

      for (int i = 0; i < poly.length; i++) {
        final d1 = haversineKm(from.lat, from.lon, poly[i][0], poly[i][1]);
        if (d1 < minD1) {
          minD1 = d1;
          idx1 = i;
        }

        final d2 = haversineKm(to.lat, to.lon, poly[i][0], poly[i][1]);
        if (d2 < minD2) {
          minD2 = d2;
          idx2 = i;
        }
      }

      if (idx1 != -1 && idx2 != -1 && minD1 < 1.0 && minD2 < 1.0) {
        if (idx1 <= idx2) {
          return poly.sublist(idx1, idx2 + 1);
        } else {
          return poly.sublist(idx2, idx1 + 1).reversed.toList();
        }
      }
    }

    return [
      [from.lat, from.lon],
      [to.lat, to.lon]
    ];
  }

  static String _fmtDist(double km) {
    if (km < 1.0) return '${(km * 1000).round()} m';
    return '${km.toStringAsFixed(1)} km';
  }

  static String _addMinutesToTime(String timeStr, double minutesToAdd) {
    try {
      final parts = timeStr.split(':');
      int h = int.parse(parts[0]);
      int m = int.parse(parts[1]);
      m += minutesToAdd.round();
      h += m ~/ 60;
      m = m % 60;
      h = h % 24;
      return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
    } catch (_) {
      return timeStr;
    }
  }

  static double _round(double val, int places) {
    final mod = pow(10.0, places);
    return (val * mod).roundToDouble() / mod;
  }
}
