#!/usr/bin/env python3
"""Adapt third-party H3 workflows to the models baked into image A.

Why: image A (comfyui-h3-novita) ships fl2va + Singularity + nvfp4 TE and has
~17 GB headroom under the 100 GB prewarm cap, so instead of downloading the
~30 GB these workflows reference we remap onto compatible in-image weights:

  UNET  minimax_h3_hybrid_fl2va_ref2va_b30-49-int8  (charsheet 6-panel)
        minimax_h3_ref2va_pruned_int8_convrot       (multishot)
    -> MiniMaxH3HybridLoader, base=fl2va, overlay=Singularity,
       preset=block_range_adaln, blocks 30..49. The hybrid file IS a b30-49
       merge of exactly these two checkpoints; normalize-models.sh strips
       Singularity's key prefix at boot so the merge succeeds. In-image node.
  CLIP  qwen3vl_32b_minimax_h3_int8_convrot (charsheet 6-panel)
    -> qwen3vl_32b_minimax_h3_nvfp4_awq (in-image, higher precision).
       Multishot already points at nvfp4; VAEs already match. Untouched.

The UNET swap keeps node id, position, MODEL output and links: only type,
inputs spec, widgets and properties change, so rewiring is unnecessary.

Usage: adapt-h3-workflows.py <src.json> <dst.json>   (run twice, once per file)
"""
import json
import sys

BASE = "minimax_h3_fl2va_pruned_int8_convrot.safetensors"
OVERLAY = "Minimax-h3_Singularity_ref2va_Pruned_v1.3_int8.safetensors"
TE_REPLACE = {
    "qwen3vl_32b_minimax_h3_int8_convrot.safetensors":
    "qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors",
}
UNET_REPLACE = {
    "minimax_h3_hybrid_fl2va_ref2va_b30-49-int8.safetensors",
    "minimax_h3_ref2va_pruned_int8_convrot.safetensors",
}

HYBRID_INPUTS = [
    {"localized_name": "base_model", "name": "base_model", "type": "COMBO",
     "widget": {"name": "base_model"}, "link": None},
    {"localized_name": "overlay_model", "name": "overlay_model", "type": "COMBO",
     "widget": {"name": "overlay_model"}, "link": None},
    {"localized_name": "overlay_preset", "name": "overlay_preset", "type": "COMBO",
     "widget": {"name": "overlay_preset"}, "link": None},
    {"localized_name": "block_range_start", "name": "block_range_start", "type": "INT",
     "widget": {"name": "block_range_start"}, "link": None},
    {"localized_name": "block_range_end", "name": "block_range_end", "type": "INT",
     "widget": {"name": "block_range_end"}, "link": None},
    {"localized_name": "final_adaln_from_overlay", "name": "final_adaln_from_overlay",
     "type": "BOOLEAN", "widget": {"name": "final_adaln_from_overlay"}, "link": None},
    {"localized_name": "custom_overlays", "name": "custom_overlays", "type": "STRING",
     "widget": {"name": "custom_overlays"}, "link": None},
    {"localized_name": "custom_base", "name": "custom_base", "type": "STRING",
     "widget": {"name": "custom_base"}, "link": None},
    {"localized_name": "weight_dtype", "name": "weight_dtype", "type": "COMBO",
     "widget": {"name": "weight_dtype"}, "link": None},
]
HYBRID_WIDGETS = [BASE, OVERLAY, "block_range_adaln", 30, 49, False, "", "", "default"]


def swap_unet(node):
    node["type"] = "MiniMaxH3HybridLoader"
    node["inputs"] = [dict(i) for i in HYBRID_INPUTS]
    node["widgets_values"] = list(HYBRID_WIDGETS)
    node["widgets_values_named"] = {
        "base_model": BASE, "overlay_model": OVERLAY,
        "overlay_preset": "block_range_adaln", "block_range_start": 30,
        "block_range_end": 49, "final_adaln_from_overlay": False,
        "custom_overlays": "", "custom_base": "", "weight_dtype": "default",
    }
    props = node.setdefault("properties", {})
    props["Node name for S&R"] = "MiniMaxH3HybridLoader"
    props.pop("models", None)


def swap_clip(node):
    vals = node.get("widgets_values") or []
    named = node.get("widgets_values_named") or {}
    if vals and vals[0] in TE_REPLACE:
        vals[0] = TE_REPLACE[vals[0]]
    if named.get("clip_name") in TE_REPLACE:
        named["clip_name"] = TE_REPLACE[named["clip_name"]]
    for m in (node.get("properties") or {}).get("models", []):
        if m.get("name") in TE_REPLACE:
            m["name"] = TE_REPLACE[m["name"]]
            m["url"] = ("https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main"
                        "/text_encoders/" + m["name"])


def adapt(node):
    t = node.get("type")
    if t == "UNETLoader":
        vals = node.get("widgets_values") or []
        named = (node.get("widgets_values_named") or {}).get("unet_name")
        if (vals and vals[0] in UNET_REPLACE) or named in UNET_REPLACE:
            swap_unet(node)
            return "unet"
    elif t == "CLIPLoader":
        vals = node.get("widgets_values") or []
        named = (node.get("widgets_values_named") or {}).get("clip_name")
        if (vals and vals[0] in TE_REPLACE) or named in TE_REPLACE:
            swap_clip(node)
            return "clip"
    return None


SPEEDUP_SUBGRAPH = "a9d3016d-7cbf-4367-a217-488144b79839"


def bypass_speedups(wf):
    """Bypass the 'Optional Speedups' subgraph instance.

    Its members (MiniMaxLowVRAMAttention, MiniMaxChunkFeedForward,
    H3SLAAttention, turbo LoraLoaderModelOnly) need the Comfy-Org/MiniMax-H3
    pack plus a turbo LoRA that neither ships in the image nor fits the
    no-new-weights budget. The workflow author marks the group deletable;
    bypass passes MODEL through untouched, so generation works at base speed.
    """
    n = 0
    for node in wf.get("nodes", []):
        if node.get("type") == SPEEDUP_SUBGRAPH and node.get("mode") != 4:
            node["mode"] = 4
            n += 1
    # Belt and suspenders: also mute the turbo-LoRA node inside the subgraph
    # definition, so definition-scanning validators stay quiet too.
    for sub in (wf.get("definitions") or {}).get("subgraphs", []):
        if sub.get("id") == SPEEDUP_SUBGRAPH:
            for node in sub.get("nodes", []):
                if node.get("type") == "LoraLoaderModelOnly":
                    node["mode"] = 4
    return n


def main():
    src, dst = sys.argv[1], sys.argv[2]
    wf = json.load(open(src))
    counts = {"unet": 0, "clip": 0}
    for n in wf.get("nodes", []):
        r = adapt(n)
        if r:
            counts[r] += 1
    bypassed = bypass_speedups(wf)
    json.dump(wf, open(dst, "w"), indent=2)
    print(f"{src} -> {dst}: swapped {counts['unet']} UNET + {counts['clip']} CLIP, "
          f"bypassed {bypassed} speedup subgraph(s)")
    if not counts["unet"]:
        print("WARN: no UNETLoader matched; check filenames")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
