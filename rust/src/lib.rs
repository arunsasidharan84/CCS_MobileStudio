use std::ffi::{CStr, CString};
use std::fs::File;
use std::io::{Seek, SeekFrom, Write};
use std::os::raw::c_char;
use std::ptr;
use tract_onnx::prelude::*;

const STAGE_WAKE: i32 = 0;
const STAGE_N1: i32 = 1;
const STAGE_N2: i32 = 2;
const STAGE_N3: i32 = 3;
const STAGE_REM: i32 = 4;

#[repr(C)]
#[derive(Clone, Copy)]
pub struct SleepScore {
    pub ready: bool,
    pub stage: i32,
    pub confidence: f64,
    pub epoch_index: u64,
    pub delta_power: f64,
    pub theta_power: f64,
    pub alpha_power: f64,
    pub beta_power: f64,
    pub artifact_ratio: f64,
    pub prob_wake: f64,
    pub prob_n1: f64,
    pub prob_n2: f64,
    pub prob_n3: f64,
    pub prob_rem: f64,
}

impl Default for SleepScore {
    fn default() -> Self {
        Self {
            ready: false,
            stage: STAGE_WAKE,
            confidence: 0.0,
            epoch_index: 0,
            delta_power: 0.0,
            theta_power: 0.0,
            alpha_power: 0.0,
            beta_power: 0.0,
            artifact_ratio: 0.0,
            prob_wake: 0.0,
            prob_n1: 0.0,
            prob_n2: 0.0,
            prob_n3: 0.0,
            prob_rem: 0.0,
        }
    }
}

pub struct SleepState {
    sample_rate: f64,
    epoch_samples: usize,
    input: Vec<f64>,
    filtered_epoch: Vec<f64>,
    epoch_history: Vec<Vec<f32>>,
    scorer: Option<SleepScorer>,
    epoch_index: u64,
    causal_stage_history: Vec<i32>,
    last_score: SleepScore,
    pub low_state: f64,
    pub high_prev_x: f64,
    pub high_prev_y: f64,
    pub step_samples: usize,
    pub raw_history: Vec<f64>,
    pub feature_history: Vec<Vec<f32>>,
}

type TractModel = SimplePlan<TypedFact, Box<dyn TypedOp>, Graph<TypedFact, Box<dyn TypedOp>>>;

pub struct SleepScorer {
    model: TractModel,
}

pub struct EdfWriter {
    file: File,
    channel_count: usize,
    sample_rate: usize,
    record_samples: Vec<Vec<i16>>,
    records: u64,
    phys_min: Vec<f64>,
    phys_max: Vec<f64>,
}

#[no_mangle]
pub unsafe extern "C" fn tn_create_sleep_state(sample_rate: f64) -> *mut SleepState {
    create_sleep_state(sample_rate, None)
}

#[no_mangle]
pub unsafe extern "C" fn tn_create_sleep_state_with_model(
    sample_rate: f64,
    model_path: *const c_char,
) -> *mut SleepState {
    let path = if model_path.is_null() {
        None
    } else {
        CStr::from_ptr(model_path).to_str().ok()
    };
    create_sleep_state(sample_rate, path)
}

fn create_sleep_state(sample_rate: f64, model_path: Option<&str>) -> *mut SleepState {
    let sf = if sample_rate.is_finite() && sample_rate >= 50.0 {
        sample_rate
    } else {
        100.0
    };
    let scorer = model_path.and_then(|path| SleepScorer::new(path).ok());
    let state = SleepState {
        sample_rate: sf,
        epoch_samples: (sf * 30.0).round() as usize,
        input: Vec::with_capacity((sf * 35.0) as usize),
        filtered_epoch: Vec::new(),
        epoch_history: Vec::new(),
        scorer,
        epoch_index: 0,
        causal_stage_history: Vec::new(),
        last_score: SleepScore::default(),
        low_state: 0.0,
        high_prev_x: 0.0,
        high_prev_y: 0.0,
        step_samples: (sf * 30.0).round() as usize,
        raw_history: Vec::new(),
        feature_history: Vec::new(),
    };
    Box::into_raw(Box::new(state))
}

#[no_mangle]
pub unsafe extern "C" fn tn_free_sleep_state(state: *mut SleepState) {
    if !state.is_null() {
        let _ = Box::from_raw(state);
    }
}

