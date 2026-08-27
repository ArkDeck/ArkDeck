import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

// Execute the actual draft state machine, not a second implementation. The
// DOM and clock are inert test doubles; no browser or device is contacted.
const html = readFileSync(new URL('../../prototype.html', import.meta.url), 'utf8');
const script = html.split('<script>')[1].split('</script>')[0];
const start = script.indexOf('/* ---------- Device · implementation-synced workspace ---------- */');
const end = script.indexOf('/* ---------- Debug ---------- */', start);
const device = script.slice(start, end);

function harness(scenario = 'empty') {
  const timers = [];
  const element = {textContent:'',style:{},classList:{toggle(){}},hidden:false,focus(){}};
  const context = vm.createContext({
    Date, URL, performance:{now:()=>0},
    location:{href:'http://localhost/prototype.html?page=device-control'},
    history:{replaceState(){}},
    $:()=>element, render(){}, renderPageIf(){},
    setTimeout(callback){timers.push(callback);},
  });
  vm.runInContext('const S={language:"zh-Hans",nav:"device-control"};' + device, context);
  const run = code => vm.runInContext(code, context);
  run(`S.deviceControl=deviceDraftState(${JSON.stringify(scenario)})`);
  const state = () => run('S.deviceControl');
  const tick = () => { assert.ok(timers.length, 'expected a pending phase'); timers.shift()(); };
  const flush = () => { while(timers.length)tick(); };
  const pointer = (x=36,y=64) => ({button:0,clientX:x,clientY:y,pointerId:1,
    currentTarget:{getBoundingClientRect:()=>({left:0,top:0,width:72,height:128}),
      setPointerCapture(){},releasePointerCapture(){}},preventDefault(){}});
  const press = (held=0, endX=36) => {
    context.event=pointer();run('devicePointerDown(event)');
    context.performance.now=()=>held;context.event=pointer(endX);run('devicePointerUp(event)');
    context.performance.now=()=>0;
  };
  return {run,state,tick,flush,press,timers};
}

test('default is empty; screenshot is explicit and no background refresh is scheduled', () => {
  const h=harness();assert.equal(h.state().frame,null);assert.equal(h.state().events.length,0);
  assert.equal(h.state().frameCount,40);assert.equal(h.timers.length,0);
  h.run('captureDeviceScreenshot()');assert.equal(h.state().isCapturing,true);
  h.run('captureDeviceScreenshot()');assert.equal(h.timers.length,1);
  h.tick();assert.equal(h.state().frame.stale,false);assert.equal(h.timers.length,0);
});

for(const [scenario,outcome,stale] of [['captured','confirmed',true],['unknown','unknown',true],['inputFailed','failed',false]]) {
  test(`${outcome} settles once and preserves the App liveness rule`, () => {
    const h=harness(scenario);h.press();assert.equal(h.state().marker.pending,true);
    h.press();assert.equal(h.timers.length,1,'pending rejects another input');
    h.tick();assert.equal(h.state().events[0].outcome,outcome);assert.equal(h.state().frame.stale,stale);
    assert.equal(h.timers.length,0,'no automatic replay or capture');
    if(stale){h.press();assert.equal(h.state().events[0].refused,true);assert.equal(h.timers.length,0);
      h.run('captureDeviceScreenshot()');h.tick();assert.equal(h.state().frame.stale,false);}
  });
}

test('pointer classification, start anchoring and duration bounds match the App', () => {
  for(const [held,x,kind,detail] of [[499,39,'tap','(360, 640)'],[500,39,'longPress','500ms'],[4000,36,'longPress','2000ms'],[10,42,'swipe','80ms']]) {
    const h=harness('captured');h.press(held,x);h.tick();
    assert.equal(h.state().events[0].key,`device.gesture.${kind}`);
    assert.ok(h.state().events[0].detail.includes(detail));
  }
});

test('history frames refuse input; failed captures retain the prior picture', () => {
  const history=harness('history');history.press();assert.equal(history.timers.length,0);
  assert.equal(history.state().events[0].refused,true);
  const capture=harness('captureFailed'),frame=capture.state().frame;
  capture.run('captureDeviceScreenshot()');capture.tick();assert.equal(capture.state().frame,frame);
  assert.equal(capture.state().events[0].key,'device.log.captureFailed');
});

