import "dart:convert";
import "dart:ffi" show Abi;
import "dart:io";

import "package:cw_minotari/src/rust/api/address.dart" as addresses;
import "package:cw_minotari/src/rust/api/balance.dart";
import "package:cw_minotari/src/rust/api/db.dart";
import "package:cw_minotari/src/rust/api/logger.dart";
import "package:cw_minotari/src/rust/api/network.dart";
import "package:cw_minotari/src/rust/api/signing.dart";
import "package:cw_minotari/src/rust/api/wallet.dart";
import "package:cw_minotari/src/rust/frb_generated.dart";
import "package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart";

/// Native ABI smoke check. Uses only a new temporary DB and never connects to a node.
/// This complements the packaged Flutter app test; it does not replace that test.
Future<void> main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln("Usage: dart run cw_minotari/tool/desktop_smoke.dart <native-library-path>");
    exitCode = 2;
    return;
  }
  final root = await Directory.systemTemp.createTemp("xtm-desktop-smoke-");
  var connected = false;
  var bridgeReady = false;
  // Assertion-style helper for this standalone Dart check.
  // ignore: avoid_positional_boolean_parameters
  void require(bool condition, String message) {
    if (!condition) {
      throw StateError(message);
    }
  }

  try {
    await RustLib.init(externalLibrary: ExternalLibrary.open(File(args.single).absolute.path));
    bridgeReady = true;
    initLogger(basePath: root.path, config: null);
    final path = "${root.path}/wallet.db";
    await initializeDatabase(path: path);
    connected = true;
    const password = "disposable-native-smoke-password";
    final created = await createWallet(
      walletName: "created",
      passphrase: password,
      network: TariNetwork.mainNet,
    );
    final words = created.seedWords!.words;
    require(words.length == 24, "Creation must return 24 seed words");
    require(created.tariAddress.isNotEmpty, "Creation must return an address");
    final zero = await getBalance(walletName: "created");
    require(
      zero.total == BigInt.zero && zero.available == BigInt.zero,
      "Initial balance must be zero",
    );
    // The native schema disallows duplicate seed fingerprints in one DB.
    await disconnectDatabase();
    connected = false;
    await initializeDatabase(path: "${root.path}/restored.db");
    connected = true;
    final restored = await restoreWallet(
      walletName: "restored",
      seedWords: words,
      passphrase: password,
      network: TariNetwork.mainNet,
    );
    require(restored.tariAddress == created.tariAddress, "Restore must preserve the address");
    const message = "XTM desktop smoke 🐂";
    final signature = await signMessage(message: message, seedWords: words);
    require(
      await verifyMessage(message: message, signature: signature, address: created.tariAddress),
      "Native sign/verify must agree",
    );
    await disconnectDatabase();
    connected = false;
    await initializeDatabase(path: path);
    connected = true;
    require(
      await addresses.getAddress(
            walletName: "created",
            passphrase: password,
            network: TariNetwork.mainNet,
          ) ==
          created.tariAddress,
      "Reopened encrypted account must preserve the address",
    );
    require((await listWallets()).single == "created", "The original account must persist");
    stdout.writeln(
      jsonEncode(
        {
          "platform": Platform.operatingSystem,
          "abi": Abi.current().toString(),
          "create": true,
          "restore": true,
          "encryptedReopen": true,
          "zeroBalance": true,
          "signVerify": true,
          "liveChain": false,
        },
      ),
    );
  } finally {
    if (connected) {
      await disconnectDatabase();
    }
    if (bridgeReady) {
      RustLib.dispose();
    }
    await root.delete(recursive: true);
  }
}
