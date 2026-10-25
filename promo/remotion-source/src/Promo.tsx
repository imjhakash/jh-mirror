import React from 'react';
import { AbsoluteFill, Audio, interpolate, Sequence, staticFile } from 'remotion';
import { FontGate } from './fonts';
import { footAt, SEGS } from './demos';
import { at, FPS, OVERLAP, scenes, sceneEnd, TOTAL } from './timeline';
import { Background, Captions, SceneIn, Sweep } from './ui';
import { Hook, Intro, Outro, Setup } from './scenes/Story';
import { Camera, Clip, Files, Mirror, Notify } from './scenes/Demos';
import { MenuBar, Pocket } from './scenes/Extra';

const VIEWS: Record<string, React.FC> = { hook: Hook, intro: Intro, setup: Setup, mirror: Mirror, menubar: MenuBar, pocket: Pocket, notify: Notify, clip: Clip, files: Files, camera: Camera, outro: Outro };

const sceneStart = (id: string) => scenes.find((s) => s.id === id)!.start;
const abs = (id: string, t: number) => sceneStart(id) + t;

// voice-over intervals (absolute seconds) for ducking the music
const voSpans = scenes.map((s) => [s.start + s.voOffset, s.start + s.voOffset + s.words[s.words.length - 1].e + 0.1] as const);

const musicVolume = (f: number) => {
  const t = f / FPS;
  let duck = 0;
  for (const [a, b] of voSpans) {
    const d = t < a ? a - t : t > b ? t - b : 0;
    duck = Math.max(duck, interpolate(d, [0, 0.35], [1, 0], { extrapolateRight: 'clamp' }));
  }
  const base = interpolate(duck, [0, 1], [0.34, 0.12]);
  const fadeIn = interpolate(t, [0, 1.2], [0.4, 1], { extrapolateRight: 'clamp' });
  const fadeOut = interpolate(t, [TOTAL / FPS - 3.5, TOTAL / FPS - 0.2], [1, 0], { extrapolateLeft: 'clamp', extrapolateRight: 'clamp' });
  return base * fadeIn * fadeOut;
};

type Fx = { at: number; src: string; vol: number; len?: number };
const fx: Fx[] = [];
const add = (t: number, src: string, vol: number, len = 2) => fx.push({ at: t, src, vol, len });

// transitions
add(0, 'whoosh_soft', 0.3);
scenes.slice(2).forEach((s) => add(s.start - 0.15, 'whoosh', 0.32));
// hook / intro
add(abs('hook', at('hook', 'strangers')), 'glitch', 0.3, 0.9);
add(sceneStart('intro') - 0.7, 'riser', 0.45, 1);
add(abs('intro', 0.25), 'impact', 0.6, 3.5);
// setup
['open', 'turn', 'switch', 'scan', "that's"].forEach((w) => add(abs('setup', at('setup', w) - 0.15), 'pop', 0.28, 1));
add(abs('setup', at('setup', 'all')), 'chime_success', 0.4);
// clicks follow the on-screen tap highlights
Object.entries(SEGS).forEach(([id, segs]) =>
  segs.forEach((sg, i) => (sg.taps ?? []).forEach(([t]) => add(abs(id, footAt(id, i, t)), 'click', 0.4, 0.6))),
);
add(abs('notify', footAt('notify', 0, 4.0)), 'notif', 0.55);
add(abs('notify', footAt('notify', 2, 16.2)), 'notif', 0.35);
add(abs('clip', footAt('clip', 0, 8.3)), 'pop', 0.3, 1);
add(abs('clip', footAt('clip', 1, 12.4)), 'pop', 0.4, 1);
add(abs('files', footAt('files', 1, 5.3)), 'whoosh_soft', 0.22);
add(abs('files', footAt('files', 2, 10.0)), 'pop', 0.35, 1);
add(abs('camera', footAt('camera', 0, 9.5)), 'shutter', 0.55, 1);
// menu bar + pocket mode
add(abs('menubar', at('menubar', 'click')), 'click', 0.5, 0.6);
add(abs('menubar', at('menubar', 'click') + 0.15), 'pop', 0.3, 1);
add(abs('menubar', at('menubar', 'instant') - 0.2), 'whoosh_soft', 0.2);
['files', 'media', 'clipboard', 'camera'].forEach((w) => add(abs('menubar', at('menubar', w) - 0.05), 'pop', 0.15, 1));
add(abs('pocket', at('pocket', 'turn')), 'click', 0.5, 0.6);
add(abs('pocket', at('pocket', 'off') - 0.1), 'whoosh_soft', 0.3);
add(abs('pocket', at('pocket', 'lock')), 'chime_success', 0.3);
// outro
['mirroring', 'notifications', 'clipboard', 'files', 'camera'].forEach((w) => add(abs('outro', at('outro', w) - 0.05), 'pop', 0.22, 1));
add(abs('outro', at('outro', 'jh') - 0.1), 'impact', 0.65, 4);

export const Promo: React.FC = () => (
  <FontGate>
    <AbsoluteFill>
      <Background />
      {scenes.map((s, i) => {
        const View = VIEWS[s.id];
        const from = Math.round(s.start * FPS);
        const end = i + 1 < scenes.length ? sceneEnd(i) + OVERLAP : TOTAL / FPS;
        return (
          <Sequence key={s.id} from={from} durationInFrames={Math.round(end * FPS) - from} name={s.id}>
            <SceneIn first={i === 0}>
              <View />
            </SceneIn>
            {i > 0 && <Sweep />}
          </Sequence>
        );
      })}
      {/* captions sit above scenes so they never blur in transitions */}
      {scenes
        .filter((s) => s.captions)
        .map((s) => (
          <Sequence key={`cap-${s.id}`} from={Math.round(s.start * FPS)} durationInFrames={Math.round((s.voOffset + s.words[s.words.length - 1].e + 0.6) * FPS)} layout="none">
            <Captions words={s.words} offset={s.voOffset} />
          </Sequence>
        ))}
      {/* audio */}
      <Audio src={staticFile('sfx/music.mp3')} volume={musicVolume} />
      {scenes.map((s) => (
        <Sequence key={`vo-${s.id}`} from={Math.round((s.start + s.voOffset) * FPS)} layout="none">
          <Audio src={staticFile(`vo/${s.vo}.mp3`)} volume={1} />
        </Sequence>
      ))}
      {fx.map((x, i) => (
        <Sequence key={`fx-${i}`} from={Math.max(0, Math.round(x.at * FPS))} durationInFrames={Math.round((x.len ?? 2) * FPS)} layout="none">
          <Audio src={staticFile(`sfx/${x.src}.mp3`)} volume={x.vol} />
        </Sequence>
      ))}
    </AbsoluteFill>
  </FontGate>
);
