import type { Seg } from './ui';
import { scenes, sceneEnd } from './timeline';

export const FOOT_START = 0.35;

const len = (id: string) => {
  const i = scenes.findIndex((s) => s.id === id);
  return sceneEnd(i) - scenes[i].start;
};
export const footDur = (id: string) => len(id) - FOOT_START - 0.05;

export const SEGS: Record<string, Seg[]> = {
  mirror: [
    { src: 'mirror', from: 3.4, to: 6.0, w: 888, h: 1652, keys: [[3.4, 1, 0.5, 0.5], [6.0, 1.05, 0.5, 0.6]], taps: [[4.05, 0.626, 0.717]] },
    { src: 'mirror', from: 8.0, to: 14.6, w: 888, h: 1652, keys: [[8.0, 1, 0.5, 0.4], [9.0, 1.55, 0.38, 0.2], [13.4, 1.55, 0.38, 0.2], [14.6, 1, 0.5, 0.4]], taps: [[8.3, 0.345, 0.214]] },
    { src: 'mirror', from: 15.8, to: 19.5, w: 888, h: 1652, keys: [[15.8, 1, 0.5, 0.5], [19.5, 1.08, 0.5, 0.6]] },
  ],
  notify: [
    { src: 'notify', from: 3.2, to: 6.0, w: 1880, h: 960, keys: [[3.2, 1, 0.5, 0.5], [4.3, 2.0, 0.8, 0.15], [6.0, 2.0, 0.8, 0.15]] },
    { src: 'notify', from: 7.4, to: 13.7, w: 1880, h: 960, keys: [[7.4, 2.0, 0.8, 0.18], [9.8, 2.0, 0.8, 0.28], [13.7, 2.0, 0.8, 0.28]], taps: [[7.8, 0.9, 0.224], [9.6, 0.91, 0.297]] },
    { src: 'notify', from: 16.0, to: 18.2, w: 1880, h: 960, keys: [[16.0, 2.0, 0.8, 0.15], [17.4, 2.0, 0.8, 0.15], [18.2, 1.3, 0.6, 0.3]] },
  ],
  clip: [
    { src: 'clip', from: 3.8, to: 9.0, w: 1840, h: 1350, keys: [[3.8, 1.2, 0.4, 0.4], [4.3, 1.8, 0.25, 0.27], [8.3, 1.8, 0.25, 0.3], [9.0, 1.2, 0.45, 0.45]], taps: [[4.2, 0.287, 0.279, true], [6.0, 0.295, 0.243], [8.0, 0.112, 0.234]] },
    { src: 'clip', from: 11.0, to: 14.6, w: 1840, h: 1350, keys: [[11.0, 1.2, 0.5, 0.45], [11.9, 1.75, 0.74, 0.36], [14.6, 1.85, 0.74, 0.34]], taps: [[11.4, 0.753, 0.59]] },
  ],
  files: [
    { src: 'gallery', from: 1.0, to: 2.6, w: 2380, h: 1510, keys: [[1.0, 1.15, 0.38, 0.5], [2.6, 1.25, 0.38, 0.5]] },
    { src: 'gallery', from: 4.8, to: 11.6, w: 2380, h: 1510, keys: [[4.8, 1.25, 0.25, 0.45], [5.4, 1.0, 0.5, 0.5], [6.0, 1.45, 0.56, 0.47], [11.6, 1.5, 0.56, 0.47]], taps: [[5.1, 0.118, 0.346]] },
    { src: 'drag', from: 4.0, to: 10.6, w: 2620, h: 1510, keys: [[4.0, 1, 0.5, 0.5], [5.2, 1, 0.5, 0.5], [5.8, 1.6, 0.3, 0.92], [8.8, 1.6, 0.3, 0.92], [9.5, 1.6, 0.8, 0.6], [10.6, 1.65, 0.8, 0.6]], taps: [[4.9, 0.84, 0.7]] },
  ],
  camera: [
    { src: 'switch', from: 4.5, to: 12.3, w: 2556, h: 1438, keys: [[4.5, 1, 0.5, 0.5], [5.0, 1.6, 0.56, 0.72], [9.4, 1.6, 0.56, 0.72], [9.9, 1, 0.5, 0.5], [12.3, 1.08, 0.5, 0.5]], taps: [[5.3, 0.52, 0.74], [9.2, 0.575, 0.843]] },
    { src: 'camera', from: 6.5, to: 9.8, w: 1520, h: 1264, keys: [[6.5, 1, 0.5, 0.4], [9.8, 1.12, 0.5, 0.38]] },
  ],
};

/** Scene-relative second at which source time `t` of segment `idx` appears on screen. */
export const footAt = (id: string, idx: number, t: number) => {
  const segs = SEGS[id];
  const total = segs.reduce((a, s) => a + (s.to - s.from), 0);
  const rate = total / footDur(id);
  const before = segs.slice(0, idx).reduce((a, s) => a + (s.to - s.from), 0);
  return FOOT_START + (before + (t - segs[idx].from)) / rate;
};
