import 'dart:async';

import 'package:expense_tracker/ui/save_button.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('saves on the first touch, shows it is saving, never twice', (tester) async {
    var saves = 0;
    final done = Completer<void>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(
            actions: [
              SaveButton(
                onSave: () {
                  saves++;
                  return done.future;
                },
              ),
            ],
          ),
        ),
      ),
    );
    // Finger down only (the page may jump before it lifts, as on iPhone with the keyboard open).
    final g = await tester.startGesture(tester.getCenter(find.text('Save')));
    await tester.pump();
    expect(saves, 1);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await g.up();
    await tester.pump();
    expect(saves, 1); // the tap itself does not save again
    done.complete();
    await tester.pumpAndSettle();
    expect(find.text('Save'), findsOneWidget);
  });
}
