// XTM-only coverage of Cake's existing Sign/Verify screen and view model.
import 'dart:async';

import 'package:cake_wallet/core/execution_state.dart';
import 'package:cake_wallet/generated/i18n.dart';
import 'package:cake_wallet/locales/locale.dart';
import 'package:cake_wallet/src/screens/dashboard/sign_page.dart';
import 'package:cake_wallet/src/screens/dashboard/widgets/sign_form.dart';
import 'package:cake_wallet/src/screens/dashboard/widgets/verify_form.dart';
import 'package:cake_wallet/src/widgets/primary_button.dart';
import 'package:cake_wallet/view_model/dashboard/sign_view_model.dart';
import 'package:cw_core/encryption_file_utils.dart';
import 'package:cw_core/wallet_info.dart';
import 'package:cw_core/wallet_type.dart';
import 'package:cw_minotari/minotari_wallet.dart';
import 'package:cw_minotari/src/rust/api/logger.dart';
import 'package:cw_minotari/src/rust/frb_generated.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _Info extends Fake implements WalletInfo {
  @override
  WalletType get type => WalletType.minotari;
  @override
  Future<Set<String>> getUsedAddresses() async => {};
  @override
  Future<Set<String>> getHiddenAddresses() async => {};
  @override
  Future<Set<String>> getManualAddresses() async => {};
}

class _Encryption extends Fake implements EncryptionFileUtils {}

class _Api extends Fake implements RustLibApi {
  String? signedMessage;
  String? verifiedMessage;
  String? verifiedSignature;
  String? verifiedAddress;
  int signingCalls = 0;
  Completer<String>? signing;
  bool valid = true;
  @override
  void crateApiLoggerInitLogger({required String basePath, LoggerConfig? config}) {}

  @override
  Future<String> crateApiSigningSignMessage(
      {required String message, required List<String> seedWords}) {
    signingCalls++;
    signedMessage = message;
    return signing?.future ?? Future.value('synthetic-scalar|synthetic-nonce');
  }

  @override
  Future<bool> crateApiSigningVerifyMessage(
      {required String message, required String signature, required String address}) async {
    verifiedMessage = message;
    verifiedSignature = signature;
    verifiedAddress = address;
    return valid;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final api = _Api();
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late SignViewModel vm;
  setUpAll(() {
    RustLib.initMock(api: api);
    messenger.setMockMethodCallHandler(paths, (_) async => '/synthetic/application-support');
  });
  tearDownAll(() {
    messenger.setMockMethodCallHandler(paths, null);
    RustLib.dispose();
  });
  setUp(() {
    api.signedMessage = null;
    api.verifiedMessage = null;
    api.verifiedSignature = null;
    api.verifiedAddress = null;
    api.signingCalls = 0;
    api.signing = null;
    api.valid = true;
  });

  Future<void> showPage(WidgetTester tester, {bool viewOnly = false}) async {
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final wallet = MinotariWallet(_Info(), DerivationInfo(),
        password: '',
        mnemonic: viewOnly ? null : List.filled(24, 'synthetic').join(' '),
        encryptionFileUtils: _Encryption());
    wallet.walletAddresses.setAddress('synthetic-own-address');
    vm = SignViewModel(wallet);
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: localizationDelegates,
      supportedLocales: S.delegate.supportedLocales,
      home: Scaffold(body: SignPage(vm)),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> showVerification(WidgetTester tester) async {
    await tester.drag(find.byType(PageView), const Offset(-420, 0));
    await tester.pumpAndSettle();
    expect(vm.isSigning, isFalse);
  }

  testWidgets('XTM signing displays the native signature and blocks duplicate taps while busy',
      (tester) async {
    await showPage(tester);
    expect(vm.signIncludesAddress, isFalse);
    final sign = tester.state<SignFormState>(find.byType(SignForm));
    final inputs = find.descendant(of: find.byType(SignForm), matching: find.byType(TextFormField));
    await tester.enterText(inputs.first, 'Сообщение 🐂');
    api.signing = Completer<String>();
    await tester.tap(find.byType(LoadingPrimaryButton));
    await tester.pump();
    expect(vm.state, isA<IsExecutingState>());
    expect(
        tester.widget<LoadingPrimaryButton>(find.byType(LoadingPrimaryButton)).isDisabled, isTrue);
    await tester.tap(find.byType(LoadingPrimaryButton));
    expect(api.signingCalls, 1);
    api.signing!.complete('synthetic-scalar|synthetic-nonce');
    await tester.pumpAndSettle();
    expect(vm.state, isA<ExecutedSuccessfullyState>());
    expect(api.signedMessage, 'Сообщение 🐂');
    expect(sign.signatureController.text, 'synthetic-scalar|synthetic-nonce');
    expect(tester.takeException(), isNull);
  });

  testWidgets('XTM verification sends the entered signer and displays success', (tester) async {
    await showPage(tester);
    await showVerification(tester);
    final inputs =
        find.descendant(of: find.byType(VerifyForm), matching: find.byType(TextFormField));
    await tester.enterText(inputs.at(0), 'Сообщение 🐂');
    await tester.enterText(inputs.at(1), 'foreign-signer');
    await tester.enterText(inputs.at(2), 'sig|nonce');
    await tester.tap(find.byType(LoadingPrimaryButton));
    await tester.pumpAndSettle();
    expect(api.verifiedMessage, 'Сообщение 🐂');
    expect(api.verifiedAddress, 'foreign-signer');
    expect(api.verifiedSignature, 'sig|nonce');
    expect(vm.state, isA<ExecutedSuccessfullyState>());
    expect(find.text(S.current.message_verified), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('XTM invalid signature displays the existing verification error', (tester) async {
    await showPage(tester);
    await showVerification(tester);
    final verify = tester.state<VerifyFormState>(find.byType(VerifyForm));
    verify.messageController.text = 'changed';
    verify.addressController.text = 'foreign-signer';
    verify.signatureController.text = 'sig|nonce';
    api.valid = false;
    await tester.tap(find.byType(LoadingPrimaryButton));
    await tester.pumpAndSettle();
    expect(vm.state, isA<FailureState>());
    expect(find.text(S.current.signature_invalid_error), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('view-only XTM reports signing failure and still permits verification',
      (tester) async {
    await showPage(tester, viewOnly: true);
    await tester.tap(find.byType(LoadingPrimaryButton));
    await tester.pumpAndSettle();
    expect(vm.state, isA<FailureState>());
    expect(find.textContaining('view-only wallet cannot sign'), findsOneWidget);
    expect(api.signingCalls, 0);
    await tester.tap(find.text(S.current.ok));
    await tester.pumpAndSettle();
    await showVerification(tester);
    final verify = tester.state<VerifyFormState>(find.byType(VerifyForm));
    verify.messageController.text = 'm';
    verify.addressController.text = 'foreign-signer';
    verify.signatureController.text = 'sig|nonce';
    await tester.tap(find.byType(LoadingPrimaryButton));
    await tester.pumpAndSettle();
    expect(find.text(S.current.message_verified), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
