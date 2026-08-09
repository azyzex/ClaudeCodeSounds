// The only job here is making a noise. A service worker cannot, so Chrome wants
// an offscreen document, and this is the smallest one that works.
chrome.runtime.onMessage.addListener((msg) => {
  if (!msg || msg.type !== 'earshot-play') return;
  try {
    const ctx = new AudioContext();
    for (const offset of msg.pattern) {
      const t = ctx.currentTime + offset / 1000;
      const osc = ctx.createOscillator();
      const gain = ctx.createGain();
      osc.frequency.value = msg.freq;
      // A short exponential decay, so it reads as a chime rather than a beep.
      gain.gain.setValueAtTime(0.0001, t);
      gain.gain.exponentialRampToValueAtTime(0.25, t + 0.01);
      gain.gain.exponentialRampToValueAtTime(0.0001, t + 0.35);
      osc.connect(gain).connect(ctx.destination);
      osc.start(t);
      osc.stop(t + 0.4);
    }
    setTimeout(() => ctx.close(), 1500);
  } catch {
    /* no audio device, or autoplay refused */
  }
});
