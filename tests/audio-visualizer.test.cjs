const assert = require("node:assert/strict");
const { test } = require("node:test");
const { readFileSync } = require("node:fs");
const { join } = require("node:path");
const { JSDOM } = require("jsdom");

function setup(t, counts = { left: 6, right: 8 }) {
  const rails = [
    ["sidebar", counts.right],
    ["message-outline", counts.left]
  ].map(([name, count]) =>
    `<div class="chatgpt-helper-${name}__rail">${Array.from({ length: count }, () =>
      `<button class="chatgpt-helper-${name}__rail-item"></button>`).join("")}</div>`
  ).join("");
  const dom = new JSDOM(`<!doctype html><body>${rails}</body>`, { runScripts: "outside-only" });
  t.after(() => dom.window.close());
  const { window } = dom;
  let now = 0;
  let nextId = 1;
  const pending = new Map();
  let motionListener;
  const media = { matches: false, addEventListener: (_, listener) => { motionListener = listener; } };
  window.matchMedia = () => media;
  window.performance.now = () => now;
  window.Date.now = () => 1700000000000 + now;
  window.requestAnimationFrame = callback => {
    const id = nextId++;
    pending.set(id, callback);
    return id;
  };
  window.cancelAnimationFrame = id => pending.delete(id);
  window.eval(readFileSync(join(__dirname, "../src/content/audio-visualizer.js"), "utf8"));
  const api = window.__CHATGPT_HELPER__.audioVisualizer;

  function channel(bands) {
    return {
      level: Math.sqrt(bands.reduce((sum, value) => sum + value * value, 0) / bands.length),
      peak: bands.reduce((maximum, value) => Math.max(maximum, value), 0),
      bands
    };
  }

  function apply(payload) {
    api.applyLevel({ timestamp: window.Date.now() / 1000, ...payload });
  }

  return {
    api,
    apply,
    send(leftBands, rightBands = leftBands, extra = {}) {
      apply({
        active: true,
        channels: [channel(leftBands), channel(rightBands)],
        ...extra
      });
    },
    disconnect() {
      apply({ active: false, channels: [] });
    },
    frame(at) {
      now = at;
      const callbacks = [...pending.values()];
      pending.clear();
      callbacks.forEach(callback => callback(now));
    },
    reduce(value) {
      media.matches = value;
      motionListener();
    },
    snapshot() {
      const levels = selector => [...window.document.querySelector(selector).children]
        .map(item => Number(item.style.getPropertyValue("--conversation-trail-bar-level")));
      return {
        left: levels(".chatgpt-helper-message-outline__rail"),
        right: levels(".chatgpt-helper-sidebar__rail")
      };
    }
  };
}

const spectrum = value => Array(24).fill(value);
const silence = () => spectrum(0);
const flatten = ({ left, right }) => [...left, ...right];

test("left and right spectra drive only their mapped rails", t => {
  const view = setup(t);
  view.send(spectrum(1), silence());
  view.frame(40);
  let levels = view.snapshot();
  assert.ok(levels.left.every(value => value > 0));
  assert.ok(levels.right.every(value => value === 0));

  view.disconnect();
  view.send(silence(), spectrum(1));
  view.frame(80);
  levels = view.snapshot();
  assert.ok(levels.left.every(value => value === 0));
  assert.ok(levels.right.every(value => value > 0));
});

test("RMS pooling preserves narrow peaks and long rails interpolate the spectral contour", t => {
  const pooled = setup(t, { left: 6, right: 6 });
  const narrowPeak = silence();
  narrowPeak[10] = 1;
  const equivalentRms = Math.sqrt((0.2 ** 2 + 0.6 ** 2 + 0.2 ** 2) / 4);
  pooled.send(narrowPeak, spectrum(equivalentRms));
  pooled.frame(100);
  const pooledLevels = pooled.snapshot();
  assert.ok(pooledLevels.left[2] > pooledLevels.left[1], "the narrow spectral peak remains visible");
  assert.ok(
    Math.abs(pooledLevels.left[2] - pooledLevels.right[2]) < 0.002,
    "a narrow peak retains the same visible energy as its equivalent RMS"
  );

  const interpolated = setup(t, { left: 6, right: 48 });
  const triangle = Array.from({ length: 24 }, (_, band) =>
    Math.max(0, 1 - Math.abs(band - 12) / 8)
  );
  interpolated.send(silence(), triangle);
  interpolated.frame(100);
  const risingSlope = interpolated.snapshot().right.slice(10, 22);
  assert.ok(
    risingSlope.every((value, index) => index === 0 || value > risingSlope[index - 1]),
    "interpolation forms a continuous rise instead of repeated flat blocks"
  );
});

test("steady spectra stay steady and silence releases monotonically without rebound", t => {
  const view = setup(t);
  view.send(spectrum(0.6), spectrum(0.35));
  for (let at = 20; at <= 400; at += 20) {
    view.frame(at);
    view.send(spectrum(0.6), spectrum(0.35));
  }
  const held = flatten(view.snapshot());
  for (let at = 420; at <= 800; at += 20) {
    view.frame(at);
    view.send(spectrum(0.6), spectrum(0.35));
    assert.deepEqual(flatten(view.snapshot()), held);
  }

  view.send(silence(), silence());
  let previous = held;
  for (let at = 820; at <= 1500; at += 20) {
    view.frame(at);
    const current = flatten(view.snapshot());
    current.forEach((value, index) => assert.ok(value >= 0 && value <= previous[index]));
    previous = current;
  }
  assert.ok(previous.every(value => value === 0));
});

test("response does not depend on display refresh rate", t => {
  function sample(fps) {
    const view = setup(t);
    const left = Array.from({ length: 24 }, (_, band) => band / 23);
    view.send(left, [...left].reverse());
    for (let index = 1; index < fps / 10; index += 1) view.frame(index * 1000 / fps);
    view.frame(100);
    return flatten(view.snapshot());
  }
  const reference = sample(60);
  for (const fps of [30, 120, 144]) {
    sample(fps).forEach((value, index) => assert.ok(Math.abs(value - reference[index]) < 0.002));
  }
});

test("lost and old frames fade out, disconnect clears, and volume never substitutes for bands", t => {
  const view = setup(t);
  view.send(spectrum(0.8));
  view.frame(40);
  assert.ok(flatten(view.snapshot()).every(value => value > 0));
  for (let at = 60; at <= 800; at += 20) view.frame(at);
  assert.ok(flatten(view.snapshot()).every(value => value === 0));

  view.send(spectrum(1), spectrum(1), { timestamp: 1699999999 });
  view.frame(840);
  assert.ok(flatten(view.snapshot()).every(value => value === 0));
  view.send(spectrum(0.8));
  view.frame(880);
  view.disconnect();
  assert.ok(flatten(view.snapshot()).every(value => value === 0));

  view.apply({
    active: true,
    channels: [{ level: 1, peak: 1 }, { level: 1, peak: 1 }]
  });
  view.frame(920);
  assert.ok(flatten(view.snapshot()).every(value => value === 0));
});

test("reduced motion remains static and does not revive a stale spectrum", t => {
  const view = setup(t);
  view.send(spectrum(0.8));
  view.frame(40);
  view.reduce(true);
  view.send(spectrum(1));
  view.frame(80);
  assert.ok(flatten(view.snapshot()).every(value => value === 0));
  view.frame(800);
  view.reduce(false);
  view.frame(840);
  assert.ok(flatten(view.snapshot()).every(value => value === 0));
});
