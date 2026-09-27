(function initAudioVisualizer(global) {
  const NAMESPACE = "__CHATGPT_HELPER__";
  const state = (global[NAMESPACE] = global[NAMESPACE] || {});
  if (state.audioVisualizerInitialized) return;
  state.audioVisualizerInitialized = true;

  const root = document.documentElement;
  const reduceMotion = global.matchMedia?.("(prefers-reduced-motion: reduce)");
  const RAILS = [
    { selector: ".chatgpt-helper-message-outline__rail", channel: 0 },
    { selector: ".chatgpt-helper-sidebar__rail", channel: 1 }
  ];
  const RAIL_SELECTOR = RAILS.map(({ selector }) => selector).join(", ");
  const CHANNEL_COUNT = 2;
  const BAND_COUNT = 24;
  const STALE_MS = 160;
  const ATTACK_MS = 12;
  const RELEASE_MS = 65;
  const VISUAL_GAIN_MAX = -Math.expm1(-2);
  const targetChannels = Array.from({ length: CHANNEL_COUNT }, () => new Float64Array(BAND_COUNT));
  const currentChannels = Array.from({ length: CHANNEL_COUNT }, () => new Float64Array(BAND_COUNT));
  const squaredBandIntegrals = Array.from(
    { length: CHANNEL_COUNT },
    () => new Float64Array(BAND_COUNT + 1)
  );
  let active = false;
  let lastMessageAt = -Infinity;
  let lastRenderAt = null;
  let frameId = 0;

  function unit(value) {
    return Math.min(1, Math.max(0, Number(value) || 0));
  }

  function clearPresentation() {
    document.querySelectorAll(RAIL_SELECTOR).forEach((rail) => {
      for (const item of rail.children) {
        item.style.removeProperty("--conversation-trail-bar-level");
      }
    });
  }

  function stopMotion() {
    cancelAnimationFrame(frameId);
    frameId = 0;
    lastRenderAt = null;
    currentChannels.forEach(bands => bands.fill(0));
    clearPresentation();
  }

  function follow(current, target, elapsed) {
    const duration = target > current ? ATTACK_MS : RELEASE_MS;
    const next = current + (target - current) * -Math.expm1(-elapsed / duration);
    return Math.abs(next - target) < 0.0005 ? target : next;
  }

  function shapeSpectrum(incoming, target) {
    for (let index = 0; index < BAND_COUNT; index += 1) {
      const previous = unit(incoming[Math.max(0, index - 1)]);
      const current = unit(incoming[index]);
      const next = unit(incoming[Math.min(BAND_COUNT - 1, index + 1)]);
      target[index] = previous * 0.2 + current * 0.6 + next * 0.2;
    }
  }

  function advance(timestamp) {
    const elapsed = lastRenderAt === null ? 0 : Math.max(0, timestamp - lastRenderAt);
    lastRenderAt = timestamp;
    const stale = timestamp - lastMessageAt >= STALE_MS;
    let settled = true;
    for (let channel = 0; channel < CHANNEL_COUNT; channel += 1) {
      for (let index = 0; index < BAND_COUNT; index += 1) {
        const target = stale ? 0 : targetChannels[channel][index];
        currentChannels[channel][index] = follow(currentChannels[channel][index], target, elapsed);
        settled = settled && currentChannels[channel][index] === target;
      }
    }
    return settled;
  }

  function squaredIntegralAt(integral, bands, position) {
    const index = Math.floor(position);
    const magnitude = bands[index] || 0;
    return integral[index] + (position - index) * magnitude * magnitude;
  }

  function resample(bands, integral, marker, markerCount) {
    if (markerCount < BAND_COUNT) {
      const start = marker * BAND_COUNT / markerCount;
      const end = (marker + 1) * BAND_COUNT / markerCount;
      const meanSquare = (squaredIntegralAt(integral, bands, end)
        - squaredIntegralAt(integral, bands, start)) / (end - start);
      return Math.sqrt(meanSquare);
    }
    const position = marker * (BAND_COUNT - 1) / (markerCount - 1);
    const lower = Math.floor(position);
    const upper = Math.min(BAND_COUNT - 1, lower + 1);
    return bands[lower] + (bands[upper] - bands[lower]) * (position - lower);
  }

  function visualGain(energy) {
    return -Math.expm1(-2 * unit(energy)) / VISUAL_GAIN_MAX;
  }

  function render(timestamp) {
    frameId = 0;
    const settled = advance(timestamp);
    for (let channel = 0; channel < CHANNEL_COUNT; channel += 1) {
      const integral = squaredBandIntegrals[channel];
      const bands = currentChannels[channel];
      integral[0] = 0;
      for (let index = 0; index < BAND_COUNT; index += 1) {
        integral[index + 1] = integral[index] + bands[index] * bands[index];
      }
    }

    RAILS.forEach(({ selector, channel }) => {
      const bands = currentChannels[channel];
      const integral = squaredBandIntegrals[channel];
      document.querySelectorAll(selector).forEach((rail) => {
        const items = rail.children;
        for (let index = 0; index < items.length; index += 1) {
          const energy = resample(bands, integral, index, items.length);
          items[index].style.setProperty(
            "--conversation-trail-bar-level",
            visualGain(energy).toFixed(3)
          );
        }
      });
    });

    const silent = currentChannels.every(bands => bands.every(value => value === 0));
    if (settled && silent) clearPresentation();
    if (!settled || timestamp - lastMessageAt < STALE_MS) {
      frameId = requestAnimationFrame(render);
    } else {
      lastRenderAt = null;
    }
  }

  function applyLevel(payload = {}) {
    const now = performance.now();
    // Finish the previous target up to this arrival so display refresh rate cannot change timing.
    advance(now);
    active = Boolean(payload.active);
    const incomingChannels = active && Array.isArray(payload.channels) ? payload.channels : [];
    for (let channel = 0; channel < CHANNEL_COUNT; channel += 1) {
      const incoming = Array.isArray(incomingChannels[channel]?.bands)
        ? incomingChannels[channel].bands
        : [];
      shapeSpectrum(incoming, targetChannels[channel]);
    }
    const age = Number.isFinite(payload.timestamp) ? Math.max(0, Date.now() - payload.timestamp * 1000) : 0;
    lastMessageAt = now - age;

    if (!active) {
      root.removeAttribute("data-conversation-trail-audio");
      stopMotion();
      return;
    }
    root.dataset.conversationTrailAudio = "active";
    if (reduceMotion?.matches) {
      stopMotion();
      return;
    }
    if (!frameId) frameId = requestAnimationFrame(render);
  }

  reduceMotion?.addEventListener("change", () => {
    stopMotion();
    if (active && !reduceMotion.matches) {
      lastRenderAt = performance.now();
      frameId = requestAnimationFrame(render);
    }
  });

  global.chrome?.runtime?.onMessage?.addListener((message) => {
    if (message?.type === "conversation-trail:audio-level") applyLevel(message);
  });
  if (global.chrome?.runtime?.sendMessage) {
    global.chrome.runtime.sendMessage({
      target: "conversation-trail-background",
      type: "audio-visualizer:get-state"
    }).then(applyLevel).catch(() => {});
  }

  state.audioVisualizer = {
    applyLevel,
    getState() {
      return {
        active,
        channels: currentChannels.map(bands => ({ bands: Array.from(bands) }))
      };
    }
  };
})(globalThis);
