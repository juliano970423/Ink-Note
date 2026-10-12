import 'dart:io';
import 'dart:typed_data';

/// 2x2 紅色 RGBA PNG（手拼：dart:io zlib + 自算 CRC，
/// 不依賴引擎解碼，純 test 裡可跑）。
Uint8List tinyPng() {
  final raw = <int>[];
  for (var y = 0; y < 2; y++) {
    raw.add(0); // filter: None
    for (var x = 0; x < 2; x++) {
      raw.addAll([255, 0, 0, 255]);
    }
  }
  void chunk(BytesBuilder out, String type, List<int> data) {
    final t = type.codeUnits;
    out.add(_be32(data.length));
    out.add(t);
    out.add(data);
    out.add(_be32(_crc32([...t, ...data])));
  }

  final out = BytesBuilder();
  out.add([137, 80, 78, 71, 13, 10, 26, 10]);
  chunk(out, 'IHDR', [
    ..._be32(2),
    ..._be32(2),
    8, 6, 0, 0, 0, // 8bit RGBA
  ]);
  chunk(out, 'IDAT', ZLibCodec().encode(raw));
  chunk(out, 'IEND', []);
  return out.toBytes();
}

List<int> _be32(int v) =>
    [(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF];

int _crc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final b in bytes) {
    crc ^= b;
    for (var k = 0; k < 8; k++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}
