---
name: bilibili-page-reader
description: "Get content from Bilibili videos: official subtitles, danmaku (density/peaks/sample), comments. When no subtitles exist (no 投稿字幕), fall back to downloading audio + ASR transcription via FunASR."
---

# Bilibili Page Reader

## Core Rules

- **Browser access** via `kimi-webbridge` for page state, login-only data, Bilibili Evolved (BE) providers.
- **Do not click BE download buttons.** Call providers directly via evaluate.
- **Always use a named session.** A session-less evaluate may land on a different tab and silently return wrong data.
- **Network calls outside the browser** (audio download, playurl API) use Node.js — PowerShell's `curl.exe` and Python's requests both get blocked by Bilibili CDN TLS fingerprinting on this platform.

---

## Workflow Overview

```
                    ┌─ BE downloadSubtitles provider ──→ 投稿字幕 (timestamps)
                    │
BiliBili video ───┼─ BE downloadDanmaku provider ────→ danmaku density/peaks/sample
                    │
                    └─ No subtitles? ──→ Audio transcription fallback
                                         1. Get audio stream URL (Node.js → playurl API)
                                         2. Download .m4s audio
                                         3. ffmpeg → .m4a
                                         4. FunASR paraformer-zh → SRT with timestamps
```

---

## Phase 1: Subtitles (preferred — via BE)

Use the one-shot evaluate below. It returns both subtitles and danmaku in a single call.

### Setup

```bash
~/.kimi-webbridge/bin/kimi-webbridge status
```

```json
{"action":"navigate","args":{"url":"https://www.bilibili.com/video/BV.../","newTab":true},"session":"bilibili"}
```

Wait 2–3 seconds for BE to fully initialize.

### One-shot evaluate

```js
(async () => {
  const pa = window.bilibiliEvolved.pluginApis;

  // ── Identifiers ──
  const s = window.__INITIAL_STATE__ || {};
  const vd = s.videoData || {};
  const bvid = vd.bvid || s.bvid || location.pathname.match(/BV[\w]+/)?.[0];
  const aid = vd.aid || s.aid;
  const pages = vd.pages || [];
  const p = parseInt(new URLSearchParams(location.search).get('p') || '1') - 1;
  const cid = pages[p]?.cid || vd.cid || s.cid || pages[0]?.cid;
  const title = vd.title || document.title;

  // ── Register providers ──
  pa.registerData('downloadVideo.assets', []);

  // ── Poll for providers (downloadDanmaku loads async, ~1-2s) ──
  function getProviders() {
    const g = pa.getData('downloadVideo.assets');
    return Array.isArray(g[0]) ? g.flat() : g;
  }
  const deadline = Date.now() + 5000;
  let providers = getProviders();
  while (!providers.find(p => p.name === 'downloadDanmaku') && Date.now() < deadline) {
    await new Promise(r => setTimeout(r, 300));
    providers = getProviders();
  }

  // ── Subtitles: try 投稿字幕 first ──
  let subResult = { count: 0, text: '', source: 'none' };
  const subProvider = providers.find(p => p.name === 'downloadSubtitles');
  if (subProvider) {
    try {
      const subAssets = await subProvider.getAssets([{ input: {} }], { type: 'json', enabled: true });
      const subRaw = subAssets[0].data;
      let subText;
      if (subRaw instanceof Blob) {
        const buf = await subRaw.arrayBuffer();
        subText = new TextDecoder('utf-8').decode(buf);
      } else {
        subText = String(subRaw);
      }
      const subtitles = JSON.parse(subText);
      const subLines = subtitles.map(s => {
        const totalSec = Math.floor(s.from);
        const h = Math.floor(totalSec / 3600);
        const m = Math.floor((totalSec % 3600) / 60);
        const sec = String(totalSec % 60).padStart(2, '0');
        if (h > 0) {
          return '[' + h + ':' + String(m).padStart(2, '0') + ':' + sec + '] ' + s.content;
        }
        return '[' + m + ':' + sec + '] ' + s.content;
      });
      subResult = { count: subtitles.length, text: subLines.join('\n'), source: '投稿字幕' };
    } catch(e) {
      subResult = { count: 0, text: '', source: '投稿字幕_error' };
    }
  }

  // ── Danmaku: analyze in-page, summary only ──
  const dmk = providers.find(p => p.name === 'downloadDanmaku');
  const dmkAssets = await dmk.getAssets(
    [{ input: { aid: String(aid), cid: String(cid) } }],
    { type: 'json', enabled: true }
  );
  const dmkRaw = dmkAssets[0].data;
  let dmkText;
  if (dmkRaw instanceof Blob) {
    const buf = await dmkRaw.arrayBuffer();
    dmkText = new TextDecoder('utf-8').decode(buf);
  } else {
    dmkText = String(dmkRaw);
  }
  const danmaku = JSON.parse(dmkText);

  // Time density: 30s buckets
  const bucketSize = 30;
  const buckets = {};
  for (const d of danmaku) {
    const b = Math.floor(d.progress / 1000 / bucketSize) * bucketSize;
    buckets[b] = (buckets[b] || 0) + 1;
  }
  const density = Object.entries(buckets)
    .map(([t, c]) => [Number(t), c])
    .sort((a, b) => a[0] - b[0]);

  // Top 5 peak moments
  const peaks = density.slice().sort((a, b) => b[1] - a[1]).slice(0, 5);

  // Stratified sample: up to 40 entries across full timeline
  const sampleCount = Math.min(40, danmaku.length);
  const step = Math.max(1, Math.floor(danmaku.length / sampleCount));
  const danmakuSample = [];
  for (let i = 0; i < danmaku.length && danmakuSample.length < sampleCount; i += step) {
    danmakuSample.push({
      t: Math.floor(danmaku[i].progress / 1000),
      c: danmaku[i].content
    });
  }

  const totalDuration = danmaku.length > 0
    ? Math.max(...danmaku.map(d => d.progress)) : 0;

  // ── Return ──
  return JSON.stringify({
    ok: true, bvid, aid: Number(aid), cid: Number(cid), p: p + 1, title,
    sub: subResult,
    dmk: {
      count: danmaku.length,
      timeSpanSec: Math.floor(totalDuration / 1000),
      density,
      peakMoments: peaks.map(pk => ({ timeSec: pk[0], count: pk[1] })),
      sample: danmakuSample
    }
  });
})()
```

