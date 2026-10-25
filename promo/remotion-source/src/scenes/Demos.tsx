import React from 'react';
import { AbsoluteFill, interpolate, useCurrentFrame } from 'remotion';
import { FOOT_START, footAt, footDur, SEGS } from '../demos';
import { at } from '../timeline';
import { C, Chip, clamp, FONT, Footage, GradText, Keycap, Kicker, Title, useAppear, useSpring } from '../ui';

const WIDE = { x: 730, y: 120, w: 1140, h: 730 };

const Col: React.FC<{ children: React.ReactNode; top?: number; width?: number }> = ({ children, top = 250, width = 570 }) => (
  <div style={{ position: 'absolute', left: 120, top, width, display: 'flex', flexDirection: 'column', gap: 26, fontFamily: FONT }}>{children}</div>
);
const Chips: React.FC<{ children: React.ReactNode }> = ({ children }) => (
  <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'flex-start', gap: 14, marginTop: 14 }}>{children}</div>
);

// ---------------------------------------------------------------- MIRROR
export const Mirror: React.FC = () => {
  const f = useCurrentFrame();
  const typeT = footAt('mirror', 1, 10.0);
  const typeEnd = footAt('mirror', 1, 13.6);
  const kb = interpolate(f / 30, [typeT - 0.2, typeT + 0.2, typeEnd, typeEnd + 0.4], [0, 1, 1, 0], clamp);
  return (
    <AbsoluteFill>
      <Col top={240} width={880}>
        <Kicker n="01" text="SCREEN MIRRORING" />
        <Title lines={['Your Android,', <GradText key="d">on your desktop.</GradText>]} />
        <Chips>
          <Chip t={at('mirror', 'open')} icon="mirror">
            Open any app
          </Chip>
          <Chip t={at('mirror', 'scroll')} icon="cursor">
            Click &amp; scroll with your mouse
          </Chip>
          <Chip t={at('mirror', 'type')} icon="keyboard">
            Type with your Mac keyboard
          </Chip>
          <Chip t={at('mirror', 'wireless')} icon="wifi" accent>
            Wireless · Real-time
          </Chip>
        </Chips>
      </Col>
      <Footage segs={SEGS.mirror} start={FOOT_START} dur={footDur('mirror')} box={{ x: 1080, y: 70, w: 640, h: 900 }} device="none" radius={30} />
      {/* keyboard callout while typing */}
      <div
        style={{
          position: 'absolute',
          left: 1590,
          top: 560,
          opacity: kb,
          transform: `scale(${0.7 + 0.3 * kb}) rotate(-4deg)`,
          display: 'flex',
          gap: 10,
        }}
      >
        <Keycap label="A" size={74} />
        <Keycap label="⌘" size={74} />
      </div>
    </AbsoluteFill>
  );
};

// ---------------------------------------------------------------- NOTIFY
export const Notify: React.FC = () => {
  const replyT = footAt('notify', 1, 10.6);
  const doneT = footAt('notify', 2, 16.0);
  return (
    <AbsoluteFill>
      <Col top={250}>
        <Kicker n="04" text="NOTIFICATIONS" />
        <Title lines={['Every alert,', <GradText key="i">instantly.</GradText>]} size={74} />
        <Chips>
          <Chip t={at('notify', 'arrive')} icon="bell">
            Arrives in real time
          </Chip>
          <Chip t={Math.min(at('notify', 'reply'), replyT)} icon="keyboard">
            Reply right from your Mac
          </Chip>
          <Chip t={at('notify', 'dismiss')} icon="check">
            Dismiss · Mark as read
          </Chip>
          <Chip t={at('notify', 'click')} icon="cursor">
            Click to open on phone
          </Chip>
          <Chip t={doneT} icon="phone" accent>
            Reply delivered to your phone
          </Chip>
        </Chips>
      </Col>
      <Footage segs={SEGS.notify} start={FOOT_START} dur={footDur('notify')} box={WIDE} />
    </AbsoluteFill>
  );
};