#[no_mangle]
pub unsafe extern "C" fn tn_sleep_state_uses_model(state: *const SleepState) -> bool {
    !state.is_null() && (*state).scorer.is_some()
}

#[no_mangle]
pub unsafe extern "C" fn tn_set_scoring_step(state: *mut SleepState, step_seconds: f64) {
    if !state.is_null() {
        let state = &mut *state;
        state.step_samples = (state.sample_rate * step_seconds).round() as usize;
        state.input.clear();
        state.raw_history.clear();
        state.feature_history.clear();
        state.epoch_history.clear();
    }
}

#[no_mangle]
pub unsafe extern "C" fn tn_push_sample(
    state: *mut SleepState,
    sample_uv: f64,
    out_score: *mut SleepScore,
) -> bool {
    if state.is_null() || out_score.is_null() {
        return false;
    }

    let state = &mut *state;
    state.input.push(if sample_uv.is_finite() {
        sample_uv
    } else {
        0.0
    });

    if state.input.len() < state.step_samples {
        (*out_score) = SleepScore::default();
        return false;
    }

    let new_samples: Vec<f64> = state.input.drain(0..state.step_samples).collect();
    state.raw_history.extend(new_samples);

    if state.raw_history.len() < state.epoch_samples {
        (*out_score) = SleepScore::default();
        return false;
    }

    // Keep raw_history capped to 600s
    let max_history = (state.sample_rate * 600.0).round() as usize;
    if state.raw_history.len() > max_history {
        let excess = state.raw_history.len() - max_history;
        state.raw_history.drain(0..excess);
    }

    let epoch_start = state.raw_history.len() - state.epoch_samples;
    let epoch = state.raw_history[epoch_start..].to_vec();
    let score = score_epoch(state, &epoch);
    state.last_score = score;
    (*out_score) = state.last_score;
    true
}

#[no_mangle]
pub unsafe extern "C" fn tn_stage_label(stage: i32) -> *mut c_char {
    let label = match stage {
        STAGE_WAKE => "Wake",
        STAGE_N1 => "N1",
        STAGE_N2 => "N2",
        STAGE_N3 => "N3",
        STAGE_REM => "REM",
        _ => "Unknown",
    };
    CString::new(label).unwrap().into_raw()
}

#[no_mangle]
pub unsafe extern "C" fn tn_free_string(value: *mut c_char) {
    if !value.is_null() {
        let _ = CString::from_raw(value);
    }
}

#[no_mangle]
pub unsafe extern "C" fn tn_edf_open(
    path: *const c_char,
    subject: *const c_char,
    channel_count: usize,
    sample_rate: usize,
) -> *mut EdfWriter {
    if path.is_null() || channel_count == 0 || sample_rate == 0 {
        return ptr::null_mut();
    }
    let path = match CStr::from_ptr(path).to_str() {
        Ok(path) => path,
        Err(_) => return ptr::null_mut(),
    };
    let subject = if subject.is_null() {
        "unknown"
    } else {
        CStr::from_ptr(subject).to_str().unwrap_or("unknown")
    };

    let mut file = match File::create(path) {
        Ok(file) => file,
        Err(_) => return ptr::null_mut(),
    };
    let phys_min = vec![-250000.0; channel_count];
    let phys_max = vec![250000.0; channel_count];
    let header = edf_header(
        subject,
        channel_count,
        sample_rate,
        -1,
        None,
        None,
        None,
        None,
        Some(&phys_min),
        Some(&phys_max),
    );
    if file.write_all(&header).is_err() {
        return ptr::null_mut();
    }

    Box::into_raw(Box::new(EdfWriter {
        file,
        channel_count,
        sample_rate,
        record_samples: vec![Vec::with_capacity(sample_rate); channel_count],
        records: 0,
        phys_min,
        phys_max,
    }))
}

#[no_mangle]
pub unsafe extern "C" fn tn_edf_push_sample(
    writer: *mut EdfWriter,
    samples: *const f64,
    count: usize,
) -> bool {
    if writer.is_null() || samples.is_null() {
        return false;
    }
    let writer = &mut *writer;
    let values = std::slice::from_raw_parts(samples, count);
    for channel in 0..writer.channel_count {
        let value = values.get(channel).copied().unwrap_or(0.0);
        let phys_min = writer.phys_min.get(channel).copied().unwrap_or(-250000.0);
        let phys_max = writer.phys_max.get(channel).copied().unwrap_or(250000.0);
        let span = (phys_max - phys_min).abs().max(1.0);
        let clipped = value.clamp(phys_min, phys_max);
        let scaled = ((clipped - phys_min) * 65535.0 / span - 32768.0).round();
        writer
            .record_samples[channel]
            .push(scaled.clamp(-32768.0, 32767.0) as i16);
    }
    if writer.record_samples[0].len() >= writer.sample_rate {
        write_edf_record(writer).is_ok()
    } else {
        true
    }
}

