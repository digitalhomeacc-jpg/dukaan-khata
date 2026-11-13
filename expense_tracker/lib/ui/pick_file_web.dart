import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'pick_file.dart';

/// Browser (iPhone home-screen app, desktop): a plain file input, which Safari handles reliably.
Future<PickedFile?> pickFile() {
  final done = Completer<PickedFile?>();
  final input = web.HTMLInputElement()
    ..type = 'file'
    // No strict filter: Safari greys out .xls files when it does not know their type.
    ..accept = '.xls,.xlsx,.csv,.txt,application/vnd.ms-excel,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet,text/csv,text/plain,*/*'
    ..style.display = 'none';
  web.document.body!.append(input);

  void finish(PickedFile? f) {
    if (!done.isCompleted) done.complete(f);
    input.remove();
  }

  input.addEventListener('change', ((web.Event _) {
    final file = input.files?.item(0);
    if (file == null) return finish(null);
    final reader = web.FileReader();
    reader.addEventListener('load', ((web.Event _) {
      final result = reader.result;
      if (result == null) return finish(null);
      finish((name: file.name, bytes: (result as JSArrayBuffer).toDart.asUint8List()));
    }).toJS);
    reader.addEventListener('error', ((web.Event _) {
      if (!done.isCompleted) done.completeError(Exception('Could not read ${file.name}'));
      input.remove();
    }).toJS);
    reader.readAsArrayBuffer(file);
  }).toJS);
  // Cancel (supported by newer browsers).
  input.addEventListener('cancel', ((web.Event _) => finish(null)).toJS);
  input.click();
  return done.future;
}
