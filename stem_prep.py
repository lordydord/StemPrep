#!/usr/bin/env python3
"""Phase 1 Ableton stem-prep analyser.

This script converts an input track to a standard analysis WAV, estimates tempo,
finds a practical grid anchor, and writes Ableton import notes.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import shutil
import subprocess
import sys
import time
import wave
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Tuple

import numpy as np

try:
    import requests
except ImportError:  # pragma: no cover - handled at runtime
    requests = None

try:
    import essentia.standard as essentia_standard
except ImportError:  # pragma: no cover - handled at runtime
    essentia_standard = None


PROJECT_ROOT = Path(__file__).resolve().parent
DEFAULT_OUTPUT_ROOT = PROJECT_ROOT / "outputs"
SUPPORTED_SUFFIXES = {".mp3", ".wav", ".aiff", ".aif", ".flac", ".m4a", ".aac"}
TARGET_SAMPLE_RATE = 44100
HOP_LENGTH = 256
FRAME_LENGTH = 2048
EXPECTED_MVSEP_STEMS = ("drums", "bass", "other", "vocals")
MVSEP_API_CREATE_URL = "https://mvsep.com/api/separation/create"
MVSEP_API_RESULT_URL = "https://mvsep.com/api/separation/get"
MVSEP_API_SEP_TYPE_5_STEM_ENSEMBLE = "28"
MVSEP_API_STANDARD_OUTPUTS = "0"
MVSEP_API_MODEL_LATEST_5_STEM = "11"
MVSEP_API_OUTPUT_FLAC_24 = "5"


@dataclass
class AudioInfo:
    duration_seconds: float
    sample_rate: int
    channels: int
    format_name: str


@dataclass
class BeatAnalysis:
    bpm: float
    ableton_bpm: float
    grid_anchor_seconds: float
    beat_positions_seconds: List[float]
    confidence: float
    fixed_tempo: bool
    tempo_drift_score: float
    method: str
    warnings: List[str]
    source: str


@dataclass
class MvsepResult:
    status: str
    stems: Dict[str, str]
    raw_files: List[Dict]
    missing_stems: List[str]
    job_hash: Optional[str] = None
    message: Optional[str] = None


def run_command(args: Sequence[str]) -> subprocess.CompletedProcess:
    return subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def load_env_file(path: Path) -> None:
    if not path.exists():
        return
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip("'\"")
        if key and key not in os.environ:
            os.environ[key] = value


def slugify(name: str) -> str:
    cleaned = "".join(ch if ch.isalnum() or ch in " -_." else " " for ch in name)
    cleaned = " ".join(cleaned.split())
    return cleaned.strip(" .") or "track"


def unique_output_dir(base: Path, name: str) -> Path:
    candidate = base / name
    if not candidate.exists():
        return candidate
    for index in range(2, 1000):
        numbered = base / f"{name} {index}"
        if not numbered.exists():
            return numbered
    raise RuntimeError("Could not create a unique output folder name.")


def probe_audio(path: Path) -> AudioInfo:
    result = run_command(
        [
            "ffprobe",
            "-v",
            "error",
            "-print_format",
            "json",
            "-show_format",
            "-show_streams",
            str(path),
        ]
    )
    if result.returncode != 0:
        raise RuntimeError(f"ffprobe could not read the file: {result.stderr.strip()}")

    data = json.loads(result.stdout)
    audio_stream = next((s for s in data.get("streams", []) if s.get("codec_type") == "audio"), None)
    if not audio_stream:
        raise RuntimeError("No audio stream found in the input file.")

    duration = float(data.get("format", {}).get("duration") or audio_stream.get("duration") or 0)
    sample_rate = int(audio_stream.get("sample_rate") or 0)
    channels = int(audio_stream.get("channels") or 0)
    format_name = data.get("format", {}).get("format_name", "unknown")
    return AudioInfo(duration, sample_rate, channels, format_name)


def convert_to_analysis_wav(input_path: Path, output_path: Path) -> None:
    result = run_command(
        [
            "ffmpeg",
            "-y",
            "-i",
            str(input_path),
            "-ac",
            "1",
            "-ar",
            str(TARGET_SAMPLE_RATE),
            "-sample_fmt",
            "s16",
            str(output_path),
        ]
    )
    if result.returncode != 0:
        raise RuntimeError(f"ffmpeg conversion failed: {result.stderr.strip()}")


def cut_from_downbeat(input_path: Path, output_path: Path, start_seconds: float) -> None:
    result = run_command(
        [
            "ffmpeg",
            "-y",
            "-ss",
            f"{max(0.0, start_seconds):.6f}",
            "-i",
            str(input_path),
            "-ac",
            "2",
            "-ar",
            str(TARGET_SAMPLE_RATE),
            "-sample_fmt",
            "s16",
            str(output_path),
        ]
    )
    if result.returncode != 0:
        raise RuntimeError(f"ffmpeg downbeat cut failed: {result.stderr.strip()}")


def read_mono_wav(path: Path) -> Tuple[np.ndarray, int]:
    with wave.open(str(path), "rb") as wav:
        sample_rate = wav.getframerate()
        channels = wav.getnchannels()
        sample_width = wav.getsampwidth()
        frames = wav.readframes(wav.getnframes())

    if channels != 1 or sample_width != 2:
        raise RuntimeError("Analysis WAV must be mono 16-bit PCM.")

    samples = np.frombuffer(frames, dtype=np.int16).astype(np.float32) / 32768.0
    return samples, sample_rate


def frame_audio(samples: np.ndarray, frame_length: int, hop_length: int) -> np.ndarray:
    if len(samples) < frame_length:
        padded = np.zeros(frame_length, dtype=np.float32)
        padded[: len(samples)] = samples
        samples = padded

    frame_count = 1 + (len(samples) - frame_length) // hop_length
    shape = (frame_count, frame_length)
    strides = (samples.strides[0] * hop_length, samples.strides[0])
    return np.lib.stride_tricks.as_strided(samples, shape=shape, strides=strides)


def onset_envelope(samples: np.ndarray, sample_rate: int) -> np.ndarray:
    frames = frame_audio(samples, FRAME_LENGTH, HOP_LENGTH)
    window = np.hanning(FRAME_LENGTH).astype(np.float32)
    spectrum = np.abs(np.fft.rfft(frames * window, axis=1))
    flux = np.maximum(0, np.diff(spectrum, axis=0)).sum(axis=1)
    flux = np.concatenate([[0.0], flux])

    if np.max(flux) > 0:
        flux = flux / np.max(flux)

    # Light smoothing removes spurious single-frame crackle while keeping kicks.
    kernel_size = max(3, int(round(0.05 * sample_rate / HOP_LENGTH)))
    kernel = np.ones(kernel_size, dtype=np.float32) / kernel_size
    smoothed = np.convolve(flux, kernel, mode="same")
    if np.max(smoothed) > 0:
        smoothed = smoothed / np.max(smoothed)
    return smoothed.astype(np.float32)


def estimate_tempo(envelope: np.ndarray, sample_rate: int) -> Tuple[float, float]:
    centered = envelope - float(np.mean(envelope))
    if not np.any(centered):
        return 120.0, 0.0

    autocorr = np.correlate(centered, centered, mode="full")[len(centered) - 1 :]
    min_bpm, max_bpm = 80.0, 180.0
    min_lag = int(round(sample_rate * 60.0 / max_bpm / HOP_LENGTH))
    max_lag = int(round(sample_rate * 60.0 / min_bpm / HOP_LENGTH))
    max_lag = min(max_lag, len(autocorr) - 1)

    if max_lag <= min_lag:
        return 120.0, 0.0

    search = autocorr[min_lag : max_lag + 1]
    best_offset = int(np.argmax(search))
    best_lag = float(min_lag + best_offset)
    if 0 < best_offset < len(search) - 1:
        left, center, right = search[best_offset - 1], search[best_offset], search[best_offset + 1]
        denominator = left - (2.0 * center) + right
        if abs(float(denominator)) > 1e-9:
            best_lag += float(0.5 * (left - right) / denominator)
    bpm = 60.0 * sample_rate / (best_lag * HOP_LENGTH)
    confidence = float(search[best_offset] / (autocorr[0] + 1e-9))

    # House/disco often produces half/double-period candidates. Prefer practical DJ tempos.
    while bpm < 90:
        bpm *= 2
    while bpm > 160:
        bpm /= 2

    return bpm, max(0.0, min(confidence * 4.0, 1.0))


def refine_tempo_from_peaks(envelope: np.ndarray, sample_rate: int, initial_bpm: float) -> float:
    period_frames = (60.0 / initial_bpm) * sample_rate / HOP_LENGTH
    min_spacing = max(1, int(round(period_frames * 0.45)))
    threshold = max(0.08, float(np.percentile(envelope, 78)))
    peaks = peak_indices(envelope, min_spacing, threshold)
    if len(peaks) < 8:
        return initial_bpm

    diffs = np.diff(peaks).astype(np.float32)
    expected = period_frames
    close = diffs[(diffs > expected * 0.65) & (diffs < expected * 1.35)]
    if len(close) < 6:
        return initial_bpm

    median_period_frames = float(np.median(close))
    if median_period_frames <= 0:
        return initial_bpm
    refined = 60.0 * sample_rate / (median_period_frames * HOP_LENGTH)

    if abs(refined - initial_bpm) <= 3.0:
        return refined
    return initial_bpm


def peak_indices(envelope: np.ndarray, min_spacing: int, threshold: float) -> np.ndarray:
    if len(envelope) < 3:
        return np.array([], dtype=np.int64)

    candidates = np.where(
        (envelope[1:-1] > envelope[:-2])
        & (envelope[1:-1] >= envelope[2:])
        & (envelope[1:-1] >= threshold)
    )[0] + 1

    if len(candidates) == 0:
        return candidates.astype(np.int64)

    selected: List[int] = []
    for idx in candidates[np.argsort(envelope[candidates])[::-1]]:
        if all(abs(int(idx) - existing) >= min_spacing for existing in selected):
            selected.append(int(idx))
    selected.sort()
    return np.array(selected, dtype=np.int64)


def grid_score(envelope: np.ndarray, anchor: int, period_frames: float, lookahead: int = 16) -> float:
    score = 0.0
    weight_total = 0.0
    for beat in range(lookahead):
        pos = int(round(anchor + beat * period_frames))
        if pos < 0 or pos >= len(envelope):
            continue
        left = max(0, pos - 2)
        right = min(len(envelope), pos + 3)
        weight = 1.0 / (1.0 + beat * 0.08)
        score += float(np.max(envelope[left:right])) * weight
        weight_total += weight
    return score / weight_total if weight_total else 0.0


def choose_grid_anchor(envelope: np.ndarray, sample_rate: int, bpm: float) -> Tuple[float, List[float], float]:
    period_seconds = 60.0 / bpm
    period_frames = period_seconds * sample_rate / HOP_LENGTH
    min_spacing = max(1, int(round(period_frames * 0.45)))
    threshold = max(0.08, float(np.percentile(envelope, 82)))
    peaks = peak_indices(envelope, min_spacing, threshold)

    if len(peaks) == 0:
        return 0.0, [], 0.0

    search_limit_seconds = min(45.0, len(envelope) * HOP_LENGTH / sample_rate)
    search_limit_frame = int(round(search_limit_seconds * sample_rate / HOP_LENGTH))
    early_peaks = [int(p) for p in peaks if p <= search_limit_frame]
    if not early_peaks:
        early_peaks = [int(peaks[0])]

    scored = [(grid_score(envelope, p, period_frames), p) for p in early_peaks]
    scored.sort(key=lambda item: (-item[0], item[1]))
    best_score, best_anchor = scored[0]

    # Prefer an earlier anchor if it is almost as convincing as the best candidate.
    for score, anchor in sorted(scored, key=lambda item: item[1]):
        if score >= best_score * 0.86:
            best_anchor = anchor
            best_score = score
            break

    anchor_seconds = best_anchor * HOP_LENGTH / sample_rate
    duration_seconds = len(envelope) * HOP_LENGTH / sample_rate
    beat_positions: List[float] = []
    beat_index = 0
    while True:
        beat_time = anchor_seconds + beat_index * period_seconds
        if beat_time > duration_seconds:
            break
        beat_positions.append(round(beat_time, 6))
        beat_index += 1

    return round(anchor_seconds, 6), beat_positions, float(best_score)


def choose_grid_anchor_from_ticks(
    envelope: np.ndarray,
    sample_rate: int,
    bpm: float,
    ticks: Sequence[float],
) -> Tuple[float, List[float], float]:
    if not ticks:
        return choose_grid_anchor(envelope, sample_rate, bpm)

    period_seconds = 60.0 / bpm
    period_frames = period_seconds * sample_rate / HOP_LENGTH
    duration_seconds = len(envelope) * HOP_LENGTH / sample_rate
    candidates = [tick for tick in ticks if 0 <= tick <= min(45.0, duration_seconds)]
    if not candidates:
        candidates = [ticks[0]]

    scored = []
    for tick in candidates:
        frame = int(round(tick * sample_rate / HOP_LENGTH))
        scored.append((grid_score(envelope, frame, period_frames), float(tick)))
    scored.sort(key=lambda item: (-item[0], item[1]))
    best_score, best_anchor = scored[0]

    for score, anchor in sorted(scored, key=lambda item: item[1]):
        if score >= best_score * 0.86:
            best_score, best_anchor = score, anchor
            break

    beat_positions: List[float] = []
    beat_index = 0
    while True:
        beat_time = best_anchor + beat_index * period_seconds
        if beat_time > duration_seconds:
            break
        beat_positions.append(round(beat_time, 6))
        beat_index += 1

    return round(best_anchor, 6), beat_positions, float(best_score)


def tempo_drift_score(beat_positions: Sequence[float], envelope: np.ndarray, sample_rate: int) -> float:
    if len(beat_positions) < 24:
        return 0.0

    residuals: List[float] = []
    for beat_time in beat_positions:
        frame = int(round(beat_time * sample_rate / HOP_LENGTH))
        if 0 <= frame < len(envelope):
            left = max(0, frame - 5)
            right = min(len(envelope), frame + 6)
            local = envelope[left:right]
            if len(local) == 0:
                continue
            local_best = left + int(np.argmax(local))
            residuals.append(abs(local_best - frame) * HOP_LENGTH / sample_rate)

    if len(residuals) < 12:
        return 0.0

    period = float(np.median(np.diff(beat_positions)))
    normalized = np.array(residuals) / max(period, 1e-6)
    return float(np.percentile(normalized, 75))


def nearest_dj_bpm(bpm: float) -> float:
    rounded_whole = round(bpm)
    rounded_half = round(bpm * 2.0) / 2.0
    return rounded_half if abs(bpm - rounded_half) < abs(bpm - rounded_whole) else float(rounded_whole)


def ableton_precise_bpm(bpm: float) -> float:
    return round(float(bpm), 2)


def has_immediate_audio(samples: np.ndarray, sample_rate: int) -> bool:
    first_window = samples[: max(1, int(sample_rate * 0.08))]
    early_window = samples[: max(1, int(sample_rate * 0.5))]
    if len(first_window) == 0 or len(early_window) == 0:
        return False

    first_rms = float(np.sqrt(np.mean(first_window**2)))
    early_rms = float(np.sqrt(np.mean(early_window**2)))
    first_peak = float(np.max(np.abs(first_window)))

    return first_peak >= 0.08 and first_rms >= max(0.015, early_rms * 0.45)


def should_snap_anchor_to_file_start(samples: np.ndarray, sample_rate: int, anchor_seconds: float, bpm: float) -> bool:
    if anchor_seconds <= 0:
        return False
    if not has_immediate_audio(samples, sample_rate):
        return False

    period_seconds = 60.0 / bpm
    if period_seconds <= 0:
        return False

    beats_from_start = anchor_seconds / period_seconds
    nearest_beat = round(beats_from_start)
    if nearest_beat < 1:
        return False

    projected_start = anchor_seconds - nearest_beat * period_seconds
    tolerance = max(0.035, period_seconds * 0.08)
    return abs(projected_start) <= tolerance


def refine_anchor_to_transient_edge(samples: np.ndarray, sample_rate: int, anchor_seconds: float) -> float:
    """Snap a beat-grid estimate to the first real waveform attack near it."""
    if anchor_seconds <= 0:
        return 0.0

    search_start = max(0, int((anchor_seconds - 0.08) * sample_rate))
    search_end = min(len(samples), int((anchor_seconds + 0.20) * sample_rate))
    if search_end <= search_start:
        return anchor_seconds

    window_size = max(16, int(0.004 * sample_rate))
    hop_size = max(1, int(0.0005 * sample_rate))
    segment = samples[search_start:search_end]
    if len(segment) < window_size:
        return anchor_seconds

    rms_values: List[Tuple[int, float, float]] = []
    for offset in range(0, len(segment) - window_size + 1, hop_size):
        window = segment[offset : offset + window_size]
        rms = float(np.sqrt(np.mean(window**2)))
        peak = float(np.max(np.abs(window)))
        rms_values.append((offset, rms, peak))

    if not rms_values:
        return anchor_seconds

    max_rms = max(value[1] for value in rms_values)
    max_peak = max(value[2] for value in rms_values)
    if max_rms < 0.01 and max_peak < 0.04:
        return anchor_seconds

    baseline_end = max(0, int((anchor_seconds - 0.02) * sample_rate) - search_start)
    baseline_values = [rms for offset, rms, _peak in rms_values if offset < baseline_end]
    baseline = float(np.median(baseline_values)) if baseline_values else 0.0

    rms_threshold = max(0.01, baseline + max(0.006, max_rms * 0.08))
    peak_threshold = max(0.04, max_peak * 0.08)

    for index, (offset, rms, peak) in enumerate(rms_values):
        if rms < rms_threshold and peak < peak_threshold:
            continue
        next_values = rms_values[index : index + 3]
        if any(next_rms >= rms_threshold or next_peak >= peak_threshold for _next_offset, next_rms, next_peak in next_values):
            return round((search_start + offset) / sample_rate, 6)

    return anchor_seconds


def beat_positions_from_anchor(anchor_seconds: float, bpm: float, duration_seconds: float) -> List[float]:
    period_seconds = 60.0 / bpm
    positions: List[float] = []
    beat_index = 0
    while True:
        beat_time = anchor_seconds + beat_index * period_seconds
        if beat_time > duration_seconds:
            break
        positions.append(round(beat_time, 6))
        beat_index += 1
    return positions


def analyse_wav(path: Path) -> BeatAnalysis:
    samples, sample_rate = read_mono_wav(path)
    envelope = onset_envelope(samples, sample_rate)
    source = "numpy_spectral_flux_autocorrelation_v1"

    if essentia_standard is not None:
        loader = essentia_standard.MonoLoader(filename=str(path), sampleRate=TARGET_SAMPLE_RATE)
        audio = loader()
        rhythm_extractor = essentia_standard.RhythmExtractor2013(method="multifeature")
        bpm, ticks, tempo_confidence, _estimates, _bpm_intervals = rhythm_extractor(audio)
        bpm = float(bpm)
        ticks = [float(tick) for tick in ticks]
        anchor_seconds, beats, anchor_score = choose_grid_anchor(envelope, sample_rate, bpm)
        if anchor_seconds == 0.0:
            anchor_seconds, beats, anchor_score = choose_grid_anchor_from_ticks(envelope, sample_rate, bpm, ticks)
        source = "essentia_rhythm_extractor_2013"
    else:
        bpm, tempo_confidence = estimate_tempo(envelope, sample_rate)
        bpm = refine_tempo_from_peaks(envelope, sample_rate, bpm)
        anchor_seconds, beats, anchor_score = choose_grid_anchor(envelope, sample_rate, bpm)

    boundary_correction_applied = False
    if should_snap_anchor_to_file_start(samples, sample_rate, anchor_seconds, bpm):
        anchor_seconds = 0.0
        beats = beat_positions_from_anchor(0.0, bpm, len(samples) / sample_rate)
        boundary_correction_applied = True
    else:
        refined_anchor = refine_anchor_to_transient_edge(samples, sample_rate, anchor_seconds)
        if abs(refined_anchor - anchor_seconds) <= 0.2:
            anchor_seconds = refined_anchor
            beats = beat_positions_from_anchor(anchor_seconds, bpm, len(samples) / sample_rate)

    drift = tempo_drift_score(beats, envelope, sample_rate)
    fixed_tempo = drift < 0.08 and tempo_confidence >= 0.18
    confidence = max(0.0, min((tempo_confidence * 0.65) + (anchor_score * 0.35), 1.0))

    warnings: List[str] = []
    if confidence < 0.35:
        warnings.append("Low confidence: check the BPM and first downbeat manually in Ableton.")
    if not fixed_tempo:
        warnings.append("Possible tempo drift: this may need manual warp markers, especially for live drums or disco edits.")
    if anchor_seconds == 0.0 and not boundary_correction_applied:
        warnings.append("No strong grid anchor found; using the file start as a fallback.")

    return BeatAnalysis(
        bpm=round(float(bpm), 3),
        ableton_bpm=ableton_precise_bpm(float(bpm)),
        grid_anchor_seconds=anchor_seconds,
        beat_positions_seconds=beats,
        confidence=round(float(confidence), 3),
        fixed_tempo=fixed_tempo,
        tempo_drift_score=round(float(drift), 3),
        method=source,
        warnings=warnings,
        source=source,
    )


def mvsep_stem_name(path: Path) -> Optional[str]:
    lower = path.name.lower()
    if "drum" in lower:
        return "drums"
    if "bass" in lower:
        return "bass"
    if "vocal" in lower:
        return "vocals"
    if "other" in lower:
        return "other"
    return None


def download_mvsep_file(url: str, target: Path) -> None:
    if requests is None:
        raise RuntimeError("The requests package is required for MVSEP downloads.")
    target.parent.mkdir(parents=True, exist_ok=True)
    with requests.get(url, stream=True, timeout=120) as response:
        response.raise_for_status()
        with target.open("wb") as handle:
            for chunk in response.iter_content(chunk_size=1024 * 1024):
                if chunk:
                    handle.write(chunk)


def run_mvsep_api(
    input_audio: Path,
    stems_dir: Path,
    *,
    api_token: str,
    poll_seconds: int,
    timeout_minutes: int,
) -> MvsepResult:
    if requests is None:
        raise RuntimeError("The requests package is required for MVSEP splitting.")

    mvsep_raw_dir = stems_dir / "mvsep-raw"
    final_dir = stems_dir / "final"
    mvsep_raw_dir.mkdir(parents=True, exist_ok=True)
    final_dir.mkdir(parents=True, exist_ok=True)

    with input_audio.open("rb") as audio_handle:
        files = {
            "audiofile": (input_audio.name, audio_handle, "application/octet-stream"),
            "api_token": (None, api_token),
            "sep_type": (None, MVSEP_API_SEP_TYPE_5_STEM_ENSEMBLE),
            "add_opt1": (None, MVSEP_API_STANDARD_OUTPUTS),
            "add_opt2": (None, MVSEP_API_MODEL_LATEST_5_STEM),
            "output_format": (None, os.environ.get("MVSEP_OUTPUT_FORMAT", MVSEP_API_OUTPUT_FLAC_24)),
            "is_demo": (None, "0"),
        }
        create_response = requests.post(MVSEP_API_CREATE_URL, files=files, timeout=180)
    create_response.raise_for_status()
    create_payload = create_response.json()
    if not create_payload.get("success"):
        data = create_payload.get("data", {}) if isinstance(create_payload.get("data"), dict) else {}
        return MvsepResult("failed", {}, [], list(EXPECTED_MVSEP_STEMS), message=data.get("message") or "MVSEP rejected the job.")

    job_hash = create_payload.get("data", {}).get("hash")
    if not job_hash:
        return MvsepResult("failed", {}, [], list(EXPECTED_MVSEP_STEMS), message="MVSEP did not return a job hash.")

    deadline = time.time() + timeout_minutes * 60
    result_payload: Optional[Dict] = None
    while time.time() < deadline:
        result_response = requests.get(MVSEP_API_RESULT_URL, params={"hash": job_hash}, timeout=60)
        result_response.raise_for_status()
        result_payload = result_response.json()
        status = result_payload.get("status")
        data = result_payload.get("data", {}) if isinstance(result_payload.get("data"), dict) else {}
        if status == "done":
            break
        if status in {"failed", "not_found"}:
            return MvsepResult("failed", {}, [], list(EXPECTED_MVSEP_STEMS), job_hash, data.get("message") or f"MVSEP status: {status}")
        time.sleep(max(5, poll_seconds))

    if not result_payload or result_payload.get("status") != "done":
        return MvsepResult("failed", {}, [], list(EXPECTED_MVSEP_STEMS), job_hash, f"Timed out after {timeout_minutes} minutes.")

    data = result_payload.get("data", {}) if isinstance(result_payload.get("data"), dict) else {}
    raw_files: List[Dict] = []
    raw_stems: Dict[str, str] = {}
    for file_info in data.get("files") or []:
        url = str(file_info.get("url", "")).replace("\\/", "/")
        filename = str(file_info.get("download") or Path(url).name)
        if not url or not filename:
            continue
        target = mvsep_raw_dir / filename
        download_mvsep_file(url, target)
        stem_name = mvsep_stem_name(target)
        raw_files.append({"download": filename, "path": str(target), "stem_name": stem_name})
        if stem_name and stem_name not in raw_stems:
            raw_stems[stem_name] = str(target)

    final_stems: Dict[str, str] = {}
    for stem in EXPECTED_MVSEP_STEMS:
        if stem in raw_stems:
            source = Path(raw_stems[stem])
            target = final_dir / f"{input_audio.stem}_{stem}{source.suffix}"
            shutil.copy2(source, target)
            final_stems[stem] = str(target)

    missing = [stem for stem in EXPECTED_MVSEP_STEMS if stem not in final_stems]
    status = "complete" if not missing else "incomplete"
    return MvsepResult(status, final_stems, raw_files, missing, job_hash)


def format_timestamp(seconds: float) -> str:
    minutes = int(seconds // 60)
    rem = seconds - minutes * 60
    return f"{minutes}:{rem:06.3f}"


def write_json(path: Path, data: Dict) -> None:
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")


def write_notes(path: Path, track_name: str, analysis: BeatAnalysis, mvsep_result: Optional[MvsepResult] = None) -> None:
    lines = [
        f"Ableton import notes for: {track_name}",
        "",
        f"Set Ableton tempo to: {analysis.ableton_bpm:g} BPM",
        f"Detected BPM: {analysis.bpm:g}",
        f"Confidence: {analysis.confidence:.2f}",
        "",
        "DJ cue point:",
        f"- First downbeat starts at {analysis.grid_anchor_seconds:.3f} seconds ({format_timestamp(analysis.grid_anchor_seconds)}) into the original audio file.",
        "- This is the point a DJ would cue as the first beat.",
        "",
        "Prepared file:",
        "- Use prepared-from-downbeat.wav for MVSEP and Ableton stem import.",
        "- This file has already been cut so the first downbeat is the very start of the file.",
        "",
        "Manual import:",
        "1. Drag prepared-from-downbeat.wav and the stems into Ableton.",
        f"2. Set Ableton tempo to {analysis.ableton_bpm:g} BPM.",
        "3. Place every clip at bar 1 beat 1.",
        "4. If Ableton asks, treat the file start as 1.1.1.",
        "5. The original uncut file is kept as original.wav for reference.",
        "",
    ]

    if analysis.fixed_tempo:
        lines.append("Tempo type: likely fixed tempo.")
    else:
        lines.append("Tempo type: possible drift; check the grid further into the track.")

    if analysis.warnings:
        lines.extend(["", "Warnings:"])
        lines.extend(f"- {warning}" for warning in analysis.warnings)

    if mvsep_result:
        lines.extend(["", "MVSEP stems:"])
        lines.append(f"- Status: {mvsep_result.status}")
        for stem in EXPECTED_MVSEP_STEMS:
            if stem in mvsep_result.stems:
                lines.append(f"- {stem}: {mvsep_result.stems[stem]}")
            else:
                lines.append(f"- {stem}: missing")
        if mvsep_result.message:
            lines.append(f"- Message: {mvsep_result.message}")

    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def process_track(input_path: Path, output_root: Path, split_with_mvsep: bool = False) -> Path:
    load_env_file(PROJECT_ROOT / ".env")
    if not input_path.exists():
        raise RuntimeError(f"Input file does not exist: {input_path}")
    if input_path.suffix.lower() not in SUPPORTED_SUFFIXES:
        raise RuntimeError(f"Unsupported audio file type: {input_path.suffix}")

    if not shutil.which("ffmpeg") or not shutil.which("ffprobe"):
        raise RuntimeError("ffmpeg and ffprobe are required for this tool.")

    info = probe_audio(input_path)
    output_root.mkdir(parents=True, exist_ok=True)
    output_dir = unique_output_dir(output_root, slugify(input_path.stem))
    stems_dir = output_dir / "stems"
    stems_dir.mkdir(parents=True)

    original_wav = output_dir / "original.wav"
    convert_to_analysis_wav(input_path, original_wav)
    analysis = analyse_wav(original_wav)
    prepared_wav = output_dir / "prepared-from-downbeat.wav"
    cut_from_downbeat(original_wav, prepared_wav, analysis.grid_anchor_seconds)

    mvsep_result: Optional[MvsepResult] = None
    if split_with_mvsep:
        api_token = os.environ.get("MVSEP_API_TOKEN")
        if not api_token:
            raise RuntimeError("MVSEP_API_TOKEN is not set. Add it to .env or export it in the shell.")
        poll_seconds = int(os.environ.get("MVSEP_POLL_SECONDS", "20"))
        timeout_minutes = int(os.environ.get("MVSEP_TIMEOUT_MINUTES", "180"))
        mvsep_result = run_mvsep_api(
            prepared_wav,
            stems_dir,
            api_token=api_token,
            poll_seconds=poll_seconds,
            timeout_minutes=timeout_minutes,
        )

    created_at = datetime.now().astimezone().isoformat(timespec="seconds")
    analysis_json = {
        "created_at": created_at,
        "input_file": str(input_path),
        "original_wav": str(original_wav),
        "prepared_wav": str(prepared_wav),
        "audio_info": {
            "duration_seconds": round(info.duration_seconds, 3),
            "sample_rate": info.sample_rate,
            "channels": info.channels,
            "format_name": info.format_name,
        },
        "analysis": {
            "bpm": analysis.bpm,
            "ableton_bpm": analysis.ableton_bpm,
            "dj_rounded_bpm": nearest_dj_bpm(analysis.bpm),
            "grid_anchor_seconds": analysis.grid_anchor_seconds,
            "dj_cue_point_seconds": analysis.grid_anchor_seconds,
            "grid_anchor_label": "1.1.1",
            "beat_positions_seconds": analysis.beat_positions_seconds,
            "confidence": analysis.confidence,
            "fixed_tempo": analysis.fixed_tempo,
            "tempo_drift_score": analysis.tempo_drift_score,
            "method": analysis.method,
            "source": analysis.source,
            "warnings": analysis.warnings,
        },
    }
    if mvsep_result:
        analysis_json["mvsep"] = {
            "status": mvsep_result.status,
            "job_hash": mvsep_result.job_hash,
            "stems": mvsep_result.stems,
            "raw_files": mvsep_result.raw_files,
            "missing_stems": mvsep_result.missing_stems,
            "message": mvsep_result.message,
            "settings": {
                "sep_type": int(MVSEP_API_SEP_TYPE_5_STEM_ENSEMBLE),
                "add_opt1": MVSEP_API_STANDARD_OUTPUTS,
                "add_opt2": MVSEP_API_MODEL_LATEST_5_STEM,
                "output_format": os.environ.get("MVSEP_OUTPUT_FORMAT", MVSEP_API_OUTPUT_FLAC_24),
                "is_demo": "0",
            },
        }

    manifest_json = {
        "schema_version": 1,
        "created_at": created_at,
        "track_name": input_path.stem,
        "files": {
            "original": str(original_wav),
            "prepared_from_downbeat": str(prepared_wav),
            "stems_dir": str(stems_dir),
            "stems": mvsep_result.stems if mvsep_result else {},
        },
        "ableton": {
            "project_bpm": analysis.ableton_bpm,
            "detected_bpm": analysis.bpm,
            "dj_rounded_bpm": nearest_dj_bpm(analysis.bpm),
            "grid_anchor_seconds": analysis.grid_anchor_seconds,
            "dj_cue_point_seconds": analysis.grid_anchor_seconds,
            "grid_anchor_label": "1.1.1",
            "clip_start_seconds": 0,
            "manual_instruction": "Use prepared-from-downbeat.wav and final stems. Place all clips at bar 1 beat 1.",
        },
        "quality": {
            "confidence": analysis.confidence,
            "fixed_tempo": analysis.fixed_tempo,
            "warnings": analysis.warnings,
        },
        "mvsep": {
            "requested": split_with_mvsep,
            "status": mvsep_result.status if mvsep_result else "not_requested",
            "missing_stems": mvsep_result.missing_stems if mvsep_result else [],
        },
    }

    write_json(output_dir / "analysis.json", analysis_json)
    write_json(output_dir / "manifest.json", manifest_json)
    write_notes(output_dir / "ableton-import-notes.txt", input_path.stem, analysis, mvsep_result)

    return output_dir


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Analyse a track and create Ableton stem-prep metadata.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    process = subparsers.add_parser("process", help="Process one audio file.")
    process.add_argument("audio_file", help="Path to the audio file to analyse.")
    process.add_argument(
        "--output-root",
        default=str(DEFAULT_OUTPUT_ROOT),
        help=f"Folder for generated outputs. Default: {DEFAULT_OUTPUT_ROOT}",
    )
    process.add_argument(
        "--mvsep",
        action="store_true",
        help="Send prepared-from-downbeat.wav to MVSEP and download drums, bass, other, and vocals.",
    )

    split = subparsers.add_parser("split", help="Analyse, cut from downbeat, send to MVSEP, and download stems.")
    split.add_argument("audio_file", help="Path to the audio file to analyse and split.")
    split.add_argument(
        "--output-root",
        default=str(DEFAULT_OUTPUT_ROOT),
        help=f"Folder for generated outputs. Default: {DEFAULT_OUTPUT_ROOT}",
    )

    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    try:
        if args.command == "process":
            output_dir = process_track(
                Path(args.audio_file).expanduser().resolve(),
                Path(args.output_root).expanduser().resolve(),
                split_with_mvsep=args.mvsep,
            )
            print(f"Created Ableton prep folder: {output_dir}")
            print(f"Read this first: {output_dir / 'ableton-import-notes.txt'}")
            return 0
        if args.command == "split":
            output_dir = process_track(
                Path(args.audio_file).expanduser().resolve(),
                Path(args.output_root).expanduser().resolve(),
                split_with_mvsep=True,
            )
            print(f"Created Ableton prep folder: {output_dir}")
            print(f"Read this first: {output_dir / 'ableton-import-notes.txt'}")
            return 0
    except Exception as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
