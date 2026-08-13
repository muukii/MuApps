browser.runtime.onMessage.addListener((message) => {
  if (message?.type === "safari-reactor:ping") {
    return Promise.resolve({ ok: true });
  }

  return Promise.resolve({ ok: false });
});
