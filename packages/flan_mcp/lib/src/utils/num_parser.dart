double parseRequiredDoubleArg(Map<String, dynamic> args, String key) {
  final value = args[key];
  if (value is num) return value.toDouble();
  if (value is String) {
    final parsed = double.tryParse(value);
    if (parsed != null) return parsed;
  }
  throw ArgumentError.value(value, key, 'Expected a numeric value');
}
