import { app } from "../../scripts/app.js";
import { api } from "../../scripts/api.js";

const VIDEO_ACCEPT = "video/*,.mp4,.mov,.mkv,.webm,.avi,.flv,.wmv,.m4v,.mpg,.mpeg,.ts";

function widgetValue(node, name, fallback) {
    const w = (node.widgets || []).find((x) => x.name === name);
    const v = w ? w.value : undefined;
    return (v === undefined || v === null || v === "") ? fallback : v;
}

function apiURL(path) {
    // api.apiURL prepends the server base; fall back to a bare path if unavailable.
    try {
        return api.apiURL(path);
    } catch (e) {
        return path;
    }
}

function mb(bytes) {
    return (bytes / 1048576).toFixed(1);
}

function fmtSeconds(s) {
    if (!isFinite(s) || s < 0) return "?";
    if (s < 60) return `${Math.round(s)}s`;
    const m = Math.floor(s / 60);
    return `${m}m${String(Math.round(s % 60)).padStart(2, "0")}s`;
}

/**
 * Upload one file, reporting progress.
 *
 * XHR rather than fetch: only XHR exposes upload progress events, and without them a
 * multi-hundred-megabyte video shows nothing for minutes. The link to these boxes runs at
 * roughly 0.1-0.5 MB/s, so progress is the difference between "working" and "looks frozen".
 */
function uploadOne(file, subfolder, onProgress) {
    return new Promise((resolve, reject) => {
        const body = new FormData();
        body.append("image", file, file.name);
        body.append("overwrite", "true");
        body.append("subfolder", subfolder);
        body.append("type", "input");

        const xhr = new XMLHttpRequest();
        xhr.open("POST", apiURL("/upload/image"), true);
        xhr.upload.onprogress = (e) => {
            if (e.lengthComputable) onProgress(e.loaded, e.total);
        };
        xhr.onload = () => {
            if (xhr.status >= 200 && xhr.status < 300) {
                resolve(xhr.responseText || "");
            } else {
                const detail = String(xhr.responseText || "").replace(/\s+/g, " ").slice(0, 160);
                reject(new Error(`HTTP ${xhr.status}${detail ? " " + detail : ""}`));
            }
        };
        xhr.onerror = () => reject(new Error("network error (connection dropped or blocked)"));
        xhr.onabort = () => reject(new Error("aborted"));
        xhr.send(body);
    });
}

/**
 * A status line that is actually visible.
 *
 * A normal text widget cannot be used for this. Measured on the deployed image: the
 * current frontend renders a widget with `disabled = true` as an empty greyed field, and
 * assigning `widget.value` from JS does not repaint it either -- the string appeared in the
 * model but nowhere in the DOM. So an upload that succeeded still looked like it did
 * nothing at all. A DOM widget is a real element, so writing textContent is immediate.
 */
function addStatusLine(node, initial) {
    const el = document.createElement("div");
    el.textContent = initial;
    el.style.cssText = [
        "box-sizing:border-box",
        "width:100%",
        "padding:4px 6px",
        "font:11px/1.35 ui-monospace,SFMono-Regular,Menlo,monospace",
        "color:#c8d3e0",
        "background:#1e2530",
        "border:1px solid #333c4a",
        "border-radius:4px",
        "white-space:pre-wrap",
        "overflow-wrap:anywhere",
    ].join(";");

    let widget = null;
    try {
        widget = node.addDOMWidget("status", "bulkio_status", el, { serialize: false });
    } catch (e) {
        // Older frontend: fall back to a plain text widget so the node still functions.
        console.warn("[BulkIO] addDOMWidget unavailable, falling back to a text widget", e);
        widget = node.addWidget("text", "status", initial, () => {});
        if (widget) widget.serialize = false;
        return {
            set(text) {
                el.textContent = text;
                if (widget) widget.value = text;
                app.graph?.setDirtyCanvas(true, true);
            },
        };
    }
    if (widget) widget.serialize = false;

    return {
        set(text) {
            el.textContent = text;
            app.graph?.setDirtyCanvas(true, true);
        },
    };
}