#[no_mangle]
pub unsafe extern "C" fn tn_edf_close(writer: *mut EdfWriter) -> bool {
    if writer.is_null() {
        return false;
    }
    let mut writer = Box::from_raw(writer);
    if !writer.record_samples[0].is_empty() {
        for channel in 0..writer.channel_count {
            let last = writer.record_samples[channel].last().copied().unwrap_or(0);
            while writer.record_samples[channel].len() < writer.sample_rate {
                writer.record_samples[channel].push(last);
            }
        }
        if write_edf_record(&mut writer).is_err() {
            return false;
        }
    }
    let count = ascii_pad(&writer.records.to_string(), 8);
    writer.file.seek(SeekFrom::Start(236)).is_ok()
        && writer.file.write_all(&count).is_ok()
        && writer.file.flush().is_ok()
}

impl SleepScorer {
    fn new(model_path: &str) -> TractResult<Self> {
        let model = tract_onnx::onnx()
            .model_for_path(model_path)?
            .with_input_fact(0, f32::fact([1, 20, 1, 3000]).into())?
            .into_optimized()?
            .into_runnable()?;
        Ok(Self { model })
    }

    fn score_sequence(&self, epochs: &[f32]) -> TractResult<(i32, f64, [f64; 5])> {
        if epochs.len() != 20 * 3000 {
            return Ok((STAGE_WAKE, 0.0, [1.0, 0.0, 0.0, 0.0, 0.0]));
        }
        let input = tract_ndarray::Array4::from_shape_vec((1, 20, 1, 3000), epochs.to_vec())?;
        let outputs = self.model.run(tvec!(input.into_tensor().into()))?;
        let logits = outputs[0].to_array_view::<f32>()?;
        let mut values = [0.0_f32; 5];
        for stage in 0..5 {
            values[stage] = logits[[0, 19, stage]];
        }
        let (stage, confidence, probs) = softmax_all(&values);
        Ok((stage as i32, confidence as f64, probs))
    }
}

fn score_epoch(state: &mut SleepState, epoch: &[f64]) -> SleepScore {
    if state.scorer.is_some() {
        if let Some(score) = score_epoch_tinysleepnet(state, epoch) {
            return score;
        }
    }
    score_epoch_causal(state, epoch)
}

fn score_epoch_tinysleepnet(state: &mut SleepState, epoch: &[f64]) -> Option<SleepScore> {
    let centered = center_epoch(epoch);
    let signal_sd = standard_deviation(&centered);
    if signal_sd < 0.5 {
        return Some(SleepScore {
            artifact_ratio: 1.0,
            ..SleepScore::default()
        });
    }
    let filtered = bandpass_notch(
        &centered,
        state.sample_rate,
        &mut state.low_state,
        &mut state.high_prev_x,
        &mut state.high_prev_y,
    );
    let model_epoch = prepare_model_epoch(&filtered, state.sample_rate);
    
    let steps_in_30s = (30.0 / (state.step_samples as f64 / state.sample_rate)).round() as usize;
    let required_len = 19 * steps_in_30s + 1;
    
    state.feature_history.push(model_epoch);
    while state.feature_history.len() < required_len {
        state.feature_history.insert(0, vec![0.0f32; 3000]);
    }
    if state.feature_history.len() > required_len {
        let excess = state.feature_history.len() - required_len;
        state.feature_history.drain(0..excess);
    }

    let mut flat = Vec::with_capacity(20 * 3000);
    for k in 0..20 {
        let idx = state.feature_history.len() - 1 - (19 - k) * steps_in_30s;
        flat.extend(state.feature_history[idx].iter().copied());
    }

    let scorer = state.scorer.as_ref()?;
    let (stage, confidence, probs) = scorer.score_sequence(&flat).ok()?;
    state.filtered_epoch = filtered.clone();
    let artifact_ratio = centered.iter().filter(|v| v.abs() > 250.0).count() as f64
        / centered.len().max(1) as f64;
    let score = SleepScore {
        ready: true,
        stage,
        confidence,
        epoch_index: state.epoch_index,
        delta_power: bandpower(&filtered, state.sample_rate, 0.5, 4.0),
        theta_power: bandpower(&filtered, state.sample_rate, 4.0, 8.0),
        alpha_power: bandpower(&filtered, state.sample_rate, 8.0, 12.0),
        beta_power: bandpower(&filtered, state.sample_rate, 12.0, 30.0),
        artifact_ratio,
        prob_wake: probs[0],
        prob_n1: probs[1],
        prob_n2: probs[2],
        prob_n3: probs[3],
        prob_rem: probs[4],
    };
    state.epoch_index += 1;
    Some(score)
}

