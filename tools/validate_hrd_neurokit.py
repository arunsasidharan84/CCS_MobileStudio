#!/usr/bin/env python3
"""Parity test for task-consumed NeuroKit2 0.2.12 ECG outputs.
Run with NeuroKit2 0.2.12 available on PYTHONPATH; it is a test-only dependency.
Usage: python3 tools/validate_hrd_neurokit.py [native-library]
"""
import ctypes as C
from pathlib import Path
import sys
import numpy as np
import neurokit2 as nk
import warnings
import importlib
warnings.filterwarnings("ignore", category=Warning, module=r"neurokit2\..*")

assert nk.__version__ == '0.2.12', f'Expected pinned NeuroKit2 0.2.12, found {nk.__version__}'
lib=C.CDLL(str(Path(sys.argv[1] if len(sys.argv)>1 else 'rust/target/debug/libtrain_nidra_core.dylib').resolve()))
ptr=lambda x:x.ctypes.data_as(C.POINTER(C.c_double))
lib.tn_hrd_ecg_neurokit.argtypes=[C.POINTER(C.c_double),C.c_size_t,C.c_double,C.POINTER(C.c_double),C.POINTER(C.c_double),C.POINTER(C.c_double),C.POINTER(C.c_double)]
lib.tn_hrd_ecg_neurokit.restype=C.c_bool
lib.tn_hrd_ecg_correct.argtypes=[C.POINTER(C.c_double),C.c_size_t,C.c_double,C.POINTER(C.c_double),C.c_size_t]
lib.tn_hrd_ecg_correct.restype=C.c_size_t
max_clean=0;max_rate=0;cases=0
for fs in [125,250,500,1000]:
    for hr in [45,72,120]:
        for noise in [0,0.03]:
            raw=np.ascontiguousarray(nk.ecg_simulate(duration=16,sampling_rate=fs,heart_rate=hr,noise=noise,random_state=42))
            t=np.arange(len(raw))/fs
            raw+=0.15*np.sin(2*np.pi*0.2*t)+0.03*np.sin(2*np.pi*50*t)+0.5
            # This is the exact Python runner's entry point, including artifact correction.
            expected,info=nk.bio_process(raw,sampling_rate=fs)
            clean=np.zeros_like(raw);peaks=np.zeros_like(raw);rates=np.zeros_like(raw);stats=np.zeros(5)
            assert lib.tn_hrd_ecg_neurokit(ptr(raw),len(raw),fs,ptr(clean),ptr(peaks),ptr(rates),ptr(stats))
            max_clean=max(max_clean,float(np.max(np.abs(clean-expected.ECG_Clean))))
            max_rate=max(max_rate,float(np.max(np.abs(rates-expected.ECG_Rate))))
            np.testing.assert_allclose(clean,expected.ECG_Clean,atol=2e-8,rtol=1e-9,err_msg=f'clean fs={fs} hr={hr} noise={noise}')
            np.testing.assert_array_equal(peaks,expected.ECG_R_Peaks,err_msg=f'peaks fs={fs} hr={hr} noise={noise}')
            np.testing.assert_allclose(rates,expected.ECG_Rate,atol=1e-9,rtol=1e-10,err_msg=f'rate fs={fs} hr={hr} noise={noise}')
            np.testing.assert_allclose(stats[0],expected.ECG_Rate.mean(),atol=1e-9)
            cases+=1
print(f'NeuroKit2 full bio_process entry: {cases} ECG cases; max cleaned error {max_clean:.3g}, max rate error {max_rate:.3g} BPM.')

# Exercise correction independently, including extra, missed, ectopic and long/short beats.
rng=np.random.default_rng(2);tested=0;classes=set()
for fs in [125,250,500]:
    for seed in range(60):
        intervals=rng.normal(fs*0.8,fs*0.04,100).astype(int)
        original=np.cumsum(intervals)
        p=original.copy()
        if seed%4==0:p=np.delete(p,[10,35])
        if seed%4==1:p=np.sort(np.insert(p,[10,35],[p[10]-int(fs*.4),p[35]-int(fs*.4)]))
        if seed%4==2:p[10]+=int(fs*.25);p[35]-=int(fs*.25)
        if seed%4==3:p[10]+=int(fs*.15);p[11]+=int(fs*.15)
        info,expected=nk.signal_fixpeaks(p,sampling_rate=fs,method='Kubios',iterative=True)
        for key in ['extra','missed','ectopic','longshort']:
            if info[key]:classes.add(key)
        source=np.ascontiguousarray(p,dtype=float);out=np.zeros(len(p)*2,dtype=float)
        count=lib.tn_hrd_ecg_correct(ptr(source),len(source),fs,ptr(out),len(out))
        np.testing.assert_array_equal(out[:count],expected,err_msg=f'artifact fs={fs} seed={seed}')
        tested+=1

# Additional short false-positive intervals specifically exercise the extra class.
find=importlib.import_module('neurokit2.signal.signal_fixpeaks')._find_artifacts
rng=np.random.default_rng(3)
for case in range(30):
    p=np.cumsum(rng.normal(200,20,100).astype(int));i=20
    p=np.sort(np.append(p,p[i-1]+rng.integers(15,170)))
    first,_=find(p,sampling_rate=250)
    for key in ['extra','missed','ectopic','longshort']:
        if first[key]:classes.add(key)
    _,expected=nk.signal_fixpeaks(p,sampling_rate=250,method='Kubios',iterative=True)
    source=np.ascontiguousarray(p,dtype=float);out=np.zeros(len(p)*2,dtype=float)
    count=lib.tn_hrd_ecg_correct(ptr(source),len(source),250,ptr(out),len(out))
    np.testing.assert_array_equal(out[:count],expected);tested+=1
assert classes=={'extra','missed','ectopic','longshort'},classes
print(f'Kubios: {tested} contaminated peak sequences match exactly; classes exercised: {sorted(classes)}.')

for raw in [np.zeros(4000),np.full(4000,1000.0)]:
    raw=np.ascontiguousarray(raw);clean=np.zeros_like(raw);peaks=np.zeros_like(raw);rates=np.zeros_like(raw);stats=np.zeros(5)
    assert lib.tn_hrd_ecg_neurokit(ptr(raw),len(raw),250,ptr(clean),ptr(peaks),ptr(rates),ptr(stats))
    assert np.isnan(stats[0]) and not peaks.any()
print('Flatline: unavailable HR, no false stimulus baseline.')
