"""
Clean CJK-noise lines from SRT subtitle files.
Usage: python clean_srt.py <input.srt> [output.srt]
"""
import re, sys

def clean_srt(input_path, output_path=None):
    if output_path is None:
        output_path = input_path.replace('.srt', '_clean.srt')

    with open(input_path, 'r', encoding='utf-8') as f:
        content = f.read()

    lines = content.strip().split('\n')
    cleaned = []
    idx = 1
    i = 0
    removed = 0

    while i < len(lines):
        line = lines[i].strip()
        if not line:
            i += 1
            continue
        if re.match(r'^\d+$', line) and i + 2 < len(lines):
            ts = lines[i + 1].strip()
            if '-->' in ts:
                txt = lines[i + 2].strip()
                cjk = len(re.findall(r'[\u4e00-\u9fff\u3040-\u30ff]', txt))
                if cjk == 0 or cjk / max(len(txt), 1) <= 0.8:
                    cleaned.append(str(idx))
                    cleaned.append(ts)
                    cleaned.append(txt)
                    cleaned.append('')
                    idx += 1
                else:
                    removed += 1
                i += 4
                continue
        i += 1

    result = '\n'.join(cleaned)
    with open(output_path, 'w', encoding='utf-8') as f:
        f.write(result)

    print(f"✅ Cleaned: {idx - 1} subtitles (removed {removed} CJK-noise lines)")
    return idx - 1

if __name__ == '__main__':
    if len(sys.argv) < 2:
        print("Usage: python clean_srt.py <input.srt> [output.srt]")
        sys.exit(1)
    input_path = sys.argv[1]
    output_path = sys.argv[2] if len(sys.argv) > 2 else None
    clean_srt(input_path, output_path)
