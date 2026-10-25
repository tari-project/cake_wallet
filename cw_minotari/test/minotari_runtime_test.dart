import 'dart:async';
import 'dart:io';

import 'package:cw_core/pathForWallet.dart';
import 'package:cw_core/wallet_type.dart';
import 'package:cw_minotari/minotari_native_lease.dart';
import 'package:cw_minotari/minotari_runtime.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final runtime = MinotariRuntime.instance;
  late Directory root;
  late String directory;
  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('xtm-runtime-test-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'), (_) async => root.path);
    directory = await pathForWalletTypeDir(type: WalletType.minotari);
  });
  tearDownAll(() async {
    await root.delete(recursive: true);
  });

  test('pause drains native operations before another engine may acquire; resume reopens',
      () async {
    final owner = Object();
    final events = <String>[];
    await runtime.attach(owner,
        pause: () async => events.add('pause'), resume: () async => events.add('resume'));
    final epoch = runtime.epoch;
    final finish = Completer<void>();
    final operation = runtime.run(() => finish.future);
    runtime.didChangeAppLifecycleState(AppLifecycleState.paused);
    await Future<void>.delayed(Duration.zero);
    expect(events, ['pause']);
    expect(MinotariNativeLease.tryAcquire('$directory/runtime.lock'), isNull);
    await expectLater(runtime.run(() async {}), throwsStateError);
    finish.complete();
    await operation;
    await runtime.idle;
    final background = MinotariNativeLease.tryAcquire('$directory/runtime.lock');
    expect(background, isNotNull);
    background!.release();
    runtime.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await runtime.idle;
    expect(events, ['pause', 'resume']);
    expect(runtime.epoch, epoch + 1);
    runtime.detach(owner);
    expect(runtime.ownsNative, isFalse);
  });

  test('background skips live foreground owner and foreground request, then retries', () async {
    final foreign = MinotariNativeLease.tryAcquire('$directory/runtime.lock')!;
    expect(await runtime.beginBackground(), isFalse);
    foreign.release();
    final request = File('$directory/foreground.request');
    await request.writeAsString(DateTime.now().toIso8601String());
    expect(await runtime.beginBackground(), isFalse);
    await request.delete();
    expect(await runtime.beginBackground(), isTrue);
    expect(runtime.backgroundCancelled, isFalse);
    await request.writeAsString(DateTime.now().toIso8601String());
    expect(runtime.backgroundCancelled, isTrue);
    await runtime.endBackground();
    await request.delete();
    expect(runtime.ownsNative, isFalse);
    expect(await runtime.beginBackground(), isTrue);
    await runtime.endBackground();
  });

  test('background releases only after all its wallets close', () async {
    expect(await runtime.beginBackground(), isTrue);
    final owner = Object();
    await runtime.attach(owner, pause: () async {}, resume: () async {});
    await expectLater(runtime.endBackground(), throwsStateError);
    runtime.detach(owner);
    expect(runtime.ownsNative, isTrue);
    await runtime.endBackground();
    expect(runtime.ownsNative, isFalse);
  });

  test('ending a background session waits for outstanding native work', () async {
    expect(await runtime.beginBackground(), isTrue);
    final finish = Completer<void>();
    final operation = runtime.run(() => finish.future);
    var ended = false;
    final ending = runtime.endBackground().then((_) => ended = true);
    await Future<void>.delayed(Duration.zero);
    expect(ended, isFalse);
    expect(MinotariNativeLease.tryAcquire('$directory/runtime.lock'), isNull);
    finish.complete();
    await operation;
    await ending;
    expect(runtime.ownsNative, isFalse);
  });

  test('closing an idle UI handle waits for its outstanding native work', () async {
    final owner = Object();
    await runtime.attach(owner, pause: () async {}, resume: () async {});
    final finish = Completer<void>();
    final operation = runtime.run(() => finish.future);
    runtime.detach(owner);
    expect(runtime.ownsNative, isTrue);
    finish.complete();
    await operation;
    await Future<void>.delayed(Duration.zero);
    expect(runtime.ownsNative, isFalse);
  });

  test('rapid pause/resume/pause leaves UI suspended and ownership free', () async {
    final owner = Object();
    await runtime.attach(owner, pause: () async {}, resume: () async {});
    runtime.didChangeAppLifecycleState(AppLifecycleState.paused);
    runtime.didChangeAppLifecycleState(AppLifecycleState.resumed);
    runtime.didChangeAppLifecycleState(AppLifecycleState.paused);
    await runtime.idle;
    expect(runtime.ownsNative, isFalse);
    await expectLater(runtime.ensureSession(), throwsStateError);
    runtime.detach(owner);
  });
}
