import 'dart:async';
import 'dart:io';

import 'package:cw_core/db/sqlite.dart' as cake_db;
import 'package:cw_core/encryption_file_utils.dart';
import 'package:cw_core/pathForWallet.dart';
import 'package:cw_core/wallet_base.dart';
import 'package:cw_core/wallet_info.dart';
import 'package:cw_core/wallet_type.dart';
import 'package:cw_minotari/minotari_wallet_service.dart';
import 'package:cw_minotari/minotari_wallet.dart';
import 'package:cw_minotari/src/rust/frb_generated.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _RemovalApi extends Fake implements RustLibApi {
  final accounts = <String>{};
  final calls = <String>[];
  String? initializedPath;
  bool failInitialization = false;
  bool failDeletion = false;
  bool failListing = false;

  @override
  Future<void> crateApiDbInitializeDatabase({required String path}) async {
    calls.add('init');
    if (failInitialization) throw StateError('init failed');
    initializedPath = path;
  }

  @override
  Future<List<String>> crateApiWalletListWallets() async {
    calls.add('list');
    if (initializedPath == null) throw StateError('database not initialized');
    if (failListing) throw StateError('list failed');
    return accounts.toList();
  }

  @override
  Future<void> crateApiWalletDeleteWallet({required String walletName}) async {
    calls.add('delete:$walletName');
    if (failDeletion) throw StateError('delete failed');
    if (!accounts.remove(walletName)) throw StateError('account missing');
  }
}

class _DelayedBackupEncryption extends Fake implements EncryptionFileUtils {
  final backupStarted = Completer<void>();
  final allowBackup = Completer<void>();

