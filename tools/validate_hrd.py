#!/usr/bin/env python3
"""Compare native HRD against the supplied Python source without importing its UI.
Usage: python3 tools/validate_hrd.py /path/to/orbit_HRD [native-library]
Requires NumPy/SciPy only for this development check, never for the app.
"""
import ast
import ctypes as C
from pathlib import Path
import sys
from types import SimpleNamespace
import numpy as np
from scipy import signal
from scipy.signal import savgol_filter

source = Path(sys.argv[1])
lib_path = sys.argv[2] if len(sys.argv) > 2 else 'rust/target/debug/libtrain_nidra_core.dylib'
lib = C.CDLL(str(Path(lib_path).resolve()))
def extract(file, name, env):
    tree = ast.parse((source / file).read_text())
    node = next(n for n in tree.body if getattr(n, 'name', None) == name)
    exec(compile(ast.Module(body=[node], type_ignores=[]), file, 'exec'), env)
    return env[name]
Psi = extract('ccs_hrd.py', 'LogisticPsiHandler', {'np': np})
lib.tn_hrd_create.restype = C.c_void_p
lib.tn_hrd_next.argtypes = [C.c_void_p];lib.tn_hrd_next.restype = C.c_double
lib.tn_hrd_update.argtypes = [C.c_void_p, C.c_double, C.c_int];lib.tn_hrd_update.restype=C.c_bool
lib.tn_hrd_estimate.argtypes=[C.c_void_p,C.POINTER(C.c_double)];lib.tn_hrd_estimate.restype=C.c_bool
lib.tn_hrd_free.argtypes=[C.c_void_p]
p = lib.tn_hrd_create()
ref = Psi(np.arange(-50.5, 51.5, 1), (-50.5, 50.5), (0.1, 10), gamma=0, delta=0.05, n_alpha_steps=102, n_beta_steps=100)
try:
    first = lib.tn_hrd_next(p); assert first == float(ref.getNextStim()), (first,ref.getNextStim())
    for i in range(25):
        stim = float(ref.getNextStim())
        native = lib.tn_hrd_next(p)
        if i > 0: assert native == stim, (i, native, stim)
        response = int(stim > 7 or i % 5 == 0)
        expected = ref.update_psi(stim, response)
        assert lib.tn_hrd_update(p, stim, response)
        out = (C.c_double * 4)();assert lib.tn_hrd_estimate(p, out)
        np.testing.assert_allclose(list(out)[:3], expected, atol=1e-10)
        np.testing.assert_allclose(out[3], ref.get_current_estimate()['beta'], atol=1e-10)
finally: lib.tn_hrd_free(p)
print('Psi: 25 posterior updates, bounds, slopes and adaptive stimuli match the source.')

ppg = extract('ccs_hrd_utilities.py', 'ppg_process_custom', {'np':np,'signal':signal,'savgol_filter':savgol_filter,'pd':SimpleNamespace(DataFrame=lambda x:x)})
lib.tn_hrd_analyze.argtypes=[C.POINTER(C.c_double),C.c_size_t,C.c_double,C.c_bool,C.POINTER(C.c_double),C.POINTER(C.c_double),C.POINTER(C.c_double)]
lib.tn_hrd_analyze.restype=C.c_bool
for fs in [62.5,125,250]:
    t=np.arange(int(15*fs))/fs
    raw=np.ascontiguousarray(100+np.sin(2*np.pi*1.2*t)+0.1*np.sin(2*np.pi*2.4*t)+0.01*np.random.default_rng(2).normal(size=len(t)))
    expected, info=ppg(raw,fs)
    clean=np.zeros_like(raw);peaks=np.zeros_like(raw);stats=np.zeros(5)
    pointer=lambda x:x.ctypes.data_as(C.POINTER(C.c_double))
    assert lib.tn_hrd_analyze(pointer(raw),len(raw),fs,False,pointer(clean),pointer(peaks),pointer(stats))
    np.testing.assert_allclose(clean,expected['PPG_Clean'],atol=2e-6)
    np.testing.assert_array_equal(np.flatnonzero(peaks),info['PPG_Peaks'])
    np.testing.assert_allclose(stats[0],info['avg_heart_rate'],atol=1e-10)
print('PPG: cleaned signals, peaks and BPM match at 62.5, 125 and 250 Hz.')

# Compare the explicitly supported source ECG fallback (NeuroKit2 absent).
for fs in [125,250]:
    t=np.arange(int(15*fs))/fs;phase=t%(60/72)
    raw=np.ascontiguousarray(1000*np.exp(-((phase-0.2)/0.012)**2)-150*np.exp(-((phase-0.23)/0.02)**2)+30*np.sin(2*np.pi*0.2*t))
    b,a=signal.butter(2,[0.5/(fs/2),40/(fs/2)],btype='bandpass')
    expected=signal.filtfilt(b,a,raw)
    expected_peaks,_=signal.find_peaks(expected,distance=fs*0.4,height=np.mean(np.abs(expected)))
    cleaned=np.zeros_like(raw);peaks=np.zeros_like(raw);stats=np.zeros(5)
    assert lib.tn_hrd_analyze(pointer(raw),len(raw),fs,True,pointer(cleaned),pointer(peaks),pointer(stats))
    np.testing.assert_allclose(cleaned,expected,atol=2e-6)
    np.testing.assert_array_equal(np.flatnonzero(peaks),expected_peaks)
    np.testing.assert_allclose(stats[0],np.mean(60/(np.diff(expected_peaks)/fs)),atol=1e-10)
print('ECG fallback: cleaned signal, R peaks and mean BPM match at 125 and 250 Hz.')

import wave
lib.tn_hrd_audio.argtypes=[C.c_double,C.c_double,C.POINTER(C.c_int16),C.c_size_t];lib.tn_hrd_audio.restype=C.c_size_t
for bpm in [15,60,72.5,120,199.5]:
    with wave.open(str(source/'ExptResources'/'Sounds'/f'{bpm:.1f}.wav')) as w:
        expected=np.frombuffer(w.readframes(w.getnframes()),dtype='<i2')
    actual=np.zeros(len(expected),dtype='<i2')
    assert lib.tn_hrd_audio(bpm,len(expected)/44100,actual.ctypes.data_as(C.POINTER(C.c_int16)),len(actual))==len(actual)
    np.testing.assert_allclose(actual,expected,atol=1)
print('Audio: synthesized PCM matches representative original WAV files within one PCM count.')
