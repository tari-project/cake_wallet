import "dart:async";
import "dart:convert";
import "dart:io";

import "package:flutter/services.dart";

/// WorkManager runs a FlutterEngine in the application process. Completing a
/// task must notify the worker, never send a signal to the application's PID.
class BackgroundSyncSession {
  BackgroundSyncSession({Directory? directory, Future<void> Function()? onComplete})
      : directory =
            directory ?? Directory("${Directory.systemTemp.path}/flutter_daemon_background"),
        _onComplete = onComplete ?? _notifyWorker;

  final Directory directory;
  final Future<void> Function() _onComplete;
  Timer? _heartbeat;
  String? _token;

  File _file(String name) => File("${directory.path}/$name");
  Map<String, dynamic>? _owner() {
    try {
      final value = jsonDecode(_file("owner.json").readAsStringSync());
      return value is Map<String, dynamic> && value["pid"] is int && value["token"] is String
          ? value
          : null;
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  bool get cancelled {
    if (_token == null || _owner()?["token"] != _token) return true;
    try {
      return _file("cancel").readAsStringSync() == _token;
    } on FileSystemException {
      return false;
    }
  }

  bool begin() {
    directory.createSync(recursive: true);
    if (_owner()?["pid"] == pid) return false;
    _token = "$pid-${DateTime.now().microsecondsSinceEpoch}";
    // Foreground must never observe a partially written owner record.
    _file("owner-$_token.tmp")
      ..writeAsStringSync(jsonEncode({"pid": pid, "token": _token}))
      ..renameSync(_file("owner.json").path);
    void heartbeat() {
      if (!cancelled) _file("__daemonfile").writeAsStringSync(DateTime.now().toIso8601String());
    }

    heartbeat();
    _heartbeat = Timer.periodic(const Duration(seconds: 1), (_) => heartbeat());
    return true;
  }

  Future<void> complete() async {
    _heartbeat?.cancel();
    _heartbeat = null;
    if (_token == null || _owner()?["token"] != _token) return;
    for (final name in ["__daemonfile", "__daemonfile.pid", "cancel", "owner.json"]) {
      final file = _file(name);
      if (file.existsSync()) file.deleteSync();
    }
    _token = null;
    await _onComplete();
  }

  Future<void> cancelActive({Duration timeout = const Duration(seconds: 30)}) async {
    final owner = _owner();
    if (owner == null || owner["pid"] != pid) {
      // A worker may begin after this read. Leave its owner/cancel records alone;
      // the next worker replaces stale process ownership. Never signal a PID.
      for (final name in ["__daemonfile.pid", "__daemonfile"]) {
        final legacy = _file(name);
        if (legacy.existsSync()) legacy.deleteSync();
      }
      return;
    }
    _file("cancel").writeAsStringSync(owner["token"] as String);
    final watch = Stopwatch()..start();
    while (_owner()?["token"] == owner["token"]) {
      if (watch.elapsed >= timeout) throw TimeoutException("Background sync is still stopping");
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  static Future<void> _notifyWorker() async {
    if (!Platform.isAndroid) return;
    await completeAndroidWorker();
  }

  static Future<void> completeAndroidWorker() async {
    const channel = MethodChannel("flutter_daemon");
    const engines = MethodChannel("cw_core/background_sync");
    // Capture ownership before acknowledging the Worker: acknowledgement lets
    // a following job replace the cache entry. It must not replace our owner.
    if (await engines.invokeMethod<bool>("prepareCompletedEngine") != true) {
      throw StateError("Background engine ownership mismatch");
    }
    // The native worker installs its completion handler after engine startup.
    for (var attempt = 0; attempt < 5; attempt++) {
      try {
        await channel.invokeMethod<void>("backgroundSyncComplete");
        break;
      } on MissingPluginException {
        if (attempt == 4) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
    // All wallets/native operations and the heartbeat have stopped first. The
    // native identity check allows disposal only from the completed job's engine.
    final disposed = await engines.invokeMethod<bool>("disposeCompletedEngine");
    if (disposed != true) throw StateError("Background engine ownership mismatch");
  }
}
