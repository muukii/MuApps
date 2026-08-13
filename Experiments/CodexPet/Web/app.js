const atlas = {
  columns: 8,
  rows: 9,
  cellWidth: 192,
  cellHeight: 208,
};

const pets = {
  "mofu-monkey": {
    name: "Mofu Monkey",
    shortName: "Mofu",
    src: "./assets/mofu-monkey-spritesheet.png",
    rendering: "soft",
  },
  "mofu-monkey-dot": {
    name: "Mofu Monkey Dot",
    shortName: "Dot",
    src: "./assets/mofu-monkey-dot-spritesheet.png",
    rendering: "pixel",
  },
};

const motions = {
  idle: { title: "Idle", row: 0, fps: 6, staticFrame: 0 },
  "running-right": { title: "Right", row: 1, fps: 12, staticFrame: 2 },
  "running-left": { title: "Left", row: 2, fps: 12, staticFrame: 2 },
  waving: { title: "Wave", row: 3, fps: 10, staticFrame: 1 },
  jumping: { title: "Jump", row: 4, fps: 10, staticFrame: 2 },
  failed: { title: "Failed", row: 5, fps: 8, staticFrame: 3 },
  waiting: { title: "Wait", row: 6, fps: 7, staticFrame: 2 },
  running: { title: "Work", row: 7, fps: 12, staticFrame: 4 },
  review: { title: "Review", row: 8, fps: 6, staticFrame: 3 },
};

const state = {
  petId: "mofu-monkey",
  motionId: "idle",
  speed: 1,
  scale: 1.34,
  startedAt: performance.now(),
};

const spriteSlot = document.querySelector("#sprite-slot");
const petFrame = document.querySelector("#pet-frame");
const petCaption = document.querySelector("#pet-caption");
const frameStatus = document.querySelector("#frame-status");
const speedInput = document.querySelector("#speed");
const speedOutput = document.querySelector("#speed-output");

const loadedPets = new Map();

async function loadPet(petId) {
  if (loadedPets.has(petId)) {
    return loadedPets.get(petId);
  }

  const pet = pets[petId];
  const image = new Image();
  image.src = pet.src;
  await image.decode();

  const framesByMotion = new Map();
  for (const [motionId, motion] of Object.entries(motions)) {
    framesByMotion.set(motionId, visibleColumns(image, motion.row));
  }

  const loaded = { ...pet, image, framesByMotion };
  loadedPets.set(petId, loaded);
  return loaded;
}

function visibleColumns(image, row) {
  const canvas = document.createElement("canvas");
  canvas.width = atlas.cellWidth;
  canvas.height = atlas.cellHeight;
  const context = canvas.getContext("2d", { willReadFrequently: true });
  const frames = [];

  for (let column = 0; column < atlas.columns; column += 1) {
    context.clearRect(0, 0, atlas.cellWidth, atlas.cellHeight);
    context.drawImage(
      image,
      column * atlas.cellWidth,
      row * atlas.cellHeight,
      atlas.cellWidth,
      atlas.cellHeight,
      0,
      0,
      atlas.cellWidth,
      atlas.cellHeight
    );

    const data = context.getImageData(0, 0, atlas.cellWidth, atlas.cellHeight).data;
    let hasVisiblePixel = false;

    for (let index = 3; index < data.length; index += 4) {
      if (data[index] > 4) {
        hasVisiblePixel = true;
        break;
      }
    }

    if (hasVisiblePixel) {
      frames.push(column);
    }
  }

  return frames.length > 0 ? frames : [0];
}

function updateSelectedButtons() {
  document.querySelectorAll("[data-pet]").forEach((button) => {
    button.classList.toggle("is-selected", button.dataset.pet === state.petId);
  });

  document.querySelectorAll("[data-motion]").forEach((button) => {
    button.classList.toggle("is-selected", button.dataset.motion === state.motionId);
  });
}

function updateSpeed(value) {
  state.speed = Number(value);
  speedOutput.value = `${state.speed.toFixed(2)}x`;
}

function frameColumn(loadedPet, motion, elapsedSeconds) {
  const frames = loadedPet.framesByMotion.get(state.motionId) ?? [motion.staticFrame];
  const frameIndex = Math.floor(elapsedSeconds * motion.fps * state.speed) % frames.length;
  return frames[frameIndex];
}

function stageTransform(motion, elapsedSeconds) {
  const travel = Math.max(0, document.querySelector(".stage").clientWidth - atlas.cellWidth * state.scale - 48);
  const phase = (elapsedSeconds * 0.16 * state.speed) % 1;

  switch (state.motionId) {
    case "running-right":
      return `translate(${(-travel / 2) + travel * phase}px, 14px)`;
    case "running-left":
      return `translate(${(travel / 2) - travel * phase}px, 14px)`;
    case "jumping": {
      const jump = Math.abs(Math.sin(elapsedSeconds * 3.6 * state.speed));
      return `translate(0, ${-92 * jump}px)`;
    }
    case "failed":
      return "translate(0, 22px)";
    default: {
      const bob = Math.sin(elapsedSeconds * 2.2 * state.speed) * 5;
      return `translate(0, ${bob}px)`;
    }
  }
}

function renderFrame(loadedPet, motion, column, elapsedSeconds) {
  const width = atlas.cellWidth * state.scale;
  const height = atlas.cellHeight * state.scale;
  const sheetWidth = atlas.columns * atlas.cellWidth * state.scale;
  const sheetHeight = atlas.rows * atlas.cellHeight * state.scale;

  spriteSlot.style.width = `${width}px`;
  spriteSlot.style.height = `${height}px`;
  spriteSlot.style.transform = stageTransform(motion, elapsedSeconds);

  petFrame.style.width = `${width}px`;
  petFrame.style.height = `${height}px`;
  petFrame.style.backgroundImage = `url("${loadedPet.src}")`;
  petFrame.style.backgroundSize = `${sheetWidth}px ${sheetHeight}px`;
  petFrame.style.backgroundPosition = `-${column * atlas.cellWidth * state.scale}px -${motion.row * atlas.cellHeight * state.scale}px`;
  petFrame.classList.toggle("is-pixel", loadedPet.rendering === "pixel");
  petFrame.setAttribute("aria-label", loadedPet.name);

  petCaption.textContent = loadedPet.name;
  frameStatus.textContent = `${motion.title} ${column + 1}`;
}

async function animate(now) {
  const loadedPet = await loadPet(state.petId);
  const motion = motions[state.motionId];
  const elapsedSeconds = (now - state.startedAt) / 1000;
  const column = frameColumn(loadedPet, motion, elapsedSeconds);
  renderFrame(loadedPet, motion, column, elapsedSeconds);
  requestAnimationFrame(animate);
}

document.querySelectorAll("[data-pet]").forEach((button) => {
  button.addEventListener("click", () => {
    state.petId = button.dataset.pet;
    state.startedAt = performance.now();
    updateSelectedButtons();
  });
});

document.querySelectorAll("[data-motion]").forEach((button) => {
  button.addEventListener("click", () => {
    state.motionId = button.dataset.motion;
    state.startedAt = performance.now();
    updateSelectedButtons();
  });
});

speedInput.addEventListener("input", (event) => {
  updateSpeed(event.target.value);
});

updateSelectedButtons();
updateSpeed(speedInput.value);
requestAnimationFrame(animate);
