//! Bayesian heart-rate discrimination. No additional runtime dependencies.
use std::f64::consts::PI;
use std::ptr;

pub struct Psi {
    posterior: Vec<f64>,
    updates: usize,
}
impl Psi {
    pub fn new() -> Self {
        Self {
            posterior: vec![1.0 / 10200.0; 10200],
            updates: 0,
        }
    }
    fn likelihood(stim: f64, a: usize, b: usize) -> f64 {
        let alpha = -50.5 + a as f64;
        let beta = 0.1 + b as f64 * 0.1;
        0.95 / (1.0 + (-beta * (stim - alpha)).clamp(-20.0, 20.0).exp())
    }
    pub fn next(&self) -> f64 {
        let mut best = (f64::INFINITY, -50.5);
        for s in 0..102 {
            let stim = -50.5 + s as f64;
            let mut yes = [0.0; 102];
            let mut no = [0.0; 102];
            for b in 0..100 {
                for a in 0..102 {
                    let p = self.posterior[b * 102 + a];
                    let l = Self::likelihood(stim, a, b).clamp(1e-9, 1.0 - 1e-9);
                    yes[a] += p * l;
                    no[a] += p * (1.0 - l);
                }
            }
            let py: f64 = yes.iter().sum();
            let pn: f64 = no.iter().sum();
            let entropy = |v: &[f64], z: f64| {
                v.iter()
                    .filter(|x| **x > 0.0)
                    .map(|x| {
                        let p = x / z;
                        -p * p.log2()
                    })
                    .sum::<f64>()
            };
            let h = py.clamp(1e-9, 1.0 - 1e-9) * entropy(&yes, py)
                + pn.clamp(1e-9, 1.0 - 1e-9) * entropy(&no, pn);
            if h < best.0 {
                best = (h, stim);
            }
        }
        best.1
    }
    pub fn update(&mut self, stim: f64, faster: bool) {
        for b in 0..100 {
            for a in 0..102 {
                let l = Self::likelihood(stim, a, b);
                self.posterior[b * 102 + a] *=
                    (if faster { l } else { 1.0 - l }).clamp(1e-9, 1.0 - 1e-9);
            }
        }
        let z: f64 = self.posterior.iter().sum();
        for p in &mut self.posterior {
            *p /= z;
        }
        self.updates += 1;
    }
    pub fn estimate(&self) -> [f64; 4] {
        if self.updates == 0 {
            return [f64::NAN; 4];
        }
        let mut a = 0.0;
        let mut b = 0.0;
        let mut a2 = 0.0;
        for bi in 0..100 {
            for ai in 0..102 {
                let p = self.posterior[bi * 102 + ai];
                let x = ai as f64 - 50.5;
                a += p * x;
                a2 += p * x * x;
                b += p * (0.1 + bi as f64 * 0.1);
            }
        }
        let half = (a2 - a * a).max(0.0).sqrt() / 2.0;
        [a, a - half, a + half, b]
    }
}
#[no_mangle]
pub extern "C" fn tn_hrd_create() -> *mut Psi {
    Box::into_raw(Box::new(Psi::new()))
}
#[no_mangle]
pub unsafe extern "C" fn tn_hrd_free(p: *mut Psi) {
    if !p.is_null() {
        drop(Box::from_raw(p));
    }
}
#[no_mangle]
pub unsafe extern "C" fn tn_hrd_next(p: *const Psi) -> f64 {
    p.as_ref().map_or(f64::NAN, |p| p.next())
}
#[no_mangle]
pub unsafe extern "C" fn tn_hrd_update(p: *mut Psi, s: f64, r: i32) -> bool {
    if !s.is_finite() || !(0..=1).contains(&r) {
        return false;
    }
    if let Some(p) = p.as_mut() {
        p.update(s, r == 1);
        true
    } else {
        false
    }
}
#[no_mangle]
pub unsafe extern "C" fn tn_hrd_estimate(p: *const Psi, out: *mut f64) -> bool {
    if let Some(p) = p.as_ref() {
        if !out.is_null() {
            ptr::copy_nonoverlapping(p.estimate().as_ptr(), out, 4);
            return true;
        }
    }
    false
}

