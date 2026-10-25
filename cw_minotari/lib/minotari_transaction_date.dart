/// Upstream's timestamps without an offset represent UTC, not device time.
DateTime? parseMinotariTransactionDate(String timestamp) {
  final value = timestamp.trim();
  final parsed = DateTime.tryParse(value);
  if (parsed == null) return null;
  final timeStart = value.indexOf(RegExp(r'[Tt ]'));
  final explicitZone = timeStart >= 0 &&
      RegExp(r'(?:[zZ]|[+-]\d{2}(?::?\d{2})?)$').hasMatch(value.substring(timeStart + 1));
  final instant = explicitZone
      ? parsed
      : DateTime.utc(parsed.year, parsed.month, parsed.day, parsed.hour, parsed.minute,
          parsed.second, parsed.millisecond, parsed.microsecond);
  return instant.toLocal();
}
