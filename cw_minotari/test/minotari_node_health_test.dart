import "dart:async";

import "package:cw_core/encryption_file_utils.dart";
import "package:cw_core/node.dart";
import "package:cw_core/wallet_info.dart";
import "package:cw_core/wallet_type.dart";
import "package:cw_minotari/minotari_wallet.dart";
import "package:cw_minotari/src/rust/frb_generated.dart";
import "package:flutter_test/flutter_test.dart";

class _WalletInfo extends Fake implements WalletInfo {
  @override
  bool get isRecovery => false;
  @override
  Future<Set<String>> getUsedAddresses() async => {};

  @override
  Future<Set<String>> getHiddenAddresses() async => {};

  @override
  Future<Set<String>> getManualAddresses() async => {};
}

class _EncryptionFileUtils extends Fake implements EncryptionFileUtils {}

class _NodeHealthApi extends Fake implements RustLibApi {
  final requests = <String>[];
  Future<bool> Function(String) probe = (_) async => true;

  @override
  Future<bool> crateApiBaseNodeCheckNodeHealth({required String baseUrl}) {
    requests.add(baseUrl);
    return probe(baseUrl);
  }
}

Node node(String address, {bool ssl = false, String path = ""}) => Node(
      uri: address,
      type: WalletType.minotari,
      useSSL: ssl,
      path: path,
    );

void main() {
  late MinotariWallet wallet;
  late _NodeHealthApi api;

  setUpAll(() {
    api = _NodeHealthApi();
    RustLib.initMock(api: api);
  });

  tearDownAll(RustLib.dispose);

  setUp(() {
    api.requests.clear();
    api.probe = (_) async => true;
    wallet = MinotariWallet(
      _WalletInfo(),
      DerivationInfo(),
      password: "",
      encryptionFileUtils: _EncryptionFileUtils(),
    );
  });

  tearDown(() async {
    await wallet.close();
  });

  test("no selected node is unhealthy without a native request", () async {
    expect(await wallet.checkNodeHealth(), isFalse);
    expect(api.requests, isEmpty);
  });

  test("health probes the selected HTTP endpoint on every call", () async {
    await wallet.connectToNode(node: node("127.0.0.1:18142"));
    final status = wallet.syncStatus;
    final balance = wallet.balance.values.single;

    expect(await wallet.checkNodeHealth(), isTrue);
    api.probe = (_) async => false;
    expect(await wallet.checkNodeHealth(), isFalse);
    expect(api.requests, ["http://127.0.0.1:18142", "http://127.0.0.1:18142"]);
    expect(wallet.syncStatus, same(status));
    expect(wallet.balance.values.single, same(balance));
  });

  test("changing the node probes its new HTTPS URL with port and path", () async {
    await wallet.connectToNode(node: node("127.0.0.1:18142"));
    api.probe = (_) async => false;
    expect(await wallet.checkNodeHealth(), isFalse);

    await wallet.connectToNode(node: node("rpc.example:8443", ssl: true, path: "/tari"));
    api.probe = (_) async => true;
    expect(await wallet.checkNodeHealth(), isTrue);
    expect(api.requests, ["http://127.0.0.1:18142", "https://rpc.example:8443/tari"]);
  });

  test("native and timeout failures return false and a later check can recover", () async {
    await wallet.connectToNode(node: node("rpc.example", ssl: true));
    api.probe = (_) async => throw StateError("bridge failure");
    expect(await wallet.checkNodeHealth(), isFalse);
    api.probe = (_) async => throw TimeoutException("node did not respond");
    expect(await wallet.checkNodeHealth(), isFalse);

    api.probe = (_) async => true;
    expect(await wallet.checkNodeHealth(), isTrue);
    expect(api.requests, List.filled(3, "https://rpc.example"));
  });

  test("an invalid selected node URL returns false without a native request", () async {
    await wallet.connectToNode(node: node("[invalid"));

    expect(await wallet.checkNodeHealth(), isFalse);
    expect(api.requests, isEmpty);
  });
}
