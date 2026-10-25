import "package:cw_minotari/minotari_transaction_history.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  for (final count in [0, 6, 100, 101, 205]) {
    test("loads all $count transactions through the paginated history API", () async {
      final expected = List.generate(count, (index) => "transaction-$index");
      final offsets = <int>[];
      final actual = await fetchAllMinotariTransactionPages<String>(
        ({required limit, required offset}) async {
          expect(limit, 100);
          offsets.add(offset);
          return expected.skip(offset).take(limit).toList();
        },
      );

      expect(actual, expected);
      expect(actual.toSet(), hasLength(count));
      expect(offsets, List.generate(count ~/ 100 + 1, (index) => index * 100));
    });
  }

  test("a later page failure is propagated instead of returning partial history", () async {
    final error = StateError("synthetic second-page failure");
    final offsets = <int>[];
    final fetched = fetchAllMinotariTransactionPages<int>(
      ({required limit, required offset}) async {
        offsets.add(offset);
        if (offset > 0) {
          throw error;
        }
        return List.generate(limit, (index) => index);
      },
    );

    await expectLater(fetched, throwsA(same(error)));
    expect(offsets, [0, 100]);
  });
}
