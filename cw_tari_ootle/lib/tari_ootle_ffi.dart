import 'package:cw_tari_ootle/src/rust/frb_generated.dart';

export 'package:cw_tari_ootle/src/rust/api/wallet.dart' show TariOotleNetwork;

Future<void>? _init;

/// Loads `rust_lib_cw_tari_ootle` once per process. Every bridge call must await this first.
Future<void> initTariOotleLib() => _init ??= RustLib.init();