fn score_epoch_causal(state: &mut SleepState, epoch: &[f64]) -> SleepScore {
    let centered = center_epoch(epoch);
    if standard_deviation(&centered) < 0.5 {
        return SleepScore {
            artifact_ratio: 1.0,
            ..SleepScore::default()
        };
    }
    let filtered = bandpass_notch(
        &centered,
        state.sample_rate,
        &mut state.low_state,
        &mut state.high_prev_x,
        &mut state.high_prev_y,
    );
    state.filtered_epoch = filtered.clone();
    let artifact_ratio = centered.iter().filter(|v| v.abs() > 250.0).count() as f64
        / centered.len().max(1) as f64;

    let delta = bandpower(&filtered, state.sample_rate, 0.5, 4.0);
    let theta = bandpower(&filtered, state.sample_rate, 4.0, 8.0);
    let alpha = bandpower(&filtered, state.sample_rate, 8.0, 12.0);
    let beta = bandpower(&filtered, state.sample_rate, 12.0, 30.0);
    let total = delta + theta + alpha + beta + 1e-9;

    let delta_ratio = delta / total;
    let theta_ratio = theta / total;
    let alpha_ratio = alpha / total;
    let beta_ratio = beta / total;

    // This is the causal fallback behind the TinySleepNet boundary. Replace this
    // function with exported TinySleepNet inference after model conversion.
    let mut stage = if artifact_ratio > 0.08 || beta_ratio > 0.35 || alpha_ratio > 0.30 {
        STAGE_WAKE
    } else if delta_ratio > 0.50 {
        STAGE_N3
    } else if theta_ratio > 0.38 && beta_ratio < 0.22 {
        STAGE_N2
    } else if theta_ratio > 0.30 {
        STAGE_N1
    } else {
        STAGE_REM
    };

    if let Some(previous) = state.causal_stage_history.last().copied() {
        if previous == STAGE_N3 && stage == STAGE_WAKE && artifact_ratio < 0.03 {
            stage = STAGE_N2;
        }
        if previous == STAGE_WAKE && stage == STAGE_REM {
            stage = STAGE_N1;
        }
    }
    state.causal_stage_history.push(stage);
    if state.causal_stage_history.len() > 40 {
        state.causal_stage_history.remove(0);
    }

    let raw_probs = [
        alpha_ratio.max(beta_ratio),
        theta_ratio,
        theta_ratio + 0.25 * delta_ratio,
        delta_ratio,
        beta_ratio + theta_ratio * 0.4,
    ];
    let sum_probs = raw_probs.iter().sum::<f64>() + 1e-9;

    let confidence = stage_confidence(stage, delta_ratio, theta_ratio, alpha_ratio, beta_ratio, artifact_ratio);
    let score = SleepScore {
        ready: true,
        stage,
        confidence,
        epoch_index: state.epoch_index,
        delta_power: delta,
        theta_power: theta,
        alpha_power: alpha,
        beta_power: beta,
        artifact_ratio,
        prob_wake: raw_probs[0] / sum_probs,
        prob_n1: raw_probs[1] / sum_probs,
        prob_n2: raw_probs[2] / sum_probs,
        prob_n3: raw_probs[3] / sum_probs,
        prob_rem: raw_probs[4] / sum_probs,
    };
    state.epoch_index += 1;
    score
}

fn prepare_model_epoch(epoch: &[f64], sample_rate: f64) -> Vec<f32> {
    let clipped: Vec<f64> = epoch.iter().map(|&v| robust_clip(v)).collect();
    let resampled = resample_linear(&clipped, (sample_rate * 30.0).round() as usize, 3000);
    robust_zscore(&resampled)
}

