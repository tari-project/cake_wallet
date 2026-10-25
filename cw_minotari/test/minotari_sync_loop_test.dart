import "dart:async";

import "package:cw_minotari/minotari_sync_loop.dart";
import "package:fake_async/fake_async.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  test("one background pass drains events and refresh without scheduling another scan", () {
    fakeAsync((clock) {
      final stream = StreamController<int>(onCancel: Future<void>.value);
      final refresh = Completer<void>();
      var scans = 0;
      var completed = false;
      var synced = 0;
      final events = <int>[];
      final loop = MinotariSyncLoop<int>(
        scan: (_) async {
          scans++;
          return stream.stream;
        },
        onEvent: (event, _) async => events.add(event),
        refresh: (_) => refresh.future,
        onSynced: () => synced++,
        onError: (error, _) => fail("$error"),
      );
      unawaited(loop.runOnce().then((_) => completed = true));
      clock.flushMicrotasks();
      stream.add(1);
      stream.add(2);
      unawaited(stream.close());
      clock.flushMicrotasks();
      expect(events, [1, 2]);
      expect(completed, isFalse);
      refresh.complete();
      clock.flushMicrotasks();
      clock.elapse(const Duration(minutes: 5));
      expect(completed, isTrue);
      expect(synced, 1);
      expect(scans, 1);
      expect(clock.pendingTimers, isEmpty);
    });
  });

  test("failed background pass reports failure without an automatic retry", () {
    fakeAsync((clock) {
      var scans = 0;
      final errors = <Object>[];
      final loop = MinotariSyncLoop<int>(
        scan: (_) async {
          scans++;
          throw StateError("offline");
        },
        onEvent: (_, __) async {},
        refresh: (_) async => fail("Failed scan must not refresh"),
        onSynced: () => fail("Failed scan must not sync"),
        onError: (error, _) => errors.add(error),
      );
      unawaited(loop.runOnce());
      clock.flushMicrotasks();
      clock.elapse(const Duration(minutes: 5));
      expect(scans, 1);
      expect(errors, hasLength(1));
      expect(clock.pendingTimers, isEmpty);
      unawaited(loop.runOnce());
      clock.flushMicrotasks();
      expect(scans, 2); // A later OS job explicitly retries.
    });
  });

  test("waits for events and refresh, then waits 20 seconds without overlap", () {
    fakeAsync((clock) {
      final streams = <StreamController<int>>[];
      final eventDone = Completer<void>();
      final refreshDone = Completer<void>();
      var refreshes = 0;
      var synced = 0;
      final loop = MinotariSyncLoop<int>(
        scan: (_) async {
          final controller = StreamController<int>(onCancel: Future<void>.value);
          streams.add(controller);
          return controller.stream;
        },
        onEvent: (_, __) => eventDone.future,
        refresh: (_) async {
          refreshes++;
          await refreshDone.future;
        },
        onSynced: () => synced++,
        onError: (error, _) => fail("$error"),
      );
      unawaited(loop.start());
      clock.flushMicrotasks();
      streams.single.add(1);
      unawaited(streams.single.close());
      clock.flushMicrotasks();
      clock.elapse(const Duration(minutes: 1));
      expect(streams, hasLength(1));
      expect(refreshes, 0);
      eventDone.complete();
      clock.flushMicrotasks();
      expect(refreshes, 1);
      clock.elapse(const Duration(minutes: 1));
      expect(streams, hasLength(1));
      refreshDone.complete();
      clock.flushMicrotasks();
      expect(synced, 1);
      clock.elapse(const Duration(seconds: 19));
      expect(streams, hasLength(1));
      clock.elapse(const Duration(seconds: 1));
      expect(streams, hasLength(2));
      unawaited(loop.stop());
      clock.flushMicrotasks();
      unawaited(streams.last.close());
      clock.elapse(const Duration(minutes: 1));
      expect(streams, hasLength(2));
      expect(clock.pendingTimers.length, 0);
    });
  });

  test("stop invalidates in-flight refresh and prevents more cycles", () {
    fakeAsync((clock) {
      final controller = StreamController<int>(onCancel: Future<void>.value);
      final refreshDone = Completer<void>();
      var applied = 0;
      var synced = 0;
      var stopped = false;
      final loop = MinotariSyncLoop<int>(
        scan: (_) async => controller.stream,
        onEvent: (_, __) async {},
        refresh: (isCurrent) async {
          await refreshDone.future;
          if (isCurrent()) {
            applied++;
          }
        },
        onSynced: () => synced++,
        onError: (error, _) => fail("$error"),
      );
      unawaited(loop.start());
      clock.flushMicrotasks();
      unawaited(controller.close());
      clock.flushMicrotasks();
      unawaited(loop.stop().then((_) => stopped = true));
      refreshDone.complete();
      clock.flushMicrotasks();
      clock.elapse(const Duration(minutes: 1));
      expect(stopped, isTrue);
      expect(applied, 0);
      expect(synced, 0);
      expect(clock.pendingTimers.length, 0);
    });
  });

  test("restart waits for old event and ignores its late result", () {
    fakeAsync((clock) {
      final streams = <StreamController<int>>[];
      final eventDone = Completer<void>();
      final applied = <int>[];
      final loop = MinotariSyncLoop<int>(
        scan: (_) async {
          final controller = StreamController<int>(onCancel: Future<void>.value);
          streams.add(controller);
          return controller.stream;
        },
        onEvent: (event, isCurrent) async {
          if (event == 1) {
            await eventDone.future;
          }
          if (isCurrent()) {
            applied.add(event);
          }
        },
        refresh: (_) async {},
        onSynced: () {},
        onError: (error, _) => fail("$error"),
      );
      unawaited(loop.start());
      clock.flushMicrotasks();
      streams.single.add(1);
      clock.flushMicrotasks();
      unawaited(loop.start());
      clock.flushMicrotasks();
      expect(streams, hasLength(1));
      eventDone.complete();
      clock.flushMicrotasks();
      expect(streams, hasLength(2));
      streams.last.add(2);
      clock.flushMicrotasks();
      expect(applied, [2]);
      unawaited(loop.stop());
      clock.flushMicrotasks();
      for (final controller in streams) {
        unawaited(controller.close());
      }
      clock.flushMicrotasks();
      expect(clock.pendingTimers.length, 0);
    });
  });

  test("event error after stream completion does not sync; retries after 20s", () {
    fakeAsync((clock) {
      final streams = <StreamController<int>>[];
      final errors = <Object>[];
      var synced = 0;
      var refreshes = 0;
      final loop = MinotariSyncLoop<int>(
        scan: (_) async {
          final controller = StreamController<int>(onCancel: Future<void>.value);
          streams.add(controller);
          return controller.stream;
        },
        onEvent: (_, __) => Future<void>.error(StateError("event failed")),
        refresh: (_) async {
          refreshes++;
        },
        onSynced: () => synced++,
        onError: (error, _) => errors.add(error),
      );
      unawaited(loop.start());
      clock.flushMicrotasks();
      streams.single.add(1);
      unawaited(streams.single.close());
      clock.flushMicrotasks();
      expect(errors, hasLength(1));
      expect(refreshes, 0);
      expect(synced, 0);
      clock.elapse(const Duration(seconds: 19));
      expect(streams, hasLength(1));
      clock.elapse(const Duration(seconds: 1));
      expect(streams, hasLength(2));
      unawaited(loop.stop());
      clock.flushMicrotasks();
      unawaited(streams.last.close());
      clock.flushMicrotasks();
      expect(clock.pendingTimers.length, 0);
    });
  });

  test("stop while opening scan prevents refresh and retry", () {
    fakeAsync((clock) {
      final opening = Completer<Stream<int>>();
      var scans = 0;
      var refreshes = 0;
      var stopped = false;
      final loop = MinotariSyncLoop<int>(
        scan: (_) {
          scans++;
          return opening.future;
        },
        onEvent: (_, __) async {},
        refresh: (_) async {
          refreshes++;
        },
        onSynced: () => fail("Stopped scan must not sync"),
        onError: (error, _) => fail("$error"),
      );
      unawaited(loop.start());
      clock.flushMicrotasks();
      unawaited(loop.stop().then((_) => stopped = true));
      opening.complete(const Stream<int>.empty());
      clock.flushMicrotasks();
      clock.elapse(const Duration(minutes: 1));
      expect(stopped, isTrue);
      expect(scans, 1);
      expect(refreshes, 0);
      expect(clock.pendingTimers.length, 0);
    });
  });
}
