import "dart:ffi";
import "dart:io";

import "package:ffi/ffi.dart";

/// One owner of Tari's process-global DB/scanner, including separate engines.
/// flock locks the open file description, unlike Dart's process-level fcntl lock.
/// Each attempt opens its own descriptor; the OS releases it on process death.
class MinotariNativeLease {
  MinotariNativeLease._(this._descriptor);

  static final _libc = DynamicLibrary.process();
  static final _open =
      _libc.lookupFunction<Int32 Function(Pointer<Utf8>, Int32), int Function(Pointer<Utf8>, int)>(
          "open");
  static final _flock =
      _libc.lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>("flock");
  static final _close = _libc.lookupFunction<Int32 Function(Int32), int Function(int)>("close");

  int? _descriptor;

  static MinotariNativeLease? tryAcquire(String path) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    file.createSync();
    final nativePath = path.toNativeUtf8();
    final int descriptor;
    try {
      descriptor = _open(nativePath, 2); // O_RDWR; no variadic O_CREAT argument.
    } finally {
      malloc.free(nativePath);
    }
    if (descriptor < 0) throw FileSystemException("Cannot open Minotari runtime lock", path);
    if (_flock(descriptor, 2 | 4) != 0) {
      // LOCK_EX | LOCK_NB on supported Unix targets.
      _close(descriptor);
      return null;
    }
    return MinotariNativeLease._(descriptor);
  }

  void release() {
    final descriptor = _descriptor;
    _descriptor = null;
    if (descriptor != null) _close(descriptor);
  }
}
