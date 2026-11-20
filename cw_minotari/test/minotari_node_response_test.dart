import 'dart:convert';
import 'package:cw_core/minotari_node_response.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> tip() => {
      'is_synced': true,
      'metadata': {
        'best_block_height': 250000,
        'best_block_hash': List.filled(32, 17),
        'pruning_horizon': 0,
        'pruned_height': 0,
        'timestamp': 1700500000,
        'accumulated_difficulty': '0x75bcd15'
      }
    };
void main() {
  test('valid synced, unsynced and metadata-less Tari nodes are reachable', () {
    expect(isMinotariTipResponse(jsonEncode(tip())), true);
    final t = tip()..['is_synced'] = false;
    expect(isMinotariTipResponse(jsonEncode(t)), true);
    expect(isMinotariTipResponse('{"is_synced":false,"metadata":null}'), true);
  });
  test('HTTP 200 is insufficient: reject HTML, unrelated JSON and malformed tip metadata', () {
    for (final text in ['<html>ok</html>', '{}', '[]', 'null', '{"url":"https://example.test"}']) {
      expect(isMinotariTipResponse(text), false, reason: text);
    }
    for (final entry in <String, dynamic>{
      'best_block_height': -1,
      'best_block_hash': [1, 2],
      'timestamp': 'bad',
      'accumulated_difficulty': 'garbage'
    }.entries) {
      final t = tip();
      (t['metadata'] as Map)[entry.key] = entry.value;
      expect(isMinotariTipResponse(jsonEncode(t)), false, reason: entry.key);
    }
  });
}
