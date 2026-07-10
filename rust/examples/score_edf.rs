use std::env;
use std::ffi::CString;
use std::fs;

use train_nidra_core::{
    tn_create_sleep_state_with_model, tn_free_sleep_state, tn_push_sample, SleepScore,
};

fn field(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes).trim().to_string()
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: score_edf <file.edf> <model.onnx> [channel]");
        std::process::exit(2);
    }
    let bytes = fs::read(&args[1]).expect("read EDF");
    let channel: usize = args.get(3).and_then(|v| v.parse().ok()).unwrap_or(0);
    let header_bytes: usize = field(&bytes[184..192]).parse().expect("header size");
    let records: usize = field(&bytes[236..244]).parse().expect("record count");
    let record_seconds: f64 = field(&bytes[244..252]).parse().expect("record duration");
    let signals: usize = field(&bytes[252..256]).parse().expect("signal count");
    assert!(channel < signals);

    let labels_offset = 256;
    let physical_min_offset = 256 + signals * (16 + 80 + 8);
    let physical_max_offset = physical_min_offset + signals * 8;
    let digital_min_offset = physical_max_offset + signals * 8;
    let digital_max_offset = digital_min_offset + signals * 8;
    let samples_offset = 256 + signals * (16 + 80 + 8 + 8 + 8 + 8 + 8 + 80);

    let mut samples_per_record = Vec::with_capacity(signals);
    for signal in 0..signals {
        let start = samples_offset + signal * 8;
        samples_per_record.push(field(&bytes[start..start + 8]).parse::<usize>().unwrap());
    }
    let label = field(
        &bytes[labels_offset + channel * 16..labels_offset + (channel + 1) * 16],
    );
    let parse_calibration = |offset: usize, signal: usize| -> f64 {
        let start = offset + signal * 8;
        field(&bytes[start..start + 8]).parse().unwrap()
    };
    let physical_min = parse_calibration(physical_min_offset, channel);
    let physical_max = parse_calibration(physical_max_offset, channel);
    let digital_min = parse_calibration(digital_min_offset, channel);
    let digital_max = parse_calibration(digital_max_offset, channel);
    let scale = (physical_max - physical_min) / (digital_max - digital_min);
    let offset = physical_min - digital_min * scale;
    let sample_rate = samples_per_record[channel] as f64 / record_seconds;

    let model = CString::new(args[2].as_str()).unwrap();
    let state = unsafe { tn_create_sleep_state_with_model(sample_rate, model.as_ptr()) };
    assert!(!state.is_null());

    println!("channel={channel} label={label} sample_rate={sample_rate}");
    println!("epoch,minute,stage,confidence,artifact");
    let record_samples: usize = samples_per_record.iter().sum();
    let mut data_offset = header_bytes;
    for _ in 0..records {
        for signal in 0..signals {
            let count = samples_per_record[signal];
            if signal == channel {
                for sample in 0..count {
                    let start = data_offset + sample * 2;
                    let digital = i16::from_le_bytes([bytes[start], bytes[start + 1]]) as f64;
                    let value = digital * scale + offset;
                    let mut score = SleepScore::default();
                    if unsafe { tn_push_sample(state, value, &mut score) } && score.ready {
                        println!(
                            "{},{:.1},{},{:.4},{:.4}",
                            score.epoch_index,
                            (score.epoch_index + 1) as f64 * 0.5,
                            score.stage,
                            score.confidence,
                            score.artifact_ratio
                        );
                    }
                }
            }
            data_offset += count * 2;
        }
        let consumed = samples_per_record.iter().sum::<usize>() * 2;
        debug_assert_eq!(consumed, record_samples * 2);
    }
    unsafe { tn_free_sleep_state(state) };
}
