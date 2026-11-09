import 'dart:js_interop';
import 'dart:typed_data';

import 'statement_parser.dart';

@JS('dkPdfText')
external JSPromise<JSString> _dkPdfText(JSUint8Array bytes, JSString? password);

/// Returns JSON `[[page, x, y, width, text], ...]` using the bundled pdf.js.
Future<String> extractPdfText(Uint8List bytes, {String? password}) async {
  try {
    // pdf.js hands the buffer to its worker, so always pass a fresh copy.
    final result = await _dkPdfText(Uint8List.fromList(bytes).toJS, password?.toJS).toDart;
    return result.toDart;
  } catch (e) {
    final m = e.toString();
    if (m.contains('needs_password')) throw StatementFormatException('needs_password');
    if (m.contains('wrong_password')) throw StatementFormatException('wrong_password');
    throw StatementFormatException('pdf_unreadable');
  }
}