fn center_epoch(epoch: &[f64]) -> Vec<f64> {
    if epoch.is_empty() {
        return Vec::new();
    }
    let mut sorted: Vec<f64> = epoch
        .iter()
        .copied()
        .filter(|value| value.is_finite())
        .collect();
    if sorted.is_empty() {
        return vec![0.0; epoch.len()];
    }
    sorted.sort_by(f64::total_cmp);
    let middle = sorted.len() / 2;
    let median = if sorted.len() % 2 == 0 {
        (sorted[middle - 1] + sorted[middle]) * 0.5
    } else {
        sorted[middle]
    };
    epoch
        .iter()
        .map(|value| {
            if value.is_finite() {
                value - median
            } else {
                0.0
            }
        })
        .collect()
}

fn standard_deviation(input: &[f64]) -> f64 {
    if input.is_empty() {
        return 0.0;
    }
    let mean = input.iter().sum::<f64>() / input.len() as f64;
    let variance = input
        .iter()
        .map(|value| {
            let delta = value - mean;
            delta * delta
        })
        .sum::<f64>()
        / input.len() as f64;
    variance.sqrt()
}

fn resample_linear(input: &[f64], expected_len: usize, output_len: usize) -> Vec<f64> {
    if input.is_empty() {
        return vec![0.0; output_len];
    }
    let usable_len = input.len().min(expected_len.max(1));
    if usable_len == output_len {
        return input[..usable_len].to_vec();
    }
    let mut out = Vec::with_capacity(output_len);
    let scale = (usable_len - 1) as f64 / (output_len - 1).max(1) as f64;
    for i in 0..output_len {
        let pos = i as f64 * scale;
        let lo = pos.floor() as usize;
        let hi = pos.ceil() as usize;
        if lo == hi || hi >= usable_len {
            out.push(input[lo.min(usable_len - 1)]);
        } else {
            let frac = pos - lo as f64;
            out.push(input[lo] * (1.0 - frac) + input[hi] * frac);
        }
    }
    out
}

fn robust_zscore(input: &[f64]) -> Vec<f32> {
    if input.is_empty() {
        return Vec::new();
    }
    let mean = input.iter().sum::<f64>() / input.len() as f64;
    let variance = input
        .iter()
        .map(|&v| {
            let d = v - mean;
            d * d
        })
        .sum::<f64>()
        / input.len() as f64;
    let sd = variance.sqrt().max(1e-6);
    input
        .iter()
        .map(|&v| ((v - mean) / sd).clamp(-10.0, 10.0) as f32)
        .collect()
}

fn softmax_all(logits: &[f32; 5]) -> (usize, f32, [f64; 5]) {
    let max_logit = logits.iter().copied().fold(f32::NEG_INFINITY, f32::max);
    let mut sum = 0.0_f32;
    let mut probs = [0.0_f64; 5];
    for (idx, &logit) in logits.iter().enumerate() {
        let value = (logit - max_logit).exp();
        probs[idx] = value as f64;
        sum += value;
    }
    if sum <= 0.0 || !sum.is_finite() {
        return (STAGE_WAKE as usize, 0.0, [1.0, 0.0, 0.0, 0.0, 0.0]);
    }
    for idx in 0..5 {
        probs[idx] /= sum as f64;
    }
    let mut best_idx = 0;
    let mut best_prob = probs[0];
    for (idx, &prob) in probs.iter().enumerate().skip(1) {
        if prob > best_prob {
            best_idx = idx;
            best_prob = prob;
        }
    }
    (best_idx, best_prob as f32, probs)
}

fn robust_clip(value: f64) -> f64 {
    if !value.is_finite() {
        0.0
    } else {
        value.clamp(-500.0, 500.0)
    }
}

fn bandpass_notch(
    input: &[f64],
    sf: f64,
    low_state: &mut f64,
    high_prev_x: &mut f64,
    high_prev_y: &mut f64,
) -> Vec<f64> {
    let mut out = Vec::with_capacity(input.len());
    let dt = 1.0 / sf;
    let hp_rc = 1.0 / (2.0 * std::f64::consts::PI * 0.3);
    let hp_alpha = hp_rc / (hp_rc + dt);
    let lp_rc = 1.0 / (2.0 * std::f64::consts::PI * 35.0);
    let lp_alpha = dt / (lp_rc + dt);

    for &x in input {
        let hp = hp_alpha * (*high_prev_y + x - *high_prev_x);
        *high_prev_x = x;
        *high_prev_y = hp;
        *low_state += lp_alpha * (hp - *low_state);
        out.push(*low_state);
    }
    out
}

