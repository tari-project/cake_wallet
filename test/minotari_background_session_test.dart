import "dart:async";
import "dart:io";

import "package:cake_wallet/core/background_sync_session.dart";
import "package:flutter_test/flutter_test.dart";
import "package:flutter/services.dart";

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late BackgroundSyncSession session;
  var completions = 0;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp("xtm-background-session-");
    completions = 0;
    session = BackgroundSyncSession(directory: directory, onComplete: () async => completions++);
  });
  tearDown(() async {
    await session.complete();
    await directory.delete(recursive: true);
  });

  test("completion clears markers and notifies the worker once without killing the process",
      () async {
    expect(session.begin(), isTrue);
    expect(session.cancelled, isFalse);
    await session.complete();
    await session.complete();
    expect(completions, 1);
    expect(directory.listSync(), isEmpty);
  });

  test("another session cannot complete an active owner's work", () async {
    expect(session.begin(), isTrue);
    final other =
        BackgroundSyncSession(directory: directory, onComplete: () async => fail("Not owner"));
    expect(other.begin(), isFalse);
    await other.complete();
    expect(session.cancelled, isFalse);
  });

  test("foreground waits for cooperative cancellation and owner cleanup", () async {
    session.begin();
    final foreground = BackgroundSyncSession(directory: directory, onComplete: () async {});
    var returned = false;
    final wait = foreground.cancelActive().then((_) => returned = true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(session.cancelled, isTrue);
    expect(returned, isFalse);
    await session.complete();
    await wait;
    expect(returned, isTrue);
    expect(completions, 1);
  });

  test("timeout leaves ownership with the running task", () async {
    session.begin();
    await expectLater(
        session.cancelActive(timeout: Duration.zero), throwsA(isA<TimeoutException>()));
    expect(File("${directory.path}/owner.json").existsSync(), isTrue);
    expect(session.cancelled, isTrue);
  });

  test("legacy PID file is removed without signalling any process", () async {
    File("${directory.path}/__daemonfile.pid").writeAsStringSync(pid.toString());
    File("${directory.path}/__daemonfile").writeAsStringSync(DateTime.now().toIso8601String());
    await session.cancelActive();
    expect(directory.listSync(), isEmpty);
    expect(session.begin(), isTrue);
  });
  test("Android completion captures owner, acknowledges Worker, then disposes only that engine",
      () async {
    final calls = <String>[];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('cw_core/background_sync'),
        (call) async {
      calls.add(call.method);
      return true;
    });
    messenger.setMockMethodCallHandler(const MethodChannel('flutter_daemon'), (call) async {
      calls.add(call.method);
      return true;
    });
    try {
      await BackgroundSyncSession.completeAndroidWorker();
      expect(calls, ['prepareCompletedEngine', 'backgroundSyncComplete', 'disposeCompletedEngine']);
    } finally {
      messenger.setMockMethodCallHandler(const MethodChannel('cw_core/background_sync'), null);
      messenger.setMockMethodCallHandler(const MethodChannel('flutter_daemon'), null);
    }
  });

  test("a rejected UI owner never acknowledges or disposes a background engine", () async {
    final calls = <String>[];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('cw_core/background_sync'),
        (call) async {
      calls.add(call.method);
      return false;
    });
    messenger.setMockMethodCallHandler(
        const MethodChannel('flutter_daemon'), (_) async => fail('Not owner'));
    try {
      await expectLater(BackgroundSyncSession.completeAndroidWorker(), throwsStateError);
      expect(calls, ['prepareCompletedEngine']);
    } finally {
      messenger.setMockMethodCallHandler(const MethodChannel('cw_core/background_sync'), null);
      messenger.setMockMethodCallHandler(const MethodChannel('flutter_daemon'), null);
    }
  });
  test('a Worker acknowledgement failure never disposes the engine', () async {
    final calls = <String>[];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('cw_core/background_sync'),
        (call) async {
      calls.add(call.method);
      return true;
    });
    messenger.setMockMethodCallHandler(const MethodChannel('flutter_daemon'), (call) async {
      calls.add(call.method);
      throw PlatformException(code: 'ack_failed');
    });
    try {
      await expectLater(
          BackgroundSyncSession.completeAndroidWorker(), throwsA(isA<PlatformException>()));
      expect(calls, ['prepareCompletedEngine', 'backgroundSyncComplete']);
    } finally {
      messenger.setMockMethodCallHandler(const MethodChannel('cw_core/background_sync'), null);
      messenger.setMockMethodCallHandler(const MethodChannel('flutter_daemon'), null);
    }
  });
}
