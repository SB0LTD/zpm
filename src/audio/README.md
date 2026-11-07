# Native audio ingestion

All production modules are Sig and allocator-free. Input file mappings, decoder
state, output blocks and resampler state belong to the caller. No OS media
framework, FFmpeg, libavcodec, libopus, subprocess or foreign codec is used.

`mp4.Demux.open(mapped_bytes)` selects a structured AAC audio track and returns
borrowed packets from `next()`. Decode each packet with `aac.Decoder.decode`
into a 1024-sample mono float buffer, then pass it to the streaming
`resample.Resampler` at the track rate and 16000 Hz. Respect both `consumed` and
`produced`; finish the resampler once after the final packet. A decoder error is
terminal for that contiguous stream until reset. Capacity errors are retryable.
Keep one decoder and resampler across blocks: reinitializing at every Whisper
window would lose AAC overlap and resampling phase.

The current compressed path supports fragmented ISO BMFF with a single AAC-LC
audio track, 1024 samples per access unit, standard frequency indexes, and mono
or stereo. AAC supports all twelve normative Huffman codebooks, long and short
windows, sine and KBD window shapes, transitions, scalefactors, escape values,
pulse correction, M/S and intensity stereo, PNS and TNS. Stereo is averaged to
mono without clipping floating-point peaks. Container sample ranges and declared
track duration are checked, including truncation at a fragment boundary.

Unsupported input fails explicitly: nonfragmented MP4 sample tables, encrypted
tracks, multi-audio-track selection, AAC Main/SSR/LD/ELD, HE-AAC/SBR/PS,
960-sample frames, program configuration elements, coupling channels and more
than two compressed channels. Opus/WebM decoding is not implemented here; the
older `core/opus.sig` simplified residual codec is not a standards decoder and
must not process real Opus packets.

`wav.Wav.open` reads borrowed RIFF/WAVE PCM8/16/24/32 and IEEE float32/64,
including their WAVEFORMATEXTENSIBLE forms, up to eight channels. It validates
chunk padding, frame alignment, sample format and finite float samples. Mono
conversion averages channels. The resampler accepts 8000–192000 Hz and uses a
96-tap Kaiser-windowed sinc, interpolated phases and exact integer sample
cadence. Equal-rate conversion is an exact copy. Output length is
`ceil(input_samples * output_rate / input_rate)`; a centered filter uses zero
padding at the endpoints without adding delay samples to the timeline.

## Numeric data provenance

`aac_tables.sig` contains only interoperability constants: Huffman codewords
and lengths from ISO/IEC 13818-7 Annex A, plus the scalefactor-band boundaries
and TNS band limits required by ISO/IEC 14496-3. The constants were checked
against the standard publisher's Annex A sample and the official FFmpeg
numeric transcription in `libavcodec/aactab.c`. The retrieved reference SHA256
is recorded in the file. No third-party decoder implementation, control flow,
binary, library, optimized lookup layout or generated executable is included.
The tree representation and decoder algorithms are independently implemented
in Sig. Sine/KBD windows and inverse-quantization values are computed from their
mathematical definitions.

References: [AAC standard](https://www.iso.org/standard/76383.html),
[Annex A publisher sample](https://standards.theiteh.com/catalog/standards/iso/5d26a0bf-b3f4-4ddf-a640-1baf5b3bb85b/iso-iec-13818-7-1997),
[official numeric cross-check](https://github.com/FFmpeg/FFmpeg/blob/master/libavcodec/aactab.c).

## Validation on 2026-10-16

The complete downloaded lesson `7Cbr_W7I2Vg` was decoded natively from
`.gotliv/efficiency-public-audio.m4a`: 182108 AAC packets, 2466 frames using PNS,
19549 using TNS, and 186478592 source samples at 44100 Hz. Resampling produced
67656633 finite mono samples at 16000 Hz, or 4228.5395625 seconds. The resulting
float WAV has 270626576 bytes and SHA256
`02e55763fd1ab9aa4a3e1432cafbb5fc5be2f4bb783e65a2491db9a3769b9600`.
Peak magnitude is 1.041784 and RMS is 0.101262; float peaks are preserved.

One ReleaseFast run including mapping, decoding, resampling and WAV I/O took
23.360 seconds, approximately 181 times the media duration. This is one local
observation, not a cross-machine performance guarantee. Independent `ffprobe`
inspection confirmed float PCM, mono, 16000 Hz and the exact duration/size.

The first 1300 packets (30.19 seconds) were compared with development-only
FFmpeg float PCM. The 1233 frames unaffected by PNS or its overlap history had
135.7 dB SNR and maximum absolute error 2.09e-7; TNS frames had 135.8 dB SNR.
PNS intentionally uses an independent deterministic noise generator, so those
samples need not equal another decoder's random realization. Overall waveform
correlation was 0.99992159 with matched gain. Huffman tests exhaust every
normative codeword; malformed-packet tests include truncations, fill escapes,
arbitrary alignment bits and a deterministic 2048-packet corpus.

The manually run `media_file_test.sig` and `decode_file_test.sig` use native
read-only file mappings and hardcoded local fixtures. They are diagnostics,
not production entrypoints or portable unit-test requirements.
