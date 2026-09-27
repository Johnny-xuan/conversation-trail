(function initDomAdapter(global) {
  const NAMESPACE = "__CHATGPT_HELPER__";
  const ITEM_ID_PREFIX = "chatgpt-helper-question";
  const MESSAGE_ID_PREFIX = "chatgpt-helper-message";
  const HEADING_ID_PREFIX = "chatgpt-helper-heading";
  const HELPER_SELECTOR = ".chatgpt-helper-sidebar, .chatgpt-helper-message-outline";
  let nextLocalId = 0;
  const USER_SELECTORS = [
    "[data-message-author-role='user']",
    "[data-chatgpt-search-unit-key$=':user']",
    "[data-content-search-unit-key$=':user']",
    "[data-user-message-bubble]",
    "[data-testid*='user-message']",
    "[data-testid*='conversation-turn-'][data-message-author-role='user']",
    "article [data-message-author-role='user']"
  ];
  const ASSISTANT_SELECTORS = [
    "[data-message-author-role='assistant']",
    "[data-chatgpt-search-unit-key$=':assistant']",
    "[data-content-search-unit-key$=':assistant']",
    "[data-conversation-role='assistant']",
    "[data-testid*='assistant-message']",
    "[data-testid*='conversation-turn-'][data-message-author-role='assistant']",
    "article [data-message-author-role='assistant']"
  ];
  const KNOWN_CONVERSATION_ROUTE_PATTERNS = [
    /^\/c\/[^/]+/i,
    /^\/share\/[^/]+/i,
    /^\/g\/[^/]+\/c\/[^/]+/i,
    /^\/projects?\/[^/]+(?:\/c\/[^/]+)?/i
  ];

  function getConversationRoot() {
    return document.querySelector("main, [role='main']");
  }

  function hasKnownConversationRoute() {
    return KNOWN_CONVERSATION_ROUTE_PATTERNS.some((pattern) =>
      pattern.test(window.location.pathname)
    );
  }

  function isConversationRoute() {
    const root = getConversationRoot();
    if (!root) {
      return hasKnownConversationRoute();
    }

    if (hasKnownConversationRoute()) {
      return true;
    }

    return hasConversationContent(root);
  }

  function normalizeTitle(rawText) {
    const firstLine = (rawText || "")
      .split("\n")
      .map((line) => line.trim())
      .find(Boolean);

    if (!firstLine) {
      return "未命名问题";
    }

    return firstLine
      .replace(/^(你说|您说|你问|用户|You said|You)\s*[:：]\s*/i, "")
      .replace(/\s+/g, " ")
      .trim()
      .slice(0, 120) || "未命名问题";
  }

  function findTurnContainer(node) {
    if (!(node instanceof HTMLElement)) {
      return null;
    }

    // New pages put the user and assistant in one turn. Keep their individual
    // message boundaries instead of climbing to that shared turn container.
    const message = node.closest("[data-chatgpt-search-unit-key], [data-message-author-role]");
    if (message) {
      return message;
    }
    if (node.matches("[data-conversation-role='assistant']")) {
      return node.parentElement;
    }

    return (
      node.closest("[data-content-search-unit-key]") ||
      node.closest("[data-testid^='conversation-turn-']") ||
      node.closest("article") ||
      node.closest("[data-message-id]") ||
      node
    );
  }

  function getTextLength(element) {
    return (element?.innerText || "").replace(/\s+/g, "").length;
  }

  function isVisibleConversationBlock(element) {
    if (!(element instanceof HTMLElement)) {
      return false;
    }

    if (element.closest(".chatgpt-helper-sidebar")) {
      return false;
    }

    if (element.closest(".chatgpt-helper-message-outline")) {
      return false;
    }

    const rect = element.getBoundingClientRect();
    return rect.height > 24 && rect.width > 120;
  }

  function looksLikeUserTurn(element) {
    if (!(element instanceof HTMLElement)) {
      return false;
    }

    const directRole = element.matches?.("[data-message-author-role='user']");
    const nestedRole = element.querySelector?.("[data-message-author-role='user']");
    const editButton = element.querySelector?.(
      "button[aria-label*='Edit'], button[aria-label*='编辑'], button[data-testid*='edit']"
    );
    const branchButton = element.querySelector?.(
      "button[aria-label*='Branch'], button[aria-label*='分支']"
    );
    const textLength = getTextLength(element);

    return (
      Boolean(directRole || nestedRole || editButton || branchButton) &&
      textLength > 0 &&
      isVisibleConversationBlock(element)
    );
  }

  // 判断节点是否像 AI 回复轮次。
  function looksLikeAssistantTurn(element) {
    if (!(element instanceof HTMLElement)) {
      return false;
    }

    const directRole = element.matches?.("[data-message-author-role='assistant']");
    const nestedRole = element.querySelector?.("[data-message-author-role='assistant']");
    const contentElement = findAssistantContentElement(element);

    return Boolean(directRole || nestedRole || contentElement) && isVisibleConversationBlock(element);
  }

  function getPrimaryCandidates(root) {
    const nodes = Array.from(root.querySelectorAll(USER_SELECTORS.join(",")));

    return nodes
      .map(findTurnContainer)
      .filter(Boolean);
  }

  // 使用优先选择器查找 AI 回复候选节点。
  function getAssistantPrimaryCandidates(root) {
    const nodes = Array.from(root.querySelectorAll(ASSISTANT_SELECTORS.join(",")));

    return nodes
      .map(findTurnContainer)
      .filter(Boolean);
  }

  // 在优先选择器失效时回退扫描 article 节点。
  function getAssistantFallbackCandidates(root) {
    return Array.from(root.querySelectorAll("article")).filter((article) => {
      return looksLikeAssistantTurn(article);
    });
  }

  // 使用启发式规则兜底识别 AI 回复节点。
  function getAssistantHeuristicCandidates(root) {
    const candidates = Array.from(
      root.querySelectorAll("[data-testid^='conversation-turn-'], [data-message-id], article, section")
    );

    return candidates.filter((element) => {
      if (!(element instanceof HTMLElement)) {
        return false;
      }

      if (looksLikeUserTurn(element) || !looksLikeAssistantTurn(element)) {
        return false;
      }

      return isVisibleConversationBlock(element);
    });
  }

  function getFallbackCandidates(root) {
    return Array.from(root.querySelectorAll("article")).filter((article) => {
      return looksLikeUserTurn(article);
    });
  }

  function getHeuristicCandidates(root) {
    const candidates = Array.from(
      root.querySelectorAll("[data-testid^='conversation-turn-'], [data-message-id], article, section")
    );

    return candidates.filter((element) => {
      if (!(element instanceof HTMLElement)) {
        return false;
      }

      if (!looksLikeUserTurn(element)) {
        return false;
      }

      return isVisibleConversationBlock(element);
    });
  }

  function dedupeElements(elements) {
    const seen = new Set();
    const deduped = [];

    elements.forEach((element) => {
      if (!(element instanceof HTMLElement)) {
        return;
      }

      if (seen.has(element)) {
        return;
      }

      seen.add(element);
      deduped.push(element);
    });

    return deduped
      .filter((element) => !element.closest(HELPER_SELECTOR))
      .filter((element) => !deduped.some((other) => other !== element && other.contains(element)))
      .sort((a, b) => a.compareDocumentPosition(b) & Node.DOCUMENT_POSITION_FOLLOWING ? -1 : 1);
  }

  function extractQuestionText(element) {
    if (!(element instanceof HTMLElement)) {
      return "";
    }

    const contentSelectors = [
      "[data-markdown-text-tone='user-message']",
      "[data-user-message-bubble] .whitespace-pre-wrap",
      "[data-user-message-bubble]",
      ".whitespace-pre-wrap",
      "[data-message-author-role='user'] .whitespace-pre-wrap",
      "[data-message-author-role='user'] [class*='whitespace-pre-wrap']",
      "[data-message-author-role='user'] [data-testid='user-message']",
      "[data-message-author-role='user'] [dir='auto']",
      "[data-message-author-role='user'] .markdown",
      "[data-message-author-role='user'] .prose",
      "[data-message-author-role='user'] p",
      "[data-testid*='user-message'] .whitespace-pre-wrap",
      "[data-testid*='user-message'] [class*='whitespace-pre-wrap']",
      "[data-testid*='user-message'] [dir='auto']",
      "[data-testid*='user-message'] .markdown",
      "[data-testid*='user-message'] .prose",
      "[data-testid*='conversation-turn-'] [dir='auto']",
      "[data-testid*='conversation-turn-'] .markdown",
      "[data-message-id] [dir='auto']",
      "[data-message-id] .markdown",
      "[data-message-id] .prose"
    ];

    for (const selector of contentSelectors) {
      const nodes = element.matches(selector) ? [element] : Array.from(element.querySelectorAll(selector));
      const matched = nodes
        .map((node) => (node.innerText || node.textContent || "").trim())
        .find((text) => text && !/^(你说|您说|你问|用户|You said|You)\s*[:：]?$/i.test(text));

      if (matched) {
        return matched;
      }
    }

    const cleanedLines = (element.innerText || "")
      .split("\n")
      .map((line) => line.trim())
      .filter(Boolean)
      .filter((line) => !/^(你说|您说|你问|用户|You said|You)\s*[:：]?$/i.test(line))
      .filter((line) => !/^(编辑消息|Edit message|复制|Copy|赞|踩|重新生成|Regenerate)$/i.test(line));

    return cleanedLines[0] || "";
  }

  // 查找 AI 回复中承载 Markdown 内容的元素。
  function findAssistantContentElement(element) {
    if (!(element instanceof HTMLElement)) {
      return null;
    }

    const selectors = [
      "[data-chatgpt-selection-message-id]",
      "[class*='MarkdownRoot']",
      "[data-message-author-role='assistant'] .markdown",
      "[data-message-author-role='assistant'] .prose",
      "[data-message-author-role='assistant'] [class*='markdown']",
      "[data-message-author-role='assistant'] [class*='prose']",
      ".markdown",
      ".prose"
    ];

    for (const selector of selectors) {
      const matched = element.matches(selector) ? element : element.querySelector(selector);
      if (matched instanceof HTMLElement) {
        return matched;
      }
    }

    const roleElement = element.matches("[data-message-author-role='assistant']")
      ? element
      : element.querySelector("[data-message-author-role='assistant']");

    return roleElement instanceof HTMLElement ? roleElement : null;
  }

  function collectCandidateElements(root) {
    if (!(root instanceof HTMLElement)) {
      return [];
    }

    const primary = getPrimaryCandidates(root);
    const fallback = primary.length ? [] : getFallbackCandidates(root);
    const heuristic = primary.length || fallback.length ? [] : getHeuristicCandidates(root);
    return dedupeElements(primary.length ? primary : fallback.length ? fallback : heuristic);
  }

  // 汇总并去重 AI 回复候选节点。
  function collectAssistantCandidateElements(root) {
    if (!(root instanceof HTMLElement)) {
      return [];
    }

    const primary = getAssistantPrimaryCandidates(root);
    const fallback = primary.length ? [] : getAssistantFallbackCandidates(root);
    const heuristic = primary.length || fallback.length ? [] : getAssistantHeuristicCandidates(root);
    return dedupeElements(primary.length ? primary : fallback.length ? fallback : heuristic);
  }

  function hasConversationContent(root) {
    return collectCandidateElements(root).length > 0;
  }

  function buildQuestionItems() {
    const root = getConversationRoot();
    if (!root) {
      return [];
    }

    const candidates = collectCandidateElements(root);
    if (!candidates.length) {
      return [];
    }

    return candidates
      .map((element, index) => {
        const id = getStableItemId(element, ITEM_ID_PREFIX, "chatgptHelperQuestionId");

        return {
          id,
          title: normalizeTitle(extractQuestionText(element)),
          element,
          index
        };
      })
      .filter((item) => item.title);
  }

  function getQuestionItems() {
    return buildQuestionItems();
  }

  function getStableItemId(element, prefix, datasetKey) {
    const sourceId =
      element.getAttribute("data-chatgpt-search-message-ids")?.trim().split(/\s+/)[0] ||
      element.getAttribute("data-chatgpt-selection-message-id") ||
      element.querySelector("[data-chatgpt-selection-message-id]")?.getAttribute("data-chatgpt-selection-message-id") ||
      element.getAttribute("data-message-id") ||
      element.querySelector("[data-message-id]")?.getAttribute("data-message-id") ||
      element.getAttribute("data-testid");
    const id = sourceId
      ? `${prefix}-${String(sourceId).replace(/[^a-zA-Z0-9_-]+/g, "-")}`
      : element.dataset[datasetKey] || `${prefix}-local-${++nextLocalId}`;
    if (element.dataset[datasetKey] !== id) {
      element.dataset[datasetKey] = id;
    }
    return id;
  }

  // 获取当前会话中可建立大纲的 AI 回复消息。
  function getAssistantMessages() {
    const root = getConversationRoot();
    if (!root) {
      return [];
    }

    return collectAssistantCandidateElements(root)
      .map((element, index) => {
        const contentElement = findAssistantContentElement(element);
        if (!contentElement) {
          return null;
        }

        return {
          id: getStableItemId(element, MESSAGE_ID_PREFIX, "chatgptHelperMessageId"),
          element,
          contentElement,
          index
        };
      })
      .filter(Boolean);
  }

  function assignHeadingId(element, messageId, index) {
    if (!element.id) {
      element.id = `${HEADING_ID_PREFIX}-${messageId}-${index + 1}`;
    }

    return element.id;
  }

  function buildHeadingItem(element, messageId, index, level, text) {
    const normalizedText = (text || "").replace(/\s+/g, " ").trim().slice(0, 120);
    if (!normalizedText) {
      return null;
    }

    return {
      id: assignHeadingId(element, messageId, index),
      level,
      text: normalizedText,
      element,
      index
    };
  }

  // 提取 AI 回复内 h1-h6 标题并补齐稳定锚点。
  function extractHeadings(contentElement, messageId = "message") {
    if (!(contentElement instanceof HTMLElement)) {
      return [];
    }

    return Array.from(contentElement.querySelectorAll("h1, h2, h3, h4, h5, h6"))
      .filter((element) => !element.closest("[hidden], [aria-hidden='true'], .sr-only, pre, code"))
      .map((element, index) => {
        return buildHeadingItem(
          element,
          messageId,
          index,
          Number(element.tagName.slice(1)),
          element.textContent
        );
      })
      .filter(Boolean);
  }

  function isScrollable(element) {
    if (!(element instanceof HTMLElement)) {
      return false;
    }

    const style = window.getComputedStyle(element);
    const overflowY = style.overflowY;
    return /(auto|scroll|overlay)/.test(overflowY) && element.scrollHeight > element.clientHeight + 24;
  }

  function findScrollContainer(element) {
    let current = element?.parentElement || null;

    while (current && current !== document.body) {
      if (isScrollable(current)) {
        return current;
      }

      current = current.parentElement;
    }

    const fallback = document.scrollingElement;
    return fallback instanceof HTMLElement ? fallback : null;
  }

  function getScrollContainer() {
    // The chat scroller is inside main on current pages, not an ancestor of it.
    const firstQuestion = getQuestionItems()[0];
    if (firstQuestion?.element) {
      return findScrollContainer(firstQuestion.element);
    }

    const firstMessage = getAssistantMessages()[0];
    if (firstMessage?.element) {
      return findScrollContainer(firstMessage.element);
    }

    const fallback = document.scrollingElement;
    return fallback instanceof HTMLElement ? fallback : null;
  }

  function scrollElementWithOffset(target, options = {}) {
    if (!(target instanceof HTMLElement)) {
      return false;
    }

    const container = findScrollContainer(target);
    const topOffset = Number(options.topOffset) || 96;
    const behavior = options.behavior || "smooth";

    if (container && container !== document.body && container !== document.documentElement) {
      const containerRect = container.getBoundingClientRect();
      const targetRect = target.getBoundingClientRect();
      const targetTop = targetRect.top - containerRect.top + container.scrollTop - topOffset;

      container.scrollTo({
        // column-reverse containers use negative scrollTop values. Let the
        // browser clamp to its own scroll range instead of forcing zero.
        top: targetTop,
        behavior
      });
      return true;
    }

    const targetTop = target.getBoundingClientRect().top + window.scrollY - topOffset;
    window.scrollTo({
      top: targetTop,
      behavior
    });
    return true;
  }

  function getTargetOffsetDelta(target, container, topOffset) {
    if (!(target instanceof HTMLElement)) {
      return 0;
    }

    if (container && container !== document.body && container !== document.documentElement) {
      const containerRect = container.getBoundingClientRect();
      const targetRect = target.getBoundingClientRect();
      return targetRect.top - containerRect.top - topOffset;
    }

    return target.getBoundingClientRect().top - topOffset;
  }

  function correctScrollUntilSettled(target, options = {}) {
    const container = findScrollContainer(target);
    const topOffset = Number(options.topOffset) || 96;
    const delay = options.delay === undefined ? 420 : Number(options.delay);
    const duration = options.duration === undefined ? 1200 : Number(options.duration);
    let stableCount = 0;
    let startedAt = 0;

    function correct() {
      if (!(target instanceof HTMLElement)) {
        return;
      }

      const delta = getTargetOffsetDelta(target, container, topOffset);
      if (Math.abs(delta) <= 3) {
        stableCount += 1;
      } else {
        stableCount = 0;

        if (container && container !== document.body && container !== document.documentElement) {
          container.scrollTo({
            top: container.scrollTop + delta,
            behavior: "auto"
          });
        } else {
          window.scrollTo({
            top: window.scrollY + delta,
            behavior: "auto"
          });
        }
      }

      if (stableCount >= 3 || Date.now() - startedAt > duration) {
        return;
      }

      window.requestAnimationFrame(correct);
    }

    const startCorrection = () => {
      startedAt = Date.now();
      window.requestAnimationFrame(correct);
    };

    if (delay <= 0) {
      startCorrection();
    } else {
      window.setTimeout(startCorrection, delay);
    }
  }

  function scrollToQuestion(id) {
    const target = document.querySelector(
      `[data-chatgpt-helper-question-id='${CSS.escape(id)}']`
    );

    if (!target) {
      return false;
    }

    const scrolled = scrollElementWithOffset(target, { behavior: "auto" });
    correctScrollUntilSettled(target, { delay: 0 });
    return scrolled;
  }

  // 平滑滚动到指定标题位置。
  function scrollToHeading(id) {
    const target = document.getElementById(id);
    if (!(target instanceof HTMLElement)) {
      return false;
    }

    return scrollElementWithOffset(target);
  }

  function isHelperMutation(mutation) {
    const target = mutation.target instanceof Element
      ? mutation.target
      : mutation.target.parentElement;
    if (target?.closest(HELPER_SELECTOR)) {
      return true;
    }
    const changedNodes = [...mutation.addedNodes, ...mutation.removedNodes];
    return mutation.type === "childList" && changedNodes.length > 0 &&
      changedNodes.every((node) => node instanceof Element && node.matches(HELPER_SELECTOR));
  }

  function observeItems(onChange, collect, signatureFor) {
    if (!document.body || typeof onChange !== "function") {
      return () => {};
    }

    let frameId = 0;
    let lastRoot = getConversationRoot();
    let lastItems = collect();
    let lastSignature = signatureFor(lastItems);
    const observer = new MutationObserver((mutations) => {
      if (mutations.every(isHelperMutation) || frameId) {
        return;
      }
      frameId = requestAnimationFrame(() => {
        frameId = 0;
        const nextRoot = getConversationRoot();
        const nextItems = collect();
        const nextSignature = signatureFor(nextItems);
        const sameElements = nextItems.length === lastItems.length &&
          nextItems.every((item, index) => item.element === lastItems[index].element &&
            item.contentElement === lastItems[index].contentElement);
        if (nextRoot === lastRoot && nextSignature === lastSignature && sameElements) {
          return;
        }
        lastRoot = nextRoot;
        lastItems = nextItems;
        lastSignature = nextSignature;
        onChange(nextItems);
      });
    });

    // Watching body survives React replacing main during client-side navigation.
    // Ignore our own UI above, and don't observe generated IDs or style changes.
    observer.observe(document.body, {
      childList: true,
      subtree: true,
      characterData: true,
      attributes: true,
      attributeFilter: [
        "data-message-author-role", "data-message-id", "data-testid",
        "data-chatgpt-search-unit-key", "data-content-search-unit-key",
        "data-chatgpt-search-message-ids", "data-chatgpt-selection-message-id",
        "data-conversation-role", "data-user-message-bubble", "hidden", "aria-hidden"
      ]
    });

    return () => {
      if (frameId) {
        cancelAnimationFrame(frameId);
      }
      observer.disconnect();
    };
  }

  function observeQuestions(onChange) {
    return observeItems(onChange, getQuestionItems, (items) =>
      JSON.stringify(items.map((item) => [item.id, item.title]))
    );
  }

  function observeAssistantMessages(onChange) {
    return observeItems(onChange, getAssistantMessages, (messages) =>
      JSON.stringify(messages.map((message) => [message.id,
        extractHeadings(message.contentElement, message.id)
          .map((heading) => [heading.id, heading.level, heading.text])
      ]))
    );
  }

  global[NAMESPACE] = global[NAMESPACE] || {};
  global[NAMESPACE].domAdapter = {
    extractHeadings,
    getAssistantMessages,
    getQuestionItems,
    getScrollContainer,
    observeAssistantMessages,
    observeQuestions,
    scrollToHeading,
    scrollToQuestion,
    isConversationRoute
  };
})(globalThis);