fn bandpower(samples: &[f64], sf: f64, low: f64, high: f64) -> f64 {
    let n = samples.len();
    if n < 8 {
        return 0.0;
    }
    let mean = samples.iter().sum::<f64>() / n as f64;
    let mut power = 0.0;
    let start_bin = ((low * n as f64 / sf).floor() as usize).max(1);
    let end_bin = ((high * n as f64 / sf).ceil() as usize).min(n / 2);
    for k in start_bin..=end_bin {
        let mut re = 0.0;
        let mut im = 0.0;
        for (i, &x) in samples.iter().enumerate() {
            let window = 0.5 - 0.5 * (2.0 * std::f64::consts::PI * i as f64 / (n - 1) as f64).cos();
            let angle = -2.0 * std::f64::consts::PI * k as f64 * i as f64 / n as f64;
            re += (x - mean) * window * angle.cos();
            im += (x - mean) * window * angle.sin();
        }
        power += (re * re + im * im) / n as f64;
    }
    power / (end_bin.saturating_sub(start_bin) + 1).max(1) as f64
}

fn stage_confidence(stage: i32, delta: f64, theta: f64, alpha: f64, beta: f64, artifact: f64) -> f64 {
    let raw = match stage {
        STAGE_WAKE => alpha.max(beta),
        STAGE_N1 => theta,
        STAGE_N2 => theta + 0.25 * delta,
        STAGE_N3 => delta,
        STAGE_REM => beta + theta * 0.4,
        _ => 0.2,
    };
    (raw * (1.0 - artifact).max(0.2)).clamp(0.05, 0.98)
}

fn write_edf_record(writer: &mut EdfWriter) -> std::io::Result<()> {
    for channel in 0..writer.channel_count {
        for &sample in &writer.record_samples[channel] {
            writer.file.write_all(&sample.to_le_bytes())?;
        }
        writer.record_samples[channel].clear();
    }
    writer.records += 1;
    Ok(())
}

fn edf_header(
    subject: &str,
    channel_count: usize,
    sample_rate: usize,
    records: i64,
    names: Option<Vec<String>>,
    phys_dims: Option<Vec<String>>,
    prefilters: Option<Vec<String>>,
    transducers: Option<Vec<String>>,
    phys_min: Option<&[f64]>,
    phys_max: Option<&[f64]>,
) -> Vec<u8> {
    let header_bytes = 256 + channel_count * 256;
    let mut header = Vec::with_capacity(header_bytes);
    let now = chrono::Local::now();
    let date_str = now.format("%d.%m.%y").to_string();
    let time_str = now.format("%H.%M.%S").to_string();

    header.extend(ascii_pad("0", 8));
    header.extend(ascii_pad(subject, 80));
    header.extend(ascii_pad("Startdate TrainNidra EEG", 80));
    header.extend(ascii_pad(&date_str, 8));
    header.extend(ascii_pad(&time_str, 8));
    header.extend(ascii_pad(&header_bytes.to_string(), 8));
    header.extend(ascii_pad("", 44));
    header.extend(ascii_pad(&records.to_string(), 8));
    header.extend(ascii_pad("1", 8));
    header.extend(ascii_pad(&channel_count.to_string(), 4));

    for channel in 0..channel_count {
        if let Some(ref n) = names {
            header.extend(ascii_pad(&n[channel], 16));
        } else {
            header.extend(ascii_pad(&format!("EEG {}", channel + 1), 16));
        }
    }
    for channel in 0..channel_count {
        if let Some(ref t) = transducers {
            header.extend(ascii_pad(&t[channel], 80));
        } else {
            header.extend(ascii_pad("frontal electrode", 80));
        }
    }
    for channel in 0..channel_count {
        if let Some(ref d) = phys_dims {
            header.extend(ascii_pad(&d[channel], 8));
        } else {
            header.extend(ascii_pad("uV", 8));
        }
    }
    for channel in 0..channel_count {
        let value = phys_min
            .and_then(|values| values.get(channel))
            .copied()
            .unwrap_or(-250000.0);
        header.extend(ascii_pad(&format_edf_physical(value), 8));
    }
    for channel in 0..channel_count {
        let value = phys_max
            .and_then(|values| values.get(channel))
            .copied()
            .unwrap_or(250000.0);
        header.extend(ascii_pad(&format_edf_physical(value), 8));
    }
    for _ in 0..channel_count {
        header.extend(ascii_pad("-32768", 8));
    }
    for _ in 0..channel_count {
        header.extend(ascii_pad("32767", 8));
    }
    for channel in 0..channel_count {
        if let Some(ref p) = prefilters {
            header.extend(ascii_pad(&p[channel], 80));
        } else {
            header.extend(ascii_pad("HP:0.3 LP:35", 80));
        }
    }
    for _ in 0..channel_count {
        header.extend(ascii_pad(&sample_rate.to_string(), 8));
    }
    for _ in 0..channel_count {
        header.extend(ascii_pad("", 32));
    }
    header.resize(header_bytes, b' ');
    header
}

