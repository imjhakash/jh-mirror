import React from 'react';
import { AbsoluteFill, Img, interpolate, OffthreadVideo, Sequence, staticFile, useCurrentFrame } from 'remotion';
import { at } from '../timeline';
import { C, Chip, clamp, ease, FONT, Footage, GradText, Icon, Kicker, Title, useAppear, useSpring, type Seg } from '../ui';

const Col: React.FC<{ children: React.ReactNode }> = ({ children }) => (
  <div style={{ position: 'absolute', left: 120, top: 250, width: 600, display: 'flex', flexDirection: 'column', gap: 26, fontFamily: FONT }}>{children}</div>
);
const Chips: React.FC<{ children: React.ReactNode }> = ({ children }) => (
  <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'flex-start', gap: 14, marginTop: 14 }}>{children}</div>
);

/** Click ripple at an absolute position, scene-relative time t. */
const Ripple: React.FC<{ x: number; y: number; t: number }> = ({ x, y, t }) => {
  const f = useCurrentFrame();
  const d = f / 30 - t;
  if (d < -0.1 || d > 0.9) return null;
  const p = interpolate(d, [-0.1, 0.7], [0, 1], clamp);
  const dot = interpolate(d, [-0.1, 0, 0.5, 0.9], [0, 1, 1, 0], clamp);
  return (
    <div style={{ position: 'absolute', left: x, top: y, width: 0, height: 0 }}>
      <div style={{ position: 'absolute', left: -20, top: -20, width: 40, height: 40, borderRadius: 20, background: 'rgba(34,211,238,0.35)', border: '2px solid #fff', opacity: dot, boxShadow: '0 0 24px rgba(34,211,238,0.9)' }} />
      <div style={{ position: 'absolute', left: -40, top: -40, width: 80, height: 80, borderRadius: 40, border: `3px solid ${C.cyan}`, opacity: (1 - p) * 0.9, transform: `scale(${0.4 + p * 1.3})` }} />
    </div>
  );
};

const Cursor: React.FC<{ path: [number, number, number][] }> = ({ path }) => {
  const f = useCurrentFrame();
  const t = f / 30;
  let x = path[0][1];
  let y = path[0][2];
  for (let i = 1; i < path.length; i++) {
    const [t0, x0, y0] = path[i - 1];
    const [t1, x1, y1] = path[i];
    if (t >= t0 && t <= t1) {
      const k = ease((t - t0) / (t1 - t0));
      x = x0 + (x1 - x0) * k;
      y = y0 + (y1 - y0) * k;
    } else if (t > t1) {
      x = x1;
      y = y1;
    }
  }
  return (
    <svg style={{ position: 'absolute', left: x - 6, top: y - 4, filter: 'drop-shadow(0 4px 8px rgba(0,0,0,0.5))' }} width={34} height={34} viewBox="0 0 24 24">
      <path d="m5 3 14 7-6 2-2 6z" fill="#fff" stroke="#111" strokeWidth={1.3} strokeLinejoin="round" />
    </svg>
  );
};

