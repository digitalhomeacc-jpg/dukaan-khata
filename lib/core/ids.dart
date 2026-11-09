import 'package:uuid/uuid.dart';

const _uuid = Uuid();

/// UUID v4 – generated on the device so entries can be created offline.
String newId() => _uuid.v4();

String nowIso() => DateTime.now().toUtc().toIso8601String();
