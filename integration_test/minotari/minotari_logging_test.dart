import 'dart:io';

import 'package:cw_minotari/minotari_ffi.dart';
import 'package:cw_minotari/src/rust/api/network.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

/// Run only on a disposable Simulator/emulator with no personal wallets.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const enabled = bool.fromEnvironment('MINOTARI_NATIVE_LOGGING_TESTS');

  testWidgets('XTM native startup writes a log before initializing its disposable database',
      (tester) async {
    final temporary = await getTemporaryDirectory();
    final root = await Directory(temporary.path).createTemp('xtm-logging-');
    final support = await getApplicationSupportDirectory();
    final logFile = File('${support.path}/logs/minotari.log');
    // Refuse a reused profile instead of deleting or truncating any existing log.
    expect(await logFile.exists(), isFalse,
        reason: 'Use scripts/ios/test_minotari.sh with the logging suite on a fresh Simulator');
    final dbPath = '${root.path}/wallet.db';
    final ffi = MinotariFfi(dataPath: dbPath, walletName: 'unused-logging-fixture');
    addTearDown(ffi.dispose);

    // Opening initializes only the shared DB. It creates no account, takes no
    // seed/password, and starts no scanner or network request.
    await ffi.open(TariNetwork.mainNet);
    expect(await File(dbPath).exists(), isTrue);
    expect(await logFile.exists(), isTrue);
    final firstLog = await logFile.readAsString();
    const marker = 'Minotari Logger Initialized';
    expect(marker.allMatches(firstLog), hasLength(1));
    expect(firstLog, contains('Initializing database at $dbPath'));
    expect(firstLog.indexOf(marker), lessThan(firstLog.indexOf('Initializing database at')));

    await ffi.dispose();
    final second = MinotariFfi(dataPath: dbPath, walletName: 'another-unused-handle');
    addTearDown(second.dispose);
    await second.open(TariNetwork.mainNet);
    expect(marker.allMatches(await logFile.readAsString()), hasLength(1),
        reason: 'Another wallet handle must reuse the process logger');
    binding.reportData = {
      'xtmNativeLogFile': true,
      'xtmLogBeforeDatabase': true,
      'xtmLoggerReused': true,
      'accountCreated': false,
      'liveChain': false,
    };
  }, skip: !enabled, timeout: const Timeout(Duration(minutes: 3)));
}
