package com.cakewallet.cw_tari_ootle

import io.flutter.embedding.engine.plugins.FlutterPlugin

class CwTariOotlePlugin: FlutterPlugin {
  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    // No-op: native library loading is handled by flutter_rust_bridge
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    // No-op
  }
}
