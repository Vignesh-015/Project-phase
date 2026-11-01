import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flexi_transit/main.dart';

void main() {
  testWidgets('FlexiTransit app smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const FlexiTransitApp());
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
