(() => {
  if (window.__safariReactorInstalled) {
    return;
  }

  window.__safariReactorInstalled = true;

  const state = {
    enabled: true,
    cueText: "",
    cueStartedAt: 0,
    currentCueId: undefined,
    nextCueId: 1,
    speedIndex: 1,
    speeds: [0.75, 1, 1.25, 1.5],
    transcript: [],
    transcriptLimit: 80,
  };

  const selectors = {
    playerRoot: [
      "[data-uia='watch-video']",
      ".watch-video",
      "[data-uia='player']",
    ],
    video: [
      "[data-uia='player'] video",
      ".watch-video video",
      "video[src^='blob:https://www.netflix.com']",
      "video",
    ],
    subtitle: [
      "[data-sr-subtitle]",
      ".player-timedtext .player-timedtext-text-container",
      "[data-uia='player-timedtext'] .player-timedtext-text-container",
      "[data-uia='player-timedtext']",
      ".player-timedtext",
      ".timedtext",
      "[class*='player-timedtext']",
      "[class*='timedtext']",
    ],
  };

  const root = document.createElement("section");
  root.id = "safari-reactor-root";
  root.setAttribute("aria-label", "Safari Reactor");
  root.innerHTML = `
    <div class="sr-shell">
      <div class="sr-header">
        <span class="sr-title">Safari Reactor</span>
        <span class="sr-status" data-sr-status>Waiting for subtitles</span>
      </div>
      <div class="sr-cue" data-sr-cue>No subtitle detected yet.</div>
      <div class="sr-transcript" aria-label="Subtitle transcript">
        <div class="sr-transcript-header">
          <span>Transcript</span>
          <span data-sr-transcript-count>0 lines</span>
        </div>
        <ol class="sr-transcript-list" data-sr-transcript-list></ol>
      </div>
      <div class="sr-tools">
        <button type="button" data-sr-action="back">Back 5s</button>
        <button type="button" data-sr-action="play">Play</button>
        <button type="button" data-sr-action="repeat">Repeat</button>
        <button type="button" data-sr-action="speed">1.0x</button>
      </div>
    </div>
  `;

  document.documentElement.append(root);

  const cueElement = root.querySelector("[data-sr-cue]");
  const statusElement = root.querySelector("[data-sr-status]");
  const transcriptCountElement = root.querySelector("[data-sr-transcript-count]");
  const transcriptListElement = root.querySelector("[data-sr-transcript-list]");
  const playButton = root.querySelector("[data-sr-action='play']");
  const speedButton = root.querySelector("[data-sr-action='speed']");

  function firstElement(selectorList, scope = document) {
    for (const selector of selectorList) {
      const element = scope.querySelector(selector);
      if (element) {
        return element;
      }
    }

    return undefined;
  }

  function video() {
    return firstElement(selectors.video);
  }

  function textLines(element) {
    return (element?.innerText || element?.textContent || "")
      .split(/\n+/)
      .map((line) => line.replace(/\s+/g, " ").trim())
      .filter((line) => line.length > 0);
  }

  function visibleText(element) {
    return textLines(element).join("\n");
  }

  function isRendered(element) {
    const style = window.getComputedStyle(element);
    return (
      style.display !== "none" &&
      style.visibility !== "hidden" &&
      style.opacity !== "0" &&
      element.getClientRects().length > 0
    );
  }

  function topLevelElements(elements) {
    return elements.filter(
      (element) => !elements.some((candidate) => candidate !== element && candidate.contains(element))
    );
  }

  function combinedVisibleText(elements) {
    const lines = [];

    for (const element of elements) {
      for (const line of textLines(element)) {
        lines.push(line);
      }
    }

    return lines.join("\n");
  }

  function formatTime(seconds) {
    if (!Number.isFinite(seconds)) {
      return "0:00";
    }

    const safeSeconds = Math.max(0, Math.floor(seconds));
    const minutes = Math.floor(safeSeconds / 60);
    const remainingSeconds = String(safeSeconds % 60).padStart(2, "0");
    return `${minutes}:${remainingSeconds}`;
  }

  function subtitleElement() {
    const scope = firstElement(selectors.playerRoot) || document;

    for (const selector of selectors.subtitle) {
      const elements = topLevelElements(Array.from(scope.querySelectorAll(selector)));
      const textElements = elements.filter((element) => visibleText(element).length > 0);
      const renderedTextElements = textElements.filter(isRendered);
      const candidates = renderedTextElements.length > 0 ? renderedTextElements : textElements;
      const text = combinedVisibleText(candidates);

      if (text.length > 0) {
        return {
          element: candidates[0],
          selector,
          text,
        };
      }
    }

    return undefined;
  }

  function cueNearTime(cue, startTime) {
    return Math.abs(cue.startTime - startTime) < 3;
  }

  function activeCue() {
    return state.transcript.find((cue) => cue.id === state.currentCueId);
  }

  function renderTranscript() {
    transcriptCountElement.textContent = `${state.transcript.length} ${
      state.transcript.length === 1 ? "line" : "lines"
    }`;

    transcriptListElement.textContent = "";

    for (const cue of state.transcript) {
      const item = document.createElement("li");
      const button = document.createElement("button");
      const time = document.createElement("span");
      const text = document.createElement("span");

      button.type = "button";
      button.dataset.srCueId = cue.id;
      button.className = "sr-transcript-item";
      button.setAttribute("aria-current", cue.id === state.currentCueId ? "true" : "false");

      time.className = "sr-transcript-time";
      time.textContent = formatTime(cue.startTime);

      text.className = "sr-transcript-text";
      text.textContent = cue.text;

      button.append(time, text);
      item.append(button);
      transcriptListElement.append(item);
    }

    const activeItem = transcriptListElement.querySelector("[aria-current='true']");
    activeItem?.scrollIntoView({ block: "nearest" });
  }

  function recordCue(text, startTime) {
    const existingCue = state.transcript.find(
      (cue) => cue.text === text && cueNearTime(cue, startTime)
    );

    if (existingCue) {
      state.currentCueId = existingCue.id;
      renderTranscript();
      return existingCue;
    }

    const cue = {
      id: `cue-${state.nextCueId}`,
      startTime,
      text,
    };

    state.nextCueId += 1;
    state.transcript.push(cue);

    if (state.transcript.length > state.transcriptLimit) {
      state.transcript.shift();
    }

    state.currentCueId = cue.id;
    renderTranscript();
    return cue;
  }

  function updateCue() {
    if (!state.enabled) {
      return;
    }

    const match = subtitleElement();
    const nextText = match?.text || "";

    if (nextText && nextText !== state.cueText) {
      const currentVideo = video();
      const cue = recordCue(nextText, currentVideo?.currentTime || 0);
      state.cueText = nextText;
      state.cueStartedAt = cue.startTime;
      cueElement.textContent = nextText;
      statusElement.textContent = "Subtitle detected";
      root.dataset.source = match.selector;
      root.dataset.ready = "true";
      return;
    }

    if (!nextText && !state.cueText) {
      statusElement.textContent = "Waiting for subtitles";
      root.dataset.ready = "false";
    }
  }

  function refreshPlaybackState() {
    const currentVideo = video();
    if (!currentVideo) {
      playButton.textContent = "Play";
      return;
    }

    playButton.textContent = currentVideo.paused ? "Play" : "Pause";
    speedButton.textContent = `${currentVideo.playbackRate.toFixed(2).replace(/\\.00$/, ".0")}x`;
  }

  function loadSettings() {
    state.enabled = true;
    root.hidden = false;
  }

  function wireControls() {
    root.addEventListener("click", async (event) => {
      const button = event.target.closest("[data-sr-action]");
      if (!button) {
        return;
      }

      const currentVideo = video();
      const action = button.dataset.srAction;

      if (action === "back" && currentVideo) {
        currentVideo.currentTime = Math.max(0, currentVideo.currentTime - 5);
      }

      if (action === "play" && currentVideo) {
        if (currentVideo.paused) {
          await currentVideo.play();
        } else {
          currentVideo.pause();
        }
      }

      if (action === "repeat" && currentVideo) {
        const cue = activeCue();
        currentVideo.currentTime = Math.max(0, (cue?.startTime || state.cueStartedAt) - 0.2);
        await currentVideo.play();
      }

      if (action === "speed" && currentVideo) {
        state.speedIndex = (state.speedIndex + 1) % state.speeds.length;
        currentVideo.playbackRate = state.speeds[state.speedIndex];
      }

      refreshPlaybackState();
    });

    root.addEventListener("click", (event) => {
      const transcriptButton = event.target.closest("[data-sr-cue-id]");
      if (!transcriptButton) {
        return;
      }

      const cue = state.transcript.find((entry) => entry.id === transcriptButton.dataset.srCueId);
      const currentVideo = video();
      if (!cue || !currentVideo) {
        return;
      }

      state.currentCueId = cue.id;
      state.cueText = cue.text;
      state.cueStartedAt = cue.startTime;
      cueElement.textContent = cue.text;
      currentVideo.currentTime = Math.max(0, cue.startTime - 0.2);
      renderTranscript();
      refreshPlaybackState();
    });
  }

  function observePage() {
    const observer = new MutationObserver(updateCue);
    observer.observe(document.body, {
      childList: true,
      subtree: true,
      characterData: true,
    });

    window.setInterval(() => {
      updateCue();
      refreshPlaybackState();
    }, 750);
  }

  window.SafariReactor = {
    updateCue,
    getState: () => ({
      ...state,
      transcript: state.transcript.map((cue) => ({ ...cue })),
    }),
  };

  loadSettings();
  wireControls();
  observePage();
  updateCue();
  refreshPlaybackState();
})();
