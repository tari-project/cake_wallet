import "dart:async";
import "dart:io";

import "package:cw_core/pathForWallet.dart";
import "package:cw_core/wallet_type.dart";
import "package:cw_core/utils/print_verbose.dart";
import "package:cw_minotari/minotari_native_lease.dart";
import "package:flutter/widgets.dart";

/// Serializes native access across FlutterEngines and yields it on UI suspension.
/// Background work skips a busy owner; foreground asks it to stop before waiting.
class MinotariRuntime with WidgetsBindingObserver {
  MinotariRuntime._();
  static final instance = MinotariRuntime._();

  final _wallets = <Object, ({Future<void> Function() pause, Future<void> Function() resume})>{};
  MinotariNativeLease? _lease;
  String? _directory;
  bool _background = false;
  bool _paused = false;
  bool _observing = false;
  int epoch = 0;
  int _operations = 0;
  Completer<void>? _operationsIdle;
  Future<void> _transition = Future<void>.value();
  Future<void>? _opening;

  bool get ownsNative => _lease != null;
  Future<void> get idle => _transition;
  bool get backgroundCancelled => _background && _directory != null && _foregroundRequested;

  bool get _foregroundRequested {
    try {
      final time = DateTime.parse(File('$_directory/foreground.request').readAsStringSync());
      return DateTime.now().difference(time) < const Duration(seconds: 35);
    } on FileSystemException {
      return false;
    } on FormatException {
      return false;
    }
  }

  Future<void> ensureSession() async {
    if (_lease != null) return;
    if (_paused && !_background) throw StateError("Minotari is suspended");
    await (_opening ??= _open().whenComplete(() => _opening = null));
  }

  Future<void> _open() async {
    _directory ??= await pathForWalletTypeDir(type: WalletType.minotari);
    final request = File('$_directory/foreground.request');
    if (!_background) await request.writeAsString(DateTime.now().toIso8601String());
    final started = Stopwatch()..start();
    try {
      do {
        if (_background && _foregroundRequested) throw StateError("Minotari foreground requested");
        _lease = MinotariNativeLease.tryAcquire('$_directory/runtime.lock');
        if (_lease != null) {
          epoch++;
          return;
        }
        if (_background) throw StateError("Minotari native runtime is busy");
        await Future<void>.delayed(const Duration(milliseconds: 100));
      } while (started.elapsed < const Duration(seconds: 30));
      throw TimeoutException("Minotari native runtime is busy");
    } finally {
      if (!_background && request.existsSync()) request.deleteSync();
    }
  }

  Future<bool> beginBackground() async {
    if (_background || _wallets.isNotEmpty || _lease != null) return false;
    _background = true;
    try {
      await ensureSession();
      return true;
    } catch (_) {
      _background = false;
      return false;
    }
  }

  Future<void> endBackground() async {
    if (_wallets.isNotEmpty) throw StateError("Close Minotari background wallets before releasing");
    if (_operations > 0) await (_operationsIdle ??= Completer<void>()).future;
    _release();
    _background = false;
  }

  Future<void> attach(Object owner,
      {required Future<void> Function() pause, required Future<void> Function() resume}) async {
    await ensureSession();
    _wallets[owner] = (pause: pause, resume: resume);
    if (!_background && !_observing) {
      WidgetsBinding.instance.addObserver(this);
      _observing = true;
    }
  }

  void detach(Object owner) {
    _wallets.remove(owner);
    if (_wallets.isEmpty) {
      if (_observing) WidgetsBinding.instance.removeObserver(this);
      _observing = false;
      _paused = false;
      releaseIfIdle();
    }
  }

  void releaseIfIdle() {
    if (_wallets.isNotEmpty || _background) return;
    if (_operations == 0) {
      _release();
    } else {
      unawaited((_operationsIdle ??= Completer<void>()).future.then((_) => releaseIfIdle()));
    }
  }

  Future<T> run<T>(Future<T> Function() operation) async {
    if (_lease == null || (_paused && !_background)) throw StateError("Minotari is suspended");
    _operations++;
    try {
      return await operation();
    } finally {
      if (--_operations == 0) {
        _operationsIdle?.complete();
        _operationsIdle = null;
      }
    }
  }

  void _release() {
    _lease?.release();
    _lease = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_background) return;
    if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      _paused = true;
      _transition = _transition.then((_) async {
        _paused = true;
        for (final wallet in _wallets.values.toList()) {
          await wallet.pause();
        }
        if (_operations > 0) await (_operationsIdle ??= Completer<void>()).future;
        _release();
      }).catchError((Object _) {
        // Keep ownership if stopping failed: another engine must not use Tari.
        printV("Minotari suspension failed; native ownership retained.");
      });
    } else if (state == AppLifecycleState.resumed) {
      _transition = _transition.then((_) async {
        _paused = false;
        if (_wallets.isEmpty) return;
        await ensureSession();
        for (final wallet in _wallets.values.toList()) {
          await wallet.resume();
        }
      }).catchError((Object _) {
        printV("Minotari resume failed; reconnect can retry.");
      });
    }
  }
}