function addBulkUploadUI(node) {
    if (node.__bulkIoUpload) return; // onNodeCreated can fire more than once per node
    node.__bulkIoUpload = true;

    const status = addStatusLine(node, "no files uploaded yet");

    // One reusable input per node. Creating a fresh one on every onNodeCreated leaked a
    // hidden <input> per node per load -- six were live after a few loads -- and each
    // carried its own listener.
    const input = document.createElement("input");
    input.type = "file";
    input.multiple = true;
    input.accept = VIDEO_ACCEPT;
    input.style.display = "none";
    document.body.appendChild(input);
    node.__bulkIoInput = input;

    input.addEventListener("change", async () => {
        const files = Array.from(input.files || []);
        if (!files.length) {
            status.set("no files selected — pick one or more videos, then press Open");
            input.value = "";
            return;
        }
        const sub = String(widgetValue(node, "subfolder", "videos")).trim() || "videos";
        const totalBytes = files.reduce((a, f) => a + (f.size || 0), 0);
        const started = Date.now();
        let done = 0;
        let sentBytes = 0;
        const failed = [];

        for (let i = 0; i < files.length; i++) {
            const f = files[i];
            const sizeMB = mb(f.size || 0);
            const priorBytes = sentBytes;
            status.set(`${i + 1}/${files.length}  ${f.name}  (${sizeMB} MB)\nstarting…  0%`);
            try {
                await uploadOne(f, sub, (loaded, total) => {
                    const pct = total ? Math.round((loaded / total) * 100) : 0;
                    status.set(
                        `${i + 1}/${files.length}  ${f.name}  (${sizeMB} MB)\n` +
                        `uploading  ${pct}%  ${mb(loaded)}/${mb(total)} MB`
                    );
                });
                done++;
                sentBytes = priorBytes + (f.size || 0);
                const elapsed = (Date.now() - started) / 1000;
                const rate = sentBytes > 0 ? (sentBytes / 1048576) / Math.max(elapsed, 0.1) : 0;
                const remaining = (totalBytes - sentBytes) / 1048576;
                status.set(
                    `uploaded ${done}/${files.length}  →  input/${sub}\n` +
                    `${mb(sentBytes)}/${mb(totalBytes)} MB at ${rate.toFixed(2)} MB/s` +
                    (i + 1 < files.length
                        ? `  ·  ~${fmtSeconds(remaining / Math.max(rate, 0.01))} left`
                        : "")
                );
            } catch (err) {
                console.error("[BulkIO] upload failed:", f.name, err);
                failed.push(`${f.name}: ${String((err && err.message) || err).slice(0, 80)}`);
                status.set(
                    `uploaded ${done}/${files.length}  →  input/${sub}\n` +
                    `FAILED ${f.name}: ${String((err && err.message) || err).slice(0, 120)}`
                );
            }
        }

        const elapsed = (Date.now() - started) / 1000;
        status.set(
            failed.length
                ? `uploaded ${done}/${files.length} in ${fmtSeconds(elapsed)} — ${failed.length} failed\n` +
                  failed.join("\n")
                : `uploaded ${done}/${files.length} in ${fmtSeconds(elapsed)}  →  input/${sub}\n` +
                  `${mb(sentBytes)} MB sent · now Queue Prompt to process them`
        );
    });

    node.addWidget("button", "⬆ Select & upload videos", null, () => input.click());
}

function addDownloadUI(node) {
    if (node.__bulkIoDownload) return;
    node.__bulkIoDownload = true;

    const status = addStatusLine(node, "run the workflow, then click download");

    node.addWidget("button", "⬇ Download all (ZIP)", null, async () => {
        const name = String(widgetValue(node, "zip_name", "upscaled_batch")).trim() || "upscaled_batch";
        const file = `${name}.zip`;
        status.set(`fetching ${file}…`);
        try {
            const resp = await api.fetchApi(
                `/view?filename=${encodeURIComponent(file)}&type=output&t=${Date.now()}`
            );
            if (!resp.ok) {
                status.set(
                    `no ${file} yet (HTTP ${resp.status})\n` +
                    `run the workflow first — the zip is rebuilt after each run`
                );
                return;
            }
            const blob = await resp.blob();
            const url = URL.createObjectURL(blob);
            const a = document.createElement("a");
            a.href = url;
            a.download = file;
            document.body.appendChild(a);
            a.click();
            a.remove();
            setTimeout(() => URL.revokeObjectURL(url), 10000);
            status.set(`downloaded ${file}  (${mb(blob.size)} MB)`);
        } catch (err) {
            console.error("[BulkIO] download failed:", err);
            status.set(`download failed: ${String((err && err.message) || err).slice(0, 140)}`);
        }
    });
}

app.registerExtension({
    name: "bulkio.nodes",
    async beforeRegisterNodeDef(nodeType, nodeData) {
        if (nodeData.name === "BulkVideoUpload") {
            const onCreated = nodeType.prototype.onNodeCreated;
            nodeType.prototype.onNodeCreated = function () {
                const r = onCreated ? onCreated.apply(this, arguments) : undefined;
                addBulkUploadUI(this);
                return r;
            };
            const onRemoved = nodeType.prototype.onRemoved;
            nodeType.prototype.onRemoved = function () {
                const r = onRemoved ? onRemoved.apply(this, arguments) : undefined;
                // drop the hidden input with the node instead of leaking it for the life
                // of the page
                try {
                    this.__bulkIoInput?.remove();
                } catch (e) {
                    /* ignore */
                }
                return r;
            };
        }
        if (nodeData.name === "DownloadAllZip") {
            const onCreated = nodeType.prototype.onNodeCreated;
            nodeType.prototype.onNodeCreated = function () {
                const r = onCreated ? onCreated.apply(this, arguments) : undefined;
                addDownloadUI(this);
                return r;
            };
        }
    },
});