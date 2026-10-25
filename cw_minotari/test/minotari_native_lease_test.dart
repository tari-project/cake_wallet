import "dart:io";
import "dart:isolate";

import "package:cw_minotari/minotari_native_lease.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  late Directory root;
  late String path;
  setUp(() async {
    root = await Directory.systemTemp.createTemp("xtm-native-lease-");
    path = "${root.path}/runtime.lock";
  });
  tearDown(() => root.delete(recursive: true));

  test("independent descriptors in one process cannot own native state together", () {
    final first = MinotariNativeLease.tryAcquire(path)!;
    try {
      expect(MinotariNativeLease.tryAcquire(path), isNull);
    } finally {
      first.release();
      first.release();
    }
    final next = MinotariNativeLease.tryAcquire(path);
    expect(next, isNotNull);
    next!.release();
  });

  test("another Dart isolate observes the same native lease", () async {
    final first = MinotariNativeLease.tryAcquire(path)!;
    try {
      expect(
          await Isolate.run(() {
            final lease = MinotariNativeLease.tryAcquire(path);
            lease?.release();
            return lease != null;
          }),
          isFalse);
    } finally {
      first.release();
    }
    expect(
        await Isolate.run(() {
          final lease = MinotariNativeLease.tryAcquire(path);
          lease?.release();
          return lease != null;
        }),
        isTrue);
  });
}
