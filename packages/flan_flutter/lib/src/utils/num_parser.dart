double parseRequiredDoubleParam(Object? value, String name) {
  if (value is num) return value.toDouble();
  if (value is String) {
    final parsed = double.tryParse(value);
    if (parsed != null) return parsed;
  }
  throw FormatException('Invalid "$name" parameter: $value');
}
