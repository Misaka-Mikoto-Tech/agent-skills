"""
FunASR audio to subtitle converter.
Usage: python audio2srt.py <input_audio> [--output <output_dir>]
"""

import os, sys, json, argparse, re
from pathlib import Path


def ms_to_srt_time(ms: float) -> str:
    """Convert milliseconds to SRT time format HH:MM:SS,mmm"""
    if ms < 0:
        ms = 0
    total_sec = ms / 1000.0
    h = int(total_sec // 3600)
    m = int((total_sec % 3600) // 60)
    s = int(total_sec % 60)
    ms_remain = int(ms % 1000)
    return f"{h:02d}:{m:02d}:{s:02d},{ms_remain:03d}"


def clean_sensevoice_tags(text: str) -> str:
    """Remove SenseVoice special tags like <|zh|>, <|HAPPY|>, etc."""
    text = re.sub(r'<\s*\|\s*[a-zA-Z_]+\s*\|\s*>', '', text)
    text = text.strip()
    return text


def segments_to_srt(segments: list) -> str:
    """Convert segment list to SRT format string."""
    lines = []
    for i, seg in enumerate(segments, 1):
        start = seg.get("start", 0)
        end = seg.get("end", start + 1000)
        text = seg.get("text", "").strip()
        if not text:
            continue
        lines.append(str(i))
        lines.append(f"{ms_to_srt_time(start)} --> {ms_to_srt_time(end)}")
        lines.append(text)
        lines.append("")
    return "\n".join(lines)


def segments_to_vtt(segments: list) -> str:
    """Convert segment list to VTT format string."""
    lines = ["WEBVTT", ""]
    for seg in segments:
        start = seg.get("start", 0)
        end = seg.get("end", start + 1000)
        text = seg.get("text", "").strip()
        if not text:
            continue
        lines.append(f"{ms_to_srt_time(start).replace(',', '.')} --> {ms_to_srt_time(end).replace(',', '.')}")
        lines.append(text)
        lines.append("")
    return "\n".join(lines)


def extract_timestamp_segments(result_item: dict, total_duration_ms: float = 0) -> list:
    """
    Extract segments with timestamps from a FunASR result item.
    
    Priority:
    1. sentence_info (with spk_model) - per-sentence start/end/str
    2. timestamp (per character) + text - group by punctuation
    3. text only - fallback, create one segment
    """
    segments = []
    
    # Method 1: sentence_info (from speaker diarization)
    sentence_info = result_item.get("sentence_info")
    if sentence_info and isinstance(sentence_info, list) and len(sentence_info) > 0:
        for sent in sentence_info:
            text = sent.get("text", sent.get("sentence", "")).strip()
            if not text:
                continue
            text = clean_sensevoice_tags(text)
            if not text:
                continue
            start = sent.get("start", 0)
            end = sent.get("end", 0)
            if isinstance(start, float) and start < 100:
                # May be in seconds, convert to ms
                start = start * 1000
            if isinstance(end, float) and end < 100:
                end = end * 1000
            segments.append({
                "start": int(start),
                "end": int(end),
                "text": text
            })
        return segments
    
    # Method 2: per-character timestamp + text
    timestamps = result_item.get("timestamp")
    text = result_item.get("text", "")
    if timestamps and isinstance(timestamps, list) and len(timestamps) > 0 and text:
        text = clean_sensevoice_tags(text)
        if text:
            # Split text into sentences by punctuation
            sentences = re.split(r'([，。！？、；：,.!?;:\n])', text)
            # Rejoin punctuation with preceding text
            merged = []
            buf = ""
            for part in sentences:
                buf += part
                if re.match(r'[，。！？、；：,.!?;:\n]', part):
                    if buf.strip():
                        merged.append(buf.strip())
                    buf = ""
            if buf.strip():
                merged.append(buf.strip())
            
            # Map each sentence to character positions in the text
            char_pos = 0
            clean_text = text
            for sent in merged:
                sent_len = len(sent)
                start_idx = clean_text.find(sent, char_pos)
                if start_idx < 0:
                    # Try fuzzy match if exact match fails
                    # Just use character position estimate
                    ratio = char_pos / max(len(clean_text), 1)
                    start_t = int(ratio * total_duration_ms) if total_duration_ms > 0 else 0
                    end_t = int((char_pos + sent_len) / max(len(clean_text), 1) * total_duration_ms) if total_duration_ms > 0 else 1000
                    segments.append({"start": start_t, "end": end_t, "text": sent})
                    char_pos += sent_len
                    continue
                
                char_pos = start_idx + sent_len
                if start_idx < len(timestamps):
                    start_ms = timestamps[min(start_idx, len(timestamps)-1)]
                    if isinstance(start_ms, (list, tuple)):
                        start_ms = start_ms[0]
                    end_idx = min(char_pos - 1, len(timestamps) - 1)
                    end_ms = timestamps[end_idx]
                    if isinstance(end_ms, (list, tuple)):
                        end_ms = end_ms[1]
                    segments.append({
                        "start": int(start_ms),
                        "end": int(end_ms),
                        "text": sent
                    })
                else:
                    segments.append({"start": 0, "end": 1000, "text": sent})
            
            return segments
    
    # Method 3: just text with sensevoice tags
    if text:
        text = clean_sensevoice_tags(text)
        if text:
            segments.append({"start": 0, "end": int(total_duration_ms), "text": text})
    
    return segments


def main():
    parser = argparse.ArgumentParser(description="FunASR audio to subtitle converter")
    parser.add_argument("input", help="Input audio file path")
    parser.add_argument("--output", "-o", default=None, help="Output directory (default: same as input)")
    parser.add_argument("--model", default="iic/SenseVoiceSmall",
                        help="ASR model (default: iic/SenseVoiceSmall)")
    parser.add_argument("--vad-model", default="fsmn-vad", help="VAD model")
    parser.add_argument("--punc-model", default=None, help="Punctuation model (auto for SenseVoice)")
    parser.add_argument("--spk-model", default=None, help="Speaker diarization model")
    parser.add_argument("--device", default="cpu", help="Device: cpu or cuda")
    parser.add_argument("--srt", action="store_true", default=True, help="Output SRT")
    parser.add_argument("--vtt", action="store_true", default=False, help="Output VTT")
    parser.add_argument("--json", action="store_true", default=False, help="Output raw JSON")
    args = parser.parse_args()
    
    audio_path = os.path.abspath(args.input)
    if not os.path.isfile(audio_path):
        print(f"Error: audio file not found: {audio_path}")
        sys.exit(1)
    
    if args.output:
        out_dir = os.path.abspath(args.output)
        os.makedirs(out_dir, exist_ok=True)
    else:
        out_dir = os.path.dirname(audio_path) or "."
    
    stem = Path(audio_path).stem
    
    # Get audio duration
    import subprocess
    ffprobe = "ffprobe.exe"
    try:
        r = subprocess.run([ffprobe, "-v", "quiet", "-show_entries", "format=duration",
                            "-of", "csv=p=0", audio_path], capture_output=True, text=True, timeout=15)
        duration_sec = float(r.stdout.strip())
        total_duration_ms = int(duration_sec * 1000)
    except:
        total_duration_ms = 0
    
    print(f"🎯 Audio: {audio_path}")
    print(f"🎯 Model: {args.model}")
    print(f"🎯 Device: {args.device}")
    print(f"📐 Loading models...", flush=True)
    
    # Use caller-provided ModelScope paths when available; otherwise fall back
    # to local output paths to avoid sandbox permission issues.
    cred_path = os.environ.get('MODELSCOPE_CREDENTIAL_PATH') or os.path.join(out_dir, '.modelscope_cred')
    os.makedirs(cred_path, exist_ok=True)
    os.environ['MODELSCOPE_CREDENTIAL_PATH'] = cred_path
    os.environ['MODELSCOPE_CACHE'] = os.environ.get('MODELSCOPE_CACHE') or os.path.join(out_dir, '.cache', 'modelscope', 'hub')
    
    import modelscope.hub.api as _ms_api
    _ms_api.ModelScopeConfig.path_credential = cred_path
    
    from funasr import AutoModel
    
    model_kwargs = dict(
        model=args.model,
        vad_model=args.vad_model,
        device=args.device,
        disable_update=True,
        disable_progress_bar=False,
    )
    if args.punc_model:
        model_kwargs["punc_model"] = args.punc_model
    if args.spk_model:
        model_kwargs["spk_model"] = args.spk_model
    
    model = AutoModel(**model_kwargs)
    
    print(f"✍️  Transcribing... (this may take a while on CPU)", flush=True)
    result = model.generate(input=audio_path)
    
    print(f"📊 Raw result: {len(result)} item(s)", flush=True)
    
    all_segments = []
    if isinstance(result, list):
        for item in result:
            segments = extract_timestamp_segments(item, total_duration_ms)
            all_segments.extend(segments)
    elif isinstance(result, dict):
        segments = extract_timestamp_segments(result, total_duration_ms)
        all_segments.extend(segments)
    
    if not all_segments:
        # Fallback: print all keys of result for debugging
        if isinstance(result, list) and len(result) > 0:
            print(f"⚠️  No segments extracted. Available keys: {list(result[0].keys())}", flush=True)
        sys.exit(1)
    
    # Sort by start time
    all_segments.sort(key=lambda x: x.get("start", 0))
    
    print(f"📊 Got {len(all_segments)} subtitle segments", flush=True)
    
    # Save SRT
    if args.srt:
        srt_path = os.path.join(out_dir, f"{stem}.srt")
        srt_content = segments_to_srt(all_segments)
        with open(srt_path, "w", encoding="utf-8") as f:
            f.write(srt_content)
        print(f"✅ SRT saved: {srt_path} ({len(srt_content)} chars)", flush=True)
    
    if args.vtt:
        vtt_path = os.path.join(out_dir, f"{stem}.vtt")
        vtt_content = segments_to_vtt(all_segments)
        with open(vtt_path, "w", encoding="utf-8") as f:
            f.write(vtt_content)
        print(f"✅ VTT saved: {vtt_path}", flush=True)
    
    if args.json:
        json_path = os.path.join(out_dir, f"{stem}.json")
        with open(json_path, "w", encoding="utf-8") as f:
            json.dump(all_segments, f, ensure_ascii=False, indent=2)
        print(f"✅ JSON saved: {json_path}", flush=True)
    
    # Preview
    print(f"\n📝 Preview (first 8 segments):")
    for seg in all_segments[:8]:
        start_s = seg["start"] / 1000.0
        end_s = seg["end"] / 1000.0
        print(f"   [{start_s:.1f}s -> {end_s:.1f}s] {seg['text'][:60]}")
    if len(all_segments) > 8:
        print(f"   ... and {len(all_segments) - 8} more segments")


if __name__ == "__main__":
    main()
