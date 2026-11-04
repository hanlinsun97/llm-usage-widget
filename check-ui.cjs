const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const html=fs.readFileSync(__dirname+'/widget.html','utf8');
const nodes=new Map(),calls=[],styles=new Map(),listeners={};
const node=()=>({innerHTML:'',textContent:'',title:'',classList:{set:new Set(),add(c){this.set.add(c)},remove(c){this.set.delete(c)},toggle(c,on){on?this.set.add(c):this.set.delete(c)},contains(c){return this.set.has(c)}}});
const ctx={console,Date,setInterval(){},setTimeout(){},document:{documentElement:{style:{setProperty(k,v){styles.set(k,v)}}},body:node(),addEventListener(k,f){listeners[k]=f},getElementById(id){if(!nodes.has(id))nodes.set(id,node());return nodes.get(id)},querySelector(q){return this.getElementById('q:'+q)}},window:{webkit:{messageHandlers:{widget:{postMessage(x){calls.push(x)}}}}}};
vm.createContext(ctx);vm.runInContext(html.match(/<script>([\s\S]*?)<\/script>/)[1],ctx);
const accounts=()=>nodes.get('accounts').innerHTML,status=()=>nodes.get('status');
const at=m=>new Date(Date.now()+m*60000).toISOString(),now=at(0);
const week=(remaining,mins=600)=>({remaining,minutes:10080,resetsAt:at(mins)});
const row={id:'codex',state:'ok',measuredAt:now,fiveHour:{remaining:100,minutes:300,resetsAt:at(60)},weekly:week(0)};

// Rings: weekly inner (r=44) and 5-hour outer (r=76); zero has no arc, full has one; no NaN.
ctx.updateSnapshot({rows:[row],collectedAt:now});
assert.equal((accounts().match(/class="arc weekly"/g)||[]).length,0,'zero weekly has no arc');
assert.match(accounts(),/class="arc five-hour"[^>]*r="76"/);
assert(/class="number ">0<\/div><div class="unit">wk</.test(accounts()),'weekly number with its wk label, no %');
ctx.updateSnapshot({rows:[{...row,weekly:week(100)}],collectedAt:now});
assert.match(accounts(),/class="arc weekly"[^>]*r="48"/);
assert(!ctx.ring({remaining:NaN,resetsAt:at(60)},48,8,'weekly').includes('NaN'));
assert.equal((accounts().match(/class="track"/g)||[]).length,2,'two rings');
ctx.updateSnapshot({rows:[{...row,id:'codex_su',weekly:week(73),fiveHour:null,fiveHourAbsent:true}],collectedAt:now});
assert.equal((accounts().match(/class="track"/g)||[]).length,1,'SU has only the weekly ring');
assert(!accounts().includes('five-badge'));

// 5-hour badge at the outer arc end: value, low warning, expired, sign-in.
assert.match(ctx.fiveBadge(row),/>100<\/span>/);
assert.match(ctx.fiveBadge({...row,fiveHour:{remaining:0,resetsAt:at(60)}}),/>0<\/span>/);
assert.match(ctx.fiveBadge({...row,fiveHour:{remaining:12,resetsAt:at(60)}}),/five-badge low[^>]*>12</);
assert.match(ctx.fiveBadge({...row,fiveHour:{remaining:50,resetsAt:at(-1)}}),/>—<\/span>/);
assert.match(ctx.fiveBadge({...row,state:'signIn'}),/>—<\/span>/);
// A window that has not started (Claude after a reset, no reset time yet) is full, not missing.
assert(ctx.validWindow({remaining:100,minutes:300,resetsAt:null}));
assert.match(ctx.fiveBadge({...row,id:'claude',fiveHour:{remaining:100,minutes:300,resetsAt:null}}),/>100<\/span>/);
assert.match(ctx.fiveBadge({...row,fiveHour:{remaining:100,resetsAt:null}}),/not started/);

