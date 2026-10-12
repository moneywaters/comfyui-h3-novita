import os
import zipfile

import folder_paths

_VIDEO_EXT = (
    ".mp4", ".mov", ".mkv", ".webm", ".avi", ".flv",
    ".wmv", ".m4v", ".mpg", ".mpeg", ".ts",
)
_AUDIO_EXT = (".mp3", ".wav", ".m4a", ".aac", ".flac", ".ogg")


def _input_dir():
    return folder_paths.get_input_directory()


def _output_dir():
    return folder_paths.get_output_directory()


def _clean(s):
    return (s or "").strip().strip("/\\")


class BulkVideoUpload:
    """Bulk-upload videos from the local PC into ComfyUI's input folder.

    The multi-file picker + upload button are added by web/bulk_io.js; this node
    resolves the target folder on the server and reports how many videos are there.
    """

    @classmethod
    def INPUT_TYPES(cls):
        return {
            "required": {
                "subfolder": ("STRING", {
                    "default": "videos",
                    "tooltip": "Subfolder of ComfyUI/input that uploads land in.",
                }),
                "replace_existing": ("BOOLEAN", {
                    "default": False,
                    "tooltip": "Delete existing videos in the folder on each run so only the current batch is processed.",
                }),
            }
        }

    RETURN_TYPES = ("STRING", "INT")
    RETURN_NAMES = ("folder_path", "video_count")
    FUNCTION = "resolve"
    CATEGORY = "Bulk IO"
    DESCRIPTION = ("Click 'Select & upload videos' to bulk-select files from your PC and "
                   "upload them to the server. Outputs the folder path for a folder batch loader.")

    def resolve(self, subfolder, replace_existing):
        sub = _clean(subfolder) or "videos"
        full = os.path.normpath(os.path.join(_input_dir(), sub))
        os.makedirs(full, exist_ok=True)

        removed = 0
        if replace_existing:
            for f in os.listdir(full):
                p = os.path.join(full, f)
                if os.path.isfile(p):
                    try:
                        os.remove(p)
                        removed += 1
                    except OSError:
                        pass

        vids = [f for f in os.listdir(full) if f.lower().endswith(_VIDEO_EXT)]
        print(f"[BulkIO] upload folder: {full} "
              f"({len(vids)} video(s){', removed %d old file(s)' % removed if removed else ''})")
        return (full, len(vids))


class DownloadAllZip:
    """Zip every finished file in a ComfyUI folder for one-click bulk download.

    Rebuilt after each run (so on a batch the final zip holds every result); the
    'Download all (ZIP)' button is added by web/bulk_io.js.
    """

    @classmethod
    def INPUT_TYPES(cls):
        return {
            "required": {
                "zip_name": ("STRING", {
                    "default": "upscaled_batch",
                    "tooltip": "Name of the .zip written into ComfyUI/output.",
                }),
                "source": (["output", "input"], {
                    "default": "output",
                    "tooltip": "Which ComfyUI folder to zip.",
                }),
                "only_videos": ("BOOLEAN", {
                    "default": True,
                    "tooltip": "Zip only video files (plus audio sidecars when enabled).",
                }),
                "include_audio": ("BOOLEAN", {
                    "default": True,
                    "tooltip": "Include audio files when 'only_videos' is on.",
                }),
            },
            "optional": {
                "trigger": ("*", {"tooltip": "Wire the last node of the chain here so the zip is built after saving."}),
            },
        }

    RETURN_TYPES = ()
    OUTPUT_NODE = True
    FUNCTION = "make_zip"
    CATEGORY = "Bulk IO"
    DESCRIPTION = ("Rebuilds a .zip of the output folder after each run and exposes a single "
                   "'Download all (ZIP)' button.")

    def make_zip(self, zip_name, source, only_videos, include_audio, trigger=None):
        base = _input_dir() if source == "input" else _output_dir()
        name = (zip_name or "upscaled_batch").strip() or "upscaled_batch"
        zip_path = os.path.join(base, name + ".zip")
        zip_abs = os.path.abspath(zip_path)

        picked = []
        for f in sorted(os.listdir(base)):
            p = os.path.join(base, f)
            if not os.path.isfile(p) or os.path.abspath(p) == zip_abs:
                continue
            low = f.lower()
            if only_videos:
                is_vid = low.endswith(_VIDEO_EXT)
                is_aud = low.endswith(_AUDIO_EXT)
                if not is_vid and not (include_audio and is_aud):
                    continue
            picked.append(p)

        if os.path.exists(zip_path):
            try:
                os.remove(zip_path)
            except OSError:
                pass

        with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as z:
            for p in picked:
                z.write(p, arcname=os.path.basename(p))

        size = os.path.getsize(zip_path)
        print(f"[BulkIO] wrote {zip_path} ({len(picked)} file(s), {size} bytes)")
        return {"ui": {"bulk_io": [{
            "filename": name + ".zip",
            "count": len(picked),
            "size": size,
        }]}}


NODE_CLASS_MAPPINGS = {
    "BulkVideoUpload": BulkVideoUpload,
    "DownloadAllZip": DownloadAllZip,
}

NODE_DISPLAY_NAME_MAPPINGS = {
    "BulkVideoUpload": "Bulk Video Upload (multi-select)",
    "DownloadAllZip": "Download All (ZIP)",
}
