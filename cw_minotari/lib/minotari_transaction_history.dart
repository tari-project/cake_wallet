import 'package:cw_core/transaction_history.dart';
import 'package:cw_minotari/minotari_transaction_info.dart';
import 'package:mobx/mobx.dart';
import 'package:collection/collection.dart';

part 'minotari_transaction_history.g.dart';

/// Serialize snapshots and deltas, without poisoning the queue after a failure.
class MinotariHistoryUpdateQueue {
  Future<void> _tail = Future<void>.value();
  Future<void> get idle => _tail;

  Future<void> run(Future<void> Function() update) {
    final result = _tail.then((_) => update());
    _tail = result.catchError((Object _) {});
    return result;
  }
}

/// Read every Rust history page before publishing an update to Cake's cache.
/// The native API returns at most 100 entries per request by default.
Future<List<T>> fetchAllMinotariTransactionPages<T>(
  Future<List<T>> Function({required int limit, required int offset}) fetchPage,
) async {
  const pageSize = 100;
  final transactions = <T>[];
  var offset = 0;
  while (true) {
    final page = await fetchPage(limit: pageSize, offset: offset);
    transactions.addAll(page);
    if (page.length < pageSize) return transactions;
    offset += page.length;
  }
}

/// Yield while mapping large native histories, and discard superseded results.
Future<Map<String, MinotariTransactionInfo>> mapMinotariTransactions<T>(
  Iterable<T> rows,
  MinotariTransactionInfo Function(T) convert, {
  bool Function()? isCurrent,
}) async {
  final mapped = <String, MinotariTransactionInfo>{};
  var count = 0;
  for (final row in rows) {
    if (isCurrent != null && !isCurrent()) return {};
    final tx = convert(row);
    mapped[tx.id] = tx;
    if (++count % 25 == 0) {
      await Future<void>.delayed(Duration.zero);
    }
  }
  if (isCurrent != null && !isCurrent()) return {};
  return mapped;
}

bool _sameTransaction(MinotariTransactionInfo a, MinotariTransactionInfo b) =>
    a.id == b.id &&
    a.txHash == b.txHash &&
    a.amount == b.amount &&
    a.fee == b.fee &&
    a.date == b.date &&
    a.direction == b.direction &&
    a.isPending == b.isPending &&
    a.height == b.height &&
    a.confirmations == b.confirmations &&
    const DeepCollectionEquality().equals(a.additionalInfo, b.additionalInfo);

class MinotariTransactionHistory = MinotariTransactionHistoryBase with _$MinotariTransactionHistory;

abstract class MinotariTransactionHistoryBase
    extends TransactionHistoryBase<MinotariTransactionInfo> with Store {
  MinotariTransactionHistoryBase();

  Future<void> applyChanges<T>(
    Iterable<T> changes,
    MinotariTransactionInfo Function(T) convert, {
    bool Function()? isCurrent,
  }) async {
    final mapped = await mapMinotariTransactions(changes, convert, isCurrent: isCurrent);
    if (isCurrent != null && !isCurrent()) return;
    mapped.removeWhere((id, tx) {
      final previous = transactions[id];
      return previous != null && _sameTransaction(previous, tx);
    });
    if (mapped.isEmpty) return;
    runInAction(() => addMany(mapped));
    await save();
  }

  @override
  Future<void> save() async {
    // Transaction history is managed by the Rust layer
  }

  @override
  void addOne(MinotariTransactionInfo transaction) {
    transactions[transaction.id] = transaction;
  }

  @override
  void addMany(Map<String, MinotariTransactionInfo> transactions) {
    this.transactions.addAll(transactions);
  }
}
