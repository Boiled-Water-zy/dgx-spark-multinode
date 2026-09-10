#!/usr/bin/env python3
"""把多段 5 秒片子接成一部连续短片。

MiniMax-H3 单次只出 124 帧（5.17s @24fps）。这个脚本用「首帧驱动」把上一段的
末帧喂给下一段，逐段生成后用 ffmpeg 拼起来，得到一部镜头连续的短片。

  python3 make-short-film.py --storyboard storyboard.json --out film.mp4

storyboard.json:
  {"style": "统一风格前缀，拼在每段提示词前面",
   "width": 640, "height": 360, "seed": 20260909,
   "shots": ["第 1 段提示词（纯文生视频）", "第 2 段…", ...]}
"""
import argparse, json, os, subprocess, sys, time, urllib.request, urllib.error, uuid

COMFY_ROOT = os.path.expanduser(os.environ.get("H3_ROOT", "~/minimax-h3")) + "/comfy/ComfyUI"


def api(host, port, path, payload=None, timeout=60):
    url = f"http://{host}:{port}{path}"
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data,
                                 headers={"Content-Type": "application/json"} if data else {})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def fill_missing_inputs(host, port, wf):
    """随包的工作流常比装好的自定义节点旧，缺新增的必填参数会被 /prompt 打回 400。
    按 /object_info 的默认值补齐。"""
    filled = []
    for nid, node in wf.items():
        try:
            info = api(host, port, f"/object_info/{node['class_type']}")[node["class_type"]]
        except Exception:
            continue
        for name, spec in (info["input"].get("required") or {}).items():
            if name in node["inputs"]:
                continue
            default = spec[1].get("default") if len(spec) > 1 and isinstance(spec[1], dict) else None
            if default is None and isinstance(spec[0], list) and spec[0]:
                default = spec[0][0]          # 下拉框取第一项
            if default is None:
                continue                       # 连不上的必填项交给 ComfyUI 报错
            node["inputs"][name] = default
            filled.append(f"{nid}.{node['class_type']}.{name}={default!r}")
    if filled:
        print("  补齐缺失参数: " + ", ".join(filled))
    return wf


def run_shot(host, port, wf, timeout):
    cid = str(uuid.uuid4())
    t0 = time.time()
    pid = api(host, port, "/prompt", {"prompt": wf, "client_id": cid})["prompt_id"]
    while time.time() - t0 < timeout:
        time.sleep(10)
        hist = api(host, port, f"/history/{pid}")
        if pid not in hist:
            continue
        h = hist[pid]
        status = h.get("status", {}).get("status_str", "?")
        if status != "success":
            raise RuntimeError(f"生成失败: {status} — {h.get('status', {}).get('messages')}")
        # SaveVideo 在不同版本里把产物挂在 videos / images(animated) / gifs 下
        for node_out in h.get("outputs", {}).values():
            for key in ("videos", "images", "gifs"):
                for f in node_out.get(key, []):
                    if not f["filename"].lower().endswith((".mp4", ".webm", ".mkv", ".mov")):
                        continue
                    rel = os.path.join(f.get("subfolder", ""), f["filename"])
                    return os.path.join(COMFY_ROOT, "output", rel), time.time() - t0
        raise RuntimeError("完成了但没有视频产物")
    raise TimeoutError(f"{timeout}s 内没出片")


def last_frame(video, dst):
    """取末帧当下一段的首帧。sseof 定位到片尾再抓最后一帧。"""
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-sseof", "-0.2", "-i", video,
                    "-update", "1", "-q:v", "2", dst], check=True)
    return dst


def concat(clips, out):
    lst = "/tmp/h3_film_concat.txt"
    with open(lst, "w") as fh:
        for c in clips:
            fh.write(f"file '{c}'\n")
    # 各段编码参数一致，优先无损拼接；失败再重编码
    r = subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "concat", "-safe", "0",
                        "-i", lst, "-c", "copy", out])
    if r.returncode != 0 or not os.path.exists(out):
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "concat", "-safe", "0",
                        "-i", lst, "-c:v", "libx264", "-crf", "18", "-preset", "medium",
                        "-c:a", "aac", "-b:a", "192k", out], check=True)
    return out


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=8188)
    p.add_argument("--workflow", default=os.path.expanduser(
        os.environ.get("H3_ROOT", "~/minimax-h3") + "/workflows/h3-i2v-firstframe-enhanced_fp8.json"))
    p.add_argument("--storyboard", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--text-encoder", default="qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors",
                   help="随包 i2v 工作流默认指向 HF 上的 heretic 编码器，本方案没下，换成 NVFP4-AWQ")
    p.add_argument("--timeout", type=int, default=3600)
    p.add_argument("--resume", action="store_true", help="已经出过的段落直接复用，不重跑")
    a = p.parse_args()

    sb = json.load(open(os.path.expanduser(a.storyboard)))
    base = json.load(open(os.path.expanduser(a.workflow)))
    style, shots = sb.get("style", ""), sb["shots"]
    indir = os.path.join(COMFY_ROOT, "input")

    clips = []
    for i, shot in enumerate(shots, 1):
        wf = json.loads(json.dumps(base))
        wf["13"]["inputs"]["clip_name"] = a.text_encoder
        v = wf["104"]["inputs"]
        v["prompt"] = (style + " " + shot).strip()
        v["width"], v["height"] = sb.get("width", 640), sb.get("height", 360)
        v["length"] = sb.get("length", 124)
        wf["15"]["inputs"]["noise_seed"] = sb.get("seed", 42) + i
        wf["92"]["inputs"]["filename_prefix"] = f"film/{sb.get('name', 'film')}_{i:02d}"
        if i == 1:
            v.pop("first_frame", None)          # 第 1 段纯文生视频
            wf.pop("137", None)
        else:
            wf["137"]["inputs"]["image"] = os.path.basename(clips[-1][1])

        # 断点续跑：一段就是两三分钟，已经出过的不重跑
        done = os.path.join(COMFY_ROOT, "output", "film",
                            f"{sb.get('name', 'film')}_{i:02d}_00001_.mp4")
        if a.resume and os.path.exists(done):
            print(f"[{i}/{len(shots)}] 已存在，跳过: {os.path.basename(done)}", flush=True)
            video, dt = done, 0.0
        else:
            wf = fill_missing_inputs(a.host, a.port, wf)
            print(f"[{i}/{len(shots)}] 生成中…", flush=True)
            video, dt = run_shot(a.host, a.port, wf, a.timeout)
        frame = last_frame(video, os.path.join(indir, f"chain_{sb.get('name','film')}_{i:02d}.png"))
        print(f"[{i}/{len(shots)}] {os.path.basename(video)}"
              + (f"  {dt/60:.2f} min" if dt else ""), flush=True)
        clips.append((video, frame))

    out = os.path.expanduser(a.out)
    concat([c[0] for c in clips], out)
    dur = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration",
                          "-of", "csv=p=0", out], capture_output=True, text=True).stdout.strip()
    print(f"\n成片: {out}  {float(dur):.1f}s  {os.path.getsize(out)/1e6:.1f} MB")


if __name__ == "__main__":
    sys.exit(main())
