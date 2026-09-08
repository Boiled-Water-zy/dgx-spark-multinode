#!/usr/bin/env python3
"""向 ComfyUI 提交一个 H3 工作流并等出片，打印耗时和产物路径。

用法:
  python3 smoke-test.py --host 192.168.130.8 --workflow ~/minimax-h3/workflows/h3-dense-baseline.json \
      [--prompt "..."] [--seed 42] [--steps 20] [--timeout 3600]
"""
import argparse, json, os, sys, time, urllib.request, urllib.error, uuid

def api(host, port, path, payload=None):
    url = f"http://{host}:{port}{path}"
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data,
                                 headers={"Content-Type": "application/json"} if data else {})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=8188)
    p.add_argument("--workflow", required=True)
    p.add_argument("--prompt")
    p.add_argument("--seed", type=int)
    p.add_argument("--steps", type=int)
    p.add_argument("--timeout", type=int, default=3600)
    a = p.parse_args()

    wf = json.load(open(os.path.expanduser(a.workflow)))
    for node in wf.values():
        ins = node.get("inputs", {})
        if a.prompt and node["class_type"].startswith("MiniMaxH3") and "prompt" in ins:
            ins["prompt"] = a.prompt
        if a.seed is not None and "noise_seed" in ins:
            ins["noise_seed"] = a.seed
        if a.steps is not None and "steps" in ins:
            ins["steps"] = a.steps

    stats = api(a.host, a.port, "/system_stats")
    dev = stats["devices"][0]
    print(f"ComfyUI {stats['system']['comfyui_version']} · {dev['name']} · "
          f"free {dev['vram_free']/2**30:.1f} GiB")

    cid = str(uuid.uuid4())
    t0 = time.time()
    r = api(a.host, a.port, "/prompt", {"prompt": wf, "client_id": cid})
    pid = r["prompt_id"]
    print(f"已提交 prompt_id={pid}，等待出片（首次运行含模型加载/编译，会很慢）…")

    last = ""
    while time.time() - t0 < a.timeout:
        time.sleep(10)
        hist = api(a.host, a.port, f"/history/{pid}")
        if pid in hist:
            h = hist[pid]
            dt = time.time() - t0
            status = h.get("status", {}).get("status_str", "?")
            print(f"\n完成: status={status}  耗时 {dt/60:.2f} min ({dt:.0f}s)")
            outs = []
            for node_out in h.get("outputs", {}).values():
                for key in ("videos", "images", "gifs"):
                    for f in node_out.get(key, []):
                        outs.append(f"{f.get('subfolder','')}/{f['filename']}")
            print("产物:", ", ".join(outs) or "(无)")
            return 0 if status == "success" else 1
        q = api(a.host, a.port, "/queue")
        run = len(q.get("queue_running", [])); pend = len(q.get("queue_pending", []))
        cur = f"running={run} pending={pend} elapsed={time.time()-t0:.0f}s"
        if cur != last:
            print("  " + cur, flush=True); last = cur
    print("超时"); return 2

if __name__ == "__main__":
    sys.exit(main())
