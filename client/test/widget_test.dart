import 'package:flutter_test/flutter_test.dart';

import 'package:client/main.dart';

void main() {
  testWidgets('Plums app renders login screen', (WidgetTester tester) async {
    await tester.pumpWidget(const PlumsApp());

    expect(find.text('Вход в plums'), findsOneWidget);
  });
}