// ---------------------------------------------------------------- MENU BAR
// popover.png is 600x1330 (2x of a 300x665pt popover); shown at scale K.
const POP_W = 600;
const POP_H = 1330;
export const MenuBar: React.FC = () => {
  const f = useCurrentFrame();
  const K = 0.6;
  const iconX = 1560;
  const barY = 96;
  const tClick = at('menubar', 'click');
  const pop = useSpring(tClick + 0.15, 13, 0.7);
  const tMenu = at('menubar', 'instant') - 0.2;
  const menu = useSpring(tMenu, 14);
  const popX = iconX - (POP_W * K) / 2 + 40;
  const popY = barY + 52;
  // button highlights (display px inside popover, from the 2x crop * K)
  const hl: { w: string; x: number; y: number; w2: number; h2: number }[] = [
    { w: 'files', x: 20, y: 958, w2: 184, h2: 64 },
    { w: 'media', x: 208, y: 958, w2: 184, h2: 64 },
    { w: 'clipboard', x: 210, y: 1036, w2: 180, h2: 104 },
    { w: 'camera', x: 22, y: 1170, w2: 178, h2: 96 },
  ];
  const nowT = f / 30;
  return (
    <AbsoluteFill>
      <Col>
        <Kicker n="02" text="MENU BAR" />
        <Title lines={['Always one', <GradText key="c">click away.</GradText>]} size={74} />
        <Chips>
          <Chip t={at('menubar', 'live')} icon="mirror">
            Live phone preview
          </Chip>
          <Chip t={at('menubar', 'files')} icon="folder">
            Files · Media · Apps
          </Chip>
          <Chip t={at('menubar', 'clipboard')} icon="clipboard">
            Clipboard history
          </Chip>
          <Chip t={at('menubar', 'camera')} icon="camera" accent>
            Phone camera &amp; mic
          </Chip>
        </Chips>
      </Col>
      {/* macOS menu bar strip */}
      <MenuStrip iconX={iconX} y={barY} active={nowT >= tClick} />
      {/* right-click menu (real screenshot) */}
      <div
        style={{
          position: 'absolute',
          left: 980,
          top: popY + 10,
          width: 426 * 0.78,
          opacity: menu,
          transform: `translateX(${(1 - menu) * 60}px) scale(${0.92 + 0.08 * menu})`,
          transformOrigin: 'right top',
        }}
      >
        <Img src={staticFile('img/menu.png')} style={{ width: '100%', borderRadius: 14, boxShadow: '0 30px 80px rgba(0,0,0,0.6), 0 0 0 1px rgba(255,255,255,0.12)' }} />
        <div style={{ position: 'absolute', top: '100%', marginTop: 14, left: 0, right: 0, textAlign: 'center', fontFamily: FONT, fontWeight: 700, fontSize: 22, color: 'rgba(255,255,255,0.85)' }}>Right-click · every control</div>
      </div>
      {/* popover (real screenshot) with live footage in its preview */}
      <div
        style={{
          position: 'absolute',
          left: popX,
          top: popY,
          width: POP_W * K,
          height: POP_H * K,
          opacity: Math.min(1, pop * 1.5),
          transform: `scale(${0.85 + 0.15 * pop})`,
          transformOrigin: `${iconX - popX}px 0px`,
          filter: 'drop-shadow(0 40px 80px rgba(0,0,0,0.6))',
        }}
      >
        <Img src={staticFile('img/popover.png')} style={{ width: '100%', height: '100%', borderRadius: 26 }} />
        <div style={{ position: 'absolute', left: 108 * K, top: 126 * K, width: 378 * K, height: 816 * K, borderRadius: 18, overflow: 'hidden', background: '#000' }}>
          <Sequence from={Math.round((tClick + 0.1) * 30)} layout="none">
            <OffthreadVideo
              src={staticFile('clips/mirror.mp4')}
              trimBefore={Math.round(3.4 * 30)}
              playbackRate={1.4}
              muted
              style={{ position: 'absolute', left: 0, top: 0, width: 378 * K * (888 / 770), height: 378 * K * (888 / 770) * (1652 / 888) }}
            />
          </Sequence>
        </div>
        {hl.map((h) => {
          const t = at('menubar', h.w) - 0.05;
          const o = interpolate(nowT, [t, t + 0.15, t + 0.9, t + 1.2], [0, 1, 1, 0], clamp);
          return (
            <div
              key={h.w}
              style={{
                position: 'absolute',
                left: h.x * K,
                top: h.y * K,
                width: h.w2 * K,
                height: h.h2 * K,
                borderRadius: 12,
                border: `2.5px solid ${C.cyan}`,
                boxShadow: `0 0 24px ${C.cyan}, inset 0 0 18px rgba(34,211,238,0.35)`,
                opacity: o,
              }}
            />
          );
        })}
      </div>
      <Cursor path={[[0, 1300, 520], [tClick - 0.6, 1300, 520], [tClick, iconX, barY + 20], [tMenu, iconX + 6, barY + 26], [tMenu + 0.8, iconX + 160, 640]]} />
      <Ripple x={iconX} y={barY + 22} t={tClick} />
    </AbsoluteFill>
  );
};

