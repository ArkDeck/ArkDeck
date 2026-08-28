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
    setAttribute() {}, focus() {},
    querySelector() { return null; },
    querySelectorAll() { return []; },
  });
  const document = {
    addEventListener() {}, activeElement: null,
    body: element(), documentElement: element(),
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
    assert.doesNotMatch(page,/4 safety checks passed|4 项安全检查通过/);
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

test('all actual navigation items and subtabs are audited', () => {
  assert.deepEqual(enumCases('ArkDeckApp/App/ArkDeckApp.swift', 'ArkDeckNavigationItem'), coverage.navigation);
  assert.deepEqual(enumCases('ArkDeckApp/Features/Debug/DebugWorkspaceView.swift', 'DebugWorkspaceTab'), coverage.debugTabs);
  assert.deepEqual(enumCases('ArkDeckApp/Features/UIDump/UIDumpWorkspaceView.swift', 'ViewerInspectorTab'), coverage.viewerTabs);
  const settings = read('ArkDeckApp/Features/Settings/SettingsRootView.swift');
  const tabs = [...settings.matchAll(/Label\(settingsText\("settings\.tab\.(\w+)"\)/g)].map(match => match[1]);
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
  h.run('prepareContinuation("S-0826-04")');
  assert.equal(h.run('S.nav'),'diagnostics');
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
  assert.equal(history.run('inspectorJobs()[0].operation'),null,
    'a display title or archive filename is not an operation identity');
  assert.equal(history.run('inspectorJobs()[3].operation'),'capture.diagnostics@1');
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
