import { app } from "../../scripts/app.js";
import { api } from "../../scripts/api.js";

const VIDEO_ACCEPT = "video/*,.mp4,.mov,.mkv,.webm,.avi,.flv,.wmv,.m4v,.mpg,.mpeg,.ts";

function widgetValue(node, name, fallback) {
    const w = (node.widgets || []).find((x) => x.name === name);
    const v = w ? w.value : undefined;
    return (v === undefined || v === null || v === "") ? fallback : v;
}

async function uploadOne(file, subfolder) {
    const body = new FormData();
    body.append("image", file, file.name);
    body.append("overwrite", "true");
    body.append("subfolder", subfolder);
    body.append("type", "input");
    const resp = await api.fetchApi("/upload/image", { method: "POST", body });
    if (resp.status !== 200) {
        throw new Error(`HTTP ${resp.status}: ${await resp.text()}`);
    }
    return await resp.json();
}

function addBulkUploadUI(node) {
    const input = document.createElement("input");
    input.type = "file";
    input.multiple = true;
    input.accept = VIDEO_ACCEPT;
    input.style.display = "none";
    document.body.appendChild(input);

    const status = node.addWidget("text", "upload status", "no files uploaded yet", () => {});
    if (status) {
        status.disabled = true;
        status.serialize = false;
    }

    input.addEventListener("change", async () => {
        const files = Array.from(input.files || []);
        if (!files.length) return;
        const sub = String(widgetValue(node, "subfolder", "videos")).trim() || "videos";
        let ok = 0;
        const failed = [];
        for (let i = 0; i < files.length; i++) {
            if (status) status.value = `uploading ${i + 1}/${files.length}: ${files[i].name}`;
            app.graph?.setDirtyCanvas(true, true);
            try {
                await uploadOne(files[i], sub);
                ok++;
            } catch (err) {
                console.error("[BulkIO] upload failed:", files[i].name, err);
                failed.push(files[i].name);
            }
        }
        if (status) {
            status.value = failed.length
                ? `uploaded ${ok}/${files.length} to input/${sub} (failed: ${failed.join(", ")})`
                : `uploaded ${ok}/${files.length} to input/${sub}`;
        }
        app.graph?.setDirtyCanvas(true, true);
        input.value = "";
    });

    node.addWidget("button", "⬆ Select & upload videos", null, () => input.click());
}

function addDownloadUI(node) {
    const status = node.addWidget("text", "download status", "run the workflow, then click download", () => {});
    if (status) {
        status.disabled = true;
        status.serialize = false;
    }

    node.addWidget("button", "⬇ Download all (ZIP)", null, async () => {
        const name = String(widgetValue(node, "zip_name", "upscaled_batch")).trim() || "upscaled_batch";
        const file = `${name}.zip`;
        try {
            const resp = await api.fetchApi(
                `/view?filename=${encodeURIComponent(file)}&type=output&t=${Date.now()}`
            );
            if (!resp.ok) {
                if (status) status.value = `no ${file} yet — run the workflow first`;
                app.graph?.setDirtyCanvas(true, true);
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
            if (status) status.value = `downloaded ${file} (${(blob.size / 1048576).toFixed(1)} MB)`;
        } catch (err) {
            console.error("[BulkIO] download failed:", err);
            if (status) status.value = `download failed: ${err}`;
        }
        app.graph?.setDirtyCanvas(true, true);
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