  @override
  Future<void> write({required String path, required String password, required String data}) async {
    if (path.endsWith('.backup')) {
      backupStarted.complete();
      await allowBackup.future;
    }
    await File(path).writeAsString('synthetic encrypted keys');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final api = _RemovalApi();
  final service = MinotariWalletService();
  late Directory root;
  late Directory target;
  late Directory keeper;
  late File sharedDb;

  Future<Directory> addWallet(String name) async {
    final path = await pathForWalletDir(name: name, type: WalletType.minotari);
    final info = WalletInfo.external(
      id: WalletBase.idFor(name, WalletType.minotari),
      name: name,
      type: WalletType.minotari,
      isRecovery: false,
      restoreHeight: 0,
      date: DateTime(2026),
      dirPath: path,
      path: '$path/$name',
      address: 'test-address',
    );
    await info.save();
    for (final suffix in ['.keys', '.keys.backup']) {
      await File('$path/$name$suffix').writeAsString('synthetic encrypted keys');
    }
    api.accounts.add(name);
    return Directory(path);
  }

  Future<void> expectPreserved() async {
    expect(await target.exists(), isTrue);
    expect(await WalletInfo.get('remove-me', WalletType.minotari), isNotNull);
    expect(await keeper.exists(), isTrue);
    expect(await sharedDb.readAsString(), 'shared database sentinel');
  }

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('xtm-removal-test-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'), (_) async => root.path);
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await cake_db.initDb();
    RustLib.initMock(api: api);
  });

  tearDownAll(() async {
    RustLib.dispose();
    await cake_db.db?.close();
    cake_db.db = null;
    await root.delete(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), null);
  });

  setUp(() async {
    api.accounts.clear();
    api.calls.clear();
    api.failDeletion = false;
    api.failListing = false;
    await cake_db.db!.delete(WalletInfo.tableName);
    target = await addWallet('remove-me');
    keeper = await addWallet('keep-me');
    sharedDb = File('${await pathForWalletTypeDir(type: WalletType.minotari)}/wallet.db');
    await sharedDb.writeAsString('shared database sentinel');
  });

  // The first call is intentionally before any XTM wallet has been opened.
  test('cold deletion initializes native DB; failed initialization is retryable', () async {
    api.failInitialization = true;
    await expectLater(service.remove('remove-me'), throwsStateError);
    await expectPreserved();
    expect(api.accounts, contains('remove-me'));
    api.failInitialization = false;
    await service.remove('remove-me');
    expect(api.calls, ['init', 'init', 'list', 'delete:remove-me']);
    expect(api.initializedPath, sharedDb.path);
    expect(await target.exists(), isFalse);
    expect(await WalletInfo.get('remove-me', WalletType.minotari), isNull);
  });

  test('deletes target keys, backup and metadata while preserving another wallet', () async {
    await service.remove('remove-me');
    expect(api.accounts, {'keep-me'});
    expect(await target.exists(), isFalse);
    expect(await WalletInfo.get('remove-me', WalletType.minotari), isNull);
    expect(await WalletInfo.get('keep-me', WalletType.minotari), isNotNull);
    expect(await File('${keeper.path}/keep-me.keys.backup').exists(), isTrue);
    expect(await sharedDb.readAsString(), 'shared database sentinel');
    // The mock implements no stopScan/disconnectDatabase: either call would fail.
  });

  test('native deletion failure preserves keys and metadata, then can retry', () async {
    api.failDeletion = true;
    await expectLater(service.remove('remove-me'), throwsStateError);
    await expectPreserved();
    api.failDeletion = false;
    await service.remove('remove-me');
    expect(await target.exists(), isFalse);
    expect(await WalletInfo.get('remove-me', WalletType.minotari), isNull);
  });

  test('listing failure must not be treated as an already deleted account', () async {
    api.failListing = true;
    await expectLater(service.remove('remove-me'), throwsStateError);
    await expectPreserved();
    expect(api.accounts, contains('remove-me'));
    // A newly acquired native lease may reinitialize the shared DB first.
    expect(api.calls.where((call) => call != 'init'), ['list']);
  });

  test('resumes file and metadata cleanup after native account was deleted', () async {
    api.accounts.remove('remove-me');
    await service.remove('remove-me');
    expect(api.calls.where((call) => call != 'init'), ['list']);
    expect(await target.exists(), isFalse);
    expect(await WalletInfo.get('remove-me', WalletType.minotari), isNull);
    expect(await keeper.exists(), isTrue);
  });

  test('resumes metadata cleanup after account and directory were deleted', () async {
    api.accounts.remove('remove-me');
    await target.delete(recursive: true);
    await service.remove('remove-me');
    expect(await target.exists(), isFalse);
    expect(await WalletInfo.get('remove-me', WalletType.minotari), isNull);
  });

  test('metadata error after native and file deletion can be retried', () async {
    await cake_db.db!.execute('''
      CREATE TRIGGER fail_metadata_delete BEFORE DELETE ON WalletInfo
      BEGIN SELECT RAISE(ABORT, 'injected metadata failure'); END
    ''');
    try {
      await expectLater(service.remove('remove-me'), throwsA(isA<DatabaseException>()));
      expect(api.accounts, {'keep-me'});
      expect(await target.exists(), isFalse);
      expect(await WalletInfo.get('remove-me', WalletType.minotari), isNotNull);
    } finally {
      await cake_db.db!.execute('DROP TRIGGER fail_metadata_delete');
    }
    await service.remove('remove-me');
    expect(await WalletInfo.get('remove-me', WalletType.minotari), isNull);
    expect(await sharedDb.readAsString(), 'shared database sentinel');
  });

  test('missing Cake metadata is rejected before native or file deletion', () async {
    await WalletInfo.delete((await WalletInfo.get('remove-me', WalletType.minotari))!);
    await expectLater(service.remove('remove-me'), throwsException);
    expect(api.calls, isEmpty);
    expect(api.accounts, contains('remove-me'));
    expect(await target.exists(), isTrue);
  });

  test('deleting last account preserves shared database and permits recreating name', () async {
    await service.remove('remove-me');
    await service.remove('keep-me');
    expect(api.accounts, isEmpty);
    expect(await sharedDb.exists(), isTrue);
    expect(await WalletInfo.getAll(), isEmpty);
    await addWallet('remove-me');
    await service.remove('remove-me');
    expect(api.accounts, isEmpty);
    expect(await WalletInfo.getAll(), isEmpty);
  });

  test('save waits for backup write so it cannot outlive subsequent deletion', () async {
    await File('${target.path}/remove-me.keys').delete();
    await File('${target.path}/remove-me.keys.backup').delete();
    final encryption = _DelayedBackupEncryption();
    final wallet = MinotariWallet(
      (await WalletInfo.get('remove-me', WalletType.minotari))!,
      DerivationInfo(),
      password: '',
      encryptionFileUtils: encryption,
    );
    var completed = false;
    final saving = wallet.save().then((_) => completed = true);
    try {
      await encryption.backupStarted.future;
      // Flush the completion callbacks that would run if save returned early.
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);
    } finally {
      encryption.allowBackup.complete();
      await saving;
      await wallet.close();
    }
    await service.remove('remove-me');
    expect(await target.exists(), isFalse);
  });
}