test('recording locks frames and repeat actions before the quota await, then visits each stage', () => {
  const h=harness();h.run('startDeviceRecording()');
  for(const stage of ['preflighting','capturing','assembling','validating']) {
    assert.equal(h.state().recordStage,stage);
    h.run('deviceChangeFrames(10);startDeviceRecording();resetDeviceRecording()');
    assert.equal(h.state().recordStage,stage);assert.equal(h.state().frameCount,40);assert.equal(h.timers.length,1);
    h.tick();
  }
  assert.equal(h.state().recordStage,'ready');assert.equal(h.state().lastRecording.frameCount,40);
  assert.ok(h.state().lastRecording.path.endsWith('.mov'));assert.equal(h.state().frame,null);
  h.run('resetDeviceRecording()');assert.equal(h.state().recordStage,'idle');assert.equal(h.timers.length,0);
});

test('quota refusal starts nothing, and shrink requires another explicit record action', () => {
  const h=harness('quota');h.run('startDeviceRecording()');assert.equal(h.state().recordStage,'preflighting');
  h.tick();assert.equal(h.state().recordStage,'refused');assert.equal(h.timers.length,0);
  h.run('deviceShrinkRecording()');assert.equal(h.state().frameCount,22);assert.equal(h.state().recordStage,'idle');assert.equal(h.timers.length,0);
  h.run('startDeviceRecording()');h.flush();assert.equal(h.state().recordStage,'ready');
});

test('unavailable quota, missing frames and failures are not presented as a complete checked result', () => {
  const quota=harness('headroomUnknown');quota.run('startDeviceRecording()');quota.tick();assert.equal(quota.state().headroomUnchecked,true);quota.flush();assert.equal(quota.state().recordStage,'ready');
  const gap=harness('missingFrames');gap.run('startDeviceRecording()');gap.flush();assert.equal(gap.state().lastRecording.missing,3);assert.equal(gap.state().lastRecording.frameCount,37);
  const failed=harness('recordingFailed');failed.run('startDeviceRecording()');failed.flush();assert.equal(failed.state().recordStage,'failed');assert.equal(failed.state().lastRecording,null);
  const absent=harness('noTarget');absent.run('captureDeviceScreenshot();startDeviceRecording()');assert.equal(absent.timers.length,0);assert.equal(absent.state().recordStage,'failed');
});

test('a new preflight clears the previous run\'s unavailable-headroom notice', () => {
  const h=harness('headroomUnknown');h.run('startDeviceRecording()');h.flush();
  assert.equal(h.state().headroomUnchecked,true);
  h.run('resetDeviceRecording();startDeviceRecording()');assert.equal(h.state().headroomUnchecked,false);
  h.tick();assert.equal(h.state().headroomUnchecked,true);
});

test('an unavailable Runtime entry fails before capture and offers no invented result', () => {
  const h=harness('runtimeUnavailable');h.run('startDeviceRecording()');
  assert.equal(h.state().recordStage,'preflighting');h.tick();
  assert.equal(h.state().recordStage,'failed');assert.equal(h.timers.length,0);
  assert.equal(h.state().lastRecording,null);assert.match(h.state().recordFailure,/methodNotAllowlisted/);
});

test('a new review scenario rejects every late capture/input/recording callback', () => {
  for(const [action,phases] of [['captureDeviceScreenshot()',0],['startDeviceRecording()',0],
    ['startDeviceRecording()',1],['startDeviceRecording()',2],['startDeviceRecording()',3],['input',0]]) {
    const h=harness('captured');if(action==='input')h.press();else h.run(action);
    for(let phase=0;phase<phases;phase++)h.tick();
    h.run('setDeviceScenario("empty")');const current=h.state();h.flush();
    assert.equal(h.state(),current);assert.equal(current.frame,null);assert.equal(current.events.length,0);assert.equal(current.recordStage,'idle');
  }
});
