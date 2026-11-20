import 'dart:convert';

/// Match the Tari tip-info response shape; HTTP 200 alone is not a node probe.
bool isMinotariTipResponse(String body) {
  try {
    final value = jsonDecode(body);
    if (value is! Map<String, dynamic> || value['is_synced'] is! bool) return false;
    final metadata = value['metadata'];
    // A node that has not acquired chain metadata can still answer the RPC.
    if (metadata == null) return true;
    if (metadata is! Map<String, dynamic>) return false;
    bool unsigned(String key) => metadata[key] is int && (metadata[key] as int) >= 0;
    final hash = metadata['best_block_hash'];
    final difficulty = metadata['accumulated_difficulty'];
    return unsigned('best_block_height') &&
        unsigned('pruning_horizon') &&
        unsigned('pruned_height') &&
        unsigned('timestamp') &&
        hash is List &&
        hash.length == 32 &&
        hash.every((value) => value is int && value >= 0 && value <= 255) &&
        difficulty is String &&
        RegExp(r'^0x[0-9a-fA-F]+$').hasMatch(difficulty);
  } on FormatException {
    return false;
  }
}