### Response shape

```json
{
  "sub": {
    "count": 243,
    "text": "[0:00] 大家好\n[0:01] 这个视频...",
    "source": "投稿字幕"
  },
  "dmk": {
    "count": 247,
    "density": [[0,11], [30,2], ...],
    "peakMoments": [{"timeSec": 1170, "count": 16}, ...],
    "sample": [{"t": 0, "c": "辛苦惹！"}, ...]
  }
}
```

If `sub.count === 0`, no 投稿字幕 was available. Proceed to **Phase 2** below.

---

## Phase 2: Audio Transcription Fallback (when no subtitles exist)

Use when Phase 1 returns `sub.count === 0`. This replaces the old "AI subtitle API" fallback which is unreliable — the `/x/player/v2` API often returns stale/empty subtitle data.

### Why this approach

The Bilibili CDN uses **TLS fingerprinting** that blocks curl and Python requests. Reliable paths:

| Method | Works? | Notes |
|--------|--------|-------|
| `curl.exe` with browser headers | ❌ Exit code 35 | SSL blocked |
| Python `requests` / `urllib` | ❌ Blocked | Same reason |
| Node.js `https.get()` | ✅ | Use `User-Agent` + `Referer` headers |
| Browser fetch (in-page) | ✅ but evaluate timeout <1s | Only for fast API calls |
| Node.js to download audio | ✅ | Backup URL is most stable |

### Step 1: Get audio stream URL via Node.js

