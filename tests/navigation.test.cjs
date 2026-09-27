const assert = require("node:assert/strict");
const { test } = require("node:test");
const { readFileSync } = require("node:fs");
const { join } = require("node:path");
const { JSDOM } = require("jsdom");

// Mirrors the message boundaries observed on chatgpt.com, using synthetic text.
function modernTurn(index, question = `问题 ${index}`, title = `章节 ${index}`) {
  return `<div class="turn">
    <div class="block"><h4 class="sr-only">You said:</h4>
      <div class="group/user-message" data-chatgpt-search-unit-key="turn-${index}:0:user" data-chatgpt-search-message-ids="user-${index}">
        <div data-content-search-unit-key="turn-${index}:0:user">
          <div data-user-message-bubble="true"><div data-markdown-text-tone="user-message" class="MarkdownRoot-example"><p>${question}</p></div></div>
        </div>
        <button aria-label="Edit message">Edit message</button>
      </div>
    </div>
    <div class="block">
      <div data-chatgpt-search-unit-key="turn-${index}:1:assistant" data-content-search-unit-key="turn-${index}:1:assistant" data-chatgpt-search-message-ids="assistant-${index}">
        <h4 class="sr-only" data-conversation-role="assistant">ChatGPT said:</h4>
        <div data-chatgpt-selection-message-id="assistant-${index}"><div class="MarkdownRoot-example"><h2>${title}</h2><p>这是一段较长的回复正文。</p><h3>具体步骤 ${index}</h3></div></div>
      </div>
    </div>
  </div>`;
}

function legacyTurn() {
  return `<article data-testid="conversation-turn-1"><div data-message-author-role="user" data-message-id="legacy-user"><div class="whitespace-pre-wrap">旧版问题</div></div></article>
    <article data-testid="conversation-turn-2"><div data-message-author-role="assistant" data-message-id="legacy-assistant"><div class="markdown"><h2>旧版章节</h2></div></div></article>`;
}

function setup(t, html, app = false) {
  const dom = new JSDOM(`<!doctype html><body>${html}</body>`, {
    url: "https://chatgpt.com/g/g-p-example/c/test-chat",
    runScripts: "outside-only",
    pretendToBeVisual: true
  });
  const { window } = dom;
  t.after(() => window.close());
  window.CSS = { escape: value => value };
  window.document.elementsFromPoint = () => [];
  window.HTMLElement.prototype.scrollIntoView = function () {};
  window.HTMLElement.prototype.scrollTo = function ({ top }) { this.scrollTop = top; };
  window.HTMLElement.prototype.getBoundingClientRect = function () {
    const top = Number(this.dataset.top || 100);
    const height = Number(this.dataset.height || 300);
    return { top, bottom: top + height, left: 280, right: 1080, width: 800, height };
  };
  const files = app
    ? ["dom-adapter.js", "sidebar.js", "message-outline.js", "audio-visualizer.js", "index.js"]
    : ["dom-adapter.js"];
  for (const file of files) {
    window.eval(readFileSync(join(__dirname, "../src/content", file), "utf8"));
  }
  return { window, document: window.document, adapter: window.__CHATGPT_HELPER__.domAdapter };
}

const settle = () => new Promise(resolve => setTimeout(resolve, 80));

test("current page markup yields one question and one outline per turn", t => {
  const { adapter } = setup(t, `<main>${modernTurn(1)}${modernTurn(2)}</main>`);
  assert.deepEqual(Array.from(adapter.getQuestionItems(), q => q.title), ["问题 1", "问题 2"]);
  const messages = adapter.getAssistantMessages();
  assert.equal(messages.length, 2);
  assert.deepEqual(Array.from(adapter.extractHeadings(messages[0].contentElement), h => h.text), ["章节 1", "具体步骤 1"]);
});

test("legacy and modern messages stay in document order without duplicates", t => {
  const { adapter } = setup(t, `<main>${modernTurn(1)}${legacyTurn()}${modernTurn(2)}</main>`);
  assert.deepEqual(Array.from(adapter.getQuestionItems(), q => q.title), ["问题 1", "旧版问题", "问题 2"]);
  assert.equal(adapter.getAssistantMessages().length, 3);
});