fn quantile(v: &[f64], q: f64) -> f64 {
    let x = (v.len() - 1) as f64 * q;
    let i = x.floor() as usize;
    v[i] + (v[x.ceil() as usize] - v[i]) * (x - i as f64)
}
fn convolve(a: &[f64], b: &[f64]) -> Vec<f64> {
    let mut o = vec![0.0; a.len() + b.len() - 1];
    for (i, x) in a.iter().enumerate() {
        for (j, y) in b.iter().enumerate() {
            o[i + j] += x * y;
        }
    }
    o
}
fn power(v: &[f64], n: usize) -> Vec<f64> {
    let mut p = vec![1.0];
    for _ in 0..n {
        p = convolve(&p, v);
    }
    p
}
// scipy.signal.butter(2, [low, high], btype='bandpass'), bilinear transform.
fn butter(fs: f64, hi: f64) -> (Vec<f64>, Vec<f64>) {
    let lo = 2.0 * fs * (PI * 0.5 / fs).tan();
    let hi = 2.0 * fs * (PI * hi / fs).tan();
    let bw = hi - lo;
    let w = lo * hi;
    let k = 2.0 * fs;
    let analog = [
        w * w,
        2.0_f64.sqrt() * bw * w,
        2.0 * w + bw * bw,
        2.0_f64.sqrt() * bw,
        1.0,
    ];
    let mut a = vec![0.0; 5];
    let mut b = vec![0.0; 5];
    for (i, c) in analog.iter().enumerate() {
        let p = convolve(&power(&[1.0, -1.0], i), &power(&[1.0, 1.0], 4 - i));
        for j in 0..5 {
            a[j] += c * k.powi(i as i32) * p[j];
            if i == 2 {
                b[j] = bw * bw * k * k * p[j];
            }
        }
    }
    let z = a[0];
    for x in &mut a {
        *x /= z;
    }
    for x in &mut b {
        *x /= z;
    }
    (b, a)
}
fn filter(x: &[f64], b: &[f64], a: &[f64]) -> Vec<f64> {
    let gain = b.iter().sum::<f64>() / a.iter().sum::<f64>();
    let mut zi = vec![0.0; 4];
    for i in 0..4 {
        zi[i] = (b[i + 1..].iter().sum::<f64>() - gain * a[i + 1..].iter().sum::<f64>()) * x[0];
    }
    let mut out = Vec::with_capacity(x.len());
    for &x in x {
        let y = b[0] * x + zi[0];
        for i in 0..3 {
            zi[i] = b[i + 1] * x + zi[i + 1] - a[i + 1] * y;
        }
        zi[3] = b[4] * x - a[4] * y;
        out.push(y);
    }
    out
}
fn clean(x: &[f64], fs: f64, ecg: bool) -> Vec<f64> {
    let mean = x.iter().sum::<f64>() / x.len() as f64;
    let mut v: Vec<f64> = x.iter().map(|x| x - mean).collect();
    if !ecg {
        let original = v.clone();
        for i in 0..v.len() {
            let mut t = [
                if i > 0 { original[i - 1] } else { 0.0 },
                original[i],
                original.get(i + 1).copied().unwrap_or(0.0),
            ];
            t.sort_by(f64::total_cmp);
            v[i] = t[1];
        }
    }
    let (b, a) = butter(fs, if ecg { 40.0_f64.min(fs * 0.45) } else { 10.0 });
    let pad = 15;
    let mut ext: Vec<f64> = (1..=pad).rev().map(|i| 2.0 * v[0] - v[i]).collect();
    ext.extend(&v);
    ext.extend((1..=pad).map(|i| 2.0 * v[v.len() - 1] - v[v.len() - 1 - i]));
    let mut y = filter(&ext, &b, &a);
    y.reverse();
    y = filter(&y, &b, &a);
    y.reverse();
    v = y[pad..pad + x.len()].to_vec();
    if !ecg {
        let mut win = (fs / 4.0) as usize;
        if win % 2 == 0 {
            win += 1;
        }
        win = win.max(3);
        if v.len() > win {
            let m = (win / 2) as isize;
            let original = v.clone();
            let mf = m as f64;
            let denom = (2.0 * mf + 1.0) * (4.0 * mf * mf + 4.0 * mf - 3.0);
            for i in win / 2..v.len() - win / 2 {
                v[i] = (-m..=m)
                    .map(|j| {
                        (3.0 * (3.0 * mf * mf + 3.0 * mf - 1.0) - 15.0 * (j * j) as f64) / denom
                            * original[(i as isize + j) as usize]
                    })
                    .sum();
            }
            let fit = |slice: &[f64]| {
                let n = win as f64;
                let s2 = (-m..=m).map(|j| (j * j) as f64).sum::<f64>();
                let s4 = (-m..=m).map(|j| (j * j * j * j) as f64).sum::<f64>();
                let sy = slice.iter().sum::<f64>();
                let sj = slice
                    .iter()
                    .enumerate()
                    .map(|(i, y)| (i as f64 - mf) * y)
                    .sum::<f64>();
                let sj2 = slice
                    .iter()
                    .enumerate()
                    .map(|(i, y)| (i as f64 - mf).powi(2) * y)
                    .sum::<f64>();
                let d = n * s4 - s2 * s2;
                [(sy * s4 - sj2 * s2) / d, sj / s2, (n * sj2 - s2 * sy) / d]
            };
            let left = fit(&original[..win]);
            let right = fit(&original[original.len() - win..]);
            for i in 0..win / 2 {
                let j = i as f64 - mf;
                v[i] = left[0] + left[1] * j + left[2] * j * j;
                let k = win - 1 - i;
                let j = k as f64 - mf;
                let n = v.len();
                v[n - 1 - i] = right[0] + right[1] * j + right[2] * j * j;
            }
        }
    }
    v
}
/// Output: avg BPM, robust MAD, HRV score, sample entropy, peak count.
#[no_mangle]
pub unsafe extern "C" fn tn_hrd_analyze(
    input: *const f64,
    n: usize,
    fs: f64,
    ecg: bool,
    cleaned: *mut f64,
    peaks: *mut f64,
    out: *mut f64,
) -> bool {
    if input.is_null()
        || cleaned.is_null()
        || peaks.is_null()
        || out.is_null()
        || !(32..=300000).contains(&n)
        || !fs.is_finite()
        || fs <= 22.0
    {
        return false;
    }
    let x = std::slice::from_raw_parts(input, n);
    if x.iter().any(|x| !x.is_finite()) {
        return false;
    }
    let y = clean(x, fs, ecg);
    ptr::copy_nonoverlapping(y.as_ptr(), cleaned, n);
    ptr::write_bytes(peaks, 0, n);
    let threshold = if ecg {
        y.iter().map(|x| x.abs()).sum::<f64>() / n as f64
    } else {
        y.iter().sum::<f64>() / n as f64
    };
    let mut candidates: Vec<usize> = (1..n - 1)
        .filter(|&i| y[i] > y[i - 1] && y[i] >= y[i + 1] && y[i] >= threshold)
        .collect();
    candidates.sort_by(|&a, &b| y[b].total_cmp(&y[a]));
    let mut selected: Vec<usize> = Vec::new();
    for i in candidates {
        if selected.iter().all(|&j| i.abs_diff(j) as f64 >= fs * 0.4) {
            selected.push(i);
        }
    }
    selected.sort_unstable();
    for &i in &selected {
        *peaks.add(i) = 1.0;
    }
    let mut rr: Vec<f64> = selected
        .windows(2)
        .map(|w| (w[1] - w[0]) as f64 * 1000.0 / fs)
        .filter(|x| ecg || (*x > 300.0 && *x < 2000.0))
        .collect();
    if !ecg && !rr.is_empty() {
        let mut sorted = rr.clone();
        sorted.sort_by(f64::total_cmp);
        let q1 = quantile(&sorted, 0.25);
        let q3 = quantile(&sorted, 0.75);
        let d = 2.0 * (q3 - q1);
        rr.retain(|x| *x >= q1 - d && *x <= q3 + d);
    }
    let bpm: Vec<f64> = rr.iter().map(|x| 60000.0 / x).collect();
    let mean = if bpm.is_empty() {
        f64::NAN
    } else {
        bpm.iter().sum::<f64>() / bpm.len() as f64
    };
    // The runner computes HRV diagnostics from all detected intervals,
    // while custom PPG mean HR uses range/IQR-filtered intervals.
    let diagnostic_bpm: Vec<f64> = selected
        .windows(2)
        .map(|w| 60.0 * fs / (w[1] - w[0]) as f64)
        .collect();
    let mut sorted = diagnostic_bpm.clone();
    sorted.sort_by(f64::total_cmp);
    let mad = if selected.len() < 3 {
        f64::NAN
    } else {
        let med = quantile(&sorted, 0.5);
        let mut dev: Vec<f64> = sorted.iter().map(|x| (x - med).abs()).collect();
        dev.sort_by(f64::total_cmp);
        quantile(&dev, 0.5) * 1.4826
    };
    let en = if selected.len() < 3 {
        f64::NAN
    } else {
        sample_entropy(&diagnostic_bpm)
    };
    let stats = [mean, mad, mad * 100.0 / 12.0, en, selected.len() as f64];
    ptr::copy_nonoverlapping(stats.as_ptr(), out, 5);
    true
}
fn sample_entropy(x: &[f64]) -> f64 {
    let n = x.len();
    if n < 3 {
        return f64::NAN;
    }
    let mean = x.iter().sum::<f64>() / n as f64;
    let sd = (x.iter().map(|v| (v - mean).powi(2)).sum::<f64>() / n as f64).sqrt();
    if sd == 0.0 {
        return 0.0;
    }
    let count = |m: usize| {
        let mut c = 0;
        for i in 0..=n - m {
            for j in i + 1..=n - m {
                if (0..m).all(|k| (x[i + k] - x[j + k]).abs() <= 0.2 * sd) {
                    c += 1;
                }
            }
        }
        c as f64
    };
    let c2 = count(2);
    let c3 = count(3);
    if c2 == 0.0 || c3 == 0.0 || n <= 4 {
        return 0.0;
    }
    -((c3 / ((n - 3) * (n - 4)) as f64) / (c2 / ((n - 2) * (n - 3)) as f64)).ln()
}
/// Generate a complete periodic stimulus in Rust; avoids per-beat Dart timers.
#[no_mangle]
pub unsafe extern "C" fn tn_hrd_audio(
    bpm: f64,
    seconds: f64,
    out: *mut i16,
    capacity: usize,
) -> usize {
    if !bpm.is_finite()
        || !(15.0..=199.5).contains(&bpm)
        || !seconds.is_finite()
        || !(0.0..=30.0).contains(&seconds)
    {
        return 0;
    }
    let n = (seconds * 44100.0).ceil() as usize;
    if out.is_null() {
        return n;
    }
    if capacity < n {
        return 0;
    }
    let period = (60.0 / bpm * 44100.0) as usize;
    for i in 0..n {
        let pos = i % period;
        *out.add(i) = if pos < 8820 && i < period * 10 {
            ((2.0 * PI * 440.0 * pos as f64 / 44100.0).sin() * 16383.5) as i16
        } else {
            0
        };
    }
    n
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn posterior_normalizes() {
        let mut p = Psi::new();
        for i in 0..100 {
            p.update(if i % 2 == 0 { 5.5 } else { -4.5 }, i % 2 == 0);
        }
        assert!((p.posterior.iter().sum::<f64>() - 1.0).abs() < 1e-12);
        let e = p.estimate();
        assert!(e.iter().all(|x| x.is_finite()));
        assert!(e[1] <= e[0] && e[0] <= e[2]);
    }
    #[test]
    fn faster_responses_shift_threshold_down() {
        let mut p = Psi::new();
        p.update(0.5, true);
        assert!(p.estimate()[0] < 0.0);
    }
    #[test]
    fn synthetic_ppg() {
        let fs = 62.5;
        let x: Vec<f64> = (0..1000)
            .map(|i| (2.0 * PI * 1.2 * i as f64 / fs).sin() + 100.0)
            .collect();
        let mut clean = vec![0.0; x.len()];
        let mut peaks = clean.clone();
        let mut out = [0.0; 5];
        assert!(unsafe {
            tn_hrd_analyze(
                x.as_ptr(),
                x.len(),
                fs,
                false,
                clean.as_mut_ptr(),
                peaks.as_mut_ptr(),
                out.as_mut_ptr(),
            )
        });
        assert!((out[0] - 72.0).abs() < 1.0, "{:?}", out);
    }
}

