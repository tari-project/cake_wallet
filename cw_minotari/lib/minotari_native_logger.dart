import 'package:cw_core/utils/print_verbose.dart';
import 'package:cw_minotari/src/rust/api/logger.dart' as native;
import 'package:path_provider/path_provider.dart';

/// One best-effort logging setup per Dart session, after the Rust bridge is ready.
/// Wallet handles share the native process logger; closing one must not reset it.
class MinotariNativeLogger {
  Future<void>? _startup;
  bool _attempted = false;

  Future<void> ensureInitialized() async {
    if (_attempted) return;
    await (_startup ??= _initialize());
  }

  Future<void> _initialize() async {
    try {
      final support = await getApplicationSupportDirectory();
      native.initLogger(basePath: support.path, config: null);
    } catch (_) {
      // Logging must not block wallet operations. Do not repeat a failed global
      // registration on every call (e.g. the native logger survived hot restart),
      // or print the exception, which can contain paths or other private data.
      printV('[Minotari] Native logger setup failed; continuing wallet operation.',
          level: LogLevel.warn);
    } finally {
      _attempted = true;
      _startup = null;
    }
  }
}
