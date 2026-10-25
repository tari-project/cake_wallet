import 'dart:async';

import 'package:cw_minotari/minotari_ffi.dart';
import 'package:cw_minotari/minotari_native_logger.dart';
import 'package:cw_minotari/src/rust/api/logger.dart';
import 'package:cw_minotari/src/rust/frb_generated.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _LoggingApi extends Fake implements RustLibApi {
  final calls = <String>[];
  LoggerConfig? config;
  Object? failure;

  @override
  void crateApiLoggerInitLogger({required String basePath, LoggerConfig? config}) {
    calls.add('logger:$basePath');
    this.config = config;
    if (failure != null) throw failure!;
  }

  @override
  Future<String> crateApiSigningSignMessage({
    required String message,
    required List<String> seedWords,
  }) async {
    calls.add('sign');
    return 'synthetic-signature';
  }

  @override
  Future<bool> crateApiSigningVerifyMessage({
    required String message,
    required String signature,
    required String address,
  }) async {
    calls.add('verify');
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const support = '/synthetic/application-support';
  final api = _LoggingApi();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  late MinotariNativeLogger logger;
  late Future<String?> Function() supportPath;
  var pathCalls = 0;

  setUpAll(() => RustLib.initMock(api: api));
  tearDownAll(RustLib.dispose);
  setUp(() {
    logger = MinotariNativeLogger();
    api.calls.clear();
    api.failure = null;
    api.config = null;
    pathCalls = 0;
    supportPath = () async => support;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'getApplicationSupportDirectory');
      pathCalls++;
      return supportPath();
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('uses application support and native defaults exactly once', () async {
    await logger.ensureInitialized();
    await logger.ensureInitialized();
    expect(pathCalls, 1);
    expect(api.calls, ['logger:$support']);
    expect(api.config, isNull);
  });

  test('concurrent callers await the same logger startup before continuing', () async {
    final path = Completer<String?>();
    supportPath = () => path.future;
    var completed = 0;
    final callers = List.generate(8, (_) async {
      await logger.ensureInitialized();
      completed++;
    });
    await Future<void>.delayed(Duration.zero);
    expect(pathCalls, 1);
    expect(api.calls, isEmpty);
    expect(completed, 0);
    path.complete(support);
    await Future.wait(callers);
    expect(completed, 8);
    expect(api.calls, ['logger:$support']);
  });

  Future<void> expectNonFatalFailure({required bool nativeFailure}) async {
    const privateError = 'synthetic-private-value-must-not-be-logged';
    if (nativeFailure) {
      api.failure = StateError(privateError);
    } else {
      supportPath = () async => throw PlatformException(code: privateError);
    }
    final output = <String>[];
    await runZoned(() async {
      await logger.ensureInitialized();
      await logger.ensureInitialized();
    }, zoneSpecification: ZoneSpecification(print: (self, parent, zone, line) => output.add(line)));
    expect(pathCalls, 1);
    expect(api.calls, nativeFailure ? ['logger:$support'] : isEmpty);
    expect(output.where((line) => line.contains('Native logger setup failed')), hasLength(1));
    expect(output.join(), isNot(contains(privateError)));
  }

  test('support directory failure is nonfatal and warns once without exception data', () async {
    await expectNonFatalFailure(nativeFailure: false);
  });

  test('native registration failure is nonfatal and warns once without exception data', () async {
    await expectNonFatalFailure(nativeFailure: true);
  });

  test('FFI startup initializes logging before operations, including a preinitialized bridge',
      () async {
    final path = Completer<String?>();
    supportPath = () => path.future;
    final signing = MinotariFfi.signMessage('m', seedWords: ['synthetic']);
    final verification = MinotariFfi.verifyMessage('m', 'sig', address: 'synthetic');
    await Future<void>.delayed(Duration.zero);
    expect(api.calls, isEmpty);
    path.complete(support);
    expect(await signing, 'synthetic-signature');
    expect(await verification, isTrue);
    expect(api.calls, ['logger:$support', 'sign', 'verify']);
    await MinotariFfi.verifyMessage('m', 'sig', address: 'synthetic');
    expect(pathCalls, 1);
    expect(api.calls.where((call) => call.startsWith('logger:')), hasLength(1));
  });
}
