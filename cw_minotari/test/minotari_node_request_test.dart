import "dart:async";
import "dart:convert";
import "dart:io";

import "package:cw_core/node.dart";
import "package:cw_core/utils/proxy_wrapper.dart";
import "package:cw_core/utils/tor/disabled.dart";
import "package:cw_core/wallet_type.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  late HttpServer server;
  late Node node;
  late Future<void> Function(HttpRequest) respond;
  final requests = <Uri>[];

  setUp(() async {
    CakeTor.instance = CakeTorDisabled();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    node = Node(uri: "127.0.0.1:${server.port}", type: WalletType.minotari);
    requests.clear();
    respond = (request) async {
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        "metadata": {"best_block_height": 42},
        "is_synced": true,
      }));
      await request.response.close();
    };
    server.listen((request) async {
      requests.add(request.uri);
      await respond(request);
    });
  });

  tearDown(() async {
    await server.close(force: true);
    CakeTor.instance = null;
  });

  test("XTM dispatch queries the selected port and the native-compatible root RPC path", () async {
    node.path = "/custom-prefix";
    final before = node.toMap();

    expect(await node.requestNode(), isTrue);
    expect(requests.map((uri) => uri.toString()), ["/get_tip_info"]);
    expect(node.toMap(), before);
  });

  test("an unsynced node without metadata is reachable", () async {
    respond = (request) async {
      request.response.write('{"metadata":null,"is_synced":false}');
      await request.response.close();
    };

    expect(await node.requestNode(), isTrue);
  });

  test("an HTTP error is unhealthy even when its JSON looks like tip info", () async {
    respond = (request) async {
      request.response.statusCode = HttpStatus.serviceUnavailable;
      request.response.write('{"metadata":null,"is_synced":true}');
      await request.response.close();
    };

    expect(await node.requestNode(), isFalse);
    expect(requests, hasLength(1), reason: "the UI probe must not retry HTTP errors");
  });

  test("invalid JSON and non-tip payloads cannot report healthy", () async {
    for (final body in [
      "not json",
      "[]",
      '{"error":"RPC unavailable"}',
      '{"metadata":null,"is_synced":"true"}',
      '{"metadata":[],"is_synced":true}',
      '{"metadata":{"best_block_height":-1},"is_synced":true}',
      '{"metadata":{"best_block_height":"42"},"is_synced":true}',
    ]) {
      respond = (request) async {
        request.response.write(body);
        await request.response.close();
      };
      expect(await node.requestNode(), isFalse, reason: body);
    }
  });

  test("invalid address and refused connection return false", () async {
    node.uriRaw = "[invalid";
    expect(await node.requestNode(), isFalse);
    expect(requests, isEmpty);

    node.uriRaw = "127.0.0.1:${server.port}";
    await server.close(force: true);
    expect(await node.requestNode(), isFalse);
  });

  test("a stalled response times out and a later probe recovers", () async {
    final stalled = Completer<HttpRequest>();
    respond = (request) async {
      stalled.complete(request);
      // Deliberately do not send headers/body or start a delayed timer.
    };
    final timer = Stopwatch()..start();

    expect(await node.requestNode(), isFalse);
    expect(stalled.isCompleted, isTrue);
    expect(timer.elapsed, lessThan(const Duration(seconds: 8)));

    respond = (request) async {
      request.response.write('{"metadata":null,"is_synced":true}');
      await request.response.close();
    };
    expect(await node.requestNode(), isTrue);
  });

  test("TLS failure cannot be mistaken for an available HTTPS RPC", () async {
    // An ordinary HTTP listener must fail the TLS handshake.
    node.useSSL = true;
    expect(await node.requestNode(), isFalse);
  });
}