```bash
node -e "
const https = require('https');
const url = 'https://api.bilibili.com/x/player/playurl' +
  '?bvid=BVxxxxxxxxx&cid=xxxxxxxxx&qn=0&fnval=4048&fourk=1&platform=web';
https.get(url, {
  headers: {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
    'Referer': 'https://www.bilibili.com/'
  }
}, (res) => {
  let data = '';
  res.on('data', (chunk) => { data += chunk; });
  res.on('end', () => {
    const d = JSON.parse(data);
    if (d.code === 0 && d.data && d.data.dash && d.data.dash.audio) {
      const audio = d.data.dash.audio;
      const best = audio.reduce((a,b) => a.bandwidth > b.bandwidth ? a : b);
      console.log(best.baseUrl + '|' + (best.backupUrl ? best.backupUrl[0] || '' : ''));
    } else {
      console.log('ERROR: no dash audio data');
    }
  });
}).on('error', (e) => { console.log('ERROR: ' + e.message); });
"
```

The `fnval=4048` flag requests DASH format with separate audio/video streams.

### Step 2: Download audio (use backup URL — most reliable)

```bash
node -e "
const https = require('https');
const fs = require('fs');
const url = 'BACKUP_URL_FROM_STEP_1';
const file = fs.createWriteStream('output.m4s');
https.get(url, {
  headers: {
    'User-Agent': 'Mozilla/5.0 ...',
    'Referer': 'https://www.bilibili.com/'
  },
  timeout: 60000
}, (res) => {
  if (res.statusCode !== 200) { console.log('HTTP ' + res.statusCode); return; }
  res.pipe(file);
  res.on('end', () => { console.log('OK size=' + file.bytesWritten); });
}).on('error', (e) => { console.log('ERR: ' + e.message); });
"
```

### Step 3: Convert to standard audio (stream copy, no re-encode)

```bash
ffmpeg -i output.m4s -c copy output.m4a -y
```

### Step 4: ASR transcription via FunASR

```bash
set MODELSCOPE_CACHE=.\cache\modelscope
set MODELSCOPE_CREDENTIAL_PATH=.\cache\modelscope_cred
python audio2srt.py output.m4a --srt --model paraformer-zh --punc-model ct-punc --spk-model cam++
```

### Step 5: Cleanup — remove intermediate audio files

```bash
del output.m4s output.m4a
```

The only artifacts worth keeping are the `.srt` subtitle file. The raw `.m4s`, the converted `.m4a`, and any `.json` debug output are all intermediate and should be cleaned up after the SRT is confirmed valid.

**What the script does:**
- Loads `paraformer-zh` (Chinese ASR, 220M params) + `fsmn-vad` + `ct-punc` + `cam++`
- Outputs SRT with per-sentence timestamps via `res[0]["sentence_info"]`
- CPU perf: ~15x realtime (21 min audio ≈ 90 sec)
- Handles ModelScope cache/credential path setup automatically

**If `cam++` is too slow to download**, omit `--spk-model` and group `res[0]["timestamp"]` (per-character ms array) by punctuation boundaries manually.

**If no `sentence_info`** in the output: the `spk_model` triggers sentence segmentation. Without it, you only get raw text + per-character timestamps.

### The `audio2srt.py` script

Located next to this `SKILL.md` file. Copy it into the current workspace or call it by its skill-directory path. It handles:

- Model loading with ModelScope credential path override (sandbox-safe)
- Multiple output formats: SRT, VTT, JSON
- Parsing `sentence_info`, `timestamp`, and raw text fallback
- Cleaning SenseVoice special tags (`<|zh|>`, `<|HAPPY|>`, etc.)
- Segment deduplication and time-sorting

**After transcription completes, delete `*.m4s` and `*.m4a`** — only the `.srt` is the final output.

---

## Danmaku Fallback: Protobuf API (when BE's `downloadDanmaku` is absent)