/// Explicit demonstration input, never substituted for missing hardware data.
#[no_mangle]
pub unsafe extern "C" fn tn_hrd_simulate(
    fs: f64,
    seconds: f64,
    ecg: bool,
    out: *mut f64,
    capacity: usize,
) -> usize {
    if !fs.is_finite()
        || !(22.0..=1000.0).contains(&fs)
        || !seconds.is_finite()
        || !(1.0..=120.0).contains(&seconds)
    {
        return 0;
    }
    let n = (fs * seconds).ceil() as usize + 1;
    if out.is_null() {
        return n;
    }
    if capacity < n {
        return 0;
    }
    for i in 0..n {
        let t = i as f64 / fs;
        let p = t % (60.0 / 72.0);
        *out.add(i) = if ecg {
            1000.0 * (-((p - 0.2) / 0.012).powi(2)).exp()
                - 150.0 * (-((p - 0.23) / 0.02).powi(2)).exp()
                + 30.0 * (2.0 * PI * 0.2 * t).sin()
        } else {
            100.0 + 20.0 * (2.0 * PI * 1.2 * t).sin() + 2.0 * (2.0 * PI * 2.4 * t).sin()
        };
    }
    n
}

#[no_mangle]
pub unsafe extern "C" fn tn_hrd_rates(
    peaks: *const f64,
    n: usize,
    fs: f64,
    mean: f64,
    ecg: bool,
    out: *mut f64,
) -> bool {
    if peaks.is_null() || out.is_null() || n == 0 || n > 300000 || !fs.is_finite() || fs <= 0.0 {
        return false;
    }
    let mask = std::slice::from_raw_parts(peaks, n);
    let indices: Vec<usize> = mask
        .iter()
        .enumerate()
        .filter(|(_, p)| **p > 0.0)
        .map(|(i, _)| i)
        .collect();
    if !ecg || indices.len() < 2 {
        for i in 0..n {
            *out.add(i) = mean;
        }
        return true;
    }
    let rates: Vec<f64> = indices
        .windows(2)
        .map(|w| 60.0 * fs / (w[1] - w[0]) as f64)
        .collect();
    let mut j = 0;
    for i in 0..n {
        while j + 1 < rates.len() && i > indices[j + 1] {
            j += 1;
        }
        *out.add(i) = if i <= indices[0] {
            rates[0]
        } else if j + 1 >= rates.len() {
            rates[j]
        } else {
            let f = (i - indices[j]) as f64 / (indices[j + 1] - indices[j]) as f64;
            rates[j] + f * (rates[j + 1] - rates[j])
        };
    }
    true
}

