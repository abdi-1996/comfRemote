// Called with WKWebView.callAsyncJavaScript; mode is a separate typed argument.
// Only the selected ComfyUI origin receives this script.
const { app } = await import(new URL('scripts/app.js', document.baseURI).href);
const root = app.rootGraph || app.graph;
if (!root) return 'waiting';
const nodes = Array.from(root._nodes || root.nodes || []);
let studio = nodes.find(node => node.miniStudio)?.miniStudio;
if (!studio && mode === 'create') {
    const factory = globalThis.LiteGraph?.createNode('H3MiniStudio');
    if (!factory) return 'missing-extension';
    factory.pos = [80, 80];
    root.add(factory);
    root.change?.();
    for (let attempt = 0; attempt < 80; attempt++) {
        await new Promise(resolve => setTimeout(resolve, 125));
        studio = Array.from(root._nodes || root.nodes || []).find(node => node.miniStudio)?.miniStudio;
        if (studio) break;
        if (factory.title?.includes('initialization failed')) throw new Error(factory._studioStatus?.textContent);
    }
}
if (!studio) return 'no-studio';
if (mode !== 'resume') {
    studio.setTab('generate');
    studio.expand(true);
}
if (mode === 'resume') {
    // Preserve workflow edits and the selected tab. ComfyUI owns WebSocket reconnects.
    window.dispatchEvent(new Event('focus'));
    await studio.reconcile?.();
}
return 'ready';