// Pace track on the weekly ring: darker from the top over the share of the week still left.
assert(Math.abs(ctx.paceFraction(week(50,5040))-0.5)<1e-3);
assert(Math.abs(ctx.paceFraction(week(50,2520))-0.25)<1e-3);
assert.equal(ctx.paceFraction({remaining:50,resetsAt:at(60)}),null,'no window length, no pace');
assert.equal(ctx.paceFraction({remaining:50,minutes:10080,resetsAt:null}),null,'no reset time, no pace');
const c=2*Math.PI*48,paceDash=m=>Number(m.match(/class="pace"[^>]*stroke-dasharray="([^ ]+)/)[1]);
assert(Math.abs(paceDash(ctx.ring(week(30,2520),48,8,'weekly'))-c/4)<0.01,'quarter of the week left -> quarter-circle pace');
assert(!ctx.ring({...row.fiveHour},76,5,'five-hour').includes('pace'),'no pace on the 5-hour ring');
const wr=ctx.ring(week(30,2520),48,8,'weekly');assert(wr.indexOf('class="pace"')<wr.indexOf('class="arc'),'allowance arc drawn over the pace');
// An unparseable reset time is not shown (no NaN text or geometry).
assert(!ctx.validWindow({remaining:50,minutes:10080,resetsAt:'bad'}));
ctx.updateSnapshot({rows:[{...row,weekly:{remaining:50,minutes:10080,resetsAt:'bad'}}],collectedAt:now});
assert(!accounts().includes('NaN')&&accounts().includes('No data'));

// Empty states: account state wins; "Updating" only right after a reset.
assert.equal(ctx.emptyLabel({state:'signIn',weekly:week(80)}),'Sign in');
assert.equal(ctx.emptyLabel({...row,weekly:{remaining:50,resetsAt:at(-1)}}),'Updating');
assert.equal(ctx.emptyLabel({...row,weekly:{remaining:50,resetsAt:at(-20)}}),'No data');
assert.equal(ctx.emptyLabel({...row,state:'stale',weekly:{remaining:50,resetsAt:at(-1)}}),'No data');
assert.equal(ctx.emptyLabel({id:'claude',state:'unavailable',weekly:null}),'No data');
ctx.updateSnapshot({rows:[{...row,state:'signIn',weekly:week(80)}],collectedAt:now});
assert(accounts().includes('>Sign in<')&&!accounts().includes('>80<'),'sign-in never shows an old number');
// Regression: the empty label must keep its small size (an unscoped .number rule once overrode it).
const css=html.match(/<style>([\s\S]*?)<\/style>/)[1];
assert.equal((css.match(/(^|[}\n])\.number\{/g)||[]).length,1,'one base .number rule');
assert(css.indexOf('.number.empty{')>css.indexOf('.number{'));
assert.match(css,/\.compact \.number\.empty\{font-size:9px/);
// Regression: light mode once inherited the dark glass tint because --glass was only declared on :root.
const lightBlock=css.match(/body\.light\{([^}]*)\}/)[1];
assert(/--glass-rgb:251,252,245/.test(lightBlock)&&/--glass:rgba\(var\(--glass-rgb\)/.test(lightBlock),'light theme redefines --glass with its own colour');

// Stale: dimmed with its age; fresh rows have no age.
ctx.updateSnapshot({rows:[{...row,weekly:week(70),state:'stale',measuredAt:at(-180)}],collectedAt:now});
assert.match(accounts(),/class="account stale/);assert(accounts().includes('3h old'));
ctx.updateSnapshot({rows:[{...row,weekly:week(70),measuredAt:at(-14)}],collectedAt:now});
assert(!accounts().includes('stale')&&!accounts().includes(' old<'));
ctx.updateSnapshot({rows:[{...row,weekly:week(70),measuredAt:at(-16)}],collectedAt:now});
assert(accounts().includes('16m old'));
ctx.updateSnapshot({rows:[{...row,weekly:week(70),measuredAt:undefined}],collectedAt:now});
assert.match(accounts(),/class="account stale/,'unknown measurement time counts as stale');

// Low allowance uses the warning colour class.
ctx.updateSnapshot({rows:[{...row,weekly:week(12)}],collectedAt:now});
assert.match(accounts(),/class="account  low"/);

// Tokens: reset-matched only, zero is valid, partial is a lower bound, Claude has none.
const total={usage:{total_tokens:0},until:row.weekly.resetsAt,complete:true,sources:[{state:'ok'}]};
const r2={...row,weekly:{...row.weekly}};const withTokens={...r2,tokenUsage:{weekly:{...total,until:r2.weekly.resetsAt}}};
const none='';
assert.match(ctx.tokenLine(withTokens),/<\/span>0 tok<\/span>$/);
assert.equal(ctx.tokenLine({...withTokens,tokenUsage:{weekly:{...total,until:at(-5)}}}),none);
assert.equal(ctx.tokenLine({...withTokens,tokenUsage:{weekly:{...total,until:r2.weekly.resetsAt,sources:[{state:'unavailable'}]}}}),none);
assert.match(ctx.tokenLine({...withTokens,tokenUsage:{weekly:{...total,until:r2.weekly.resetsAt,complete:false}}}),/≥0 tok/);
assert.equal(ctx.tokenLine({id:'claude'}),none);
assert.equal(ctx.tokenCount(123835025),'124M');assert.equal(ctx.tokenCount(9061234),'9.1M');
assert.equal(ctx.tokenCount(1500),'1.5K');assert.equal(ctx.tokenCount(0),'0');assert.equal(ctx.tokenCount(2.4e9),'2.4B');

// Reset line under the ring: weekly countdown.
ctx.updateSnapshot({rows:[{...row,weekly:week(50,600)}],collectedAt:now});
assert(accounts().includes('↻ 10h 0m'));
{const wk=week(50,600);ctx.updateSnapshot({rows:[{...row,weekly:wk,tokenUsage:{weekly:{usage:{total_tokens:123835025},until:wk.resetsAt,complete:true,sources:[{state:'ok'}]}}}],collectedAt:now});
 assert.match(accounts(),/↻ 10h 0m<span class="tok"[^>]*><span class="dot"> · <\/span>124M tok/,'tokens follow the reset time');}
ctx.updateSnapshot({rows:[{...row,weekly:week(50,600),state:'stale',measuredAt:at(-180)}],collectedAt:now});
assert(accounts().includes('3h old')&&!accounts().includes(' tok<'),'stale age replaces the token count');
// Dark-mode readability: active chips use the badge colours, never white on the light ring colour.
assert(/\.account-tag\.active\{[^}]*color:var\(--badge-ink\)/.test(css)&&/\.pill\.on\{[^}]*color:var\(--badge-ink\)/.test(css));

// Footer: connected count, unreachable or unconfigured source.
const all=['codex','codex_iu','codex_su','claude'].map(id=>({...row,id,weekly:week(50)}));
ctx.updateSnapshot({rows:all,collectedAt:now});assert.equal(status().textContent,'● 4/4 connected');
ctx.updateSnapshot({rows:[{...all[0],state:'signIn',weekly:null},...all.slice(1)],collectedAt:now});
assert.equal(status().textContent,'◌ 3/4 connected');
ctx.setSource({ok:false});ctx.updateSnapshot({rows:all,collectedAt:at(-40)});
assert.equal(status().textContent,'Offline · data 40m old');
ctx.setSource({ok:false,unconfigured:true});assert.equal(status().textContent,'Set snapshotURL — see README');ctx.setSource({ok:true});

// Accounts from accounts.json: order, missing rows, unknown rows, custom accounts, escaping.
const config=JSON.parse(fs.readFileSync(__dirname+'/tests/accounts-fixture.json'));
ctx.setAccounts(config);
ctx.updateSnapshot({rows:[...all].reverse().concat([{...row,id:'stranger'}]),collectedAt:now});
{const html=accounts(),pos=['>A<','>B<','>C<','<b>Claude</b>'].map(t=>html.indexOf(t));
 assert(pos.every((p,i)=>p>0&&(i===0||p>pos[i-1])),'cards follow accounts.json order, not snapshot order');
 assert(!html.includes('stranger'),'rows not in accounts.json are not shown');}
ctx.updateSnapshot({rows:all.slice(0,3),collectedAt:now});
assert.equal((accounts().match(/class="account /g)||[]).length,4);assert(accounts().includes('No data'),'configured account without a row shows No data');
assert.equal(status().textContent,'◌ 3/4 connected');
ctx.setAccounts([{id:'glm',name:'GLM',label:'<Z>'},{id:'bad'},null]);
ctx.updateSnapshot({rows:[{...row,id:'glm',weekly:week(70)}],collectedAt:now});
{const html=accounts();assert(html.includes('<b>GLM</b>')&&html.includes('&lt;Z&gt;')&&!html.includes('<svg class="codex-icon"'),'custom account: name, escaped tag, no icon');
 ctx.setAccounts([{id:'glm',name:'GLM',icon:'codex',iconSVG:'<svg viewBox="0 0 1 1"><circle r="1"/></svg>'}]);assert(accounts().includes('<svg class="codex-icon" aria-hidden="true" viewBox="0 0 1 1">'),'iconSVG replaces the built-in icon');
 ctx.setAccounts([{id:'glm',name:'GLM',icon:'codex'}]);assert(accounts().includes('<rect x="2.5"'),'codex icon is the neutral terminal glyph');
 ctx.setAccounts([{id:'glm',name:'GLM',label:'<Z>'},{id:'bad'},null]);
 assert.equal((html.match(/class="account /g)||[]).length,1,'invalid entries are dropped');ctx.details(0);assert(!nodes.get('detail').innerHTML.includes('Use in app'),'no switching without chatgptProfile');}
ctx.setAccounts(config);

// Details: short key/value list, app control, Escape closes.
ctx.updateAppProfile({running:true,id:'codex'});ctx.updateSnapshot({rows:all,collectedAt:now});
assert(accounts().includes('account-tag active'));
ctx.details(0);let d=nodes.get('detail').innerHTML;
assert(d.includes('Codex A')&&d.includes('>In app<')&&d.includes('<dt>Weekly</dt>'));
assert(d.replace(/<[^>]+>/g,' ').split(/\s+/).filter(Boolean).length<40,'details stay short');
ctx.details(1);assert(nodes.get('detail').innerHTML.includes('Use in app'));
listeners.keydown({key:'Escape',preventDefault(){}});assert(!nodes.get('detail').classList.contains('open'));
// An open panel follows its account across reorders and closes if the account disappears (no accounts.json).
ctx.setAccounts([]);
ctx.details(1);ctx.updateSnapshot({rows:[all[1],all[0],all[2],all[3]],collectedAt:now});
assert(nodes.get('detail').innerHTML.includes('<span>codex_iu</span>'),'without accounts.json the id is the name');
ctx.updateSnapshot({rows:[all[0],all[2]],collectedAt:now});assert(!nodes.get('detail').classList.contains('open'));
// Extra allowance windows are listed.
ctx.updateSnapshot({rows:[{...all[3],extras:[{label:'Opus weekly',remaining:30,resetsAt:at(600)}]}],collectedAt:now});ctx.details(0);
assert(nodes.get('detail').innerHTML.includes('<dt>Opus weekly</dt><dd>30% left'));
// Snapshot strings are escaped everywhere they reach HTML.
const evil='<img src=x onerror="refresh()">';
ctx.updateSnapshot({rows:[{...all[0],id:evil,extras:[{label:evil,remaining:5,resetsAt:at(60)}],tokenUsage:{weekly:{usage:{total_tokens:1,input_tokens:evil},until:all[0].weekly.resetsAt,complete:true,incompleteCalls:evil,sources:[{name:evil,state:evil}]}}}],collectedAt:now});ctx.details(0);
for(const h of [accounts(),nodes.get('detail').innerHTML])assert(!h.includes('<img'),'unescaped snapshot string');

// Native bridge.
calls.length=0;ctx.switchTo('codex_iu');assert.deepEqual(calls,['switch:codex_iu']);ctx.switchFinished('codex_iu',true,'');
ctx.refresh();assert.equal(calls.at(-1),'refresh');assert(nodes.get('refresh').classList.contains('spinning'));
ctx.refresh();assert.equal(calls.filter(c=>c==='refresh').length,1,'no double refresh');
ctx.refreshFinished();assert(!nodes.get('refresh').classList.contains('spinning'));
ctx.setGlassIntensity(15);assert.equal(styles.get('--glass-tint'),'0.03');
ctx.setGlassIntensity(50);assert.equal(styles.get('--glass-tint'),'0.127');
ctx.setGlassIntensity(100);assert.equal(styles.get('--glass-tint'),'1','maximum is fully opaque');
ctx.setGlassIntensity(0);assert.equal(styles.get('--glass-tint'),'0.127','invalid falls back to the default');
ctx.setLayout(1);assert.equal(styles.get('--columns'),'4');ctx.setLayout(2);assert.equal(styles.get('--columns'),'2');

// Live snapshot, if given.
if(process.argv[2]){const snapshot=JSON.parse(fs.readFileSync(process.argv[2]));ctx.setAccounts(config);ctx.updateSnapshot(snapshot);for(let i=0;i<snapshot.rows.length;i++)ctx.details(i);
 assert.equal((accounts().match(/class="account /g)||[]).length,config.length);assert(!accounts().includes('NaN')&&!nodes.get('detail').innerHTML.includes('NaN'));}
console.log('PASS: accounts.json (order, missing, unknown, custom, invalid, escaping), two rings (weekly inner, 5-hour outer) + badge + pace track, wk label, tokens on reset line, chip contrast, not-started windows, zero/full/NaN, sign-in/updating/no-data labels, empty-label size regression, stale age, low warning, tokens (zero/mismatch/partial/format/alignment), reset line, footer, details + Escape + reorder + extras, escaping, bridge'+(process.argv[2]?', live snapshot':''));
