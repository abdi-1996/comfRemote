import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const source = readFileSync(new URL('../Resources/studio-bridge.js', import.meta.url), 'utf8')
  .replace("const { app } = await import(new URL('scripts/app.js', document.baseURI).href);", 'const { app } = harness;');

const AsyncFunction = Object.getPrototypeOf(async function(){}).constructor;
const run = new AsyncFunction('mode', 'payload', 'harness', 'window', 'globalThis', source);

test('resume reconciles existing studio without switching tabs, queueing or editing graph', async () => {
  const calls = [];
  const studio = {
    setTab: () => calls.push('tab'),
    expand: () => calls.push('expand'),
    reconcile: async () => calls.push('reconcile')
  };
  const nodes = [{id: 7, miniStudio: studio}, {id: 8}];
  const graph = {_nodes: nodes};
  const result = await run('resume', {}, {app:{graph}}, {dispatchEvent:e=>calls.push(e.type)}, {});
  assert.equal(result,'ready');
  assert.deepEqual(calls, ['focus','reconcile']);
  assert.equal(graph._nodes, nodes);
});

test('open preserves existing nodes and opens generate tab', async () => {
  const calls=[];
  const graph={_nodes:[{miniStudio:{setTab:v=>calls.push(v),expand:v=>calls.push(v)}}]};
  assert.equal(await run('open', {}, {app:{graph}}, {}, {}), 'ready');
  assert.deepEqual(calls,['generate',true]);
});

test('no automatic node creation when studio is missing', async () => {
  for (const mode of ['open','resume']) {
    assert.equal(
      await run(mode, {}, {app:{graph:{_nodes:[]}}},{}, {LiteGraph:{createNode:()=>{throw Error('must not create')}}}),
      'no-studio'
    );
  }
});

test('explicit create preserves existing nodes and awaits initialized studio', async () => {
  const existing={id:1};
  const calls=[];
  const graph={
    _nodes:[existing],
    add(factory){this._nodes.push({miniStudio:{setTab:v=>calls.push(v),expand:v=>calls.push(v)}})},
    change(){calls.push('change')}
  };
  assert.equal(
    await run('create', {}, {app:{graph}},{},{LiteGraph:{createNode:()=>({})}}),
    'ready'
  );
  assert.equal(graph._nodes[0],existing);
  assert.deepEqual(calls,['change','generate',true]);
});

test('loader catalog finds model, text encoder, VAE and LoRA widgets', async () => {
  const graph={_nodes:[
    {id:1,type:'UNETLoader',title:'H3 Model',widgets:[{name:'unet_name',value:'h3.safetensors',options:{values:['h3.safetensors','h3-fast.safetensors']}}]},
    {id:2,type:'CLIPLoader',widgets:[{name:'clip_name',value:'qwen.safetensors',options:{values:['qwen.safetensors']}}]},
    {id:3,type:'VAELoader',title:'Video VAE',widgets:[{name:'vae_name',value:'video_vae.safetensors',options:{values:['video_vae.safetensors']}}]},
    {id:4,type:'LoraLoaderModelOnly',widgets:[
      {name:'lora_name',value:'turbo.safetensors',options:{values:['turbo.safetensors']}},
      {name:'strength_model',value:1.0}
    ]}
  ]};

  const raw = await run('loader-catalog', {}, {app:{graph}}, {}, {});
  const data = JSON.parse(raw);
  assert.equal(data.ok,true);
  assert.equal(data.targets.length,4);
  assert.deepEqual(data.targets.map(x=>x.category),['diffusion_models','text_encoders','vae','loras']);
  assert.equal(data.targets[0].options.length,2);
});

test('set-loader writes the selected filename into the actual graph widget', async () => {
  const calls=[];
  const studio={reconcile:async()=>calls.push('reconcile')};
  const widget={name:'unet_name',value:'old.safetensors',options:{values:['old.safetensors']}};
  const node={id:11,type:'UNETLoader',title:'H3 Model',widgets:[widget],miniStudio:studio};
  const graph={_nodes:[node],change:()=>calls.push('change'),setDirtyCanvas:()=>calls.push('dirty')};
  const payload={graphIndex:0,nodeId:'11',widget:'unet_name',category:'diffusion_models',value:'new.safetensors'};

  const raw=await run('set-loader',payload,{app:{graph,canvas:{setDirty:()=>calls.push('canvas')}}},{},{});
  const data=JSON.parse(raw);
  assert.equal(data.ok,true);
  assert.equal(widget.value,'new.safetensors');
  assert.ok(widget.options.values.includes('new.safetensors'));
  assert.ok(calls.includes('change'));
  assert.ok(calls.includes('reconcile'));
});

test('pick-loader applies the filename returned by the Windows picker endpoint', async () => {
  const widget={name:'lora_name',value:'old.safetensors',options:{values:['old.safetensors']}};
  const graph={_nodes:[{id:22,type:'LoraLoaderModelOnly',title:'Turbo LoRA',widgets:[widget]}],change(){}};
  const globalObject={
    fetch: async (url, options) => {
      assert.equal(url,'/ministudio/model-picker/pick');
      assert.equal(JSON.parse(options.body).category,'loras');
      return {ok:true,status:200,json:async()=>({ok:true,filename:'turbo-4step.safetensors',action:'existing'})};
    }
  };
  const payload={graphIndex:0,nodeId:'22',widget:'lora_name',category:'loras'};
  const raw=await run('pick-loader',payload,{app:{graph}},{},globalObject);
  const data=JSON.parse(raw);
  assert.equal(data.ok,true);
  assert.equal(data.action,'existing');
  assert.equal(widget.value,'turbo-4step.safetensors');
});
