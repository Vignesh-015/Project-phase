import 'dart:convert';
import 'package:http/http.dart' as http;
import 'api_service.dart';

class AIServiceResult {
  final bool success;
  final String source;
  final String destination;
  final String rawQuery;

  AIServiceResult({
    required this.success,
    required this.source,
    required this.destination,
    required this.rawQuery,
  });
}

class AIService {
  /// Send natural language query to backend OpenRouter endpoint
  static Future<AIServiceResult> parseQuery(String query) async {
    try {
      final uri = Uri.parse('${ApiService.baseUrl}/api/ai/natural-query');
      final response = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: json.encode({'query': query}),
          )
          .timeout(const Duration(seconds: 8));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return AIServiceResult(
          success: data['success'] ?? true,
          source: data['source'] ?? '',
          destination: data['destination'] ?? '',
          rawQuery: query,
        );
      }
    } catch (_) {
      // Fallback local heuristic parser
    }

    return _heuristicParse(query);
  }

  static AIServiceResult _heuristicParse(String query) {
    final q = query.toLowerCase();
    String source = '';
    String dest = '';

    if (q.contains(' from ') && q.contains(' to ')) {
      final parts = q.split(' from ');
      if (parts.length > 1) {
        final sub = parts[1].split(' to ');
        source = sub[0].trim();
        if (sub.length > 1) dest = sub[1].trim();
      }
    } else if (q.contains(' to ')) {
      final parts = q.split(' to ');
      source = parts[0]
          .replaceAll('find a route', '')
          .replaceAll('take me', '')
          .replaceAll('route', '')
          .trim();
      dest = parts[1].trim();
    } else {
      dest = query.trim();
    }

    return AIServiceResult(
      success: true,
      source: source,
      destination: dest,
      rawQuery: query,
    );
  }
}