#[no_mangle]
pub unsafe extern "C" fn tn_edf_open_with_labels(
    path: *const c_char,
    subject: *const c_char,
    channel_names: *const *const c_char,
    phys_dims: *const *const c_char,
    prefilters: *const *const c_char,
    transducers: *const *const c_char,
    channel_count: usize,
    sample_rate: usize,
) -> *mut EdfWriter {
    tn_edf_open_with_labels_and_ranges(
        path,
        subject,
        channel_names,
        phys_dims,
        prefilters,
        transducers,
        ptr::null(),
        ptr::null(),
        channel_count,
        sample_rate,
    )
}

#[no_mangle]
pub unsafe extern "C" fn tn_edf_open_with_labels_and_ranges(
    path: *const c_char,
    subject: *const c_char,
    channel_names: *const *const c_char,
    phys_dims: *const *const c_char,
    prefilters: *const *const c_char,
    transducers: *const *const c_char,
    phys_min: *const f64,
    phys_max: *const f64,
    channel_count: usize,
    sample_rate: usize,
) -> *mut EdfWriter {
    if path.is_null() || channel_count == 0 || sample_rate == 0 {
        return ptr::null_mut();
    }
    let path = match CStr::from_ptr(path).to_str() {
        Ok(path) => path,
        Err(_) => return ptr::null_mut(),
    };
    let subject = if subject.is_null() {
        "unknown"
    } else {
        CStr::from_ptr(subject).to_str().unwrap_or("unknown")
    };

    let mut names_vec = Vec::new();
    let mut dims_vec = Vec::new();
    let mut prefs_vec = Vec::new();
    let mut trans_vec = Vec::new();

    if !channel_names.is_null() {
        let slice = std::slice::from_raw_parts(channel_names, channel_count);
        for &ptr in slice {
            names_vec.push(CStr::from_ptr(ptr).to_string_lossy().into_owned());
        }
    }
    if !phys_dims.is_null() {
        let slice = std::slice::from_raw_parts(phys_dims, channel_count);
        for &ptr in slice {
            dims_vec.push(CStr::from_ptr(ptr).to_string_lossy().into_owned());
        }
    }
    if !prefilters.is_null() {
        let slice = std::slice::from_raw_parts(prefilters, channel_count);
        for &ptr in slice {
            prefs_vec.push(CStr::from_ptr(ptr).to_string_lossy().into_owned());
        }
    }
    if !transducers.is_null() {
        let slice = std::slice::from_raw_parts(transducers, channel_count);
        for &ptr in slice {
            trans_vec.push(CStr::from_ptr(ptr).to_string_lossy().into_owned());
        }
    }
    let phys_min_vec = if phys_min.is_null() {
        vec![-250000.0; channel_count]
    } else {
        std::slice::from_raw_parts(phys_min, channel_count).to_vec()
    };
    let phys_max_vec = if phys_max.is_null() {
        vec![250000.0; channel_count]
    } else {
        std::slice::from_raw_parts(phys_max, channel_count).to_vec()
    };

    let mut file = match File::create(path) {
        Ok(file) => file,
        Err(_) => return ptr::null_mut(),
    };
    let header = edf_header(
        subject,
        channel_count,
        sample_rate,
        -1,
        Some(names_vec),
        Some(dims_vec),
        Some(prefs_vec),
        Some(trans_vec),
        Some(&phys_min_vec),
        Some(&phys_max_vec),
    );
    if file.write_all(&header).is_err() {
        return ptr::null_mut();
    }

    Box::into_raw(Box::new(EdfWriter {
        file,
        channel_count,
        sample_rate,
        records: 0,
        record_samples: vec![Vec::with_capacity(sample_rate); channel_count],
        phys_min: phys_min_vec,
        phys_max: phys_max_vec,
    }))
}

