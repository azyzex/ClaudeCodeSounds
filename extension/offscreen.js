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
      osc.type = msg.wave || 'sine';
      osc.frequency.value = msg.freq;
      // A short exponential decay, so it reads as a chime rather than a beep.
      gain.gain.setValueAtTime(0.0001, t);
      // Volume arrives as 0 to 100. Squared on the way in, because loudness is
      // heard closer to a curve than a straight line: half way up a linear
      // slider does not sound half as loud.
      const level = Math.max(0.0002, ((msg.volume ?? 60) / 100) ** 2 * 0.6);
      gain.gain.exponentialRampToValueAtTime(level, t + 0.01);
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