// ---------------------------------------------------------------- CLIPBOARD
export const Clip: React.FC = () => {
  const f = useCurrentFrame();
  const copyT = footAt('clip', 0, 8.3);
  const pasteT = footAt('clip', 1, 12.4);
  const cmd = useSpring(pasteT - 0.35, 10);
  const press = interpolate(f / 30, [pasteT - 0.05, pasteT + 0.05, pasteT + 0.2], [0, 1, 0], clamp);
  const keyOut = interpolate(f / 30, [pasteT + 1.4, pasteT + 1.8], [1, 0], clamp);
  const copied = useSpring(copyT, 12);
  const copiedOut = interpolate(f / 30, [copyT + 1.2, copyT + 1.5], [1, 0], clamp);
  return (
    <AbsoluteFill>
      <Col top={250}>
        <Kicker n="05" text="UNIVERSAL CLIPBOARD" />
        <Title lines={[<span key="a">Copy on <span style={{ color: C.android }}>Android.</span></span>, <GradText key="p">Paste on Mac.</GradText>]} size={64} />
        <Chips>
          <Chip t={at('clip', 'copy')} icon="phone">
            Copy text or images on your phone
          </Chip>
          <Chip t={at('clip', 'command')} icon="keyboard">
            Press ⌘V on your Mac
          </Chip>
          <Chip t={at('clip', "it's")} icon="bolt" accent>
            Automatic. No extra taps.
          </Chip>
        </Chips>
      </Col>
      <Footage segs={SEGS.clip} start={FOOT_START} dur={footDur('clip')} box={WIDE} />
      {/* copied badge */}
      <div
        style={{
          position: 'absolute',
          left: 860,
          top: 760,
          opacity: copied * copiedOut,
          transform: `scale(${0.7 + 0.3 * copied})`,
          padding: '14px 26px',
          borderRadius: 999,
          background: 'linear-gradient(100deg,#8b5cf6,#22d3ee)',
          fontFamily: FONT,
          fontWeight: 700,
          fontSize: 28,
          color: '#fff',
          boxShadow: '0 20px 50px rgba(79,124,255,0.5)',
        }}
      >
        Copied on Android → ready on Mac
      </div>
      {/* ⌘V keycaps */}
      <div
        style={{
          position: 'absolute',
          left: 1560,
          top: 640,
          display: 'flex',
          gap: 16,
          opacity: Math.min(1, cmd * 1.4) * keyOut,
          transform: `scale(${0.6 + 0.4 * cmd}) translateY(${press * 8}px)`,
        }}
      >
        <Keycap label="⌘" size={110} />
        <Keycap label="V" size={110} />
      </div>
    </AbsoluteFill>
  );
};

// ---------------------------------------------------------------- FILES
export const Files: React.FC = () => {
  const dragT = footAt('files', 2, 7.2);
  return (
    <AbsoluteFill>
      <Col top={240}>
        <Kicker n="06" text="GALLERY & FILES" />
        <Title lines={['Every photo.', <GradText key="f">Every file.</GradText>]} size={74} />
        <Chips>
          <Chip t={at('files', 'gallery')} icon="photo">
            Browse your whole gallery
          </Chip>
          <Chip t={at('files', 'preview')} icon="mirror">
            Fast full-screen preview
          </Chip>
          <Chip t={Math.min(at('files', 'drag'), dragT)} icon="cursor">
            Drag straight into Finder
          </Chip>
          <Chip t={at('files', 'drop')} icon="folder" accent>
            Drop files back to your phone
          </Chip>
        </Chips>
      </Col>
      <Footage segs={SEGS.files} start={FOOT_START} dur={footDur('files')} box={WIDE} />
    </AbsoluteFill>
  );
};

// ---------------------------------------------------------------- CAMERA
export const Camera: React.FC = () => {
  const f = useCurrentFrame();
  const sw = footAt('camera', 0, 9.6);
  const seg2 = footAt('camera', 1, SEGS.camera[1].from);
  const before = interpolate(f / 30, [FOOT_START + 0.3, FOOT_START + 0.6, sw - 0.2, sw], [0, 1, 1, 0], clamp);
  const after = interpolate(f / 30, [sw + 0.3, sw + 0.6, seg2 - 0.15, seg2], [0, 1, 1, 0], clamp);
  const ring = interpolate(f / 30, [sw, sw + 0.6], [0, 1], clamp);
  const Label: React.FC<{ text: string; o: number; color: string }> = ({ text, o, color }) => (
    <div
      style={{
        position: 'absolute',
        left: 776,
        top: 166,
        opacity: o,
        transform: `translateY(${(1 - o) * -10}px)`,
        padding: '12px 20px',
        borderRadius: 14,
        background: 'rgba(6,6,26,0.78)',
        border: '1px solid rgba(255,255,255,0.2)',
        fontFamily: FONT,
        fontWeight: 700,
        fontSize: 26,
        color: '#fff',
        display: 'flex',
        alignItems: 'center',
        gap: 12,
      }}
    >
      <span style={{ width: 12, height: 12, borderRadius: 6, background: color, boxShadow: `0 0 12px ${color}` }} />
      {text}
    </div>
  );
  const sp = useAppear(sw - 0.05, 0.3);
  return (
    <AbsoluteFill>
      <Col top={240}>
        <Kicker n="07" text="PHONE AS WEBCAM" />
        <Title lines={[<span key="a">Your <span style={{ color: C.android }}>Android</span> is</span>, <GradText key="w">your webcam.</GradText>]} size={68} />
        <Chips>
          <Chip t={at('camera', 'continuity')} icon="camera">
            Like Continuity Camera on iPhone
          </Chip>
          <Chip t={at('camera', 'webcam')} icon="mac">
            Works in any Mac video app
          </Chip>
          <Chip t={at('camera', 'switch')} icon="phone" accent>
            Front / rear · one click
          </Chip>
        </Chips>
      </Col>
      <Footage segs={SEGS.camera} start={FOOT_START} dur={footDur('camera')} box={WIDE} />
      <Label text="MacBook camera" o={before} color="#a1a1aa" />
      <Label text="Android phone camera" o={after} color={C.android} />
      {/* switch burst */}
      <div
        style={{
          position: 'absolute',
          left: 1300 - 200,
          top: 485 - 200,
          width: 400,
          height: 400,
          borderRadius: '50%',
          border: `4px solid ${C.cyan}`,
          opacity: sp * (1 - ring),
          transform: `scale(${0.3 + ring * 1.4})`,
        }}
      />
    </AbsoluteFill>
  );
};
