import 'dart:typed_data';

/// Small WAV/PCM helpers shared by the TTS engines. Clips are kept as 16-bit
/// mono at the engine's native sample rate (no transcoder needed).

/// Wraps 16-bit mono PCM samples in a WAV container.
Uint8List pcm16MonoToWav(Int16List samples, int rate) {
  final dataLen = samples.length * 2;
  final b = BytesBuilder();
  void s(String x) => b.add(x.codeUnits);
  void u32(int v) => b.add([v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff]);
  void u16(int v) => b.add([v & 0xff, (v >> 8) & 0xff]);
  s('RIFF'); u32(36 + dataLen); s('WAVE');
  s('fmt '); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16);
  s('data'); u32(dataLen);
  b.add(Uint8List.view(samples.buffer, samples.offsetInBytes, dataLen));
  return b.toBytes();
}

/// Parses a simple PCM WAV into 16-bit mono samples + sample rate. If the file
/// is stereo, channel 0 is taken. Returns null if it isn't a 16-bit PCM WAV.
({Int16List samples, int rate})? parseWavPcm16(Uint8List b) {
  if (b.length < 44) return null;
  if (String.fromCharCodes(b.sublist(0, 4)) != 'RIFF' ||
      String.fromCharCodes(b.sublist(8, 12)) != 'WAVE') return null;
  int u32(int o) => b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);
  int u16(int o) => b[o] | (b[o + 1] << 8);

  var pos = 12, channels = 1, rate = 24000, bits = 16, dataPos = -1, dataLen = 0;
  while (pos + 8 <= b.length) {
    final id = String.fromCharCodes(b.sublist(pos, pos + 4));
    final size = u32(pos + 4);
    final body = pos + 8;
    if (id == 'fmt ') {
      channels = u16(body + 2);
      rate = u32(body + 4);
      bits = u16(body + 14);
    } else if (id == 'data') {
      dataPos = body;
      dataLen = size;
      break;
    }
    pos = body + size + (size & 1);
  }
  if (dataPos < 0 || bits != 16 || channels < 1) return null;

  final frameBytes = 2 * channels;
  final frames = (dataLen ~/ frameBytes).clamp(0, (b.length - dataPos) ~/ frameBytes);
  final out = Int16List(frames);
  var p = dataPos;
  for (var i = 0; i < frames; i++) {
    out[i] = (b[p] | (b[p + 1] << 8)).toSigned(16); // channel 0
    p += frameBytes;
  }
  return (samples: out, rate: rate);
}

/// [ms] of silence as 16-bit mono PCM at [rate].
Int16List silencePcm16(int rate, int ms) => Int16List(rate * ms ~/ 1000);
