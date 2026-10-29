package com.cakewallet.cw_tari_ootle

import android.content.Context
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin

class CwTariOotlePlugin: FlutterPlugin {
  companion object {
    // Hands the app Context to rustls-platform-verifier (see the bridge's src/android.rs).
    @JvmStatic external fun initTls(context: Context): Boolean
  }

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    System.loadLibrary("rust_lib_cw_tari_ootle")
    if (!initTls(binding.applicationContext)) {
      Log.e("CwTariOotle", "TLS verifier init failed; HTTPS to the indexer will fail")
    }
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {}
}