fn format_edf_physical(value: f64) -> String {
    if value.fract().abs() < 0.000001 {
        format!("{}", value as i64)
    } else {
        format!("{:.3}", value)
    }
}

fn ascii_pad(value: &str, len: usize) -> Vec<u8> {
    let mut out = vec![b' '; len];
    for (idx, byte) in value.as_bytes().iter().copied().take(len).enumerate() {
        out[idx] = byte;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scores_after_one_epoch() {
        let mut state = SleepState {
            sample_rate: 100.0,
            epoch_samples: 3000,
            input: Vec::new(),
            filtered_epoch: Vec::new(),
            epoch_history: Vec::new(),
            scorer: None,
            epoch_index: 0,
            causal_stage_history: Vec::new(),
            last_score: SleepScore::default(),
            low_state: 0.0,
            high_prev_x: 0.0,
            high_prev_y: 0.0,
            step_samples: 3000,
            raw_history: Vec::new(),
            feature_history: Vec::new(),
        };
        let epoch: Vec<f64> = (0..3000)
            .map(|i| (2.0 * std::f64::consts::PI * 2.0 * i as f64 / 100.0).sin() * 80.0)
            .collect();
        let score = score_epoch_causal(&mut state, &epoch);
        assert!(score.ready);
        assert_eq!(score.stage, STAGE_N3);
    }

    #[test]
    fn loads_tinysleepnet_onnx_and_scores_sequence() {
        let scorer = SleepScorer::new("../assets/models/tinysleepnet-supratak/model.onnx")
            .expect("TinySleepNet ONNX should load");
        let input = vec![0.0_f32; 20 * 3000];
        let (stage, confidence, _probs) = scorer
            .score_sequence(&input)
            .expect("TinySleepNet ONNX should run");
        assert!((STAGE_WAKE..=STAGE_REM).contains(&stage));
        assert!((0.0..=1.0).contains(&confidence));
    }

    #[test]
    fn loads_wearable_onnx_and_scores_sequence() {
        let scorer = SleepScorer::new("../assets/models/tinysleepnet-supratak/wearable_model.onnx")
            .expect("Wearable TinySleepNet ONNX should load");
        let input = vec![0.0_f32; 20 * 3000];
        let (stage, confidence, _probs) = scorer
            .score_sequence(&input)
            .expect("Wearable TinySleepNet ONNX should run");
        assert!((STAGE_WAKE..=STAGE_REM).contains(&stage));
        assert!((0.0..=1.0).contains(&confidence));
    }

    #[test]
    fn loads_psg_onnx_and_scores_sequence() {
        let scorer = SleepScorer::new("../assets/models/tinysleepnet-supratak/psg_model.onnx")
            .expect("PSG TinySleepNet ONNX should load");
        let input = vec![0.0_f32; 20 * 3000];
        let (stage, confidence, _probs) = scorer
            .score_sequence(&input)
            .expect("PSG TinySleepNet ONNX should run");
        assert!((STAGE_WAKE..=STAGE_REM).contains(&stage));
        assert!((0.0..=1.0).contains(&confidence));
    }

    #[test]
    fn rejects_flat_signal() {
        let mut state = SleepState {
            sample_rate: 100.0,
            epoch_samples: 3000,
            input: Vec::new(),
            filtered_epoch: Vec::new(),
            epoch_history: Vec::new(),
            scorer: None,
            epoch_index: 0,
            causal_stage_history: Vec::new(),
            last_score: SleepScore::default(),
            low_state: 0.0,
            high_prev_x: 0.0,
            high_prev_y: 0.0,
            step_samples: 3000,
            raw_history: Vec::new(),
            feature_history: Vec::new(),
        };
        let score = score_epoch_causal(&mut state, &vec![42.0; 3000]);
        assert!(!score.ready);
        assert_eq!(score.artifact_ratio, 1.0);
    }
}
