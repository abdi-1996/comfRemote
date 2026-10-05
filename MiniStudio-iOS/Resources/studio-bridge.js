// Called with WKWebView.callAsyncJavaScript.
// mode is a typed argument; payload carries loader/model commands.
// This script only runs inside the configured ComfyUI origin.
const { app } = await import(new URL('scripts/app.js', document.baseURI).href);
const root = app.rootGraph || app.graph;
if (!root) return 'waiting';

function rootNodes(graph) {
    return Array.from(graph?._nodes || graph?.nodes || []);
}

function findStudio() {
    for (const node of rootNodes(root)) {
        if (node?.miniStudio) return node.miniStudio;
    }
    return null;
}

function collectGraphs() {
    const graphs = [];
    const seen = new Set();

    function add(graph) {
        if (!graph || seen.has(graph)) return;
        const nodes = rootNodes(graph);
        if (!nodes.length && graph !== root) return;
        seen.add(graph);
        graphs.push(graph);

        for (const node of nodes) {
            for (const candidate of [
                node?.subgraph,
                node?.innerGraph,
                node?.workflowGraph,
                node?._graph,
                node?.graph
            ]) {
                if (candidate && candidate !== graph) add(candidate);
            }
        }
    }

    add(root);
    const studio = findStudio();
    if (studio) {
        for (const candidate of [
            studio.graph,
            studio.subgraph,
            studio.innerGraph,
            studio.workflowGraph,
            studio.rootGraph,
            studio._graph
        ]) add(candidate);

        // Mini Studio versions can keep their real workflow graph behind different
        // internal properties. Inspect only graph/workflow-like branches and stop
        // after a shallow depth so we can discover them without walking the page.
        const inspected = new Set();
        function inspectGraphHolders(object, depth) {
            if (!object || typeof object !== 'object' || inspected.has(object) || depth < 0) return;
            inspected.add(object);
            for (const key of Object.keys(object)) {
                if (!/(graph|workflow|studio|state|sub)/i.test(key)) continue;
                let value;
                try { value = object[key]; } catch { continue; }
                if (!value || typeof value !== 'object') continue;
                const nodes = value?._nodes || value?.nodes;
                if (Array.isArray(nodes)) add(value);
                if (depth > 0) inspectGraphHolders(value, depth - 1);
            }
        }
        inspectGraphHolders(studio, 2);
    }
    return graphs;
}

function nodeType(node) {
    return String(node?.comfyClass || node?.type || node?.constructor?.type || node?.title || 'Node');
}

function categoryFor(node, widget) {
    const name = String(widget?.name || '').toLowerCase();
    const context = `${nodeType(node)} ${node?.title || ''} ${name}`.toLowerCase();

    if (/lora/.test(context)) return 'loras';
    if (/vae/.test(context)) return 'vae';
    if (/clip|text[_ -]?encoder|qwen|encoder_name/.test(context)) return 'text_encoders';
    if (/ckpt|checkpoint/.test(context)) return 'checkpoints';
    if (/unet|diffusion|model_name|model file|model$/.test(context)) return 'diffusion_models';
    return null;
}

function isLoaderWidget(node, widget) {
    const value = widget?.value;
    if (typeof value !== 'string') return false;

    const name = String(widget?.name || '').toLowerCase();
    const context = `${nodeType(node)} ${node?.title || ''}`.toLowerCase();
    const knownName = /(^|_)(unet|ckpt|checkpoint|model|lora|clip|vae|encoder)(_name)?$/.test(name)
        || /(unet_name|ckpt_name|model_name|lora_name|clip_name|vae_name|encoder_name)/.test(name);
    const loaderNode = /(loader|load|checkpoint|lora|unet|diffusion|vae|clip|encoder)/.test(context);
    const fileValue = /\.(safetensors|ckpt|pt|pth|bin|gguf)$/i.test(value);
    const values = widget?.options?.values;
    const hasStringOptions = Array.isArray(values) && values.some(v => typeof v === 'string');

    return (knownName || loaderNode) && (fileValue || hasStringOptions || knownName);
}