const MenuStrip: React.FC<{ iconX: number; y: number; active: boolean }> = ({ iconX, y, active }) => {
  const a = useAppear(0.1, 0.6);
  return (
    <div
      style={{
        position: 'absolute',
        left: 760,
        top: y,
        width: 1100,
        height: 46,
        borderRadius: 14,
        background: 'rgba(255,255,255,0.1)',
        border: '1px solid rgba(255,255,255,0.15)',
        backdropFilter: 'blur(16px)',
        opacity: a,
        transform: `translateY(${(1 - a) * -20}px)`,
        fontFamily: FONT,
        color: '#fff',
      }}
    >
      <div style={{ position: 'absolute', left: 22, top: 10, fontSize: 21, fontWeight: 700, display: 'flex', gap: 26 }}>
        <span></span>
        <span>Finder</span>
        <span style={{ fontWeight: 500, opacity: 0.85 }}>File</span>
        <span style={{ fontWeight: 500, opacity: 0.85 }}>Edit</span>
        <span style={{ fontWeight: 500, opacity: 0.85 }}>View</span>
      </div>
      <div style={{ position: 'absolute', right: 22, top: 10, fontSize: 20, fontWeight: 600, display: 'flex', gap: 22, alignItems: 'center' }}>
        <Icon name="wifi" size={22} sw={2.2} />
        <span>67%</span>
        <span>Tue 9:01</span>
      </div>
      {/* JH Mirror status icon */}
      <div
        style={{
          position: 'absolute',
          left: iconX - 760 - 20,
          top: 4,
          width: 40,
          height: 38,
          borderRadius: 10,
          background: active ? 'rgba(255,255,255,0.25)' : 'transparent',
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          boxShadow: active ? '0 0 20px rgba(167,139,250,0.7)' : undefined,
        }}
      >
        <Icon name="phone" size={24} sw={2.2} />
      </div>
    </div>
  );
};

// ---------------------------------------------------------------- POCKET MODE
const POCKET_SEGS: Seg[] = [
  { src: 'mirror', from: 16.0, to: 19.5, w: 888, h: 1652, keys: [[16, 1, 0.5, 0.5], [19.5, 1.05, 0.5, 0.55]] },
  { src: 'mirror', from: 3.4, to: 6.0, w: 888, h: 1652, taps: [[4.05, 0.626, 0.717]] },
];

