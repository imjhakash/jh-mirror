import hook from '../public/vo/01_hook.json';
import intro from '../public/vo/02_intro.json';
import setup from '../public/vo/03_setup.json';
import mirror from '../public/vo/04_mirror.json';
import menubar from '../public/vo/04b_menubar.json';
import pocket from '../public/vo/04c_pocket.json';
import notify from '../public/vo/05_notify.json';
import clip from '../public/vo/06_clip.json';
import files from '../public/vo/07_files.json';
import camera from '../public/vo/08_camera.json';
import outro from '../public/vo/09_outro.json';

export const FPS = 30;
export const TOTAL = 109 * FPS;
export const OVERLAP = 0.5; // seconds a scene stays under the next one's entrance

export type Word = { w: string; s: number; e: number };

export type SceneDef = {
  id: string;
  start: number; // seconds
  vo: string; // file stem in public/vo
  voOffset: number; // seconds after scene start
  words: Word[];
  captions: boolean;
};

const defs: Omit<SceneDef, 'voOffset'>[] = [
  { id: 'hook', start: 0, vo: '01_hook', words: hook, captions: false },
  { id: 'intro', start: 5.5, vo: '02_intro', words: intro, captions: false },
  { id: 'setup', start: 11.2, vo: '03_setup', words: setup, captions: true },
  { id: 'mirror', start: 27.1, vo: '04_mirror', words: mirror, captions: true },
  { id: 'menubar', start: 36.9, vo: '04b_menubar', words: menubar, captions: true },
  { id: 'pocket', start: 47.6, vo: '04c_pocket', words: pocket, captions: true },
  { id: 'notify', start: 55.9, vo: '05_notify', words: notify, captions: true },
  { id: 'clip', start: 64.5, vo: '06_clip', words: clip, captions: true },
  { id: 'files', start: 71.3, vo: '07_files', words: files, captions: true },
  { id: 'camera', start: 80.9, vo: '08_camera', words: camera, captions: true },
  { id: 'outro', start: 91.1, vo: '09_outro', words: outro, captions: false },
];

export const scenes: SceneDef[] = defs.map((d) => ({ ...d, voOffset: d.id === 'intro' ? 0.4 : 0.3 }));

export const sceneEnd = (i: number) => (i + 1 < scenes.length ? scenes[i + 1].start : TOTAL / FPS);

/** Scene-relative seconds at which the n-th occurrence of a word (prefix match) is spoken. */
export const at = (id: string, word: string, nth = 0): number => {
  const s = scenes.find((x) => x.id === id)!;
  const hits = s.words.filter((w) => w.w.toLowerCase().replace(/[^a-z0-9']/g, '').startsWith(word.toLowerCase()));
  const w = hits[nth];
  if (!w) throw new Error(`word ${word} not in ${id}`);
  return s.voOffset + w.s;
};
