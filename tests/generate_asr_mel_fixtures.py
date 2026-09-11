"""Optional reference generation; no Python dependency in the native runtime.

uv run --no-project --with numpy==2.3.3 --with transformers==4.57.6 python tests/generate_asr_mel_fixtures.py
Uses the exact WhisperFeatureExtractor selected by Qwen3-ASR-0.6B's processor.
"""
import hashlib
import json
from pathlib import Path
import numpy as np
import transformers
from transformers import WhisperFeatureExtractor

assert np.__version__ == '2.3.3'
assert transformers.__version__ == '4.57.6'
out = Path(__file__).parent / 'fixtures' / 'asr-mel'
out.mkdir(parents=True, exist_ok=True)
extractor = WhisperFeatureExtractor(feature_size=128, sampling_rate=16000, n_fft=400, hop_length=160, dither=0)
t = np.arange(3207, dtype=np.float64) / 16000
impulse = np.zeros(801, dtype=np.float32)
impulse[[0, 73, 799, 800]] = [1, -0.75, 0.5, -0.25]
rng = np.random.Generator(np.random.PCG64(73091))
cases = {
    'silence': np.zeros(320, dtype=np.float32),
    'short-dc': np.full(201, 0.125, dtype=np.float32),
    'impulses': impulse,
    'tones': (0.3 * np.sin(2 * np.pi * 997.3 * t) + 0.1 * np.cos(2 * np.pi * 3100.7 * t)).astype(np.float32),
    'noise': rng.uniform(-0.8, 0.8, 1601).astype(np.float32),
    'quiet': rng.uniform(-1e-7, 1e-7, 641).astype(np.float32),
    'ramp': np.linspace(-1, 1, 479, dtype=np.float32),
}
manifest = {'reference': 'transformers 4.57.6 WhisperFeatureExtractor._np_extract_fbank_features', 'numpy': np.__version__, 'layout': 'frame-major f32le', 'absolute_tolerance': 2e-5, 'cases': []}
for name, audio in cases.items():
    features = extractor._np_extract_fbank_features(audio[None, :], 'cpu')[0].T.astype('<f4')
    assert features.shape == (len(audio) // 160, 128)
    pcm_bytes = audio.astype('<f4').tobytes()
    feature_bytes = features.tobytes()
    (out / f'{name}.pcm').write_bytes(pcm_bytes)
    (out / f'{name}.mel').write_bytes(feature_bytes)
    manifest['cases'].append({'name': name, 'samples': len(audio), 'frames': features.shape[0], 'pcm_sha256': hashlib.sha256(pcm_bytes).hexdigest(), 'mel_sha256': hashlib.sha256(feature_bytes).hexdigest()})
(out / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(f'Generated {len(cases)} independent frontend fixtures')