export const Pocket: React.FC = () => {
  const f = useCurrentFrame();
  const t = f / 30;
  const tTurn = at('pocket', 'turn');
  const tOff = at('pocket', 'off');
  const tLock = at('pocket', 'lock');
  const tPocket = at('pocket', 'pocket') - 0.3;
  const tKeep = at('pocket', 'while') - 0.2;
  const menuP = useSpring(0.25, 14);
  const menuOut = interpolate(t, [tTurn + 0.6, tTurn + 1.0], [1, 0], clamp);
  const phoneIn = useSpring(tTurn + 0.8, 13);
  const dark = interpolate(t, [tOff - 0.1, tOff + 0.4], [0, 1], { ...clamp, easing: ease });
  const lock = useSpring(tLock, 11);
  const pocket = interpolate(t, [tPocket, tPocket + 0.8], [0, 1], { ...clamp, easing: ease });
  const usable = useAppear(tKeep + 0.2, 0.5);
  const ROW_Y = 0.662; // "Turn Phone Screen Off" row in menu.png
  const MW = 426 * 0.8;
  const MH = 968 * 0.8;
  return (
    <AbsoluteFill>
      <Col>
        <Kicker n="03" text="POCKET MODE" />
        <Title lines={['Screen off.', <GradText key="s">Still in control.</GradText>]} size={74} />
        <Chips>
          <Chip t={at('pocket', 'screen')} icon="phone">
            Phone display turns off
          </Chip>
          <Chip t={tLock} icon="check">
            Touch locked · no pocket taps
          </Chip>
          <Chip t={tKeep} icon="mac">
            Keep using it from your Mac
          </Chip>
          <Chip t={tKeep + 0.6} icon="bolt" accent>
            Android 14 and newer
          </Chip>
        </Chips>
      </Col>
      {/* step 1: real menu, click "Turn Phone Screen Off" */}
      <div style={{ position: 'absolute', left: 1130, top: 150, width: MW, height: MH, opacity: menuP * menuOut, transform: `scale(${0.9 + 0.1 * menuP})` }}>
        <Img src={staticFile('img/menu.png')} style={{ width: MW, height: MH, borderRadius: 14, boxShadow: '0 30px 80px rgba(0,0,0,0.6), 0 0 0 1px rgba(255,255,255,0.12)' }} />
        <div
          style={{
            position: 'absolute',
            left: 6,
            top: ROW_Y * MH - 17,
            width: MW - 12,
            height: 34,
            borderRadius: 8,
            background: 'rgba(62,123,250,0.55)',
            opacity: interpolate(t, [tTurn - 0.5, tTurn - 0.3], [0, 1], clamp),
          }}
        />
        <Img src={staticFile('img/menu.png')} style={{ position: 'absolute', left: 0, top: 0, width: MW, height: MH, clipPath: `inset(${ROW_Y * MH - 17}px 6px ${MH - ROW_Y * MH - 17}px 6px)`, mixBlendMode: 'screen' }} />
      </div>
      <Cursor path={[[0, 1600, 900], [tTurn - 0.9, 1600, 900], [tTurn - 0.2, 1130 + 150, 150 + ROW_Y * MH], [tTurn + 1.0, 1130 + 150, 150 + ROW_Y * MH], [tTurn + 1.5, 1920, 1000]]} />
      <Ripple x={1130 + 150} y={150 + ROW_Y * MH} t={tTurn} />

      {/* step 2: the physical phone goes dark and locks; the Mac keeps control */}
      <div style={{ position: 'absolute', left: 820, top: 190, opacity: phoneIn, transform: `translateY(${(1 - phoneIn) * 60}px)` }}>
        <div style={{ fontFamily: FONT, fontWeight: 700, fontSize: 24, color: 'rgba(255,255,255,0.8)', textAlign: 'center', marginBottom: 18 }}>Your phone</div>
        <div style={{ position: 'relative', width: 300, height: 620, borderRadius: 46, border: '9px solid #2a2b35', background: '#0b0b10', overflow: 'hidden', boxShadow: '0 40px 90px rgba(0,0,0,0.6)' }}>
          {/* screen: home-screen tint → off */}
          <div style={{ position: 'absolute', inset: 0, background: 'linear-gradient(160deg,#4f46e5,#0ea5e9 60%,#22d3ee)', opacity: 1 - dark }} />
          <div style={{ position: 'absolute', inset: 0, background: '#000', opacity: dark }} />
          <div style={{ position: 'absolute', top: 16, left: 134, width: 14, height: 14, borderRadius: 7, background: '#1c1d25' }} />
          {/* lock badge */}
          <div style={{ position: 'absolute', left: 0, right: 0, top: 140, display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 14, opacity: lock, transform: `scale(${0.6 + 0.4 * lock})` }}>
            <div style={{ width: 96, height: 96, borderRadius: 48, background: 'rgba(52,211,153,0.15)', border: `2px solid ${C.green}`, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
              <svg width={46} height={46} viewBox="0 0 24 24" fill="none" stroke={C.green} strokeWidth={2} strokeLinecap="round" strokeLinejoin="round">
                <rect x="5" y="11" width="14" height="10" rx="2" />
                <path d="M8 11V8a4 4 0 0 1 8 0v3" />
              </svg>
            </div>
            <div style={{ fontFamily: FONT, fontWeight: 700, fontSize: 22, color: '#d1fae5' }}>Display off · Touch locked</div>
          </div>
        </div>
        {/* pocket */}
        <div
          style={{
            position: 'absolute',
            left: -40,
            top: 60 + 620 - pocket * 260,
            width: 380,
            height: 460,
            borderRadius: '30px 30px 60px 60px',
            background: 'linear-gradient(180deg,#27406b,#1b2c4d)',
            border: '2px dashed rgba(255,255,255,0.25)',
            boxShadow: 'inset 0 20px 30px rgba(0,0,0,0.35)',
            opacity: pocket,
          }}
        >
          <div style={{ position: 'absolute', top: 24, left: 0, right: 0, textAlign: 'center', fontFamily: FONT, fontWeight: 700, fontSize: 22, color: 'rgba(255,255,255,0.75)' }}>In your pocket</div>
        </div>
      </div>
      {/* the Mac side: real mirror footage keeps working */}
      <div style={{ position: 'absolute', left: 1300, top: 150, fontFamily: FONT, fontWeight: 700, fontSize: 24, color: 'rgba(255,255,255,0.85)', opacity: usable, width: 470, textAlign: 'center' }}>
        On your Mac · <span style={{ color: C.green }}>still fully usable</span>
      </div>
      <Footage segs={POCKET_SEGS} start={tKeep} dur={8.3 - tKeep - 0.05} box={{ x: 1330, y: 200, w: 410, h: 740 }} device="none" radius={26} />
      {/* link line between them */}
      <svg style={{ position: 'absolute', left: 0, top: 0, opacity: usable }} width={1920} height={1080}>
        <line x1={1145} y1={560} x2={1320} y2={560} stroke={C.cyan} strokeWidth={3} strokeDasharray="8 10" strokeDashoffset={-f * 2} />
      </svg>
    </AbsoluteFill>
  );
};
