import 'package:cw_minotari/minotari_transaction_date.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('naive upstream timestamps represent UTC and become device local time', () {
    final date = parseMinotariTransactionDate('2026-10-24 07:31:56')!;
    expect(date.isUtc, isFalse);
    expect(date.toUtc(), DateTime.utc(2026, 10, 24, 7, 31, 56));
    expect(date, DateTime.utc(2026, 10, 24, 7, 31, 56).toLocal());
  });
  test('explicit UTC and offsets are not shifted twice', () {
    final instant = DateTime.utc(2026, 10, 24, 7, 31, 56);
    for (final timestamp in [
      '2026-10-24T07:31:56Z',
      '2026-10-24T10:31:56+03:00',
      '2026-10-24T02:31:56-0500',
    ]) {
      expect(parseMinotariTransactionDate(timestamp)!.toUtc(), instant);
    }
  });
  test('fractions and crossing midnight preserve the instant', () {
    expect(parseMinotariTransactionDate('2026-10-24 23:59:59.123456')!.toUtc(),
        DateTime.utc(2026, 10, 24, 23, 59, 59, 123, 456));
    expect(parseMinotariTransactionDate('2026-10-25T01:30:00+03:00')!.toUtc(),
        DateTime.utc(2026, 10, 24, 22, 30));
  });
  test('invalid timestamps retain the caller fallback', () {
    expect(parseMinotariTransactionDate(''), isNull);
    expect(parseMinotariTransactionDate('not a timestamp'), isNull);
  });
}
