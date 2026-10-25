package com.cakewallet.cw_core;

import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import androidx.annotation.NonNull;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.embedding.engine.FlutterEngineCache;
import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodChannel;

/** Completes the lifecycle of a daemon engine after its Worker acknowledges completion. */
public final class CwCorePlugin implements FlutterPlugin {
    // flutter_daemon c24ee99 creates this cache entry but never destroys it.
    // Keep in sync with that pinned plugin; remove this bridge when it owns cleanup.
    private static final String BACKGROUND_ENGINE = "background_engine";
    private MethodChannel channel;
    private FlutterEngine completedEngine;
    private boolean disposing;

    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
        completedEngine = null;
        disposing = false;
        final BinaryMessenger messenger = binding.getBinaryMessenger();
        channel = new MethodChannel(messenger, "cw_core/background_sync");
        channel.setMethodCallHandler((call, result) -> {
            final FlutterEngineCache cache = FlutterEngineCache.getInstance();
            if (call.method.equals("prepareCompletedEngine")) {
                final FlutterEngine cached = cache.get(BACKGROUND_ENGINE);
                if (cached == null || cached.getPlugins().get(CwCorePlugin.class) != this) {
                    result.success(false);
                    return;
                }
                completedEngine = cached;
                result.success(true);
                return;
            }
            if (!call.method.equals("disposeCompletedEngine")) {
                result.notImplemented();
                return;
            }
            final FlutterEngine engine = completedEngine;
            // A UI engine can never dispose itself or somebody else's engine.
            if (disposing || engine == null || engine.getPlugins().get(CwCorePlugin.class) != this) {
                result.success(false);
                return;
            }
            disposing = true;
            result.success(true);
            new Handler(Looper.getMainLooper()).post(() -> {
                // A following Worker may already have replaced the cache entry.
                if (cache.get(BACKGROUND_ENGINE) == engine) cache.remove(BACKGROUND_ENGINE);
                engine.destroy();
                Log.i("CakeBackgroundSync", "Completed background engine destroyed");
            });
        });
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        channel.setMethodCallHandler(null);
        channel = null;
        completedEngine = null;
    }
}
