const assert = require("node:assert/strict");
const { test } = require("node:test");
const { readFileSync } = require("node:fs");
const { join } = require("node:path");
const { JSDOM } = require("jsdom");

const settle = () => new Promise(resolve => setTimeout(resolve, 20));

test("saved mode stays enabled and can be disabled while setup or connection is unavailable", async t => {
  const html = readFileSync(join(__dirname, "../src/popup/popup.html"), "utf8");
  const script = readFileSync(join(__dirname, "../src/popup/popup.js"), "utf8");
  for (const connectionState of ["permission-required", "error"]) {
    const dom = new JSDOM(html, {
      url: "chrome-extension://onahjemknbndeedkmhlmchmadplokcnp/src/popup/popup.html",
      runScripts: "outside-only"
    });
    const { window } = dom;
    t.after(() => window.close());
    let state = { enabled: true, state: connectionState, active: false, error: "", message: "" };
    window.chrome = {
      tabs: { query: async () => [{ id: 42, url: "https://example.com/" }] },
      runtime: {
        getManifest: () => ({ version: "0.1.0" }),
        sendMessage: async message => {
          if (message.type === "audio-visualizer:retry") throw new Error("Connection unavailable");
          if (message.type === "audio-visualizer:set-enabled") {
            state = { enabled: message.enabled, state: "idle", active: false, error: "", message: "" };
          }
          return state;
        }
      }
    };
    window.eval(script);
    await settle();
    const toggle = window.document.querySelector("#audio-toggle");
    const retry = window.document.querySelector("#retry-connection");
    assert.equal(toggle.checked, true, "waiting for native setup must not erase the saved choice");
    assert.equal(toggle.disabled, false, "the global preference is usable outside ChatGPT");
    assert.equal(retry.hidden, false);

    retry.click();
    await settle();
    assert.equal(toggle.checked, true, "a failed retry must not turn the remembered mode off");
    assert.equal(toggle.disabled, false);

    toggle.checked = false;
    toggle.dispatchEvent(new window.Event("change"));
    await settle();
    assert.equal(toggle.checked, false);
    assert.equal(retry.hidden, true, "disabled mode must not invite a reconnect");
  }
});
