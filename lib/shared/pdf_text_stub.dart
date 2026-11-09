import 'dart:typed_data';

import 'statement_parser.dart';

/// Returns JSON `[[page, x, y, width, text], ...]`.
Future<String> extractPdfText(Uint8List bytes, {String? password}) async =>
    throw StatementFormatException('pdf');
