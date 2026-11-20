import 'dart:async';

/// FRB 2.11 starts a streamed Rust call with an unawaited NormalTask. A Rust
/// Result::Err is delivered through that detached future in addition to the
/// terminal Error event. Keep both error paths owned by this scan's listener.
/// In particular, a refused background scan must not become a root-isolate error.
void listenMinotariScan<T>({
  required Stream<T> Function() stream,
  required void Function(T) onData,
  required void Function(Object, StackTrace) onError,
}) {
  runZonedGuarded(() {
    stream().listen(onData, onError: onError);
  }, onError);
}
