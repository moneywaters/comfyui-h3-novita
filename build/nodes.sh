#!/bin/bash
# Clone the ComfyUI custom nodes used by the Seed Hunter / Qwen / SeedVR2 workflows.
# Each clone is independent: one failure never aborts the build.
set -uo pipefail
cd /opt/ComfyUI/custom_nodes || exit 1

clone() {
    local url="$1" dir="$2"
    if [ -d "$dir/.git" ]; then echo "exists: $dir"; return 0; fi
    echo "cloning: $dir"
    git clone --depth 1 "$url" "$dir" 2>&1 | tail -2 || echo "WARN: failed to clone $dir"
}

# --- core / workflow plumbing -------------------------------------------------
clone https://github.com/ltdrdata/ComfyUI-Manager.git                 ComfyUI-Manager
clone https://github.com/kijai/ComfyUI-KJNodes.git                    ComfyUI-KJNodes
clone https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git     ComfyUI-VideoHelperSuite
clone https://github.com/ltdrdata/ComfyUI-Impact-Pack.git             ComfyUI-Impact-Pack
clone https://github.com/Fannovel16/comfyui_controlnet_aux.git        comfyui_controlnet_aux
clone https://github.com/chrisgoringe/cg-use-everywhere.git           cg-use-everywhere
clone https://github.com/pythongosssss/ComfyUI-Custom-Scripts.git     ComfyUI-Custom-Scripts
clone https://github.com/rgthree/rgthree-comfy.git                    rgthree-comfy
clone https://github.com/yolain/ComfyUI-Easy-Use.git                  ComfyUI-Easy-Use
clone https://github.com/pixaroma/ComfyUI-Pixaroma.git                ComfyUI-Pixaroma
clone https://github.com/Fannovel16/ComfyUI-Frame-Interpolation.git   ComfyUI-Frame-Interpolation

# --- MiniMax H3 toolchain ----------------------------------------------------
clone https://github.com/ethanfel/ComfyUI-H3-Prompt-IDE.git                          ComfyUI-H3-Prompt-IDE
clone https://github.com/Adudeguyman/ComfyUI-Fantastic-MiniMaxH3-PromptBuilder.git   ComfyUI-Fantastic-MiniMaxH3-PromptBuilder
clone https://github.com/Luisacaotica/ComfyUI-MiniMaxH3Mod.git                       ComfyUI-MiniMaxH3Mod
clone https://github.com/LBH-123-AI/Comfyui_Minimax_h3_latent_Upscaler.git           Comfyui_Minimax_h3_latent_Upscaler
clone https://github.com/GACLove/ComfyUI-VFI.git                                     ComfyUI-VFI
clone https://github.com/sepiablue-ai/ComfyUI-MiniMax-H3-W4A4-VSA.git                ComfyUI-MiniMax-H3-W4A4-VSA
# merges fl2va (base) + ref2va (overlay) tensor groups -> needs BOTH diffusion models
clone https://github.com/scottmudge/ComfyUI_MinimaxH3HybridLoader.git                ComfyUI_MinimaxH3HybridLoader
# supplies ThreeWaySwitch, used twice by Seed Hunter v2.5.1
clone https://github.com/gseth/ControlAltAI-Nodes.git                                ControlAltAI-Nodes

# --- upscaling ---------------------------------------------------------------
clone https://github.com/numz/ComfyUI-SeedVR2_VideoUpscaler.git      ComfyUI-SeedVR2_VideoUpscaler

echo "=== stripping VCS metadata + bytecode (image size) ==="
find /opt/ComfyUI/custom_nodes -maxdepth 2 -name .git -type d -prune -exec rm -rf {} + 2>/dev/null || true
find /opt/ComfyUI/custom_nodes -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
find /opt/ComfyUI/custom_nodes -name '*.pyc' -delete 2>/dev/null || true
find /opt/ComfyUI/custom_nodes -maxdepth 2 \( -name 'examples' -o -name 'docs' -o -name '.github' \) -type d -prune -exec rm -rf {} + 2>/dev/null || true

echo "=== custom nodes present ==="
ls -1
du -sh /opt/ComfyUI/custom_nodes 2>/dev/null
