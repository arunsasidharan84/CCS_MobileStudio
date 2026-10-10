//! HRD-consumed NeuroKit2 0.2.12 default ECG pipeline.
//! Adapted from NeuroKit2 (MIT); see third_party/neurokit2/LICENSE.
use std::f64::consts::PI;

fn odd_pad(x: &[f64], pad: usize) -> Vec<f64> {
    let mut v = Vec::with_capacity(x.len() + 2 * pad);
    for i in (1..=pad).rev() {
        v.push(2.0 * x[0] - x[i]);
    }
    v.extend_from_slice(x);
    for i in 1..=pad {
        v.push(2.0 * x[x.len() - 1] - x[x.len() - 1 - i]);
    }
    v
}
fn highpass_sos(fs: f64) -> [[f64; 5]; 3] {
    let k = 2.0 * fs;
    let w = k * (PI * 0.5 / fs).tan();
    let r = (k - w) / (k + w);
    let mut sos = [
        [1.0, -1.0, 0.0, -r, 0.0],
        [1.0, -2.0, 1.0, 0.0, 0.0],
        [1.0, -2.0, 1.0, 0.0, 0.0],
    ];
    for (i, angle) in [4.0 * PI / 5.0, 3.0 * PI / 5.0].iter().enumerate() {
        let re = w * angle.cos();
        let im = w * angle.sin();
        let denom = (k - re).powi(2) + im * im;
        let pr = (k * k - re * re - im * im) / denom;
        let pi = 2.0 * k * im / denom;
        sos[i + 1][3] = -2.0 * pr;
        sos[i + 1][4] = pr * pr + pi * pi;
    }
    let gain = (1.0 + r) * (1.0 - sos[1][3] + sos[1][4]) * (1.0 - sos[2][3] + sos[2][4]) / 32.0;
    sos[0][0] = gain;
    sos[0][1] = -gain;
    sos
}
fn sos_pass(x: &[f64], sos: &[[f64; 5]; 3]) -> Vec<f64> {
    let mut z = [[0.0; 2]; 3];
    z[0][0] = -sos[0][0] * x[0];
    let mut out = Vec::with_capacity(x.len());
    for &v in x {
        let mut v = v;
        for (i, s) in sos.iter().enumerate() {
            let y = s[0] * v + z[i][0];
            z[i][0] = s[1] * v - s[3] * y + z[i][1];
            z[i][1] = s[2] * v - s[4] * y;
            v = y;
        }
        out.push(v);
    }
    out
}
fn fir_pass(x: &[f64], width: usize) -> Vec<f64> {
    (0..x.len())
        .map(|i| {
            (0..width)
                .map(|j| if j <= i { x[i - j] } else { x[0] })
                .sum::<f64>()
                / width as f64
        })
        .collect()
}
pub fn clean(x: &[f64], fs: f64) -> Option<Vec<f64>> {
    let width = if fs >= 100.0 { (fs / 50.0) as usize } else { 2 };
    let pad = 3 * width;
    if x.len() <= 18 || x.len() <= pad || width == 0 {
        return None;
    }
    let sos = highpass_sos(fs);
    let mut v = sos_pass(&odd_pad(x, 18), &sos);
    v.reverse();
    v = sos_pass(&v, &sos);
    v.reverse();
    let v = &v[18..18 + x.len()];
    let mut v = fir_pass(&odd_pad(v, pad), width);
    v.reverse();
    v = fir_pass(&v, width);
    v.reverse();
    Some(v[pad..pad + x.len()].to_vec())
}
fn round_even(x: f64) -> f64 {
    let floor = x.floor();
    if x - floor == 0.5 {
        if floor as u64 % 2 == 0 {
            floor
        } else {
            floor + 1.0
        }
    } else {
        x.round()
    }
}
fn smooth(x: &[f64], width: usize) -> Vec<f64> {
    let left = width as isize / 2;
    let at = |i: isize| x[i.clamp(0, x.len() as isize - 1) as usize];
    let mut sum = (0..width).map(|j| at(j as isize - left)).sum::<f64>();
    let mut out = Vec::with_capacity(x.len());
    out.push(sum / width as f64);
    for i in 1..x.len() {
        sum += at(i as isize - left + width as isize - 1) - at(i as isize - 1 - left);
        out.push(sum / width as f64);
    }
    out
}
fn prominent(x: &[f64]) -> Option<usize> {
    let mut best = None;
    let mut strength = -1.0;
    let mut i = 1;
    while i + 1 < x.len() {
        if x[i] > x[i - 1] {
            let mut end = i;
            while end + 1 < x.len() && x[end + 1] == x[i] {
                end += 1;
            }
            if end + 1 < x.len() && x[end + 1] < x[i] {
                let peak = (i + end) / 2;
                let h = x[i];
                let mut lo = h;
                let mut j = i;
                while j > 0 && x[j - 1] <= h {
                    j -= 1;
                    lo = lo.min(x[j]);
                }
                let mut ro = h;
                let mut j = end;
                while j + 1 < x.len() && x[j + 1] <= h {
                    j += 1;
                    ro = ro.min(x[j]);
                }
                let p = h - lo.max(ro);
                if p > strength {
                    best = Some(peak);
                    strength = p;
                }
            }
            i = end + 1;
        } else {
            i += 1;
        }
    }
    best
}
pub fn detect(x: &[f64], fs: f64) -> Vec<usize> {
    let n = x.len();
    if n < 3 {
        return vec![];
    }
    let mut grad = Vec::with_capacity(n);
    grad.push((x[1] - x[0]).abs());
    for i in 1..n - 1 {
        grad.push(((x[i + 1] - x[i - 1]) / 2.0).abs());
    }
    grad.push((x[n - 1] - x[n - 2]).abs());
    let small = round_even(0.1 * fs) as usize;
    let big = round_even(0.75 * fs) as usize;
    if small < 1 || big > n {
        return vec![];
    }
    let sm = smooth(&grad, small);
    let avg = smooth(&sm, big);
    let qrs: Vec<bool> = sm.iter().zip(avg).map(|(s, a)| *s > 1.5 * a).collect();
    let begin: Vec<usize> = (0..n - 1).filter(|&i| !qrs[i] && qrs[i + 1]).collect();
    if begin.is_empty() {
        return vec![];
    }
    let end: Vec<usize> = (0..n - 1)
        .filter(|&i| qrs[i] && !qrs[i + 1] && i > begin[0])
        .collect();
    let count = begin.len().min(end.len());
    if count == 0 {
        return vec![];
    }
    let min_len = (0..count).map(|i| (end[i] - begin[i]) as f64).sum::<f64>() / count as f64 * 0.4;
    let delay = round_even(fs * 0.3) as usize;
    let mut result = vec![];
    let mut previous = 0;
    for i in 0..count {
        if (end[i] - begin[i]) as f64 >= min_len {
            if let Some(p) = prominent(&x[begin[i]..end[i]]) {
                let p = p + begin[i];
                if p - previous > delay {
                    result.push(p);
                    previous = p;
                }
            }
        }
    }
    result
}
fn quantile(x: &[f64], q: f64) -> f64 {
    let mut v = x.to_vec();
    v.sort_by(f64::total_cmp);
    let f = (v.len() - 1) as f64 * q;
    let i = f.floor() as usize;
    v[i] + (v[f.ceil() as usize] - v[i]) * (f - i as f64)
}
fn rolling(x: &[f64], width: usize, q: f64) -> Vec<f64> {
    let half = width / 2;
    (0..x.len())
        .map(|i| quantile(&x[i.saturating_sub(half)..(i + half + 1).min(x.len())], q))
        .collect()
}
fn threshold(x: &[f64]) -> Vec<f64> {
    let abs: Vec<f64> = x.iter().map(|v| v.abs()).collect();
    let q1 = rolling(&abs, 91, 0.25);
    let q3 = rolling(&abs, 91, 0.75);
    q1.iter()
        .zip(q3)
        .map(|(a, b)| 5.2 * (b - a) / 2.0)
        .collect()
}
fn reflect(i: isize, n: usize) -> usize {
    if n <= 1 {
        return 0;
    }
    let span = 2 * (n as isize - 1);
    let j = i.rem_euclid(span);
    if j >= n as isize {
        (span - j) as usize
    } else {
        j as usize
    }
}
fn min_nan(a: f64, b: f64) -> f64 {
    if a.is_nan() || b.is_nan() {
        f64::NAN
    } else {
        a.min(b)
    }
}
fn max_nan(a: f64, b: f64) -> f64 {
    if a.is_nan() || b.is_nan() {
        f64::NAN
    } else {
        a.max(b)
    }
}
#[derive(Default, Clone, Debug)]
struct Artifacts {
    extra: Vec<usize>,
    missed: Vec<usize>,
    ectopic: Vec<usize>,
    longshort: Vec<usize>,
}
impl Artifacts {
    fn count(&self) -> usize {
        self.extra.len() + self.missed.len() + self.ectopic.len() + self.longshort.len()
    }
}
fn artifacts(peaks: &[usize], fs: f64) -> Artifacts {
    let n = peaks.len();
    if n == 0 {
        return Artifacts::default();
    }
    let mut rr = vec![0.0; n];
    for i in 1..n {
        rr[i] = (peaks[i] - peaks[i - 1]) as f64 / fs;
    }
    rr[0] = if n > 1 {
        rr[1..].iter().sum::<f64>() / (n - 1) as f64
    } else {
        1.0
    };
    let mut drr = vec![0.0; n];
    for i in 1..n {
        drr[i] = rr[i] - rr[i - 1];
    }
    drr[0] = if n > 1 {
        drr[1..].iter().sum::<f64>() / (n - 1) as f64
    } else {
        0.0
    };
    let th1 = threshold(&drr);
    for i in 0..n {
        drr[i] = if th1[i] != 0.0 {
            drr[i] / th1[i]
        } else {
            f64::NAN
        };
    }
    let at = |i: isize| drr[reflect(i, n)];
    let mut s12 = vec![0.0; n];
    let mut s22 = vec![0.0; n];
    for i in 0..n {
        let j = i as isize;
        if drr[i] > 0.0 {
            s12[i] = max_nan(at(j - 1), at(j + 1));
        } else if drr[i] < 0.0 {
            s12[i] = min_nan(at(j - 1), at(j + 1));
        }
        if drr[i] >= 0.0 {
            s22[i] = min_nan(at(j + 1), at(j + 2));
        } else if drr[i] < 0.0 {
            s22[i] = max_nan(at(j + 1), at(j + 2));
        }
    }
    let med = rolling(&rr, 11, 0.5);
    let mut mrr: Vec<f64> = rr
        .iter()
        .zip(&med)
        .map(|(r, m)| {
            let d = r - m;
            if d < 0.0 {
                d * 2.0
            } else {
                d
            }
        })
        .collect();
    let th2 = threshold(&mrr);
    for i in 0..n {
        mrr[i] = if th2[i] != 0.0 {
            mrr[i] / th2[i]
        } else {
            f64::NAN
        };
    }
    let mut a = Artifacts::default();
    let mut i = 0;
    while i + 2 < n {
        if drr[i].abs() <= 1.0 {
            i += 1;
            continue;
        }
        let eq1 = drr[i] > 1.0 && s12[i] < (-0.13 * drr[i] - 0.17);
        let eq2 = drr[i] < -1.0 && s12[i] > (-0.13 * drr[i] + 0.17);
        if eq1 || eq2 {
            a.ectopic.push(i);
            i += 1;
            continue;
        }
        if !(drr[i].abs() > 1.0 || mrr[i].abs() > 3.0) {
            i += 1;
            continue;
        }
        let mut candidates = vec![i];
        if drr[i + 1].abs() < drr[i + 2].abs() {
            candidates.push(i + 1);
        }
        for j in candidates {
            let eq3 = drr[j] > 1.0 && s22[j] < -1.0;
            let eq4 = mrr[j].abs() > 3.0;
            let eq5 = drr[j] < -1.0 && s22[j] > 1.0;
            if !(eq3 || eq4 || eq5) {
                i += 1;
                continue;
            }
            let eq6 = (rr[j] / 2.0 - med[j]).abs() < th2[j];
            let eq7 = (rr[j] + rr[j + 1] - med[j]).abs() < th2[j];
            if eq5 && eq7 {
                a.extra.push(j);
            } else if eq3 && eq6 {
                a.missed.push(j);
            } else {
                a.longshort.push(j);
            }
            i += 1;
        }
    }
    a
}
fn update_indices(source: &[usize], indices: &mut Vec<usize>, shift: isize) {
    for &s in source {
        for u in indices.iter_mut() {
            if *u > s {
                *u = (*u as isize + shift) as usize;
            }
        }
    }
    indices.sort_unstable();
    indices.dedup();
}
fn relocate(peaks: &mut Vec<usize>, indices: &[usize]) {
    let valid: Vec<usize> = indices
        .iter()
        .copied()
        .filter(|&i| i > 1 && i + 1 < peaks.len())
        .collect();
    let added: Vec<usize> = valid
        .iter()
        .map(|&i| (peaks[i - 1] + peaks[i + 1]) / 2)
        .collect();
    let mut pos = 0;
    peaks.retain(|_| {
        let keep = !valid.contains(&pos);
        pos += 1;
        keep
    });
    peaks.extend(added);
    peaks.sort_unstable();
}
fn apply(mut p: Vec<usize>, mut a: Artifacts) -> Vec<usize> {
    if !a.extra.is_empty() {
        let mut index = 0;
        p.retain(|_| {
            let keep = !a.extra.contains(&index);
            index += 1;
            keep
        });
        update_indices(&a.extra, &mut a.missed, -1);
        update_indices(&a.extra, &mut a.ectopic, -1);
        update_indices(&a.extra, &mut a.longshort, -1);
    }
    if !a.missed.is_empty() {
        let insert: Vec<(usize, usize)> = a
            .missed
            .iter()
            .copied()
            .filter(|&i| i > 1 && i < p.len())
            .map(|i| (i, (p[i - 1] + p[i]) / 2))
            .collect();
        for (i, pos) in insert.into_iter().rev() {
            p.insert(i, pos);
        }
        update_indices(&a.missed, &mut a.ectopic, 1);
        update_indices(&a.missed, &mut a.longshort, 1);
    }
    if !a.ectopic.is_empty() {
        relocate(&mut p, &a.ectopic);
    }
    if !a.longshort.is_empty() {
        relocate(&mut p, &a.longshort);
    }
    p
}
pub fn correct(peaks: &[usize], fs: f64) -> Vec<usize> {
    if peaks.is_empty() {
        return vec![];
    }
    let a = artifacts(peaks, fs);
    let mut previous = a.count();
    let mut p = apply(peaks.to_vec(), a);
    loop {
        let a = artifacts(&p, fs);
        let count = a.count();
        if count >= previous {
            break;
        }
        previous = count;
        p = apply(p, a);
    }
    p
}
fn slope_edge(h0: f64, h1: f64, m0: f64, m1: f64) -> f64 {
    let d = ((2.0 * h0 + h1) * m0 - h0 * m1) / (h0 + h1);
    if d.signum() != m0.signum() {
        0.0
    } else if m0.signum() != m1.signum() && d.abs() > 3.0 * m0.abs() {
        3.0 * m0
    } else {
        d
    }
}
pub fn rate(peaks: &[usize], fs: f64, n: usize) -> Vec<f64> {
    let k = peaks.len();
    if k <= 3 {
        return vec![f64::NAN; n];
    }
    let h: Vec<f64> = peaks.windows(2).map(|w| (w[1] - w[0]) as f64).collect();
    if h.iter().any(|x| *x <= 0.0) {
        return vec![f64::NAN; n];
    }
    let mut period = vec![0.0; k];
    for i in 1..k {
        period[i] = h[i - 1] / fs;
    }
    period[0] = period[1..].iter().sum::<f64>() / (k - 1) as f64;
    let m: Vec<f64> = (0..k - 1)
        .map(|i| (period[i + 1] - period[i]) / h[i])
        .collect();
    let mut d = vec![0.0; k];
    d[0] = slope_edge(h[0], h[1], m[0], m[1]);
    d[k - 1] = slope_edge(h[k - 2], h[k - 3], m[k - 2], m[k - 3]);
    for i in 1..k - 1 {
        if m[i - 1] == 0.0 || m[i] == 0.0 || m[i - 1].signum() != m[i].signum() {
            d[i] = 0.0;
        } else {
            let w1 = 2.0 * h[i] + h[i - 1];
            let w2 = h[i] + 2.0 * h[i - 1];
            d[i] = (w1 + w2) / (w1 / m[i - 1] + w2 / m[i]);
        }
    }
    let mut rates = Vec::with_capacity(n);
    let mut j = 0;
    for i in 0..n {
        let p = if i <= peaks[0] {
            period[0]
        } else if i >= peaks[k - 1] {
            period[k - 1]
        } else {
            while j + 1 < k - 1 && i > peaks[j + 1] {
                j += 1;
            }
            let t = (i - peaks[j]) as f64 / h[j];
            (2.0 * t.powi(3) - 3.0 * t * t + 1.0) * period[j]
                + (t.powi(3) - 2.0 * t * t + t) * h[j] * d[j]
                + (-2.0 * t.powi(3) + 3.0 * t * t) * period[j + 1]
                + (t.powi(3) - t * t) * h[j] * d[j + 1]
        };
        rates.push(60.0 / p);
    }
    rates
}
#[cfg(test)]
mod tests {
    use super::*;
    mod reference {
        include!("hrd_ecg_fixtures.rs");
    }
    #[test]
    fn matches_pinned_neurokit_reference() {
        let fs = 250.0;
        let raw: Vec<f64> = (0..4000)
            .map(|i| {
                let t = i as f64 / fs;
                let p = t % (60.0 / 72.0);
                1000.0 * (-((p - 0.2) / 0.012).powi(2)).exp()
                    - 150.0 * (-((p - 0.23) / 0.02).powi(2)).exp()
                    + 30.0 * (2.0 * PI * 0.2 * t).sin()
            })
            .collect();
        let cleaned = clean(&raw, fs).unwrap();
        let peaks = correct(&detect(&cleaned, fs), fs);
        let rates = rate(&peaks, fs, raw.len());
        assert_eq!(peaks, reference::PEAKS);
        for (j, &i) in reference::SAMPLES.iter().enumerate() {
            assert!((cleaned[i] - reference::CLEAN[j]).abs() < 2e-8);
            assert!((rates[i] - reference::RATES[j]).abs() < 1e-9);
        }
        assert!((rates.iter().sum::<f64>() / rates.len() as f64 - reference::MEAN).abs() < 1e-9);
    }
    #[test]
    fn matches_reference_artifact_correction() {
        assert_eq!(
            correct(&reference::ARTIFACT_INPUT, 250.0),
            reference::ARTIFACT_CORRECTED
        );
    }
    #[test]
    fn sparse_rate_is_unavailable() {
        assert!(rate(&[10, 50, 100], 250.0, 200).iter().all(|v| v.is_nan()));
    }
    #[test]
    fn regular_rate() {
        let peaks: Vec<usize> = (1..20).map(|i| i * 250).collect();
        assert!(rate(&peaks, 250.0, 5000)
            .iter()
            .all(|v| (*v - 60.0).abs() < 1e-10));
    }
    #[test]
    fn flatline() {
        let y = clean(&vec![1000.0; 4000], 250.0).unwrap();
        assert!(detect(&y, 250.0).is_empty());
    }
}
