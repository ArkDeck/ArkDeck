import assert from 'node:assert/strict';
import {readFileSync, readdirSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import {join, relative} from 'node:path';
import test from 'node:test';
import vm from 'node:vm';
import {createRequire} from 'node:module';
import {transformSync} from 'esbuild';
import {createElement} from 'react';
import {renderToStaticMarkup} from 'react-dom/server';

const root = fileURLToPath(new URL('../../../../', import.meta.url));
const read = path => readFileSync(join(root, path), 'utf8');
const coverage = JSON.parse(read('docs/design/implementation-coverage.json'));
const report = read('docs/design/implementation-audit-2026-08-27.md');
const html = read('docs/design/prototype.html');
const script = html.split('<script>')[1].split('</script>')[0];
const files = dir => readdirSync(dir, {withFileTypes:true}).flatMap(entry => {
  const path = join(dir, entry.name);
  return entry.isDirectory() ? files(path) : [path];
});

let swiftSourceCache;
function swiftSources() {
  if (swiftSourceCache === undefined) {
    const roots = ['ArkDeckApp', 'ArkDeckAppUITests', 'Packages'].map(dir => join(root, dir));
    swiftSourceCache = roots
      .filter(dir => { try { readdirSync(dir); return true; } catch { return false; } })
      .flatMap(dir => files(dir))
      .filter(path => path.endsWith('.swift'))
      .map(path => readFileSync(path, 'utf8'))
      .join('\n');
  }
  return swiftSourceCache;
}

function enumCases(path, name) {
  const source=read(path), start=source.indexOf(`enum ${name}:`);
  assert.notEqual(start,-1,`${name} was renamed; update the audit inventory`);
  const body=source.slice(start).split(/\n\s*(?:var|public var) /)[0];
  return [...body.matchAll(/^\s*case ([\w, ]+)$/gm)]
    .flatMap(match=>match[1].split(',').map(value=>value.trim()));
}

// Execute the actual draft with inert DOM and clock doubles. These tests do
// not control a browser, contact Runtime, or prove hardware acceptance.
function harness(search='') {
  const elements=new Map();
  const timers=[];
  const element = () => ({
    innerHTML: '', textContent: '', value: '', style: {}, dataset: {},
    classList: {toggle() {}, add() {}, remove() {}},
    setAttribute() {}, focus() {}, scrollIntoView() {this.scrolledIntoView=true;},
    querySelector() { return null; },
    querySelectorAll() { return []; },
  });
  const document = {
    addEventListener() {}, activeElement: null,
    body: element(), documentElement: element(), scrollingElement: element(),
    getElementById(id) {
      if (!elements.has(id)) elements.set(id, element());
      return elements.get(id);
    },
    querySelector(selector) { return this.getElementById(selector); },
    querySelectorAll() { return []; },
  };
  const context = vm.createContext({
    URLSearchParams, URL, Date, document,
    location: {search, href: `http://localhost/prototype.html${search}`},
    performance: {now: () => 0}, history: {replaceState() {}},
    setTimeout(callback) {timers.push(callback);return timers.length;},
    clearTimeout(id) {if(id)timers[id-1]=null;}, setInterval() {}, clearInterval() {},
    requestAnimationFrame() {},
  });
  vm.runInContext(script.replace(/\nrender\(\);\s*$/, ''), context);
  const run = code => vm.runInContext(code, context);
  run('render=()=>{}; renderPage=()=>{}; renderDrawer=()=>{};');
  return {run, document, flushTimers(){const queued=timers.splice(0);for(const callback of queued)callback?.();}};
}

test('Flash distinguishes a connected assessment lane from execution availability', () => {
  for(const lang of ['en','zh-Hans']) {
    const h=harness(`?page=flash&flashState=hardwareGated&lang=${lang}`);
    h.run('chooseFlashImage()');
    const page=h.run('pFlash()');
    assert.match(page,/data-sync-id="flash.availability"/);
    assert.match(page,/hardwareGated/);
    assert.match(page,/data-sync-id="flash.execute.prerequisiteBlocker"/);
    assert.doesNotMatch(page,/<button[^>]+onclick="runFlash\(\)"/);
    assert.doesNotMatch(page,/3 required safety checks passed|3 项必需安全检查通过/);
    const before=h.run('S.jobs.length');
    h.run('runFlash()');
    assert.equal(h.run('S.jobs.length'),before);
    assert.equal(h.run('S.flashView'),'ready');
    assert.equal(h.run('S.flashJob'),null);
  }
  const ready=harness('?page=flash&lang=en');
  ready.run('chooseFlashImage(); runFlash()');
  assert.equal(ready.run('S.flashView'),'running');
});

test('Flash retained history focuses the latest success and opens that exact record', () => {
  for(const lang of ['en','zh-Hans']) {
    const h=harness(`?page=flash&flashHistory=retained&lang=${lang}`);
    const original=h.run('JSON.stringify(HIST)');
    assert.equal(h.run('focusedFlashActivity().id'),'S-0826-01');
    assert.match(h.run('flashActivityHTML()'),/data-sync-id="flash.runtime.jobID">S-0826-01/);
    assert.doesNotMatch(h.run('flashActivityHTML()'),/Observed Runtime timeline|Runtime 观测时间线|waitingForDevice/);
    assert.doesNotMatch(h.run('pFlash()'),/data-sync-id="flash.runtime.attention"/);
    assert.equal(h.run('JSON.stringify(HIST)'),original);
    h.document.getElementById('page').scrollTop=500;
    h.document.scrollingElement.scrollTop=80;
    h.run("S.hf.kind='viewer'; S.hf.query='hide flash'; openFlashRecord(focusedFlashActivity().id)");
    assert.equal(h.run('S.nav'),'history');
    assert.equal(h.run('S.histSel'),'S-0826-01');
    assert.equal(h.document.getElementById('page').scrollTop,0);
    assert.equal(h.document.scrollingElement.scrollTop,0);
    assert.match(h.run('pHistory()'),/data-sync-id="history.detail.job">S-0826-01/);
    assert.equal(h.run("HIST.find(h=>h.id==='job-demo-flash-alias').outcomeUnknown"),true);
    assert.equal(h.run("HIST.find(h=>h.id==='job-demo-flash-superseded').st"),'waitingForRecovery');
  }
});

test('Flash History uses detail timeline and reported artifacts without inventing legacy metadata', () => {
  for(const lang of ['en','zh-Hans']) {
    const h=harness(`?page=flash&flashHistory=retained&lang=${lang}`);
    const original=h.run('JSON.stringify(HIST)');
    const detail=h.run('histDetail(focusedFlashActivity())');
    assert.match(detail,/data-sync-id="history.detail.timeline.entries"/);
    assert.match(detail,/Journal summary|Journal 摘要/);
    assert.match(detail,/waitingForDevice/);
    assert.match(detail,/flash.full-restore@1/);
    for(const name of ['post-flash-facts.json','post-flash-hilog.txt','flash-report.json']) {
      assert.ok(detail.includes(`data-artifact-name="${name}"`));
    }
    assert.doesNotMatch(detail,/plan\.json|flash\.log|9 steps|e0a1|binding rev 3/);
    const retained=h.run("histDetail(HIST.find(row=>row.id==='job-demo-flash-alias'))");
    assert.match(retained,/Outcome unknown|结果未知/);
    assert.doesNotMatch(retained,/data-artifact-name=|post-flash-facts|9 steps|e0a1/);
    h.run("exportModal('S-0826-01','post-flash-hilog.txt')");
    assert.match(h.document.getElementById('modalHost').innerHTML,/post-flash-hilog\.txt/);
    assert.doesNotMatch(h.document.getElementById('modalHost').innerHTML,/post-flash-facts\.json|plan\.json/);
    h.document.getElementById('modalHost').innerHTML='';
    h.run("exportModal('S-0826-01','missing-artifact'); exportModal('job-demo-flash-alias')");
    assert.equal(h.document.getElementById('modalHost').innerHTML,'');
    assert.equal(h.run('JSON.stringify(HIST)'),original);
    h.run("HIST.find(row=>row.id==='S-0826-01').artifacts[1].status='missing'; exportModal('S-0826-01','post-flash-hilog.txt')");
    assert.equal(h.document.getElementById('modalHost').innerHTML,'');
  }
});

test('Flash unresolved stops outrank later success and never offer another flash', () => {
  for(const state of ['unknown','waiting','running']) {
    const h=harness(`?page=flash&flashHistory=${state}&lang=en`);
    assert.equal(h.run('focusedFlashActivity().id'),`job-demo-flash-${state}`);
    if(state==='running')continue;
    h.run('chooseFlashImage()');
    const page=h.run('pFlash()');
    assert.match(page,/data-sync-id="flash.runtime.attention"/);
    assert.doesNotMatch(page,/<button[^>]+onclick="runFlash\(\)"/);
    h.run('runFlash()');
    assert.equal(h.run('S.jobs.length'),0);
    h.run('openFlashRecord(focusedFlashActivity().id)');
    assert.equal(h.run('S.histSel'),`job-demo-flash-${state}`);
  }
});

test('every History kind preserves missing facts and exports only its explicit inventory', () => {
  for(const lang of ['en','zh-Hans']) {
    const h=harness(`?page=history&lang=${lang}`);
    for(const kind of ['flash','debug','viewer','trace','diagnostics','device','other']) {
      const detail=h.run(`histDetail({id:'missing',kind:'${kind}',st:'cancelled',mode:'execute',dev:'DAYU200'})`);
      assert.match(detail,/Not reported|未报告/);
      assert.match(detail,/did not report typed parameters|未报告类型化参数/);
      assert.doesNotMatch(detail,/9 steps|e0a1|binding rev|plan\.json|flash\.log|trace\.htrace|stdout\.elementtree|persist\.ace|compensation completed|参数已恢复|data-artifact-name=/);
    }
    const parameters=h.run(`historyParametersHTML({inputs:{durationSeconds:30},traceParameters:[
      {name:'explicit.parameter',beforeState:'value',beforeValue:'false',afterState:'value',afterValue:'false',comparison:'unchanged'},
      {name:'changed.parameter',beforeState:'value',beforeValue:'false',afterState:'value',afterValue:'true',comparison:'changed'},
      {name:'unreadable.parameter',beforeState:'missing',afterState:'unreadable',comparison:'unverified'}]})`);
    assert.match(parameters,/history.parameters.traceDiff/);
    assert.match(parameters,/history.parameters"/);
    assert.match(parameters,/Unchanged|未改变/);
    assert.match(parameters,/Changed|已改变/);
    assert.match(parameters,/Unverified|未验证/);
    assert.match(parameters,/Unreadable|无法读取/);
    assert.doesNotMatch(parameters,/Restored|已恢复/);
    assert.match(h.run('historyParametersHTML({inputs:{}})'),/recorded no parameters|未记录参数/);
    const original=h.run('JSON.stringify(HIST)');
    for(const row of JSON.parse(original)) {
      const detail=h.run(`histDetail(HIST.find(row=>row.id===${JSON.stringify(row.id)}))`);
      assert.doesNotMatch(detail,/schema 1\.0|e0a1|9 steps|binding rev|restoreParam/);
      for(const artifact of row.artifacts||[]) {
        assert.ok(detail.includes(`data-artifact-name="${artifact.name}"`));
        h.run(`exportModal(${JSON.stringify(row.id)},${JSON.stringify(artifact.name)})`);
        const preview=h.document.getElementById('modalHost').innerHTML;
        assert.ok(preview.includes(artifact.name));
        assert.ok(preview.includes(artifact.privacy));
        assert.match(preview,/Demo complete: no file written/);
        assert.doesNotMatch(preview,/已导出并校验/);
        if(artifact.privacy==='standard')assert.doesNotMatch(preview,/Export sensitive|导出敏感/);
        h.document.getElementById('modalHost').innerHTML='';
      }
      h.run(`exportModal(${JSON.stringify(row.id)},'missing-file')`);
      assert.equal(h.document.getElementById('modalHost').innerHTML,'');
    }
    h.run("exportModal('missing-job','plan.json')");
    assert.equal(h.document.getElementById('modalHost').innerHTML,'');
    assert.equal(h.run('JSON.stringify(HIST)'),original);
    assert.equal(h.run('inspectorJobs()[2].standardLog'),'capture.log');
    assert.equal(h.run('inspectorJobs()[3].standardLog'),null);
    h.run("HIST[2].artifacts.find(a=>a.name==='capture.log').status='missing'");
    assert.equal(h.run('inspectorJobs()[2].standardLog'),null);
    h.run("exportModal('S-0826-03','capture.log')");
    assert.equal(h.document.getElementById('modalHost').innerHTML,'');
  }
});

test('History filters use exact identity, current attention facts and reported timestamps', () => {
  const h=harness('?page=history&lang=en');
  h.run(`HIST.splice(0,HIST.length,
    {id:'a',kind:'trace',op:'capture.diagnostics@1',st:'succeeded',mode:'execute',target:'target-a',sessionID:'session-a',finishedAtUTC:'2026-08-26T06:00:00Z'},
    {id:'b',kind:'trace',op:'capture.diagnostics@1',st:'running',mode:'planned',target:'target-b',sessionID:'session-a',createdAtUTC:'2026-08-25T06:00:00Z',waitingForHuman:true},
    {id:'c',kind:'other',st:'interrupted',dev:'target-a',outcomeUnknown:true,resolvedByTargetAliasResolutionID:'relation',createdAtUTC:'2026-08-19T05:59:00Z'},
    {id:'d',kind:'other',st:'cancelled',outstandingResidueCount:1,day:'Today'},
    {id:'e',kind:'other',st:'interrupted'},
    {id:'f',kind:'other',st:'waitingForRecovery',outcomeUnknown:true},
    {id:'g',kind:'other',st:'future-state'})`);
  const ids=()=>JSON.parse(h.run("JSON.stringify(filteredHistory(Date.parse('2026-08-26T06:30:00Z')).map(row=>row.id))"));
  assert.deepEqual(ids(),['a','b','c','g','f','e','d']);
  for(const [query,expected] of [['capture.diagnostics',['a','b']],['target-a',['a']],['session-a',['a','b']],['running',['b']]]) {
    h.run(`resetHistoryFilters();S.hf.query=${JSON.stringify(query)}`);
    assert.deepEqual(ids(),expected);
  }
  h.run("resetHistoryFilters();S.hf.session='session-a'");assert.deepEqual(ids(),['a','b']);
  h.run("S.hf.session='a'");assert.deepEqual(ids(),[],'Job ID is not a Session ID');
  h.run("resetHistoryFilters();S.hf.target='target-a'");assert.deepEqual(ids(),['a'],'display device is not an exact target');
  h.run("resetHistoryFilters();S.hf.status='attention'");assert.deepEqual(ids(),['b','f','d']);
  h.run("S.hf.status='active'");assert.deepEqual(ids(),['b','f']);
  h.run("resetHistoryFilters();S.hf.mode='planOnly'");assert.deepEqual(ids(),['b']);
  h.run("S.hf.mode='unknown'");assert.deepEqual(ids(),['c','g','f','e','d']);
  for(const [time,expected] of [['lastHour',['a']],['lastDay',['a']],['lastWeek',['a','b']]]) {
    h.run(`resetHistoryFilters();S.hf.time=${JSON.stringify(time)}`);assert.deepEqual(ids(),expected);
  }
  // The presets the toolbar actually invokes; there is no second preset entry point.
  h.run("S.hf.query='stale';applyHistorySavedAction('attention')");assert.equal(h.run('S.hf.query'),'');assert.deepEqual(ids(),['b','f','d']);
  h.run("applyHistorySavedAction('failed')");assert.equal(h.run('S.hf.time'),'lastWeek');
  const stateSource=readFileSync(join(root,'Packages/ArkDeckKit/Sources/ArkDeckCore/JobStateMachine.swift'),'utf8');
  const states=[...stateSource.split('public enum JobState:')[1].split('public var isTerminal')[0].matchAll(/^  case (\w+)$/gm)].map(match=>match[1]);
  const terminal=stateSource.match(/case (\.planned[^:]+):\s+true/)[1].split(',').map(value=>value.trim().slice(1));
  assert.deepEqual(JSON.parse(h.run('JSON.stringify(HISTORY_ACTIVE_STATES)')),states.filter(state=>!terminal.includes(state)));
});

test('Recovery banners keep each unresolved Job identity and the native guidance without replay', () => {
  const catalog=JSON.parse(read('ArkDeckApp/Resources/JobsLocalizable.xcstrings')).strings;
  for(const lang of ['en','zh-Hans']) {
    const h=harness(`?page=debug&lang=${lang}`);
    h.run(`HIST.splice(0,HIST.length,
      {id:'job-unknown',kind:'flash',op:'flash.full-restore@1',target:'target-one',st:'interrupted',outcomeUnknown:true},
      {id:'job-human',kind:'flash',op:'flash.full-restore@1',target:'target-two',st:'awaitingRebindConfirmation',waitingForHuman:true},
      {id:'job-safe',kind:'flash',op:'flash.full-restore@1',target:'target-three',st:'resumeAtConfirmedSafeBoundary'},
      {id:'job-archive',kind:'flash',op:'flash.full-restore@1',target:'target-four',st:'userAbandonRequested'},
      {id:'job-waiting',kind:'flash',op:'flash.full-restore@1',target:'target-five',st:'waitingForRecovery'},
      {id:'job-resolved',kind:'flash',op:'flash.full-restore@1',target:'target-old',st:'waitingForRecovery',outcomeUnknown:true,supersededByRecoveryEpochID:'recovery-demo'});
      S.hf.query='unrelated';S.hf.kind='viewer'`);
    const before=h.run('JSON.stringify(HIST)'),banners=h.run('recoveryHTML()');
    assert.ok(banners.includes(catalog['jobRecovery.count'].localizations[lang].stringUnit.value.replace('%d','5')));
    const ids=['job-unknown','job-human','job-safe','job-archive','job-waiting'];
    assert.deepEqual([...banners.matchAll(/data-job-id="([^"]+)"/g)].map(match=>match[1]),ids);
    assert.ok(!banners.includes('job-resolved'));
    for(const kind of ['outcomeUnknown','humanRequired','resumeSafe','archivePending','waiting']) {
      for(const field of ['title','guidance'])assert.ok(banners.includes(catalog[`jobRecovery.${kind}.${field}`].localizations[lang].stringUnit.value));
    }
    assert.match(banners,/onclick="openHistoryRun\(this.dataset.jobId\)"/);
    for(const page of ['overview','flash','debug','dump','trace','device-control','diagnostics','history','device','auth']) {
      h.run(`S.nav=${JSON.stringify(page)}`);assert.equal(h.run('recoveryHTML()'),banners,`${page} retains all outstanding items`);
    }
    for(const page of ['settings','trace-viewer','trace-shortcuts','automation']) {
      h.run(`S.nav=${JSON.stringify(page)}`);assert.equal(h.run('recoveryHTML()'),'');
    }
    for(const id of ids) {
      h.run(`S.hf.query='unrelated';S.hf.kind='viewer';openHistoryRun(${JSON.stringify(id)})`);
      assert.equal(h.run('S.histSel'),id);assert.equal(h.run('S.hf.query'),'');assert.equal(h.run('S.hf.kind'),'all');
      assert.equal(h.document.querySelector('.history-record.on').scrolledIntoView,true);
    }
    assert.equal(h.run('JSON.stringify(HIST)'),before);assert.equal(h.run('S.jobs.length'),0);
    h.run("HIST.splice(1);S.nav='history'");
    assert.ok(!h.run('recoveryHTML()').includes('jobRecovery.count'), 'one record does not need a count header');
    h.run('HIST.splice(0)');assert.equal(h.run('recoveryHTML()'),'');
  }
});

test('Review appearance keeps its actual mode label across language and page rendering', () => {
  const h=harness('?page=history&lang=en&appearance=dark');
  for(const [mode,en,zh] of [['dark','Dark','深色外观'],['light','Light','浅色外观'],['system','System appearance','系统外观']]) {
    for(const [lang,label] of [['en',en],['zh-Hans',zh]]) {
      h.run(`S.appearance=${JSON.stringify(mode)};S.language=${JSON.stringify(lang)};renderShellText()`);
      assert.equal(h.document.getElementById('themeToggle').textContent,label);
    }
  }
});

test('History query updates immediately while keeping selection and expanded filter controls', () => {
  const h=harness('?page=history&lang=en');
  const input=h.document.querySelector('.history-search input');
  input.selectionStart=3;input.selectionEnd=5;input.focus=()=>{input.focused=true;};
  input.setSelectionRange=(start,end)=>{input.restoredRange=[start,end];};
  h.run("S.historyFiltersOpen=true;setHistoryQuery('no-such-record')");
  assert.equal(h.run('filteredHistory().length'),0);
  assert.equal(input.focused,true);assert.deepEqual(input.restoredRange,[3,5]);
  assert.match(h.run('pHistory()'),/oninput="setHistoryQuery\(this.value\)"/);
  assert.match(h.run('pHistory()'),/<details open class="history-expanded-filters" ontoggle=/);
  h.run("setHistoryFilter('status','failed');resetHistoryFilters()");
  assert.equal(h.run('S.historyFiltersOpen'),true);
});

test('History compact activity picker mirrors every native category and the workspace-width boundary', () => {
  const native=read('ArkDeckApp/Features/History/RuntimeHistoryView.swift');
  // Match the threshold, not the container idiom around it: #1606 moved this
  // from `workspace.size.width >= 890` to onGeometryChange plus a stored
  // `workspaceWidth`, and a pattern tied to the old spelling broke while the
  // boundary itself never changed.
  const boundary=Number(native.match(/(?:workspaceWidth|workspace\.size\.width)\s*>=\s*(\d+)/)[1]);
  assert.ok(html.includes(`@container history (max-width:${boundary-1}px)`));
  assert.match(html,/classList\.toggle\("history-page",S\.nav==="history"\)/);
  const h=harness('?page=history&lang=en');
  h.run("setHistoryFilter('kind','device')");
  const picker=h.run('pHistory()').match(/<label class="history-compact-activity">[\s\S]*?<\/label>/)[0];
  const keys=[...picker.matchAll(/<option value="([^"]+)"/g)].map(m=>m[1]);
  assert.deepEqual(keys.slice().sort(),enumCases('ArkDeckApp/Features/History/RuntimeHistoryView.swift','HistoryActivityFilter').sort());
  assert.match(picker,/<option value="device" selected>/);
});

test('History compact popovers retain filters, saved actions and focus after a filter rerender', () => {
  for(const lang of ['en','zh-Hans']) {
    const h=harness(`?page=history&lang=${lang}`),markup=h.run('pHistory()');
    assert.match(markup,/id="historyCompactFiltersButton" popovertarget="historyCompactFilters"/);
    const fields=markup.match(/id="historyCompactFilters"[\s\S]*?<\/div>\s*<div class="history-popover"/)[0];
    assert.match(fields,/popover="auto" role="dialog" aria-label="(?:Filter history|筛选历史)"/);
    assert.deepEqual([...fields.matchAll(/<select[^>]*data-history-filter="([^"]+)"/g)].map(m=>m[1]),['status','mode','session','target','time']);

    const panel=h.document.querySelector('.history-popover:popover-open');
    panel.id='historyCompactFilters';panel.dataset.trigger='historyCompactFiltersButton';
    const restored=h.document.getElementById(panel.id),trigger=h.document.getElementById(panel.dataset.trigger);
    const selected={focus(){this.focused=true;}};
    trigger.focus=()=>{trigger.focused=true;};
    trigger.getBoundingClientRect=()=>({right:850,bottom:300});
    restored.getBoundingClientRect=()=>({width:360,height:290});
    restored.dataset=panel.dataset;
    restored.showPopover=options=>{restored.source=options.source;};
    restored.querySelector=selector=>selector==='[data-history-filter="status"]'?selected:null;
    h.document.documentElement.clientWidth=900;h.document.documentElement.clientHeight=650;
    h.document.activeElement={dataset:{historyFilter:'status'}};
    h.run("setHistoryFilter('status','failed')");
    assert.equal(h.run('S.hf.status'),'failed');
    assert.equal(restored.source,trigger);assert.ok(trigger.focused&&selected.focused);
    assert.equal(restored.style.left,'490px');assert.equal(restored.style.top,'308px');

    h.run(`let dismissPanel=document.querySelector('.history-popover:popover-open'),dismissTrigger=$(dismissPanel.dataset.trigger),insideTarget={},outsideTarget={};
      dismissPanel.contains=target=>target===insideTarget;
      dismissTrigger.contains=target=>target===dismissTrigger;
      dismissPanel.hidePopover=()=>dismissPanel.hidden=(dismissPanel.hidden||0)+1;
      let escapeEvent={key:'Escape',preventDefault(){this.prevented=true}};`);
    assert.equal(h.run('dismissHistoryPopoverOnEscape({key:"Enter"})'),false);
    assert.equal(h.run('dismissHistoryPopoverOnEscape(escapeEvent)'),true);
    assert.equal(h.run('escapeEvent.prevented'),true);
    assert.equal(h.run('dismissPanel.hidden'),1);
    assert.equal(h.run('dismissHistoryPopoverOnPointerDown({target:insideTarget})'),false);
    assert.equal(h.run('dismissHistoryPopoverOnPointerDown({target:dismissTrigger})'),false);
    assert.equal(h.run('dismissHistoryPopoverOnPointerDown({target:outsideTarget})'),true);
    assert.equal(h.run('dismissPanel.hidden'),2);

    h.run("S.hf.kind='viewer';applyHistorySavedAction('save');resetHistoryFilters();applyHistorySavedAction('restore')");
    assert.equal(h.run('S.hf.kind'),'viewer');assert.equal(h.run('S.hf.status'),'failed');
    h.run("applyHistorySavedAction('attention')");assert.equal(h.run('S.hf.kind'),'all');assert.equal(h.run('S.hf.status'),'attention');
    h.run("applyHistorySavedAction('failed')");assert.equal(h.run('S.hf.time'),'lastWeek');
    h.run("applyHistorySavedAction('delete')");assert.equal(h.run('S.savedHistoryFilter'),null);
  }
});

test('History details expose supplied correlation, evidence and artifact metadata without filling gaps', () => {
  for (const lang of ['en','zh-Hans']) {
    const h=harness(`?page=history&lang=${lang}`);
    h.run(`const rich={id:'job-explicit',kind:'trace',op:'capture.diagnostics@1',st:'failed',mode:'execute',
      sessionID:'session-explicit',target:'target-explicit',createdAtUTC:'2026-08-26T01:00:00Z',startedAtUTC:'2026-08-26T01:00:01Z',finishedAtUTC:'2026-08-26T01:00:02Z',
      outcomeUnknown:false,waitingForHuman:true,outstandingResidueCount:2,
      correlation:{jobID:'job-explicit',sessionID:'session-explicit',operationReference:'capture.diagnostics@1',targetID:'target-explicit',artifacts:[{id:'artifact-explicit',name:'capture.log',role:'log',sha256:'fixture-hash'}]},
      evidence:{providerID:'hdc',catalogDigest:'fixture-catalog',bindingRevision:0,authorityKind:'fixture-authority',authorityReference:'fixture-reference',observedModel:'fixture-model',observedFirmware:'fixture-firmware',observedTransport:'USB',terminalState:'failed',executionMode:'execute',actualEffect:'deviceMutation',firstEvidenceStepAtUTC:'2026-08-26T01:00:01Z',actualStepKinds:['captureTrace'],blockers:['<not markup>']},
      artifacts:[{name:'capture.log',role:'log',privacy:'standard',status:'invalid',sourceOperation:'capture.diagnostics@1',mediaType:'text/plain',statusDetail:'fixture hash mismatch'}]};HIST.unshift(rich)`);
    const detail=h.run('histDetail(rich)');
    for(const id of ['summary','correlation','evidence','recovery'])assert.ok(detail.includes(`data-sync-id="history.detail.${id}"`));
    for(const value of ['session-explicit','2026-08-26T01:00:00Z','2026-08-26T01:00:02Z','fixture-catalog','fixture-reference','fixture-model','fixture-firmware','artifact-explicit','fixture-hash','captureTrace','text/plain','fixture hash mismatch'])assert.ok(detail.includes(value),value);
    assert.match(detail,/&lt;not markup&gt;/);assert.doesNotMatch(detail,/<not markup>/);
    assert.match(detail,/Awaiting human action|等待人工操作/);
    h.run("S.hf.kind='flash';showHistorySession('job-explicit')");
    assert.equal(h.run('S.hf.session'),'session-explicit');
    h.run("rich.correlation.jobID='foreign-job'");
    assert.doesNotMatch(h.run('histDetail(rich)'),/artifact-explicit|fixture-hash/,'foreign correlation is not projected into this Job');
    for(const record of [{id:'missing',st:'cancelled'},{id:'unknown',st:'interrupted',outcomeUnknown:true,supersededByRecoveryEpochID:'recovery-demo'}]) {
      const missing=h.run(`histDetail(${JSON.stringify(record)})`);
      assert.match(missing,/Not reported|未报告/);
      assert.doesNotMatch(missing,/fixture-hash|fixture-catalog|No recovery needed|无需恢复/);
    }
    assert.match(h.run("histDetail({id:'known',st:'succeeded',outcomeUnknown:false,waitingForHuman:false,outstandingResidueCount:0})"),/No recovery needed|无需恢复/);
    assert.match(h.run("histDetail({id:'planned',mode:'planOnly',artifacts:[]})"),/plan-only|仅计划/);
    h.run("resetHistoryFilters();HIST.splice(0,HIST.length,{id:'missing',kind:'other'});S.histSel='missing'");
    assert.doesNotMatch(h.run('pHistory()'),/>undefined</);
  }
});

test('History workspace revisits retain exact read-only source context across all six destinations', () => {
  for(const lang of ['en','zh-Hans']) {
    const h=harness(`?page=history&lang=${lang}`);
    for(const [kind,page] of Object.entries({flash:'flash',debug:'debug',viewer:'dump',trace:'trace',device:'device-control',diagnostics:'diagnostics'})) {
      h.run(`HIST.unshift({id:'source-${kind}',kind:'${kind}',op:'capture.diagnostics@1',st:'interrupted',mode:'simulated',target:'original-target',sessionID:'original-session',artifacts:[{name:'explicit.txt',status:'published'}]})`);
      const before=h.run('JSON.stringify({jobs:S.jobs,continuation:S.continuation,devices:DEVICES})');
      h.run(`openHistoryDesignWorkspace('source-${kind}')`);
      assert.equal(h.run('S.nav'),page);
      const context=h.run('historyContextHTML()');
      for(const value of [`source-${kind}`,'original-target','capture.diagnostics@1','interrupted','explicit.txt'])assert.ok(context.includes(value));
      assert.match(context,/history.context.dismiss/);
      assert.equal(h.run('S.historyContext.kind'),kind);
      h.run(`HIST.find(row=>row.id==='source-${kind}').artifacts[0].name='later-change.txt'`);
      assert.match(h.run('historyContextHTML()'),/explicit.txt/,'context is a snapshot');
      assert.equal(h.run('JSON.stringify({jobs:S.jobs,continuation:S.continuation,devices:DEVICES})'),before);
      h.run("go('settings')");assert.equal(h.run('historyContextHTML()'),'');
      h.run(`go('${page}');dismissHistoryContext()`);assert.equal(h.run('historyContextHTML()'),'');
    }
    h.run("openHistoryDesignDiagnostics('source-viewer')");
    assert.equal(h.run('S.historyContext.kind'),'viewer','forwarding does not relabel the source workspace');
    assert.equal(h.run('S.nav'),'diagnostics');
    assert.match(h.run('historyContextHTML()'),/source-viewer/);
    h.run("openHistoryRun('source-viewer')");assert.equal(h.run('S.histSel'),'source-viewer');
    const before=h.run('JSON.stringify(S.historyContext)');
    h.run("openHistoryDesignWorkspace('missing');openHistoryDesignWorkspace('S-0825-04')");
    assert.equal(h.run('JSON.stringify(S.historyContext)'),before);
    const debugSource=read('Packages/ArkDeckKit/Sources/ArkDeckWorkflows/DebugApplicationFacade.swift');
    for(const [constant,tab] of [['debugHAPReference','apps'],['nativeLibraryReference','artifacts'],['captureDiagnosticsReference','logs'],['createPortForwardReference','net'],['removePortForwardReference','net']]) {
      const operation=debugSource.match(new RegExp(`static let ${constant} = "([^"]+)"`))[1];
      h.run(`HIST.unshift({id:'source-${constant}',kind:'debug',op:${JSON.stringify(operation)},st:'succeeded'});openHistoryDesignWorkspace('source-${constant}')`);
      assert.equal(h.run('S.debugTab'),tab);
    }
    assert.match(html,/historyContextHTML\(\)\+continuationDraftHTML\(\)/);
  }
});

test('Inspector record navigation preserves exact unknown facts rather than manufacturing a Diagnostics row', () => {
  const h=harness('?page=history&lang=en');
  h.run("S.jobs.push({id:'inspector-source',kind:'debug',operation:'debug.hap@1',state:'waitingForRecovery',outcomeUnknown:true,target:'original-target',sessionID:'original-session',mode:'execute',log:['explicit journal']});openInspectorRecord('inspector-source')");
  const record=JSON.parse(h.run("JSON.stringify(HIST.find(row=>row.id==='inspector-source'))"));
  assert.equal(record.kind,'debug');assert.equal(record.op,'debug.hap@1');
  assert.equal(record.outcomeUnknown,true);assert.equal(record.target,'original-target');
  assert.equal(record.sessionID,'original-session');assert.deepEqual(record.timeline,['explicit journal']);
  const before=h.run('JSON.stringify(HIST)');h.run("openInspectorRecord('inspector-source')");
  assert.equal(h.run('JSON.stringify(HIST)'),before);
  const unknown=harness('?jobState=unknown&lang=en');unknown.run("openInspectorRecord('job-demo-global')");
  assert.equal(unknown.run("HIST.find(row=>row.id==='job-demo-global').outcomeUnknown"),true);
});

test('explicit History samples use current Catalog fields and Artifact descriptors', () => {
  const h=harness('?page=history&lang=en');
  const operations=new Map(files(join(root,'Catalog/operations')).filter(path=>path.endsWith('.json')).map(path=>{
    const operation=JSON.parse(readFileSync(path,'utf8'));
    return [`${operation.id}@${operation.version}`,operation];
  }));
  for(const row of JSON.parse(h.run('JSON.stringify(HIST)')).filter(row=>row.artifacts)) {
    const operation=operations.get(row.op);
    assert.ok(operation,`${row.id} must name an exact published operation`);
    if(row.evidence)assert.equal(row.evidence.providerID,operation.provider);
    for(const artifact of row.artifacts) {
      const declared=operation.artifacts.find(a=>a.name===artifact.name);
      assert.ok(declared,`${row.id}: ${artifact.name} is not declared`);
      assert.equal(artifact.role,declared.role);
      assert.equal(artifact.privacy,declared.privacy);
      if(artifact.mediaType)assert.equal(artifact.mediaType,declared.mediaType);
      if(artifact.sourceOperation)assert.equal(artifact.sourceOperation,row.op);
    }
    for(const key of Object.keys(row.inputs||{}))assert.ok(operation.inputs.fields[key],`${row.id}: ${key} is not a typed input`);
  }
});

test('non-Flash demo history keeps its Job identity and never infers compensation or activity from a title', () => {
  const h=harness('?page=history&lang=en');
  h.run(`let completed={id:'job-demo-native',kind:'debug',operation:'deploy.native-library.app-owned@1',title:'本地库',state:'cancelled',mode:'execute',log:['explicit entry'],inputs:{nested:{value:1}}};histFromJob(completed);histFromJob(completed)`);
  assert.equal(h.run("HIST.filter(row=>row.id==='job-demo-native').length"),1);
  assert.equal(h.run('HIST[0].kind'),'debug');
  assert.equal(h.run('HIST[0].op'),'deploy.native-library.app-owned@1');
  h.run("completed.inputs.nested.value=2;completed.log.push('later');openHistoryRun(completed.id)");
  assert.equal(h.run('S.histSel'),'job-demo-native');
  assert.equal(h.run('HIST[0].inputs.nested.value'),1);
  assert.equal(h.run('HIST[0].timeline.length'),1);
  h.run("histFromJob({id:'unknown',title:'Flash Debug Trace',state:'planned',log:[]})");
  assert.equal(h.run('HIST[0].kind'),'other');
  h.run("let stopped={id:'cancelled-demo',title:'Demo',state:'running',cancelled:true,phaseIdx:3,safeBoundary:3,log:[]};advanceJob(stopped)");
  assert.equal(h.run('stopped.state'),'cancelled');
  assert.match(h.run("stopped.log.join(' ')"),/no compensation or parameter readback evidence/);
  assert.doesNotMatch(h.run('histDetail(HIST[0])'),/Restored|参数已恢复|compensation completed/);
});

test('Flash result and activity retain the submitted demo Job identity', () => {
  const h=harness('?page=flash&lang=en');
  h.run('chooseFlashImage(); runFlash()');
  const id=h.run('S.flashJob.id');
  assert.equal(h.run('focusedFlashActivity().id'),id);
  h.run('openFlashRecord(S.flashJob.id)');
  assert.equal(h.run('S.histSel'),id);
  h.run("finishFlash(S.flashJob,'succeeded','Design postflight sample')");
  assert.equal(h.run('S.lastFlash.jobID'),id);
  assert.equal(h.run('focusedFlashActivity().id'),id);
  assert.equal(h.run(`HIST.filter(h=>h.id==='${id}').length`),1);
  assert.match(h.run('pFlash()'),new RegExp(`openFlashRecord\\('${id}'\\)`));
});

test('all actual navigation items and subtabs are audited', () => {
  assert.deepEqual(enumCases('ArkDeckApp/App/ArkDeckApp.swift', 'ArkDeckNavigationItem'), coverage.navigation);
  assert.deepEqual(enumCases('ArkDeckApp/Features/Debug/DebugWorkspaceView.swift', 'DebugWorkspaceTab'), coverage.debugTabs);
  assert.deepEqual(enumCases('ArkDeckApp/Features/UIDump/UIDumpWorkspaceView.swift', 'ViewerInspectorTab'), coverage.viewerTabs);
  const settings = read('ArkDeckApp/Features/Settings/SettingsRootView.swift');
  // Same reason: #1606 replaced `Label(settingsText(...))` with SwiftUI's
  // `Tab(settingsText(...))`. Anchor on the localization call, which is the
  // fact under audit, rather than on whichever container wraps it.
  const tabs = [...settings.matchAll(/settingsText\("settings\.tab\.(\w+)"\)/g)].map(match => match[1]);
  assert.deepEqual(tabs, coverage.settingsTabs);
  const settingsCopy = JSON.parse(read('ArkDeckApp/Resources/SettingsLocalizable.xcstrings')).strings;
  const draftTabs = JSON.parse(harness().run('JSON.stringify(SETTINGS_TABS)'));
  assert.deepEqual(draftTabs, coverage.settingsTabs.map(id => [
    id === 'remoteSources' ? 'servers' : id,
    settingsCopy[`settings.tab.${id}`].localizations['zh-Hans'].stringUnit.value,
    settingsCopy[`settings.tab.${id}`].localizations.en.stringUnit.value,
  ]));
  const trace = read('ArkDeckApp/Features/Trace/TraceViewerWorkspaceView.swift').split('struct TraceSettingsPane:')[1];
  const sections = [...trace.split('var id:')[0].matchAll(/case (\w+)/g)].map(match => match[1]);
  assert.deepEqual(sections, coverage.traceSettingsSections);
});

test('new Flash drafts use the canonical operation and a supported archive format', () => {
  const h=harness('?page=flash&lang=en');
  h.run('chooseFlashImage()');
  assert.match(h.run('S.flashImage.name'), /\.tar\.gz$/);
  assert.match(h.run('flashDetails(S.flashImage)'), /flash\.full-restore@1/);
  assert.doesNotMatch(h.run('flashDetails(S.flashImage)'), /flash\.dayu200/);
  h.run('runFlash()');
  assert.match(h.run('S.flashJob.title'), /flash\.full-restore@1/);
});

test('Flash device access distinguishes an empty observation from a failed probe', () => {
  for (const lang of ['en','zh-Hans']) {
    for (const state of ['absent','available','unavailable']) {
      const h=harness(`?page=flash&lang=${lang}&deviceAccess=${state}`);
      const html=h.run('flashDetails(null)');
      assert.match(html, /data-sync-id="flash.deviceAccess"/);
      assert.match(html, state==='available'?/Loader device access is ready|Loader 设备访问就绪/:state==='unavailable'?/RockUSB discovery is unavailable|RockUSB 探测不可用/:/Device is offline or not in Loader mode|设备离线或未进入 Loader 模式/);
      if (state==='unavailable') {
        assert.match(html, /runtime_device_access_unreachable/);
        assert.doesNotMatch(html, /Responsible party|处理责任方/);
      } else {
        assert.match(html, /Responsible party|处理责任方/);
        assert.match(html, /Minimum next step|最小修复步骤/);
        if (state==='available') assert.match(html, /1 device\(s\) · Loader|1 台设备 · Loader/);
      }
      assert.match(html, /does not authorize flashing|不因发现 Loader 而授予刷写权限/);
      assert.doesNotMatch(html, /14 steps|Maximum stage effect|阶段最高 effect/);
      assert.doesNotMatch(h.run('pFlash()'), /3 required safety checks passed|3 项必需安全检查通过/);
      h.run('recheckFlashDeviceAccess()');
      assert.equal(h.document.querySelector('.flash-details').open, true);
      assert.equal(h.run('S.flashJob'), null);
    }
  }
});

test('Flash stage summaries never lower the published maximum effect', () => {
  const steps=JSON.parse(read('Catalog/operations/flash.full-restore.v1.json')).steps;
  const ranks=['hostOnly','readOnly','deviceMutation','destructive'];
  const groups=[steps.slice(0,3),steps.slice(3,7),steps.slice(7,8),steps.slice(8)];
  for (const lang of ['en','zh-Hans']) {
    const html=harness(`?page=flash&lang=${lang}`).run('flashDetails({name:"dayu200.tar.gz"})');
    const rows=[...html.matchAll(/<tr><td>.*?<\/tr>/g)].map(match=>match[0]);
    assert.equal(rows.length,groups.length);
    groups.forEach((group,index)=>{
      const maximum=ranks[Math.max(...group.map(step=>ranks.indexOf(step.effect)))];
      assert.ok(rows[index].includes(maximum), `${lang} stage ${index} must show ${maximum}`);
    });
  }
  for (const name of ['DataTable','JobInspector','PhaseTrack','WindowFrame']) {
    const source=read(`.design-sync/previews/${name}.tsx`);
    assert.doesNotMatch(source,/\.imgpkg|4 项安全检查通过/, `${name} must mirror supported current drafts`);
  }
  assert.match(read('.design-sync/previews/Card.tsx'), /flash\.full-restore@1 · hardwareGated/);
});

test('every App View file and preview is covered and linked', () => {
  const declaration = /\b(?:struct|class)\s+\w+(?:<[^{}]*>)?\s*:\s*[^\n{]*\b(?:View|NSViewRepresentable|NSView)\b/;
  const actual = files(join(root, 'ArkDeckApp'))
    .filter(path => path.endsWith('.swift') && declaration.test(readFileSync(path, 'utf8')))
    .map(path => relative(root, path)).sort();
  assert.deepEqual(actual, coverage.appViewFiles);
  for (const path of actual) assert.ok(report.includes(path), `missing source link: ${path}`);
  const previews = files(join(root, '.design-sync/previews'))
    .filter(path => path.endsWith('.tsx')).map(path => relative(root, path)).sort();
  assert.deepEqual(previews, coverage.previewFiles);
  for (const path of coverage.designInputs) assert.ok(read(path).length);
  const ids = [...report.matchAll(/^\| ([a-z][A-Za-z]+\.[A-Za-z]+) \|/gm)].map(match => match[1]);
  assert.deepEqual(ids, coverage.surfaceIDs);
  assert.equal(new Set(ids).size, ids.length);
});

test('all prototype destinations render in both languages', () => {
  const h = harness();
  for (const language of ['en', 'zh-Hans']) {
    h.run(`S.language=${JSON.stringify(language)}`);
    for (const page of h.run('Object.keys(PAGES)')) {
      h.run(`S.nav=${JSON.stringify(page)}`);
      const markup = h.run(`PAGES[${JSON.stringify(page)}]()`);
      assert.match(markup, /data-page-title=/, `${page} needs a window title`);
      assert.ok(markup.length > 100, `${page} returned no content`);
    }
  }
  const trust = harness('?page=auth&lang=en');
  assert.equal(trust.run('DEVICES.find(device=>device.id===S.device).state'), 'unauthorized',
    'a trust deep link must not label an already adopted candidate as untrusted');
});

test('prototype subtabs include every shipped Debug and Viewer destination', () => {
  const h = harness('?page=dump&viewerState=captured');
  const aliases = {properties:'attributes', rawDump:'raw', advancedDump:'advanced'};
  assert.deepEqual(JSON.parse(h.run('JSON.stringify(VIEWER_TABS.map(([id])=>id))')),
    coverage.viewerTabs.map(id=>aliases[id]||id));
  const viewer = [...h.run('pViewer()').matchAll(/data-viewer-tab="(\w+)"/g)].map(match=>match[1]);
  assert.deepEqual(viewer, coverage.viewerTabs.map(id=>aliases[id]||id));
  const debug = [...h.run('pDebug()').matchAll(/id="debug-tab-(\w+)"/g)].map(match=>match[1]);
  assert.deepEqual(debug, coverage.debugTabs.map(id=>({network:'net',commands:'cmd'})[id]||id));
  h.run('viewerTabKey({key:"End",preventDefault(){}},"attributes")');
  assert.equal(h.run('S.viewer.tab'), 'advanced');
});

test('Advanced Dump search and refusal states stay bound to the selected component', () => {
  const h = harness('?page=dump&viewerState=captured&viewerTab=advanced');
  h.run('S.viewer.advancedQuery="componentId"');
  assert.match(h.run('viewerAdvancedResults(viewerNode(42))'), /<dd>42<\/dd>/);
  h.run('selectViewerNode(31)');
  assert.match(h.run('viewerAdvancedHTML(viewerNode(S.viewer.selected))'), /<dd>31<\/dd>/);
  h.run('S.viewer.advancedState="missingIDs"');
  const refusal = h.run('viewerAdvancedHTML(viewerNode(S.viewer.selected))');
  assert.match(refusal, /no numeric hostWindowId\/componentId pair/);
  assert.doesNotMatch(refusal, /<dd>/);
  h.run('S.viewer.advancedState="failed"');
  assert.match(h.run('viewerAdvancedHTML(viewerNode(31))'), /viewer\.advancedDump\.retry/);
});

test('HAP mirrors published steps and validates the draft without creating a Job', () => {
  const h = harness('?page=debug&debugTab=apps');
  const operation = JSON.parse(read('Catalog/operations/debug.hap.v1.json'));
  assert.deepEqual(JSON.parse(h.run('JSON.stringify(DEBUG_HAP_STEPS)')),
    operation.steps.map(step=>[step.stepID,step.kind,step.effect]));
  assert.doesNotMatch(h.run('pDebug()'), /providerLoweringMissing/);
  assert.equal(h.run('debugHAPReady()'), false);
  h.run('debugPickHAP();S.hap.bundle="com.example.app";S.hap.ability="EntryAbility"');
  assert.equal(h.run('debugHAPReady()'), true);
  const cleanupSelect=h.run('pDebug()').match(/<select[^>]*data-hap-policy="cleanupPolicy"[^>]*>(.*?)<\/select>/s)[1];
  assert.deepEqual([...cleanupSelect.matchAll(/<option value="([^"]+)"/g)].map(m=>m[1]), operation.inputs.fields.cleanupPolicy.enum);
  assert.doesNotMatch(h.run('pDebug()'), /installFresh|restorePrevious/);
  for (const policy of operation.inputs.fields.cleanupPolicy.enum) {
    h.run(`S.hap.cleanup=${JSON.stringify(policy)}`);
    assert.equal(h.run('debugHAPReady()'), true);
  }
  h.run('S.hap.install="installFresh"');
  assert.equal(h.run('debugHAPReady()'), false);
  h.run('S.hap.install="installOrReplace";S.hap.cleanup="restorePrevious"');
  assert.equal(h.run('debugHAPReady()'), false);
  h.run('S.hap.cleanup="uninstall"');
  h.run('let hapModal="";modal=markup=>{hapModal=markup;};debugHAPPreview()');
  assert.match(h.run('hapModal'), /不会导入文件、创建 Job/);
  assert.equal(h.run('S.jobs.length'), 0);
  h.run('S.hap.bundle="com.example.app;id"');
  assert.equal(h.run('debugHAPReady()'), false);
  h.run('S.hap.bundle="com.example.app";S.hap.seconds="301"');
  assert.equal(h.run('debugHAPReady()'), false);
  h.run('S.hap.seconds="30";S.hap.available=false');
  assert.equal(h.run('debugHAPReady()'), false);
});

test('current navigation excludes the removed Automation plane', () => {
  const h = harness();
  const nav = JSON.parse(h.run('JSON.stringify(NAV.map(([id])=>id))'));
  const names = {uiDump: 'dump', device: 'device-control'};
  assert.deepEqual(nav, coverage.navigation.map(id => names[id] || id));
  assert.match(h.run('pAutomation()'), /CHG-2026-064/);
  assert.doesNotMatch(h.run('pAutomation()'), /HTASK-DEMO|onclick=".*(?:reconcile|pause|cancel)/);
});

test('Trace exposes validation without starting unavailable or invalid capture', () => {
  const h = harness();
  assert.doesNotMatch(h.run('pTrace()'), /data-sync-id="trace.start"[^>]*disabled/);
  h.run('startTrace()');
  assert.equal(h.run('S.trace.running'), false);
  assert.match(h.run('pTrace()'), /data-sync-id="trace.submission.failure"/);
  h.run('S.trace.availability="available"');
  for (const input of ['', '0', '1.5', '1e2', '601', 'Infinity']) {
    h.run(`setTraceDuration(${JSON.stringify(input)});startTrace()`);
    assert.equal(h.run('S.trace.duration'), input);
    assert.equal(h.run('traceDurationValid()'), false);
    assert.equal(h.run('S.trace.running'), false);
    assert.ok(h.run('S.trace.submissionFailure'));
  }
  h.run('setTraceDuration("10");startTrace()');
  assert.equal(h.run('S.trace.running'), true);
  h.run('S.trace.availability="unavailable";startTrace()');
  assert.equal(h.run('S.trace.running'), false);
});

test('Trace unit changes preserve duration and round minutes up', () => {
  const h = harness();
  h.run('setTraceDuration("121");setTraceUnit("minutes")');
  assert.equal(h.run('Number(S.trace.duration)'), 3);
  h.run('setTraceUnit("seconds")');
  assert.equal(h.run('Number(S.trace.duration)'), 180);
  h.run('setTraceDuration(600);setTraceUnit("minutes")');
  assert.equal(h.run('Number(S.trace.duration)'), 10);
  assert.equal(h.run('traceDurationValid()'), true);
  h.run('setTraceDuration("11")');
  assert.equal(h.run('traceDurationValid()'), false);
});

test('Trace validates each keystroke without rebuilding the focused field', () => {
  const h = harness();
  assert.match(h.run('pTrace()'), /oninput="setTraceDurationInput\(this\)"/);
  h.run('S.trace.availability="available";renderPage=()=>{throw new Error("must preserve input focus")};var input={value:"601",setAttribute(){}};setTraceDurationInput(input)');
  assert.equal(h.document.querySelector('[data-sync-id="trace.duration.validation"]').hidden, false);
  assert.equal(h.run('S.trace.submissionFailure'), null);
  h.run('input.value="600";setTraceDurationInput(input)');
  assert.equal(h.document.querySelector('[data-sync-id="trace.duration.validation"]').hidden, true);
  assert.equal(h.run('S.trace.duration'), '600');
});

test('Diagnostics defaults to unavailable controls rather than a fake session', () => {
  const h = harness();
  const markup = h.run('pDiagnostics()');
  assert.match(markup, /diagnostic_session_capture_not_connected/);
  assert.match(markup, /disabled data-sync-id="diagnostics.capture.arm"/);
  assert.match(markup, /disabled data-sync-id="diagnostics.capture.mark"/);
  assert.doesNotMatch(markup, /class="diag-timeline|已校准 ±|onclick="startDiagnostic/);
  const concept = harness('?concept=diagnostics&lang=en');
  assert.match(concept.run('pDiagnostics()'), /Future concept:/);
});

test('History selection belongs to the filtered list', () => {
  const h = harness();
  for (const kind of ['debug', 'device', 'other']) {
    h.run(`setHistoryFilter('kind',${JSON.stringify(kind)});pHistory()`);
    assert.equal(h.run('HIST.find(row=>row.id===S.histSel).kind'), kind);
  }
  h.run('setHistoryFilter("query","no-matching-record-xyz")');
  const markup = h.run('pHistory()');
  assert.equal(h.run('S.histSel'), null);
  assert.doesNotMatch(markup, /data-sync-id="history.detail.job"/);
});

test('Overview selects the source record despite old History filters', () => {
  const h = harness();
  h.run('S.hf.kind="debug";S.hf.query="unrelated";openHistoryRun("S-0711-04");pHistory()');
  assert.equal(h.run('S.nav'), 'history');
  assert.equal(h.run('S.histSel'), 'S-0711-04');
  assert.equal(h.run('S.hf.kind'), 'all');
  assert.equal(h.run('S.hf.query'), '');
});

test('HiLog summaries revisit exact History records across coverage and failure states without replay', () => {
  for(const lang of ['en','zh-Hans']) {
    const h=harness(`?page=history&hilogSummary=complete&lang=${lang}`);
    const before=h.run('JSON.stringify(HIST)'),jobs=h.run('S.jobs.length');
    const historyCopy=JSON.parse(read('ArkDeckApp/Resources/HistoryLocalizable.xcstrings')).strings;
    assert.ok(h.run('pHistory()').includes(historyCopy['history.context.readOnly'].localizations[lang].stringUnit.value));
    assert.doesNotMatch(h.run('pHistory()'),/index \/ summary \/ markers/,'summary history must not promise capture-session validation');
    for(const state of ['complete','partial','unrecognized','empty','corrupt','complete']) {
      h.run(`openHistoryDesignWorkspace('job-demo-hilog-summary-${state}')`);
      assert.equal(h.run('S.nav'),'diagnostics');
      assert.equal(h.run('S.historyContext.id'),`job-demo-hilog-summary-${state}`);
      const markup=h.run('pDiagnostics()');
      if(state==='corrupt') {
        assert.match(markup,/diagnostics_hilog_summary_integrity_mismatch/);
        assert.doesNotMatch(markup,/data-sync-id="diagnostics.hilog.summary"/);
        assert.match(h.run('pDiagnostics()'),/diagnostics_hilog_summary_integrity_mismatch/,'retry reads the same malformed record');
      } else {
        assert.match(markup,/data-sync-id="diagnostics.hilog.summary"/);
        assert.ok(markup.includes(`data-sync-id="diagnostics.hilog.job">job-demo-hilog-summary-${state}`));
        assert.match(markup,/do not prove capture completeness|不证明采集完整/);
        assert.match(markup,/does not read the raw log|不会读取或重新核验原始日志/);
        assert.doesNotMatch(markup,/data-sync-id="diagnostics.alignment"|data-sync-id="diagnostics.capture.arm"|data-sync-id="diagnostics.preview.text"/);
        for(const level of ['D','I','W','E','F'])assert.ok(markup.includes(`data-sync-id="diagnostics.hilog.count.${level}"`));
      }
      h.run("readDiagnosticPreview('hilog.txt')");
      assert.equal(h.run('S.diagnostics.preview'),null);
      assert.equal(h.run('JSON.stringify(HIST)'),before);
      assert.equal(h.run('S.jobs.length'),jobs);
    }
    h.run("openHistoryDesignDiagnostics('S-0826-04')");
    assert.equal(h.run('S.diagnostics.hilogSummary'),null);
    assert.match(h.run('pDiagnostics()'),/data-sync-id="diagnostics.alignment"/);
    assert.doesNotMatch(h.run('pDiagnostics()'),/data-sync-id="diagnostics.hilog.summary"/);
    h.run("openHistoryDesignWorkspace('job-demo-hilog-summary-complete'); HIST.push({id:'unsupported-analysis',kind:'diagnostics',op:'analyzer.extract-crash-signature@1'}); openHistoryDesignWorkspace('unsupported-analysis')");
    assert.match(h.run('pDiagnostics()'),/diagnostics_unsupported_operation/);
    assert.doesNotMatch(h.run('pDiagnostics()'),/data-sync-id="diagnostics.hilog.summary"/);
    const copy=JSON.parse(h.run('JSON.stringify(DIAGNOSTICS_COPY)'));
    const native=JSON.parse(read('ArkDeckApp/Resources/DiagnosticsLocalizable.xcstrings')).strings;
    for(const key of Object.keys(native).filter(key=>key.startsWith('diagnostics.hilog.'))) {
      assert.equal(copy[key][lang],native[key].localizations[lang].stringUnit.value,key);
    }
  }
});

test('Settings exposes all seven panes and excludes raw data from App diagnostics', () => {
  const h = harness();
  const keys = JSON.parse(h.run('JSON.stringify(SETTINGS_TABS.map(([id])=>id))'));
  assert.deepEqual(keys, coverage.settingsTabs.map(key => key === 'remoteSources' ? 'servers' : key));
  h.run('let openedModal="";modal=markup=>{openedModal=markup;};diagModal()');
  assert.match(h.run('openedModal'), /device raw/);
  assert.doesNotMatch(h.run('openedModal'), /<input/);
});

test('saved Diagnostics sessions expose actual gaps and require an explicit raw preview', () => {
  const h=harness('?page=diagnostics&diagnosticsState=loaded&lang=en');
  const markup=h.run('pDiagnostics()');
  assert.match(markup,/Cannot align/);
  assert.match(markup,/Time not reported/);
  assert.doesNotMatch(markup,/data-sync-id="diagnostics.preview.text"/);
  assert.doesNotMatch(markup,/data-sync-id="diagnostics.partial"/);
  h.run('readDiagnosticPreview("hilog.txt")');
  assert.match(h.run('pDiagnostics()'),/UI fixture only/);
  h.run('S.diagnostics.replacedInvalidUTF8=true');
  assert.match(h.run('pDiagnostics()'),/diagnostics.preview.encodingWarning/);
  assert.match(h.run('pDiagnostics()'),/original Artifact and its SHA-256 are unchanged/);
  h.run('readDiagnosticPreview("capture-summary.json")');
  assert.doesNotMatch(h.run('pDiagnostics()'),/diagnostics.preview.encodingWarning/,'JSON must never use lossy text decoding');
  h.run('S.diagnostics.reader="partial";S.diagnostics.preview=null');
  assert.match(h.run('pDiagnostics()'),/data-sync-id="diagnostics.partial"/);
  h.run('S.diagnostics.reader="failed"');
  assert.match(h.run('pDiagnostics()'),/diagnostics.session.retry/);
  h.run('S.histSel="S-0826-03"');
  assert.match(h.run('pHistory()'),/data-sync-id="history.openDiagnostics"/);
  h.run('openHistoryDesignDiagnostics("S-0826-03")');
  assert.equal(h.run('S.diagnostics.jobID'),'S-0826-03');
  assert.equal(h.run('S.diagnostics.reader'),'trace');
  assert.equal(h.run('HIST.find(h=>h.id==="S-0826-03").kind'),'trace','opening another reader must retain the source workspace');
  assert.equal(h.run('S.jobs.length'),0,'reading a capture must not create a Job');
  h.run('openHistoryDesignDiagnostics("S-0826-01")');
  assert.equal(h.run('S.diagnostics.jobID'),'S-0826-03','non-capture records cannot enter this reader');
});

test('Overview copies typed input and thread into a new draft without a Job or authority', () => {
  const h=harness('?lang=en');
  h.run('S.historyContext={source:"analyzer.summarize-hilog@1",jobID:"job-demo-hilog-summary-complete"}');
  h.document.getElementById('page').scrollTop=500;
  h.document.scrollingElement.scrollTop=80;
  h.run('prepareContinuation("S-0826-04")');
  assert.equal(h.run('S.nav'),'diagnostics');
  assert.equal(h.run('S.historyContext'),null,'the new draft must replace the previous History source context');
  assert.equal(h.document.getElementById('page').scrollTop,0,'the workspace must reveal the prepared draft');
  assert.equal(h.document.scrollingElement.scrollTop,0,'document scroll must not hide the prepared draft');
  assert.equal(h.run('S.jobs.length'),0);
  assert.equal(h.run('S.continuation.thread'),h.run('HIST.find(x=>x.id==="S-0826-04").thread'));
  h.run('S.continuation.inputs.durationSeconds=20');
  assert.equal(h.run('HIST.find(x=>x.id==="S-0826-04").inputs.durationSeconds'),10,'input objects must not alias history');
  h.run('submitContinuationPreview()');
  assert.equal(h.run('S.jobs.length'),0);
  assert.equal(h.run('S.continuation.attempted'),true);
  assert.match(h.run('continuationDraftHTML()'),/No Job is dispatched or created/);
  h.run('S.continuation=null;prepareContinuation("S-0711-04")');
  assert.equal(h.run('S.continuation'),null,'unknown outcomes must not prepare a replay');
});

test('Trace Viewer selects actual sample events, rejects invalid ranges and preserves focus', () => {
  const h=harness('?page=trace-viewer&traceViewerState=loaded&lang=en');
  assert.match(h.run('pTraceViewer()'),/trace.viewer.timeline/);
  assert.equal(h.run('S.traceViewer.selection'),'none');
  assert.match(h.run('traceViewerInspectorHTML()'),/trace.viewer.metadata/);
  assert.match(h.run('traceViewerInspectorHTML()'),/Source bytes/);
  h.run('traceViewerAddMark()');
  assert.equal(h.run('S.traceViewer.marks.length'),0,'no selection must not invent a mark');
  h.run('S.traceViewer.query="DrawFrame";S.traceViewer.event="absent";traceViewerStepMatch(-1)');
  assert.equal(h.run('S.traceViewer.event'),'draw');
  assert.doesNotMatch(h.run('traceViewerInspectorHTML()'),/trace.viewer.metadata/);
  h.run('traceViewerSelect("not-an-event")');
  assert.equal(h.run('S.traceViewer.event'),'draw');
  for(const value of ['','NaN','-1','9'])h.run(`traceViewerRange({value:${JSON.stringify(value)},setAttribute(){}},{value:"3.8",setAttribute(){}})`);
  assert.deepEqual(JSON.parse(h.run('JSON.stringify(S.traceViewer.range)')),[2.1,3.8]);
  assert.match(h.document.getElementById('traceRangeError').textContent,/start before its end/);
  h.run('traceViewerRange({value:"1",setAttribute(){}},{value:"3.8",setAttribute(){}});traceViewerAddMark()');
  assert.equal(h.run('S.traceViewer.marks[0].time'),1);
  assert.equal(h.run('S.traceViewer.marks[0].kept'),false);
  h.run('renderPage=()=>{throw Error("input focus must be retained")};traceViewerSearch({value:"Draw"});traceViewerFilter({value:"no-matching-track"})');
  assert.match(h.run('traceViewerTracksHTML()'),/No matching tracks/);
  h.run('S.traceViewer.state="failed"');
  assert.doesNotMatch(h.run('pTraceViewer()'),/data-sync-id="trace.viewer.timeline"/);
});

test('Trace help mirrors all pinned shortcut sections and bindings in both languages', () => {
  const h=harness();
  const sections=JSON.parse(h.run('JSON.stringify(TRACE_SHORTCUT_SECTIONS)'));
  assert.deepEqual(sections.map(x=>x.title),['Timeline','Pointer, on the timeline','Search Results']);
  assert.equal(sections.flatMap(x=>x.shortcuts).length,19);
  assert.ok(sections.every(section=>section.titleZH&&section.shortcuts.every(x=>x.actionZH&&x.keysZH)));
  const pin=JSON.parse(read('ArkDeck.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved')).pins.find(x=>x.identity==='arktrace').state.revision;
  assert.ok(html.includes(`Generated reference: ArkTrace ${pin}`),'refresh the mirror when the package pin changes');
  h.run('S.language="en"');
  assert.match(h.run('pTraceShortcuts()'),/Zoom in \/ out about the pointer/);
  h.run('S.language="zh-Hans"');
  assert.match(h.run('pTraceShortcuts()'),/以指针位置为锚点放大/);
});

test('Trace annotations keep flag and range identity through edit, colour and removal', () => {
  const h=harness('?page=trace-viewer&traceViewerState=loaded&lang=en');
  for (const invalid of ['NaN','-1','9']) h.run(`traceViewerAddFlag(${invalid})`);
  assert.equal(h.run('S.traceViewer.flags.length'),0);
  h.run('traceViewerAddFlag(2)');
  assert.equal(h.run('S.traceViewer.flags[0].time'),2);
  assert.match(h.run('traceViewerInspectorHTML()'),/trace.viewer.metadata/);
  assert.match(h.run('traceViewerInspectorHTML()'),/Rename Flag 1/);
  h.run('traceViewerEditAnnotation("flag",1);traceViewerRenameAnnotation("flag",1,"<probe>")');
  assert.match(h.run('traceViewerAnnotationsHTML()'),/Rename &lt;probe&gt;/);
  assert.doesNotMatch(h.run('traceViewerAnnotationsHTML()'),/<probe>/);
  h.run('for(let i=0;i<7;i++)traceViewerColorAnnotation("flag",1)');
  assert.equal(h.run('S.traceViewer.flags[0].color'),1);
  h.run('traceViewerRemoveAnnotation("flag",1);traceViewerAddFlag(4)');
  assert.equal(h.run('S.traceViewer.flags[0].id'),2,'deleted annotation IDs must not be reused');
  assert.equal(h.run('S.traceViewer.flags[0].label'),'Flag 1','display names follow native item counts, not stable IDs');
  h.run('traceViewerSelect("draw");traceViewerAddMark();traceViewerAddMark(true)');
  assert.deepEqual(JSON.parse(h.run('JSON.stringify(S.traceViewer.marks.map(m=>m.range))')),[[3.8,5.05],[3.8,5.05]]);
  assert.deepEqual(JSON.parse(h.run('JSON.stringify(S.traceViewer.marks.map(m=>m.kept))')),[false,true]);
  assert.match(h.run('traceViewerAnnotationsHTML()'),/temporary/);
  assert.doesNotMatch(h.run('traceViewerAnnotationsHTML()'),/type="checkbox"/);
  h.run('traceViewerRenameAnnotation("mark",3,"Range A");traceViewerRemoveAnnotation("mark",4);S.traceViewer.selection="none"');
  assert.match(h.run('traceViewerInspectorHTML()'),/Range A/,'clearing selection must retain annotations');
  h.run('S.language="zh-Hans"');
  assert.match(h.run('traceViewerAnnotationsHTML()'),/重命名 Range A/);
  h.run('traceViewerRemoveAnnotation("mark",3);traceViewerRemoveAnnotation("flag",2)');
  assert.equal(h.run('traceViewerAnnotationsHTML()'),'');
  h.run('S.traceViewer.selection="range";S.traceViewer.range=[1,2];traceViewerAddMark();traceViewerAddMark(true);S.traceViewer.range=[3,4];traceViewerAddMark()');
  assert.deepEqual(JSON.parse(h.run('JSON.stringify(S.traceViewer.marks.map(m=>({id:m.id,range:m.range,kept:m.kept,label:m.label,color:m.color})))')),[
    {id:6,range:[1,2],kept:true,label:'Mark 2',color:1},
    {id:7,range:[3,4],kept:false,label:'Mark',color:1},
  ],'M replaces only the previous temporary mark and preserves kept marks');
  assert.match(h.run('traceViewerMarkBandsHTML()'),/trace.viewer.mark.6.*left:12.5%;width:12.5%/);
  assert.match(h.run('traceViewerMarkBandsHTML()'),/trace.viewer.mark.7.*left:37.5%;width:12.5%/);
  assert.doesNotMatch(h.run('traceViewerTracksHTML()'),/trace.viewer.mark.5/,'the replaced temporary band must disappear from the timeline too');
  h.run('traceViewerAddMark(true)');
  assert.equal(h.run('S.traceViewer.marks.filter(m=>m.kept).length'),2,'Shift+M accumulates kept marks');
  h.run('for(const id of [6,7,8])traceViewerRemoveAnnotation("mark",id)');
  h.run('S.traceViewer.state="failed";traceViewerAddFlag(2);traceViewerAddMark()');
  assert.equal(h.run('S.traceViewer.flags.length+S.traceViewer.marks.length'),0);
  assert.equal(h.run('S.jobs.length'),0,'annotation demos never create Runtime Jobs');
});

test('global inspector does not turn cancellation requests or unknown outcomes into success', () => {
  const history=harness('?lang=en');
  assert.equal(history.run('inspectorJobs()[0].operation'),'flash.full-restore@1');
  history.run('delete HIST[0].op');
  assert.equal(history.run('inspectorJobs()[0].operation'),null,
    'a display title or archive filename is not an operation identity');
  assert.equal(history.run('inspectorJobs()[3].operation'),'capture.diagnostics@1');
  assert.equal(history.run('inspectorJobs()[0].standardLog'),null,
    'canonical Flash has no standard log Artifact; its sensitive raw HiLog belongs in History');
  const retained=harness('?flashHistory=retained&lang=en');
  assert.equal(retained.run('inspectorJobs()[0].outcomeUnknown'),true);
  assert.equal(retained.run('inspectorCanCancel(inspectorJobs()[0])'),false);
  const h=harness('?jobState=running&lang=en');
  assert.equal(h.run('inspectorCanCancel(inspectorJobs()[0])'),true);
  h.run('requestInspectorCancellation("job-demo-global")');
  assert.equal(h.run('inspectorJobs()[0].state'),'running');
  const unknown=harness('?jobState=unknown&lang=en');
  assert.equal(unknown.run('inspectorCanCancel(inspectorJobs()[0])'),false);
  unknown.run('requestInspectorCancellation("job-demo-global")');
  assert.equal(unknown.run('S.inspectorCancellation'),null);
});

test('Native Debug plan and all five typed log fields match their published shape', () => {
  const h=harness('?page=debug&debugTab=logs&lang=en');
  assert.equal(h.run('S.lg.lines.length'),0);
  assert.match(h.run('pDebug()'),/No live stream is attached/);
  assert.match(h.run('pDebug()'),/512 MiB/);
  assert.doesNotMatch(h.run('pDebug()'),/quota 1GB|64MB host shards/);
  const operation=JSON.parse(read('Catalog/operations/deploy.native-library.app-owned.v1.json'));
  assert.deepEqual(JSON.parse(h.run('JSON.stringify(DEBUG_PLAN_STEPS)')),operation.steps.map(x=>[x.stepID,x.kind,x.effect]));
  assert.equal(h.run('debugLibValid("lib.so")'),false);
  assert.equal(h.run('debugLibValid("lib"+"a".repeat(124)+".so")'),false);
  h.run('debugPickLocal();debugSetBundle({value:"com.example.app"})');
  assert.equal(h.document.querySelector('[data-sync-id="debug.artifacts.preview"]').disabled,false);
  h.run('debugSetLib({value:"../libbad.so"})');
  assert.equal(h.document.querySelector('[data-sync-id="debug.artifacts.preview"]').disabled,true);
  h.run('S.lg.domain="0xD003900";S.lg.pid="1234";S.lg.keyword="render";S.lg.marker="sample";S.lg.tag="ArkUI"');
  assert.equal(h.run('logFilterTokens()'),'[domain:0xD003900, tag:ArkUI, pid:1234, keyword:render, marker:sample, level:warn]');
  for(const duration of ['0','601','1.5','1e2']){
    h.run(`S.lg.seconds=${JSON.stringify(duration)};startLogs()`);
    assert.equal(h.run('S.lg.on'),false);
  }
  h.run('S.lg.seconds="600";S.lg.keyword="render;id";startLogs()');
  assert.equal(h.run('S.lg.on'),false);
  assert.doesNotMatch(h.run('logFilterTokens()'),/render;id/);
  h.run('S.lg.keyword="render";startLogs()');
  assert.equal(h.run('S.lg.on'),true);
  assert.ok(h.run('S.lg.deadline')>0);
});

test('SSH design verification is explicit and input drift invalidates pending results', () => {
  const h=harness('?lang=en');
  h.run('let lastModal="";modal=markup=>{lastModal=markup;};openDebugServerEditor("")');
  assert.match(h.run('lastModal'),/id="dbgSave" disabled/);
  const fields={dbgName:'Demo',dbgHost:'build.example.internal',dbgPort:'22',dbgUser:'builder',dbgRoot:'/build/output',dbgAuth:'key'};
  for(const [key,value] of Object.entries(fields))h.document.getElementById(key).value=value;
  h.run('saveDebugServer("")');
  assert.equal(h.run('DEBUG_SERVERS.length'),1);
  h.run('debugTestConnection();debugInvalidateServerProbe()');
  h.flushTimers();
  assert.equal(h.run('S.debug.serverProbeRevision'),null);
  assert.equal(h.document.getElementById('dbgSave').disabled,true);
  h.run('debugTestConnection()');h.flushTimers();
  assert.equal(h.document.getElementById('dbgSave').disabled,false);
  assert.match(h.document.getElementById('dbgError').textContent,/no SSH connection occurred/);
  h.run('saveDebugServer("")');
  assert.equal(h.run('DEBUG_SERVERS.length'),2);
  assert.equal(h.run('S.jobs.length'),0);
});

test('English Debug tabs and trust/editor dialogs contain translated interface copy', () => {
  const h=harness('?lang=en');
  const visibleText=markup=>markup.replace(/<[^>]*>/g,'');
  for(const tab of ['artifacts','logs','apps','net','cmd']){
    h.run(`S.debugTab=${JSON.stringify(tab)}`);
    assert.doesNotMatch(visibleText(h.run('pDebug()')),/[\u3400-\u9fff]/,`untranslated ${tab} interface`);
  }
  h.run('let copyModal="";modal=markup=>{copyModal=markup;};openDebugServerEditor("")');
  assert.doesNotMatch(visibleText(h.run('copyModal')),/[\u3400-\u9fff]/);
  assert.doesNotMatch(visibleText(h.run('pAuth()')),/[\u3400-\u9fff]/);
});

const componentModule = {exports: {}};
vm.runInNewContext(transformSync(read('docs/design/arkdeck-ds/src/components/session.tsx'), {
  loader: 'tsx', format: 'cjs', jsx: 'automatic',
}).code, {module: componentModule, exports: componentModule.exports, require: createRequire(import.meta.url)});
const sessionComponents = componentModule.exports;
const renderComponent = (name, props) => renderToStaticMarkup(createElement(sessionComponents[name], props));

test('session components show missing and unaligned facts without manufacturing images', () => {
  const alignment = renderComponent('DiagnosticAlignmentDisclosure', {
    alignment: {kind:'cannotAlign', label:'Cannot align', detail:'No calibration was recorded'},
  });
  assert.match(alignment, /<summary>Cannot align/);
  assert.doesNotMatch(alignment, /±/);
  const thumbnail = renderComponent('DiagnosticScreenThumbnail', {label:'Mark 1',absenceReason:'No screenshot at this mark'});
  assert.match(thumbnail, /No screenshot at this mark/);
  assert.doesNotMatch(thumbnail, /<img/);
  assert.equal(renderComponent('PartialSessionBanner', {title:'Partial',missing:[]}), '');
  assert.match(renderComponent('PartialSessionBanner', {title:'Partial',missing:[{name:'trace.htrace',reason:'not published'}]}), /trace.htrace/);
});

test('frame control enforces 2–300 and disabled changes never reach the caller', () => {
  const calls=[];
  const make=disabled=>sessionComponents.DeviceFrameCountStepper({label:'Frames',value:40,disabled,onChange:n=>calls.push(n)}).props.children[1];
  for (const value of [NaN,1,2,2.5,300,301]) make(false).props.onChange({currentTarget:{valueAsNumber:value}});
  make(true).props.onChange({currentTarget:{valueAsNumber:10}});
  assert.deepEqual(calls,[2,300]);
});

test('cursor refuses invalid geometry and presets refuse unavailable options', () => {
  const calls=[];
  const props={label:'Cursor',minimum:0,maximum:10,value:2,valueText:'2 s',onChange:n=>calls.push(n)};
  const input=sessionComponents.DiagnosticTimeCursor(props).props.children[1];
  for (const value of [-1,9,11,NaN]) input.props.onChange({currentTarget:{valueAsNumber:value}});
  assert.deepEqual(calls,[0,9,10]);
  const invalid=sessionComponents.DiagnosticTimeCursor({...props,maximum:0}).props.children[1];
  assert.equal(invalid.props.disabled,true);
  const picker=sessionComponents.DiagnosticPresetPicker({label:'Preset',value:'bounded',onChange:n=>calls.push(n),options:[
    {value:'bounded',label:'Bounded'}, {value:'future',label:'Future',unavailable:true},
  ]}).props.children[1];
  picker.props.onChange({currentTarget:{value:'future'}});
  picker.props.onChange({currentTarget:{value:'bounded'}});
  assert.deepEqual(calls,[0,9,10,'bounded']);
});

test('HAP optional packages form one bounded selection without creating a Job', () => {
  const h = harness('?page=debug&debugTab=apps');
  h.run('debugAddHAP()');
  assert.equal(h.run('S.hap.additional.length'), 0, 'choose the entry first');
  h.run('debugPickHAP();S.hap.bundle="com.example.app";S.hap.ability="EntryAbility";debugAddHAP();debugAddHAP()');
  assert.deepEqual(JSON.parse(h.run('JSON.stringify(S.hap.additional)')), ['feature-1.hap','shared-2.hsp']);
  assert.equal(h.run('debugHAPReady()'), true);
  assert.match(h.run('pDebug()'), /debug.apps.additional.remove.1/);
  for (const language of ['zh-Hans','en']) {
    h.run(`S.language=${JSON.stringify(language)}`);
    for (const cleanup of ['uninstall','retain']) {
      for (const postRun of ['stopped','running']) {
        h.run(`S.hap.cleanup=${JSON.stringify(cleanup)};S.hap.postRun=${JSON.stringify(postRun)}`);
        const rendered = h.run('pDebug()');
        const warns = cleanup==='uninstall'&&postRun==='running';
        assert.equal(rendered.includes('debug.apps.runningCleanupHint'), warns);
        if (warns) assert.ok(rendered.includes(language==='en' ? 'Uninstall after run removes the app' : '运行后卸载会移除应用'));
        assert.equal(h.run('debugHAPReady()'), true, 'the hint does not change the published request policy');
      }
    }
  }
  h.run('debugRemoveHAP(0)');
  assert.deepEqual(JSON.parse(h.run('JSON.stringify(S.hap.additional)')), ['shared-2.hsp']);
  h.run('for(let i=0;i<20;i++)debugAddHAP()');
  assert.equal(h.run('S.hap.additional.length'), 16);
  assert.equal(h.run('debugHAPReady()'), true);
  h.run('S.hap.additional.push("overflow.hap")');
  assert.equal(h.run('debugHAPReady()'), false);
  h.run('S.hap.additional=["same.hap","same.hap"]');
  assert.equal(h.run('debugHAPReady()'), false);
  h.run('S.hap.additional=["wrong.zip"]');
  assert.equal(h.run('debugHAPReady()'), false);
  h.run('debugClearHAP()');
  assert.equal(h.run('S.hap.additional.length'), 0);
  assert.equal(h.run('debugHAPReady()'), false);
  assert.equal(h.run('S.jobs.length'), 0);
});

test('device detail reaches every candidate state the App renders, in both languages', () => {
  const notices = {
    ready: ['已授权且已接管——设备就绪。', 'Authorized and adopted — this device is ready.'],
    authorizedUnadopted: [
      '已授权。该设备尚未被接管为持久目标。',
      'Authorized. The device is not adopted as a durable target yet.',
    ],
    offline: [
      '设备报告离线。请检查 USB 连接后重新检测。',
      'The device reports Offline. Check the USB connection, then re-check.',
    ],
    needsRecheck: ['状态待重新确认', 'Status needs re-check'],
    unknownState: [
      '工具报告了未识别的状态：Recovery。按原文展示，不做解读。',
      'The tool reports an unrecognized state: Recovery. Shown as-is, not interpreted.',
    ],
  };
  // Every string above is copied from Localizable.xcstrings device.trust.* / device.state.*,
  // so a rename on either side breaks this instead of drifting silently.
  const app = JSON.parse(read('ArkDeckApp/Resources/Localizable.xcstrings')).strings;
  const appValue = (key, language) =>
    app[key].localizations[language].stringUnit.value;
  for (const [state, [zh, en]] of Object.entries(notices)) {
    for (const [language, expected] of [['zh-Hans', zh], ['en', en]]) {
      const h = harness(`?page=device&deviceDetail=${state}&lang=${language}`);
      const page = h.run('pDevice()');
      assert.ok(page.includes(`data-sync-id="device.trust.${state}"`), `${state} notice is missing`);
      assert.ok(page.includes(expected), `${state}/${language} must use the App's wording`);
      // Adoption is a CLI action; say so only where the App does.
      assert.equal(
        page.includes('data-sync-id="device.detail.adoptViaCLI"'),
        state === 'authorizedUnadopted');
      assert.ok(page.includes(appValue('device.fact.stateObservedAt', language)));
      assert.ok(page.includes(appValue('device.fact.firmware', language)));
      assert.ok(page.includes(appValue('device.detail.recheckNote', language)));
    }
  }
  const adopted = harness('?page=device&deviceDetail=authorizedUnadopted&lang=en');
  assert.ok(adopted.run('pDevice()').includes(appValue('device.detail.adoptViaCLI', 'en')));
});

test('retired draft paths leave no residue and window titles equal the App page names', () => {
  const source = html;
  for (const removed of ['addTargetModal', 'restartSrvModal', 'rebindOk', 'rebindAbort', 'historyPreset']) {
    assert.doesNotMatch(source, new RegExp(`function ${removed}\\b`), `${removed} is a retired path`);
  }
  // Spec §5.8: the published USB Flash path exposes no rebind confirm/abort control.
  assert.doesNotMatch(source, /pauseAt/);
  assert.doesNotMatch(source, /addTargetButton/);
  const titles = [...source.matchAll(/data-page-title="([^"]*)"/g)].map(match => match[1]);
  assert.ok(titles.includes('Debug'), 'Debug window title must equal the App navigation name');
  assert.ok(titles.includes('Flash'), 'Flash window title must equal the App navigation name');
  assert.ok(!titles.some(title => /工作台|Workbench|刷机/.test(title)));
});

test('shell chrome and demo job timelines are bilingual', () => {
  const shellText = {
    'zh-Hans': ['工作流', 'Job 检查器', '没有运行中的 Job'],
    en: ['Workflows', 'Job inspector', 'No running jobs'],
  };
  for (const [language, expected] of Object.entries(shellText)) {
    const h = harness(`?page=overview&lang=${language}`);
    h.run(`S.language=${JSON.stringify(language)};renderShellText()`);
    assert.equal(h.document.getElementById('workflowsSectionLabel').textContent, expected[0]);
    assert.equal(h.document.getElementById('jobsLabel').textContent, expected[1]);
    assert.equal(h.document.getElementById('drawerSt').textContent, expected[2]);
  }
  // The Flash and Diagnostics demo jobs write their own timeline entries, which
  // the Job inspector and History both render. They used to be Chinese only.
  const en = harness('?page=flash&lang=en');
  en.run('chooseFlashImage(); runFlash()');
  for (let tick = 0; tick < 24; tick += 1) en.flushTimers();
  const log = en.run('JSON.stringify(S.jobs[0].log)') + en.run('JSON.stringify(S.jobs[0].phases)');
  assert.doesNotMatch(log, /[一-鿿]/, 'the English Flash timeline must not fall back to Chinese');
  const zh = harness('?page=flash&lang=zh-Hans');
  zh.run('chooseFlashImage(); runFlash()');
  assert.match(zh.run('JSON.stringify(S.jobs[0].phases)'), /[一-鿿]/);
});

test('Viewer accessibility names and the node footer follow the App locale', () => {
  const app = JSON.parse(read('ArkDeckApp/Resources/UIDumpLocalizable.xcstrings')).strings;
  for (const language of ['zh-Hans', 'en']) {
    const h = harness(`?page=dump&viewerState=captured&lang=${language}`);
    // Match navigation only renders while a query is active, so set one.
    h.run("S.viewer.query='Toggle'");
    const page = h.run('pViewer()');
    for (const key of ['viewer.tree.label', 'viewer.separator.label', 'viewer.search.previous', 'viewer.search.next']) {
      assert.ok(
        page.includes(app[key].localizations[language].stringUnit.value),
        `${key} must use the App's ${language} wording`);
    }
    assert.match(page, language === 'en' ? /\d+ nodes ·/ : /\d+ 个节点 ·/);
    // Node text is device content and stays untranslated; the chrome around it does not.
    const chrome = page.replace(/aria-label="[^"]*"/g, '').replace(/<span class="vs-[^"]*"[^>]*>[^<]*</g, '<');
    if (language === 'en') assert.doesNotMatch(chrome, /选择组件|完整 UI 树|个节点/);
  }
});

test('Overview reaches every device, build-source and record state the App renders', () => {
  const app = JSON.parse(read('ArkDeckApp/Resources/Localizable.xcstrings')).strings;
  const value = (key, language) => app[key].localizations[language].stringUnit.value;
  for (const language of ['zh-Hans', 'en']) {
    // Device scope: one bound target, a picker for several, and an honest empty.
    const none = harness(`?page=overview&lang=${language}&overviewDevice=none`);
    assert.ok(none.run('pOverview()').includes(value('overview.record.device.none', language)));
    assert.ok(none.run('pOverview()').includes(value('overview.record.device.noneDetail', language)));
    const multi = harness(`?page=overview&lang=${language}&overviewDevice=multi`);
    assert.match(multi.run('pOverview()'), /data-sync-id="overview.record.device.picker"/);
    assert.ok(multi.run('pOverview()').includes(value('overview.record.device.choose', language)));

    // Build source: five states, each with the App's own wording.
    for (const [state, key] of [['loading', 'loading'], ['unbound', 'unbound'], ['stale', 'stale'], ['unavailable', 'unavailable']]) {
      const h = harness(`?page=overview&lang=${language}&overviewServer=${state}`);
      assert.ok(
        h.run('pOverview()').includes(value(`overview.record.remoteServer.${key}`, language)),
        `${state} build source must use the App's wording`);
    }

    // Records: loading, unreadable and empty are distinct from "no attention".
    assert.match(
      harness(`?page=overview&lang=${language}&overviewRecords=loading`).run('pOverview()'),
      /data-sync-id="overview.record.recent.loading"/);
    const unreadable = harness(`?page=overview&lang=${language}&overviewRecords=unavailable`);
    assert.ok(unreadable.run('pOverview()').includes(value('overview.record.recent.unavailable.title', language)));
    const empty = harness(`?page=overview&lang=${language}&overviewRecords=empty`);
    assert.ok(empty.run('pOverview()').includes(value('overview.record.recent.empty', language)));
    assert.ok(empty.run('pOverview()').includes(value('overview.record.next.empty.title', language)));

    // An unresolved run is pinned first and is never offered as repeatable.
    const attention = harness(`?page=overview&lang=${language}&flashHistory=unknown`);
    const page = attention.run('pOverview()');
    assert.ok(page.includes(value('overview.record.next.attention', language)));
    assert.ok(page.includes(value('overview.record.next.unknownDetail', language)));
    assert.ok(page.includes(value('overview.record.refusal.neverReplayed', language)));
    assert.equal(attention.run('overviewThreads()[0].needsAttention'), true);
    assert.doesNotMatch(page, /overview\.record\.run\.job-demo-flash-unknown\.again/);

    // A line keeps its bounded disclosure instead of flattening into one list.
    const grouped = harness(`?page=overview&lang=${language}`);
    assert.match(grouped.run('pOverview()'), /data-sync-id="overview.record.thread.thread:t-design-viewer.more"/);
    assert.equal(grouped.run("overviewThreads().find(t=>t.id==='thread:t-design-viewer').runs.length"), 2);

    // Evidence that has not been read yet is neither offered nor refused.
    const pending = harness(`?page=overview&lang=${language}&overviewEvidence=pending`);
    assert.equal(pending.run("overviewDisposition(HIST.find(h=>h.id==='S-0826-04')).kind"), 'detailNotLoaded');
    assert.match(pending.run('pOverview()'), /data-sync-id="overview.record.run.S-0826-04.again"[^>]*disabled|disabled[^>]*data-sync-id="overview.record.run.S-0826-04.again"/);
  }
  // ⌘R belongs to Overview only, matching the App's page-scoped shortcut.
  const shortcut = harness('?page=overview&lang=en');
  assert.match(html, /S\.nav==="overview"&&\(e\.metaKey\|\|e\.ctrlKey\)&&!e\.shiftKey&&e\.key\.toLowerCase\(\)==="r"/);
  assert.match(shortcut.run('pOverview()'), /data-sync-id="hdc.devices.refresh"/);
});

test('Flash reaches checking, missing device, image import and a failed result', () => {
  const app = JSON.parse(read('ArkDeckApp/Resources/FlashLocalizable.xcstrings')).strings;
  const value = (key, language) => app[key].localizations[language].stringUnit.value;
  const enabledRun = markup => /<button(?![^>]*disabled)[^>]*onclick="runFlash\(\)"/.test(markup);
  for (const language of ['zh-Hans', 'en']) {
    const expectations = [
      ['checking', 'flash.workspace.readiness.checking', 'flash.availability.checking'],
      ['noDevice', 'flash.workspace.readiness.noDevice', 'flash.workspace.readiness.noDeviceDetail'],
      ['importing', 'flash.workspace.readiness.checking', 'flash.workspace.image.validating'],
      ['invalid', 'flash.workspace.readiness.blocked', 'flash.error.invalid'],
    ];
    for (const [scenario, titleKey, detailKey] of expectations) {
      const h = harness(`?page=flash&lang=${language}&flashState=${scenario}`);
      const page = h.run('pFlash()');
      assert.ok(page.includes(value(titleKey, language)), `${scenario} readiness title`);
      assert.ok(page.includes(value(detailKey, language)), `${scenario} readiness detail`);
      // None of these may dispatch, even after an image is chosen.
      h.run('chooseFlashImage(); runFlash()');
      assert.equal(h.run('S.jobs.length'), 0, `${scenario} must not create a Job`);
      assert.equal(h.run('S.flashJob'), null);
      assert.ok(!enabledRun(h.run('pFlash()')), `${scenario} must not offer an enabled flash button`);
    }
    // A non-successful terminal result never reads as success.
    const failed = harness(`?page=flash&lang=${language}&flashState=failed`);
    const result = failed.run('pFlash()');
    assert.ok(result.includes(value('flash.workspace.result.stopped', language)));
    assert.ok(result.includes(value('flash.runtime.result.failed', language)));
    assert.ok(result.includes(value('flash.workspace.result.unverified', language)));
    // The refusal sentence quotes the words "flash succeeded", so check the
    // heading rather than the page text: no success heading may be rendered.
    assert.ok(result.includes(`<h2>${value('flash.workspace.result.stopped', language)}</h2>`));
    assert.ok(!result.includes(`<h2>${value('flash.workspace.result.success', language)}</h2>`));
    // Choosing an image on an available workspace still starts the demo run.
    const ready = harness(`?page=flash&lang=${language}`);
    ready.run('chooseFlashImage()');
    assert.ok(enabledRun(ready.run('pFlash()')));
    ready.run('runFlash()');
    assert.equal(ready.run('S.flashView'), 'running');
  }
});

test('Trace separates availability, capture outcome and the viewable artifact', () => {
  const app = JSON.parse(read('ArkDeckApp/Resources/TraceLocalizable.xcstrings')).strings;
  const value = (key, language) => app[key].localizations[language].stringUnit.value;
  for (const language of ['zh-Hans', 'en']) {
    const checking = harness(`?page=trace&lang=${language}&traceState=checking`);
    assert.ok(checking.run('pTrace()').includes(value('trace.availability.checking', language)));
    checking.run('startTrace()');
    assert.equal(checking.run('S.trace.running'), false, 'checking must not start a capture');

    const noTarget = harness(`?page=trace&lang=${language}&traceState=noTarget`);
    assert.ok(noTarget.run('pTrace()').includes(value('trace.target.empty', language)));
    assert.ok(noTarget.run('pTrace()').includes(value('trace.blocker.target', language)));
    noTarget.run('startTrace()');
    assert.equal(noTarget.run('S.trace.running'), false);

    // A finished Job and a readable trace are two separate facts.
    for (const [token, key] of [['succeeded', 'trace.capture.finished'],
      ['outcomeUnknown', 'trace.capture.outcomeUnknown'], ['notCompleted', 'trace.capture.notCompleted']]) {
      const h = harness(`?page=trace&lang=${language}&traceState=ready&traceCapture=${token}`);
      assert.ok(h.run('pTrace()').includes(value(key, language)), `${token} capture outcome`);
    }
    for (const [token, key] of [['preparing', 'trace.viewer.preparing'], ['latest', 'trace.viewer.latest'],
      ['failure', 'trace.viewer.artifactInvalid']]) {
      const h = harness(`?page=trace&lang=${language}&traceState=ready&traceArtifact=${token}`);
      assert.ok(h.run('pTrace()').includes(value(key, language)), `${token} viewer artifact`);
    }
    const retry = harness(`?page=trace&lang=${language}&traceState=ready&traceArtifact=failure`);
    assert.ok(retry.run('pTrace()').includes(value('trace.viewer.tryAgain', language)));

    // An active capture replaces the start button with the Job and a cancel.
    const ready = harness(`?page=trace&lang=${language}&traceState=ready`);
    ready.run('startTrace()');
    assert.match(ready.run('pTrace()'), /data-sync-id="trace.cancel"/);
    assert.ok(ready.run('pTrace()').includes(value('trace.action.refresh', language)));
  }
});

test('Settings panes expose the shared loading, error and success rows', () => {
  const app = JSON.parse(read('ArkDeckApp/Resources/SettingsLocalizable.xcstrings')).strings;
  const value = (key, language) => app[key].localizations[language].stringUnit.value;
  const tabs = ['general', 'toolchains', 'servers', 'storage', 'trace', 'updates', 'diagnostics'];
  for (const language of ['zh-Hans', 'en']) {
    for (const [state, key, id] of [
      ['loading', 'settings.common.loading', 'settings.common.loading'],
      ['error', 'settings.error.refresh', 'settings.error.refresh'],
      ['success', 'settings.diagnostics.exported', 'settings.success'],
    ]) {
      for (const tab of tabs) {
        const h = harness(`?page=settings&lang=${language}&settingsState=${state}`);
        h.run(`S.settingsTab=${JSON.stringify(tab)}`);
        const pane = h.run('pSettings()');
        assert.ok(pane.includes(`data-sync-id="${id}"`), `${tab}/${state} row`);
        assert.ok(pane.includes(value(key, language)), `${tab}/${state} wording`);
      }
    }
    // Toolchain switching says something different while Jobs are running.
    const idle = harness(`?page=settings&lang=${language}`);
    idle.run("S.settingsTab='toolchains'");
    assert.ok(idle.run('pSettings()').includes(value('settings.toolchains.futureJobs', language)));
    const active = harness(`?page=settings&lang=${language}&settingsJobs=active`);
    active.run("S.settingsTab='toolchains'");
    assert.ok(active.run('pSettings()').includes(value('settings.toolchains.futureJobsActive', language)));

    // Storage keeps an invalid policy, unclassified bytes and an unreadable
    // measurement apart instead of collapsing them into one number.
    for (const [token, key] of [['invalid', 'settings.storage.validationError'],
      ['unknownPressure', 'settings.storage.unknownPressure'],
      ['measurementUnavailable', 'settings.storage.measurementUnavailable']]) {
      const h = harness(`?page=settings&lang=${language}&settingsStorage=${token}`);
      h.run("S.settingsTab='storage'");
      assert.ok(h.run('pSettings()').includes(value(key, language)), `${token} storage state`);
    }
    const unavailable = harness(`?page=settings&lang=${language}&settingsStorage=measurementUnavailable`);
    unavailable.run("S.settingsTab='storage'");
    assert.doesNotMatch(unavailable.run('pSettings()'), /data-sync-id="settings.storage.usage"/,
      'an unavailable measurement must not show a usage number');
  }
});

test('the Job inspector separates an unreachable Runtime from an empty archive', () => {
  const app = JSON.parse(read('ArkDeckApp/Resources/JobsLocalizable.xcstrings')).strings;
  const value = (key, language) => app[key].localizations[language].stringUnit.value;
  for (const language of ['zh-Hans', 'en']) {
    const loading = harness(`?page=overview&lang=${language}&inspectorState=loading`);
    assert.match(loading.run('inspectorBodyHTML(inspectorJobs())'), /data-sync-id="jobInspector.loading"/);
    assert.equal(
      loading.run('inspectorCompactStatus(inspectorJobs(),[])'),
      value('jobInspector.refreshing', language));

    const unavailable = harness(`?page=overview&lang=${language}&inspectorState=unavailable`);
    const unavailableBody = unavailable.run('inspectorBodyHTML(inspectorJobs())');
    assert.ok(unavailableBody.includes(value('jobInspector.unavailable.title', language)));
    assert.ok(unavailableBody.includes(value('jobInspector.unavailable.guidance', language)));
    assert.equal(
      unavailable.run('inspectorCompactStatus(inspectorJobs(),[])'),
      value('jobInspector.compact.unavailable', language));

    const empty = harness(`?page=overview&lang=${language}&inspectorState=empty`);
    const emptyBody = empty.run('inspectorBodyHTML(inspectorJobs())');
    assert.ok(emptyBody.includes(value('jobInspector.empty.title', language)));
    assert.ok(emptyBody.includes(value('jobInspector.empty.description', language)));
    assert.equal(
      empty.run('inspectorCompactStatus(inspectorJobs(),[])'),
      value('jobInspector.compact.empty', language));

    // Residue and a critical write are facts about a running Job, not states.
    const residue = harness(`?page=overview&lang=${language}&jobState=running&jobFacts=residue`);
    assert.match(residue.run('inspectorBodyHTML(inspectorJobs())'), /data-sync-id="jobInspector.residue"/);
    const critical = harness(`?page=overview&lang=${language}&jobState=running&jobFacts=criticalWrite`);
    assert.ok(critical.run('inspectorBodyHTML(inspectorJobs())').includes(value('jobInspector.criticalWrite', language)));

    // An established current epoch replaces the state label and the warning,
    // while the originally recorded state stays visible.
    for (const [fact, key] of [['supersededByRecovery', 'jobInspector.result.supersededByRecovery'],
      ['targetAliasResolved', 'jobInspector.result.targetAliasResolved']]) {
      const h = harness(`?page=overview&lang=${language}&jobState=waitingForRecovery&jobFacts=${fact}`);
      const body = h.run('inspectorBodyHTML(inspectorJobs())');
      assert.ok(body.includes(value(key, language)), `${fact} relation`);
      assert.ok(body.includes(value('jobInspector.state.currentEpochEstablished', language)));
      assert.ok(body.includes(value('jobInspector.fact.recordedState', language)));
      assert.doesNotMatch(body, /data-sync-id="jobInspector.attention"/);
      assert.doesNotMatch(body, /data-sync-id="jobInspector.cancel"/);
    }

    // An unknown outcome keeps its warning and is never cancellable.
    const unknown = harness(`?page=overview&lang=${language}&jobState=unknown`);
    const unknownBody = unknown.run('inspectorBodyHTML(inspectorJobs())');
    assert.ok(unknownBody.includes(value('jobInspector.result.outcomeUnknown', language)));
    assert.doesNotMatch(unknownBody, /data-sync-id="jobInspector.cancel"/);

    const human = harness(`?page=overview&lang=${language}&jobState=waitingForDevice&jobFacts=waitingForHuman`);
    assert.ok(human.run('inspectorBodyHTML(inspectorJobs())').includes(value('jobInspector.result.waitingForHuman', language)));

    // The collapsed bar counts what is actually running.
    const running = harness(`?page=overview&lang=${language}&jobState=running`);
    assert.match(
      running.run('inspectorCompactStatus(inspectorJobs(),inspectorJobs().filter(inspectorCanCancel))'),
      language === 'en' ? /1 active/ : /1 个进行中/);
  }
});

test('Viewer refuses to map a screenshot it cannot place, and says when nothing was measured', () => {
  const app = JSON.parse(read('ArkDeckApp/Resources/UIDumpLocalizable.xcstrings')).strings;
  const value = (key, language) => app[key].localizations[language].stringUnit.value;
  for (const language of ['zh-Hans', 'en']) {
    // Empty has three different explanations; a failure is shown, not hidden.
    const explain = harness(`?page=dump&lang=${language}`);
    assert.ok(explain.run('pViewer()').includes(value('viewer.empty.explain', language)));
    const select = harness(`?page=dump&lang=${language}&viewerEmpty=selectTarget`);
    assert.ok(select.run('pViewer()').includes(value('viewer.empty.selectTarget', language)));
    const blocked = harness(`?page=dump&lang=${language}&viewerEmpty=targetBlocked`);
    assert.match(blocked.run('pViewer()'), /TGT-1a62a0dbedd6/);
    const failed = harness(`?page=dump&lang=${language}&viewerState=failed`);
    assert.match(failed.run('pViewer()'), /data-sync-id="viewer.captureFailure"/);

    // Opening a historical capture is its own state, not an empty workspace.
    const loading = harness(`?page=dump&lang=${language}&viewerState=loading`);
    assert.match(loading.run('pViewer()'), /data-sync-id="viewer.history.loading"/);
    assert.doesNotMatch(loading.run('pViewer()'), /data-sync-id="viewer.empty"/);

    // Without a provable coordinate space there is no clickable map at all.
    const geometry = harness(`?page=dump&lang=${language}&viewerState=geometryUnavailable`);
    const geometryPage = geometry.run('pViewer()');
    assert.ok(geometryPage.includes(value('viewer.pane.coordinatesUnverified', language)));
    assert.ok(geometryPage.includes(value('viewer.screenshot.unverifiedDetail', language)));
    assert.doesNotMatch(geometryPage, /viewer-hit/, 'unverified coordinates must not offer hit regions');
    assert.match(geometryPage, /data-sync-id="viewer.footer"/, 'the tree and raw dump stay readable');

    const missingImage = harness(`?page=dump&lang=${language}&viewerState=screenshotUnavailable`);
    assert.ok(missingImage.run('pViewer()').includes(value('viewer.screenshot.unavailable', language)));

    // Unmeasured metrics say so instead of showing numbers from another run.
    const unmeasured = harness(`?page=dump&lang=${language}&viewerState=noMetrics`);
    const footer = unmeasured.run('pViewer()').match(/data-sync-id="viewer\.footer"[^>]*>([^<]*)</)[1];
    assert.ok(footer.includes(value('viewer.footer.notMeasured', language)));
    assert.doesNotMatch(footer, /submit|Σ/);

    // A search that matches nothing says so and keeps the selection.
    const search = harness(`?page=dump&lang=${language}&viewerState=captured`);
    const before = search.run('S.viewer.selected');
    search.run("S.viewer.query='zzz-no-such-node'");
    assert.ok(search.run('pViewer()').includes(value('viewer.tree.noMatches', language)));
    assert.equal(search.run('S.viewer.selected'), before);
  }
});

test('Overview environment keeps the App five groups and its capability matrix states', () => {
  const app = JSON.parse(read('ArkDeckApp/Resources/Localizable.xcstrings')).strings;
  const value = (key, language) => app[key].localizations[language].stringUnit.value;
  for (const language of ['zh-Hans', 'en']) {
    const h = harness(`?page=overview&lang=${language}`);
    const page = h.run('pOverview()');
    for (const key of ['overview.section.serverToolchain', 'overview.section.capabilities',
      'overview.section.deviceChannel', 'overview.section.needsAttention', 'overview.section.advanced']) {
      assert.match(page, new RegExp(`data-sync-id="${key}"`), `${key} group`);
      assert.ok(page.includes(value(key, language)), `${key} wording`);
    }
    // Server & Toolchain keeps the named fields, not a single summary line.
    for (const key of ['overview.field.serverHealth', 'overview.field.source', 'overview.field.path',
      'overview.field.hash', 'overview.field.platformTrust', 'overview.field.clientVersion',
      'overview.field.serverVersion', 'overview.field.daemonVersion', 'overview.field.endpoint']) {
      assert.ok(page.includes(value(key, language)), `${key} field`);
    }
    // The matrix is three columns with a named state per capability.
    for (const key of ['overview.capabilities.column.capability', 'overview.capabilities.column.state',
      'overview.capabilities.column.evidence']) {
      assert.ok(page.includes(value(key, language)), `${key} column`);
    }
    for (const state of ['available', 'limited', 'unknown']) {
      assert.ok(page.includes(value(`overview.capabilities.state.${state}`, language)), `${state} state`);
    }
    // Probing and an unreadable probe are distinct from an empty matrix.
    const loading = harness(`?page=overview&lang=${language}&overviewCapabilities=loading`);
    assert.ok(loading.run('pOverview()').includes(value('overview.capabilities.loading', language)));
    const failure = harness(`?page=overview&lang=${language}&overviewCapabilities=failure`);
    assert.match(failure.run('pOverview()'), /data-sync-id="overview.capabilities.failure"/);
    assert.doesNotMatch(failure.run('pOverview()'), /data-sync-id="overview.capabilities.hidumper.state"/);

    // Needs Attention says nothing is outstanding rather than staying blank.
    assert.ok(page.includes(value('overview.attention.clear', language)));
    const items = harness(`?page=overview&lang=${language}&overviewAttention=items`);
    const itemsPage = items.run('pOverview()');
    assert.ok(itemsPage.includes(value('overview.attention.trust', language)));
    assert.ok(itemsPage.includes(value('overview.attention.nextStep.refresh', language)));
    assert.ok(itemsPage.includes(value('overview.attention.channel', language)));
    assert.ok(!itemsPage.includes(value('overview.attention.clear', language)));
    // Recovery stays a preview-first flow with no direct dispatch button.
    assert.ok(page.includes(value('overview.recovery.previewImpact', language)));
    assert.doesNotMatch(page, /data-sync-id="hdc.lifecycle.dispatch"/);
  }
});

test('the Diagnostics concept pages read in both languages', () => {
  // The captured device's own screen is device output and stays untranslated;
  // everything this draft authored is a language pair.
  const deviceScreen = /设置|搜索设置项|小艺|华为账号|已连接|蓝牙|已开启|移动网络/;
  const chinese = markup => [...new Set(
    [...markup.matchAll(/[^<>"]*[一-鿿][^<>"]*/g)].map(match => match[0].trim()))]
    .filter(text => !deviceScreen.test(text) && !text.includes("lc("));
  for (const view of ['session', 'capture', 'recording', 'finalizing']) {
    const h = harness('?page=diagnostics&concept=diagnostics&lang=en');
    if (view !== 'session') h.run(`S.diagnostics.view=${JSON.stringify(view)}`);
    if (view === 'recording' || view === 'finalizing') {
      h.run('S.diagnostics.markers=[{time:13.2,label:{zh:"问题出现",en:"Problem appeared"},kind:"manual",shotState:"saved",shotAfterMs:512}]');
    }
    assert.deepEqual(chinese(h.run('pDiagnostics()')), [], `${view} must not fall back to Chinese`);
  }
  for (const session of [0, 1, 2]) {
    const h = harness('?page=diagnostics&concept=diagnostics&lang=en');
    h.run(`chooseDiagSession(${session})`);
    assert.deepEqual(chinese(h.run('pDiagnostics()')), [], `session ${session} must not fall back to Chinese`);
    // The alignment and raw-log sheets are part of the same page.
    h.run('modal=html=>{globalThis.__modal=html;}');
    h.run('showDiagAlignment()');
    assert.deepEqual(chinese(h.run('__modal')), [], `session ${session} alignment sheet`);
  }
  const raw = harness('?page=diagnostics&concept=diagnostics&lang=en');
  raw.run('modal=html=>{globalThis.__modal=html;}');
  raw.run('showDiagRawLogs()');
  assert.deepEqual(chinese(raw.run('__modal')), []);
  assert.equal(harness('?page=diagnostics&concept=diagnostics&lang=en').run('diagMarkerStatusText()'), 'No marker yet');
  // Both languages still render, and the Chinese one is still Chinese.
  const zh = harness('?page=diagnostics&concept=diagnostics&lang=zh-Hans');
  assert.match(zh.run('pDiagnostics()'), /当前画面/);
});

test('the trust page shows the same Runtime facts column and every wait answer', () => {
  const app = JSON.parse(read('ArkDeckApp/Resources/Localizable.xcstrings')).strings;
  const value = (key, language) => app[key].localizations[language].stringUnit.value;
  for (const language of ['zh-Hans', 'en']) {
    const idle = harness(`?page=auth&lang=${language}`);
    const page = idle.run('pAuth()');
    // Spec §5.2: the trust guidance lives inside the same device detail, so the
    // Runtime facts column is present here too.
    assert.match(page, /class="device-layout"/);
    assert.ok(page.includes(value('device.detail.statusTitle', language)));
    assert.ok(page.includes(value('device.detail.factsTitle', language)));
    assert.ok(page.includes(value('device.trust.waiting', language)));
    assert.ok(page.includes(value('device.trust.stepsTitle', language)));
    for (const step of ['device.trust.step1', 'device.trust.step2', 'device.trust.step3']) {
      assert.ok(page.includes(value(step, language)), `${step} must use the App's wording`);
    }
    // An unauthorized candidate has no target, binding, model or firmware, so
    // no such row is drawn rather than filled with a demo value.
    assert.ok(page.includes(value('device.fact.connectKey', language)));
    assert.ok(page.includes(value('device.fact.state', language)));
    assert.ok(!page.includes(value('device.fact.target', language)));
    assert.ok(!page.includes(value('device.fact.bindingRevision', language)));
    assert.ok(!page.includes(value('device.fact.firmware', language)));

    // Four wait answers; "cannot check" is not "denied".
    const polling = harness(`?page=auth&lang=${language}&authState=polling`);
    assert.ok(polling.run('pAuth()').includes(value('device.wait.polling', language)));
    assert.match(polling.run('pAuth()'), /id="authcd">\d\d:\d\d</, 'the bounded wait must render its countdown');
    assert.equal(polling.run('fmtLeft(180)'), '03:00');
    const timedOut = harness(`?page=auth&lang=${language}&authState=timedOut`);
    assert.ok(timedOut.run('pAuth()').includes(value('device.wait.timedOut', language)));
    assert.ok(timedOut.run('pAuth()').includes(value('device.wait.openOverviewRecovery', language)));
    assert.ok(timedOut.run('pAuth()').includes(value('device.action.retryWait', language)));
    const unavailable = harness(`?page=auth&lang=${language}&authState=unavailable`);
    assert.match(unavailable.run('pAuth()'), /data-sync-id="device.wait.unavailable"/);
    assert.ok(unavailable.run('pAuth()').includes(value('device.wait.unavailable', language).replace('%@', '').trim()));

    // Trusting is not adopting: the App says who performs adoption instead.
    const trusted = harness(`?page=auth&lang=${language}&authState=ready`);
    const trustedPage = trusted.run('pAuth()');
    assert.ok(trustedPage.includes(value('device.trust.authorizedUnadopted', language)));
    assert.ok(trustedPage.includes(value('device.detail.adoptViaCLI', language)));
    assert.doesNotMatch(trustedPage, /data-sync-id="device.trust.steps"/);
  }
});

test('the shared workspace chrome has no App-side copies', () => {
  // F52 item 4: five workspaces had written their own notice, page, header and
  // key/value list beside the shared ones. The row now carries what those
  // copies added, so the next caller extends it instead of writing a sixth.
  const chrome = read('ArkDeckApp/DesignSystem/WorkspaceChrome.swift');
  for (const option of ['usesTabularDigits', 'usesMonospacedName', 'isSelectable', 'elidedValue']) {
    assert.match(chrome, new RegExp(`var ${option}`), `WorkspaceFactRow must carry ${option}`);
  }

  const device = read('ArkDeckApp/Features/Devices/DeviceWorkspace.swift');
  assert.doesNotMatch(device, /func deviceNotice\(/, 'device detail must not define a second notice');
  assert.equal(
    (device.match(/WorkspaceNotice\(/g) ?? []).length, 8,
    'every trust and wait state reads through the shared notice');
  for (const identifier of [
    'device.trust.needsRecheck', 'device.trust.waiting', 'device.trust.offline',
    'device.trust.ready', 'device.trust.unknownState',
    'device.wait.polling', 'device.wait.timedOut', 'device.wait.unavailable',
  ]) {
    assert.ok(
      device.includes(`identifier: "${identifier}"`),
      `${identifier} must stay addressable after the convergence`);
  }

  const settings = read('ArkDeckApp/Features/Settings/SettingsRootView.swift');
  for (const copy of [
    'SettingsPaneContainer', 'SettingsPaneHeader', 'SettingsValueGrid', 'SettingsValueRow',
    'SettingsErrorBanner', 'SettingsSuccessBanner',
  ]) {
    assert.doesNotMatch(
      settings, new RegExp(`struct ${copy}\\b`), `${copy} duplicates the shared chrome`);
  }
  for (const idiom of ['WorkspacePage {', 'WorkspaceHeaderBar(', 'WorkspaceFactGrid {', 'WorkspaceNotice(']) {
    assert.ok(settings.includes(idiom), `Settings must render through ${idiom}`);
  }

  // A component two features already render is shared vocabulary, not the
  // private detail of whichever workspace happened to need it first.
  assert.match(
    read('ArkDeckApp/DesignSystem/RuntimeExecutionModeBadge.swift'),
    /struct RuntimeExecutionModeBadge: View/);
  assert.doesNotMatch(
    read('ArkDeckApp/Features/History/RuntimeHistoryView.swift'),
    /struct RuntimeExecutionModeBadge/);
  assert.ok(
    read('ArkDeckApp/Features/Jobs/GlobalJobInspectorView.swift').includes('RuntimeExecutionModeBadge('),
    'the job inspector still renders the shared badge');
});

test('every key/value list in the App is the shared fact grid', () => {
  // F52 item 4, second half: 19 hand-written Grid( sites, of which 15 were
  // key/value lists. What is left must be a genuine table or form, and must
  // say so, so the next reader does not "converge" a header row into a fact
  // list.
  const rawGrid = /(?<!Workspace(?:Fact)?)\bGrid\(/;
  const exempt = new Map([
    ['ArkDeckApp/Features/Settings/SettingsRootView.swift', 'three columns of editable'],
    ['ArkDeckApp/Features/Flash/FlashWorkspaceView.swift', 'three-column table with its own header row'],
    ['ArkDeckApp/Features/HDC/HDCStatusView.swift', 'three-column matrix with a header row'],
  ]);
  const offenders = [];
  for (const path of coverage.appViewFiles) {
    if (path.startsWith('ArkDeckApp/DesignSystem/')) continue;
    const source = read(path);
    const lines = source.split('\n');
    lines.forEach((line, index) => {
      if (!rawGrid.test(line)) return;
      // A hand-written Grid is allowed only where the two lines above it say
      // why it is not a key/value list.
      const preamble = lines.slice(Math.max(0, index - 4), index).join(' ');
      if (/not a WorkspaceFactGrid/i.test(preamble)) return;
      offenders.push(`${path}:${index + 1}`);
    });
  }
  assert.deepEqual(offenders, [], 'these key/value lists must use WorkspaceFactGrid');
  for (const [path, reason] of exempt) {
    assert.ok(read(path).includes(reason), `${path} must keep its recorded exception`);
  }

  // The rows the workspaces used to hand-roll now come from the shared row.
  for (const [path, symbol] of [
    ['ArkDeckApp/Features/History/RuntimeHistoryView.swift', 'private func row('],
    ['ArkDeckApp/Features/Jobs/GlobalJobInspectorView.swift', 'private func factRow('],
    ['ArkDeckApp/Features/Flash/FlashRuntimeActivityView.swift', 'private func factRow('],
    ['ArkDeckApp/Features/Flash/FlashWorkspaceView.swift', 'private func summaryRow('],
    ['ArkDeckApp/Features/HDC/HDCStatusView.swift', 'private func field('],
    ['ArkDeckApp/Features/Debug/DebugWorkspaceView.swift', 'private func planFact('],
    ['ArkDeckApp/Features/Diagnostics/DiagnosticsWorkspaceView.swift', 'private func hilogCount('],
    ['ArkDeckApp/Features/Devices/DeviceWorkspace.swift', 'private func deviceFact('],
  ]) {
    const source = read(path);
    const start = source.indexOf(symbol);
    assert.notEqual(start, -1, `${symbol} was renamed in ${path}`);
    const body = source.slice(start, start + 700);
    assert.match(body, /-> WorkspaceFactRow/, `${symbol} in ${path} must return the shared row`);
  }

  // HDC's diagnostics fields stay unselectable on purpose: selection changes
  // the accessibility representation UI automation reads.
  const hdc = read('ArkDeckApp/Features/HDC/HDCStatusView.swift');
  assert.match(hdc, /isSelectable` and `elidedValue` at their defaults/);
  assert.doesNotMatch(hdc, /struct FieldTextStyle/, 'the local font modifier is now the row option');
});

test('App type sizes that have a shared role use it', () => {
  // F52 item 4, final part. Only the four writings with an exact WorkspaceFont
  // equivalent were converged; the rest change rendered size or weight and are
  // product decisions, so this guards the converged four and pins what is
  // deliberately left behind.
  const exact = [
    [/\.font\(\.system\(size: 13, weight: \.semibold\)\)/, 'WorkspaceFont.sectionTitle'],
    [/\.font\(\.system\(size: 12, design: \.monospaced\)\)/, 'WorkspaceFont.monospacedValue'],
    [/\.font\(\.system\(size: 11, design: \.monospaced\)\)/, 'WorkspaceFont.monospacedDense'],
    [/\.font\(\.system\(size: 11\)\)/, 'WorkspaceFont.caption'],
    // Ruled by the maintainer: converge these to the nearest role. 12pt has
    // only `secondary`, so the weight goes medium -> regular; the 11pt sites
    // are badges and titles, which is what `label` is for, so medium ->
    // semibold. Both keep their size, so only the weight shifts.
    [/\.font\(\.system\(size: 12, weight: \.medium\)\)/, 'WorkspaceFont.secondary'],
    [/\.font\(\.system\(size: 11, weight: \.medium\)\)/, 'WorkspaceFont.label'],
  ];
  const offenders = [];
  for (const path of coverage.appViewFiles) {
    const source = read(path);
    for (const [pattern, role] of exact) {
      if (pattern.test(source)) offenders.push(`${path} → ${role}`);
    }
  }
  assert.deepEqual(offenders, [], 'these sizes have an exact shared role');

  // What stays off the scale, and why. 10pt is a maintainer ruling: spec §2's
  // smallest non-mono role is 12 and this table adds 11, so 10 sits below both;
  // promoting it would change the density of the surfaces that use it.
  const remaining = coverage.appViewFiles
    .flatMap(path => [...read(path).matchAll(/\.font\(\.system\(size: ([0-9]+)(, weight: \.(\w+))?/g)]
      .map(m => ({path, size: Number(m[1]), weight: m[3]})));
  const tiers = new Map();
  for (const site of remaining) {
    const key = site.weight ? `${site.size}/${site.weight}` : `${site.size}`;
    tiers.set(key, (tiers.get(key) ?? 0) + 1);
  }
  // Every surviving site is one of: the retained 10pt tier, a medium weight the
  // scale has no role for, or an outlier glyph size. A new bare size outside
  // these fails here rather than drifting in unnoticed.
  const allowed = new Set(['10', '10/semibold', '9/semibold', '36', '28/semibold']);
  const unexpected = [...tiers.keys()].filter(key => !allowed.has(key));
  assert.deepEqual(unexpected, [], 'a new off-scale type size appeared');
  assert.equal(tiers.get('10') ?? 0, 19, 'the retained 10pt tier changed size');

  assert.match(
    read('ArkDeckApp/DesignSystem/WorkspaceChrome.swift'),
    /There is deliberately no 10pt role/,
    'the shared table must record why 10pt stays off the scale');
});

test('localization catalogs carry no keys for paths the App no longer renders', () => {
  // F52 item 6. Static reachability alone cannot condemn a key: the App looks
  // several up through variables (`Text(LocalizedStringKey(serverHealthKey))`,
  // `field(_ titleKey:)`) and builds others by interpolation
  // (`"debug.tab.\(tabID)"`). A key counts as referenced if it appears as a
  // literal anywhere in Swift, if its generated camelCase accessor is used, or
  // if any interpolated prefix in the source is a prefix of it.
  const swift = swiftSources();
  const literals = new Set([...swift.matchAll(/"([^"\\\n]*)"/g)].map(m => m[1]));
  const identifiers = new Set(swift.match(/[A-Za-z_][A-Za-z0-9_]*/g) ?? []);
  const interpolated = [...swift.matchAll(/"([a-zA-Z0-9_.]*?)\\\(/g)].map(m => m[1]).filter(Boolean);
  const camel = key => {
    const parts = key.split(/[._]/);
    return parts[0] + parts.slice(1).map(w => w ? w[0].toUpperCase() + w.slice(1) : '').join('');
  };
  const unreferenced = name => {
    const keys = Object.keys(JSON.parse(read(`ArkDeckApp/Resources/${name}.xcstrings`)).strings);
    return keys.filter(key =>
      !literals.has(key)
      && !identifiers.has(camel(key))
      && !interpolated.some(prefix => key.startsWith(prefix)));
  };

  // Swept in this batch: these catalogs must stay clean.
  for (const name of ['DebugLocalizable', 'DiagnosticsLocalizable', 'FlashLocalizable', 'HistoryLocalizable']) {
    assert.deepEqual(unreferenced(name), [], `${name} regained keys nothing renders`);
  }

  // Held back on purpose, each tied to an open maintainer decision. Pinned by
  // count so neither the cleanup nor the decision can drift silently.
  assert.equal(
    unreferenced('UIDumpLocalizable').length, 25,
    'the Viewer inspector keys are held for the English-retention decision (F52-5)');
  assert.equal(
    unreferenced('SettingsLocalizable').length, 4,
    'the Settings pane titles are held for the duplicate-page-title decision');
});

test('every design preview is type-checked and bundled by a script', () => {
  // F52 item 8. `tsconfig.json` includes only `src/**` and `build:review`
  // bundles a single entry, so the previews were checked by nobody; the audit's
  // "all previews bundle independently" was a hand-run loop. This pins the
  // wiring that makes it a script, so it cannot quietly come back out.
  const manifest = JSON.parse(read('docs/design/arkdeck-ds/package.json'));
  const scripts = manifest.scripts;
  assert.equal(scripts['check:previews'], 'tsc -p tsconfig.previews.json');
  assert.equal(scripts['build:previews'], 'node scripts/build-previews.mjs');
  for (const step of ['check:previews', 'build:previews']) {
    assert.match(scripts.build, new RegExp(`npm run ${step.replace(':', ':')}`),
      `${step} must run as part of \`npm run build\``);
  }

  // The type-check config has to reach outside the package and resolve React
  // through @types; both are load-bearing, so state them rather than trust them.
  const previewConfig = read('docs/design/arkdeck-ds/tsconfig.previews.json');
  assert.match(previewConfig, /\.design-sync\/previews/);
  assert.match(previewConfig, /"react":\s*\["\.\/node_modules\/@types\/react"\]/);
  assert.match(previewConfig, /"react\/jsx-runtime":\s*\["\.\/node_modules\/@types\/react\/jsx-runtime"\]/);

  // One entry point per preview: a combined bundle would still pass even if a
  // preview only compiled because a sibling pulled in what it needed.
  const bundler = read('docs/design/arkdeck-ds/scripts/build-previews.mjs');
  assert.match(bundler, /entryPoints: \[join\(previewDir, entry\)\]/);
  assert.match(bundler, /process\.exit\(1\)/, 'a failed preview must fail the script');

  // And the set it walks is the audited set.
  const previews = files(join(root, '.design-sync/previews'))
    .filter(path => path.endsWith('.tsx'));
  assert.equal(previews.length, coverage.previewFiles.length);
});