/// Native NeuroKit2 ECG branch. Retains legacy tn_hrd_analyze for replay.
#[no_mangle]
pub unsafe extern "C" fn tn_hrd_ecg_neurokit(
    input: *const f64,
    n: usize,
    fs: f64,
    cleaned: *mut f64,
    peaks: *mut f64,
    rates: *mut f64,
    out: *mut f64,
) -> bool {
    if input.is_null()
        || cleaned.is_null()
        || peaks.is_null()
        || rates.is_null()
        || out.is_null()
        || !(32..=300000).contains(&n)
        || !fs.is_finite()
        || !(25.0..=5000.0).contains(&fs)
    {
        return false;
    }
    let x = std::slice::from_raw_parts(input, n);
    if x.iter().any(|v| !v.is_finite()) {
        return false;
    }
    let y = match crate::hrd_ecg::clean(x, fs) {
        Some(v) => v,
        None => return false,
    };
    let raw_peaks = crate::hrd_ecg::detect(&y, fs);
    let selected = crate::hrd_ecg::correct(&raw_peaks, fs);
    let rate = crate::hrd_ecg::rate(&selected, fs, n);
    ptr::copy_nonoverlapping(y.as_ptr(), cleaned, n);
    ptr::copy_nonoverlapping(rate.as_ptr(), rates, n);
    ptr::write_bytes(peaks, 0, n);
    for &i in &selected {
        if i < n {
            *peaks.add(i) = 1.0;
        }
    }
    let mean = rate.iter().sum::<f64>() / n as f64;
    let bpm: Vec<f64> = selected
        .windows(2)
        .map(|w| 60.0 * fs / (w[1] - w[0]) as f64)
        .collect();
    let mad = if selected.len() < 3 {
        f64::NAN
    } else {
        let med = quantile(
            &{
                let mut v = bpm.clone();
                v.sort_by(f64::total_cmp);
                v
            },
            0.5,
        );
        let mut dev: Vec<f64> = bpm.iter().map(|x| (x - med).abs()).collect();
        dev.sort_by(f64::total_cmp);
        quantile(&dev, 0.5) * 1.4826
    };
    let en = if selected.len() < 3 {
        f64::NAN
    } else {
        sample_entropy(&bpm)
    };
    let stats = [mean, mad, mad * 100.0 / 12.0, en, selected.len() as f64];
    ptr::copy_nonoverlapping(stats.as_ptr(), out, 5);
    true
}
/// Testable pure stages, also available to offline cardiac validation tools.
#[no_mangle]
pub unsafe extern "C" fn tn_hrd_ecg_correct(
    input: *const f64,
    n: usize,
    fs: f64,
    out: *mut f64,
    capacity: usize,
) -> usize {
    if input.is_null() || out.is_null() || n == 0 || n > 20000 || !fs.is_finite() || fs <= 0.0 {
        return 0;
    }
    let x = std::slice::from_raw_parts(input, n);
    if x.iter()
        .any(|v| !v.is_finite() || *v < 0.0 || *v > (usize::MAX / 4) as f64)
        || x.windows(2).any(|w| w[1] <= w[0])
    {
        return 0;
    }
    let p: Vec<usize> = x.iter().map(|v| *v as usize).collect();
    let corrected = crate::hrd_ecg::correct(&p, fs);
    if corrected.len() > capacity {
        return 0;
    }
    for (i, v) in corrected.iter().enumerate() {
        *out.add(i) = *v as f64;
    }
    corrected.len()
}
