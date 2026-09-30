import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const source = readFileSync(new URL('../Resources/studio-bridge.js', import.meta.url), 'utf8')
  .replace("const { app } = await import(new URL('scripts/app.js', document.baseURI).href);", 'const { app } = harness;');
const AsyncFunction = Object.getPrototypeOf(async function(){}).constructor;
const run = new AsyncFunction('mode', 'harness', 'window', 'globalThis', source);

test('resume reconciles existing studio without switching tabs, queueing or editing graph', async () => {
  const calls = [];
  const studio = {setTab: () => calls.push('tab'), expand: () => calls.push('expand'), reconcile: async () => calls.push('reconcile')};
  const nodes = [{id: 7, miniStudio: studio}, {id: 8}];
  const graph = {_nodes: nodes};
  const result = await run('resume', {app:{graph}}, {dispatchEvent:e=>calls.push(e.type)}, {});
  assert.equal(result,'ready'); assert.deepEqual(calls, ['focus','reconcile']); assert.equal(graph._nodes, nodes);
});
test('open preserves existing nodes and opens generate tab', async () => {
  const calls=[];
  const graph={_nodes:[{miniStudio:{setTab:v=>calls.push(v),expand:v=>calls.push(v)}}]};
  assert.equal(await run('open',{app:{graph}}, {}, {}), 'ready');
  assert.deepEqual(calls,['generate',true]);
});
test('no automatic node creation when studio is missing', async () => {
  for (const mode of ['open','resume']) {
    assert.equal(await run(mode,{app:{graph:{_nodes:[]}}},{}, {LiteGraph:{createNode:()=>{throw Error('must not create')}}}), 'no-studio');
  }
});
test('explicit create preserves existing nodes and awaits initialized studio', async () => {
  const existing={id:1}; const calls=[];
  const graph={_nodes:[existing],add(factory){this._nodes.push({miniStudio:{setTab:v=>calls.push(v),expand:v=>calls.push(v)}})},change(){calls.push('change')}};
  assert.equal(await run('create',{app:{graph}},{},{LiteGraph:{createNode:()=>({})}}),'ready');
  assert.equal(graph._nodes[0],existing); assert.deepEqual(calls,['change','generate',true]);
});