```js
(async () => {
  const be = window.bilibiliEvolved;
  const proto = await be.runtimeLibrary.protobufLibrary;

  const schema = {
    nested: {
      DmSegMobileReply: {
        fields: { elems: { rule: 'repeated', type: 'DanmakuElem', id: 1 } },
      },
      DanmakuElem: {
        fields: {
          id: { type: 'int64', id: 1 },
          progress: { type: 'int32', id: 2 },
          mode: { type: 'int32', id: 3 },
          fontsize: { type: 'int32', id: 4 },
          color: { type: 'uint32', id: 5 },
          midHash: { type: 'string', id: 6 },
          content: { type: 'string', id: 7 },
          ctime: { type: 'int64', id: 8 },
          pool: { type: 'int32', id: 11 },
          idStr: { type: 'string', id: 12 },
          attr: { type: 'int32', id: 13 },
          animation: { type: 'string', id: 22 },
        },
      },
    },
  };
  const root = proto.Root.fromJSON(schema);
  const DmSegMobileReply = root.lookupType('DmSegMobileReply');

  const raw = await new Promise((resolve, reject) => {
    be.monkeyApis.GM_xmlhttpRequest({
      method: 'GET',
      url: `https://api.bilibili.com/x/v2/dm/web/seg.so?type=1&oid=${cid}&pid=${aid}&segment_index=1`,
      headers: { 'Referer': 'https://www.bilibili.com/' },
      responseType: 'arraybuffer',
      onload: r => resolve(r.response),
      onerror: r => reject(r.responseType)
    });
  });
  const decoded = DmSegMobileReply.decode(new Uint8Array(raw));
  return JSON.stringify(decoded.elems || []);
})()
```

If segment 1 has data and segment 2 is empty, treat segment 1 as complete. Apply the same density/peak/sample logic from Phase 1.

---

## Comments

```text
https://api.bilibili.com/x/v2/reply/main?jsonp=jsonp&type=1&oid={aid}&mode={mode}&ps=20&next=0
```

Modes: `2` = newest, `3` = popular, `0` = popular (server-dependent). Use DOM to confirm render order.

---

## Data Structures

### 投稿字幕 (from BE `downloadSubtitles`)

```js
[
  { "from": 0.3, "to": 5.3, "sid": 1, "location": 2, "content": "文字内容", "music": 0 },
  ...
]
```

### Danmaku

```js
{ "progress": 40000, "mode": 1, "fontsize": 25, "color": 16777215,
  "content": "弹幕内容", ... }
```

`progress` is in milliseconds.

### DASH audio stream (from playurl API)

- `fnval=4048` → DASH response with `dash.audio[]`
- Audio IDs: 30216 (~65kbps), 30232 (~74kbps), 30280 (~128kbps AAC)
- Codec: `mp4a.40.2` (AAC-LC, 48kHz, stereo)
- Format: `.m4s` = fragmented MP4, valid for ffmpeg stream copy

### ASR output (`sentence_info`)

```js
[
  { "start": 110, "end": 2190, "text": "话说大家有没有见过那种反驳型人格", "spk": 0 },
  { "start": 2330, "end": 3750, "text": "就是不管听到你说什么，", "spk": 0 },
  ...
]
```

`start`/`end` in milliseconds. `spk` is the speaker ID (from cam++ diarization).

---

## Gotchas

| Issue | What to do |
|-------|------------|
| **`downloadDanmaku` not in providers** | Polling loop handles this. If absent after 5s, fall back to Protobuf API. |
| **Session-less evaluate** | Always use `"session":"bilibili"` or similar. |
| **`registerData()` without `[]`** | Always pass `[]`. Provider callbacks crash without data. |
| **`Blob.text()` hangs** | Use `arrayBuffer()` + `TextDecoder('utf-8').decode()` instead. |
| **CDN blocks `curl.exe`** | Use Node.js `https.get()` with browser UA + Referer. |
| **playurl API returns `no dash`** | Don't use `platform=html5`. Use `fnval=4048&platform=web`. |
| **Audio URL returns 403** | URLs expire after ~5 min (deadline param). Fetch + download immediately in one pass. |
| **ModelScope cache permission denied** | Set `MODELSCOPE_CACHE` + `MODELSCOPE_CREDENTIAL_PATH` to writable workspace dirs. The `audio2srt.py` script handles this. |
| **No `sentence_info` in output** | Add `--spk-model cam++` to trigger sentence segmentation. |
| **Nested array from getData** | Always flatten: `Array.isArray(g[0]) ? g.flat() : g`. |
| **`curl.exe` downloading** | Use `node -e` with `https.get()` instead. |