function loaderCatalog() {
    const targets = [];
    const graphs = collectGraphs();

    graphs.forEach((graph, graphIndex) => {
        for (const node of rootNodes(graph)) {
            const widgets = Array.from(node?.widgets || []);
            for (const widget of widgets) {
                if (!isLoaderWidget(node, widget)) continue;
                const category = categoryFor(node, widget);
                if (!category) continue;

                const rawValues = widget?.options?.values;
                const options = Array.isArray(rawValues)
                    ? rawValues.filter(v => typeof v === 'string')
                    : [];
                const value = typeof widget.value === 'string' ? widget.value : '';

                targets.push({
                    id: `${graphIndex}:${String(node?.id ?? '')}:${String(widget?.name || '')}`,
                    graphIndex,
                    nodeId: String(node?.id ?? ''),
                    nodeTitle: String(node?.title || nodeType(node)),
                    nodeType: nodeType(node),
                    widget: String(widget?.name || ''),
                    category,
                    value,
                    options
                });
            }
        }
    });

    return targets;
}

function locateTarget(command) {
    const graphs = collectGraphs();
    const graph = graphs[Number(command?.graphIndex)];
    if (!graph) throw new Error('The workflow graph changed. Refresh Models & LoRA.');

    const node = rootNodes(graph).find(item => String(item?.id ?? '') === String(command?.nodeId ?? ''));
    if (!node) throw new Error('The loader node is no longer available. Refresh Models & LoRA.');

    const widget = Array.from(node?.widgets || []).find(item => String(item?.name || '') === String(command?.widget || ''));
    if (!widget) throw new Error('The loader control is no longer available. Refresh Models & LoRA.');

    return { graph, node, widget };
}

async function applyLoader(command, value) {
    if (typeof value !== 'string' || !value) throw new Error('Empty model filename.');
    const { graph, node, widget } = locateTarget(command);
    const oldValue = widget.value;

    const values = widget?.options?.values;
    if (Array.isArray(values) && !values.includes(value)) values.push(value);

    widget.value = value;
    try { widget.callback?.(value, app.canvas, node, undefined, undefined); } catch {}
    try { node.onWidgetChanged?.(widget.name, value, oldValue, widget); } catch {}
    try { graph.change?.(); } catch {}
    try { graph.setDirtyCanvas?.(true, true); } catch {}
    try { app.graph?.change?.(); } catch {}
    try { app.canvas?.setDirty?.(true, true); } catch {}

    const studio = findStudio();
    try { await studio?.reconcile?.(); } catch {}

    return { ok: true, value };
}

if (mode === 'loader-catalog') {
    return JSON.stringify({ ok: true, targets: loaderCatalog() });
}

if (mode === 'set-loader') {
    try {
        return JSON.stringify(await applyLoader(payload || {}, String(payload?.value || '')));
    } catch (error) {
        return JSON.stringify({ ok: false, error: String(error?.message || error) });
    }
}

if (mode === 'pick-loader') {
    try {
        if (!globalThis.fetch) throw new Error('Browser networking is unavailable.');
        const response = await globalThis.fetch('/ministudio/model-picker/pick', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ category: String(payload?.category || '') })
        });

        let result = {};
        try { result = await response.json(); } catch {}

        if (response.status === 404) {
            return JSON.stringify({
                ok: false,
                code: 'missing-extension',
                error: 'Install MiniStudio-ModelPicker in ComfyUI/custom_nodes and restart ComfyUI.'
            });
        }
        if (!response.ok || result?.ok === false) {
            return JSON.stringify({
                ok: false,
                cancelled: Boolean(result?.cancelled),
                error: String(result?.error || `Model picker failed (HTTP ${response.status}).`)
            });
        }
        if (result?.cancelled) return JSON.stringify({ ok: false, cancelled: true });

        const applied = await applyLoader(payload || {}, String(result?.filename || ''));
        return JSON.stringify({
            ...result,
            ...applied,
            ok: true
        });
    } catch (error) {
        return JSON.stringify({ ok: false, error: String(error?.message || error) });
    }
}

let studio = findStudio();

if (!studio && mode === 'create') {
    const factory = globalThis.LiteGraph?.createNode('H3MiniStudio');
    if (!factory) return 'missing-extension';
    factory.pos = [80, 80];
    root.add(factory);
    root.change?.();

    for (let attempt = 0; attempt < 80; attempt++) {
        await new Promise(resolve => setTimeout(resolve, 125));
        studio = findStudio();
        if (studio) break;
        if (factory.title?.includes('initialization failed')) {
            throw new Error(factory._studioStatus?.textContent);
        }
    }
}

if (!studio) return 'no-studio';

if (mode !== 'resume') {
    studio.setTab('generate');
    studio.expand(true);
}

if (mode === 'resume') {
    window.dispatchEvent(new Event('focus'));
    await studio.reconcile?.();
}

return 'ready';
