// Reads positioned text out of a PDF (web: bundled pdf.js; other platforms:
// not available yet – the user is asked for Excel/CSV instead).
export 'pdf_text_stub.dart' if (dart.library.js_interop) 'pdf_text_web.dart';