test("native bubble and assistant labels work without search annotations", t => {
  const html = modernTurn(1).replace(/ data-(?:chatgpt-search-[\w-]+|content-search-unit-key)="[^"]*"/g, "");
  const { adapter } = setup(t, `<main>${html}</main>`);
  assert.deepEqual(Array.from(adapter.getQuestionItems(), q => q.title), ["问题 1"]);
  const messages = adapter.getAssistantMessages();
  assert.equal(messages.length, 1);
  assert.deepEqual(Array.from(adapter.extractHeadings(messages[0].contentElement), h => h.text), ["章节 1", "具体步骤 1"]);
});

test("message identity survives inserting earlier history", t => {
  const { adapter, document } = setup(t, `<main>${modernTurn(2)}</main>`);
  const original = adapter.getQuestionItems()[0].id;
  document.querySelector("main").insertAdjacentHTML("afterbegin", modernTurn(1));
  assert.equal(adapter.getQuestionItems()[1].id, original);
});

test("finds inner scrolling container and accepts negative scroll offsets", t => {
  const { adapter, document } = setup(t, `<main><div id="scroll" style="overflow-y:auto;display:flex;flex-direction:column-reverse">${modernTurn(1)}</div></main>`);
  const scroller = document.querySelector("#scroll");
  Object.defineProperties(scroller, { scrollHeight: { value: 3000 }, clientHeight: { value: 800 } });
  scroller.dataset.top = "0";
  scroller.scrollTop = -500;
  const question = adapter.getQuestionItems()[0];
  assert.ok(question, "current user message must be recognized");
  question.element.dataset.top = "296";
  assert.equal(adapter.getScrollContainer(), scroller);
  adapter.scrollToQuestion(question.id);
  assert.equal(scroller.scrollTop, -300);
});

test("observer follows main replacement and subsequent streamed messages", async t => {
  const { adapter, document } = setup(t, `<main>${modernTurn(1)}</main>`);
  let notifications = 0;
  const stop = adapter.observeQuestions(() => notifications++);
  document.querySelector("main").outerHTML = `<main>${modernTurn(1)}</main>`;
  await settle();
  assert.equal(notifications, 1, "new DOM nodes must replace stale references even when text is unchanged");
  document.querySelector("main").insertAdjacentHTML("beforeend", modernTurn(2));
  await settle();
  assert.equal(notifications, 2);
  stop();
});

test("renders both navigators and updates outline during streaming", async t => {
  const { document, window } = setup(t, `<main>${modernTurn(1)}</main>`, true);
  assert.equal(document.querySelector(".chatgpt-helper-sidebar").dataset.visible, "true");
  assert.equal(document.querySelector(".chatgpt-helper-message-outline").dataset.visible, "true");
  assert.equal(document.querySelectorAll(".chatgpt-helper-message-outline__item").length, 2);
  assert.equal(document.querySelectorAll(".chatgpt-helper-message-outline__rail-item.is-active").length, 1);
  document.querySelector('[data-chatgpt-selection-message-id] .MarkdownRoot-example').insertAdjacentHTML("beforeend", "<h2>流式新增章节</h2>");
  await settle();
  assert.equal(document.querySelectorAll(".chatgpt-helper-message-outline__item").length, 3);
  window.document.dispatchEvent(new window.Event("scroll", { bubbles: false }));
  await settle();
});

test("question highlight stays with the answer being read", async t => {
  const { document, window } = setup(t, `<main>${modernTurn(1)}${modernTurn(2)}</main>`, true);
  const users = document.querySelectorAll('[data-chatgpt-search-unit-key$=":user"]');
  users[0].dataset.top = "-800";
  users[0].dataset.height = "50";
  users[1].dataset.top = "900";
  window.dispatchEvent(new window.Event("scroll"));
  await settle();
  assert.equal(document.querySelector(".chatgpt-helper-sidebar__item.is-active").textContent, "问题 1");
});

test("an empty conversation does not create an observer refresh loop", async t => {
  const { document } = setup(t, "<main><div>开始新的对话</div></main>", true);
  await settle();
  assert.equal(document.querySelectorAll(".chatgpt-helper-sidebar").length, 1);
  assert.equal(document.querySelector(".chatgpt-helper-sidebar").dataset.visible, "false");
});
