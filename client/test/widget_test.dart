import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:client/main.dart';

void main() {
  testWidgets('Plums app renders login screen', (WidgetTester tester) async {
    // AuthGate.restoreSession() reads tokens via SharedPreferences.getInstance()
    // before showing LoginScreen. Without a mock store the platform channel
    // call never resolves in the test environment, leaving the initial
    // CircularProgressIndicator spinning forever (pumpAndSettle would time
    // out). Seeding an in-memory store lets that read complete immediately.
    SharedPreferences.setMockInitialValues(const {});

    await tester.pumpWidget(const PlumsApp());
    await tester.pumpAndSettle();

    expect(find.text('Вход в plums'), findsOneWidget);
  });
}
