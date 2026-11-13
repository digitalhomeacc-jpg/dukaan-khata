import 'dart:typed_data';

import 'pick_file_io.dart' if (dart.library.js_interop) 'pick_file_web.dart' as impl;

/// A file the user picked: its name and contents.
typedef PickedFile = ({String name, Uint8List bytes});

/// Lets the user pick a bank statement (.xls, .xlsx, .csv). Null when they cancel.
Future<PickedFile?> pickStatementFile() => impl.pickFile();
