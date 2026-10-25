import 'package:cw_core/encryption_file_utils.dart';
import 'package:cw_core/wallet_info.dart';
import 'package:cw_minotari/minotari_wallet.dart';
import 'package:cw_minotari/src/rust/frb_generated.dart';
import 'package:flutter_test/flutter_test.dart';

class _Info extends Fake implements WalletInfo {
  @override
  Future<Set<String>> getUsedAddresses() async => {};
  @override
  Future<Set<String>> getHiddenAddresses() async => {};
  @override
  Future<Set<String>> getManualAddresses() async => {};
}

class _Encryption extends Fake implements EncryptionFileUtils {}

class _SigningApi extends Fake implements RustLibApi {
  final signed = <({String message, List<String> words})>[];
  final verified = <({String message, String signature, String address})>[];
  Object? signingError;
  Object? verificationError;
  bool valid = true;

  // Any DB, node, scanner or transaction call fails through Fake.noSuchMethod:
  // these operations must work offline without opening a wallet.
  @override
  Future<String> crateApiSigningSignMessage(
      {required String message, required List<String> seedWords}) async {
    signed.add((message: message, words: seedWords));
    if (signingError != null) throw signingError!;
    return 'synthetic-scalar|synthetic-nonce';
  }

  @override
  Future<bool> crateApiSigningVerifyMessage(
      {required String message, required String signature, required String address}) async {
    verified.add((message: message, signature: signature, address: address));
    if (verificationError != null) throw verificationError!;
    return valid;
  }
}

void main() {
  final api = _SigningApi();
  final words = List.generate(24, (i) => 'synthetic$i');
  MinotariWallet wallet({String? mnemonic, String? passphrase}) => MinotariWallet(
        _Info(),
        DerivationInfo(),
        password: 'synthetic-file-password',
        mnemonic: mnemonic,
        passphrase: passphrase,
        encryptionFileUtils: _Encryption(),
      );

  setUpAll(() => RustLib.initMock(api: api));
  tearDownAll(RustLib.dispose);
  setUp(() {
    api.signed.clear();
    api.verified.clear();
    api.signingError = null;
    api.verificationError = null;
    api.valid = true;
  });

  test('offline signing preserves exact UTF8 message and normalizes seed whitespace', () async {
    final w = wallet(mnemonic: ' \n${words.join(' \t ')}\n ', passphrase: 'synthetic-db-password');
    const message = '  Сообщение 🐂\nline two\t ';
    expect(await w.signMessage(message), 'synthetic-scalar|synthetic-nonce');
    expect(api.signed.single.message, message);
    expect(api.signed.single.words, words);
    expect(api.verified, isEmpty);
  });

  test('explicit own address and omitted address select the same spend key', () async {
    final w = wallet(mnemonic: words.join(' '));
    w.walletAddresses.setAddress('synthetic-own-address');
    await w.signMessage('m', address: ' synthetic-own-address\n');
    await w.signMessage('m');
    expect(api.signed[0].message, api.signed[1].message);
    expect(api.signed[0].words, api.signed[1].words);
  });

  test('a foreign signing address is rejected before handing the seed to native', () async {
    final w = wallet(mnemonic: words.join(' '));
    w.walletAddresses.setAddress('synthetic-own-address');
    await expectLater(w.signMessage('m', address: 'foreign-address'), throwsArgumentError);
    expect(api.signed, isEmpty);
  });

  test('view-only and empty seeds cannot sign but can verify someone else', () async {
    for (final mnemonic in [null, '', ' \t\n ']) {
      final w = wallet(mnemonic: mnemonic);
      await expectLater(w.signMessage('m'), throwsA(isA<StateError>()));
      expect(await w.verifyMessage('m', 'sig|nonce', address: 'foreign-address'), isTrue);
    }
    expect(api.signed, isEmpty);
    expect(api.verified.length, 3);
  });

  test('wrong mnemonic length is rejected before native signing', () async {
    for (final count in [1, 23, 25]) {
      await expectLater(
          wallet(mnemonic: List.filled(count, 'synthetic').join(' ')).signMessage('m'),
          throwsStateError);
    }
    expect(api.signed, isEmpty);
  });

  test('invalid native mnemonic and signing failures reach the caller', () async {
    final error = StateError('Invalid Seed Words: synthetic failure');
    api.signingError = error;
    await expectLater(wallet(mnemonic: words.join(' ')).signMessage('m'), throwsA(same(error)));
    expect(api.signed.length, 1);
  });

  test('verification uses supplied address, preserves message and trims pasted fields', () async {
    final w = wallet();
    w.walletAddresses.setAddress('own-address');
    const message = ' \nПодпись 🐂\t ';
    expect(
        await w.verifyMessage(message, ' \nsig|nonce\t ', address: ' foreign-address\n'), isTrue);
    expect(api.verified.single,
        (message: message, signature: 'sig|nonce', address: 'foreign-address'));
  });

  test('missing verification address or signature returns false without native work', () async {
    final w = wallet();
    // Never silently substitute the current wallet's address for a missing signer.
    w.walletAddresses.setAddress('own-address');
    for (final address in [null, '', ' \t\n ']) {
      expect(await w.verifyMessage('m', 'sig|nonce', address: address), isFalse);
    }
    for (final signature in ['', ' \n ']) {
      expect(await w.verifyMessage('m', signature, address: 'address'), isFalse);
    }
    expect(api.verified, isEmpty);
  });

  test('a cryptographically incorrect signature stays false', () async {
    api.valid = false;
    expect(await wallet().verifyMessage('changed', 'sig|nonce', address: 'address'), isFalse);
    expect(api.verified.length, 1);
  });

  test('malformed native inputs return false and a later verification can recover', () async {
    final w = wallet();
    for (final error in [
      ArgumentError('Invalid Recipient Address'),
      StateError('Signing Error: invalid public nonce')
    ]) {
      api.verificationError = error;
      expect(await w.verifyMessage('m', 'bad', address: 'bad'), isFalse);
    }
    api.verificationError = null;
    expect(await w.verifyMessage('m', 'sig|nonce', address: 'address'), isTrue);
  });

  test('empty messages are signed and verified as empty, without altering bytes', () async {
    final w = wallet(mnemonic: words.join(' '));
    final signature = await w.signMessage('');
    expect(await w.verifyMessage('', signature, address: 'address'), isTrue);
    expect(api.signed.single.message, isEmpty);
    expect(api.verified.single.message, isEmpty);
  });
}
