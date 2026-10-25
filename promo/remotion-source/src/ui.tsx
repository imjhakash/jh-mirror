import React from 'react';
import {
  AbsoluteFill,
  Easing,
  interpolate,
  OffthreadVideo,
  Sequence,
  spring,
  staticFile,
  useCurrentFrame,
  useVideoConfig,
} from 'remotion';
import type { Word } from './timeline';

export const C = {
  bg: '#06061a',
  ink: '#ffffff',
  sub: 'rgba(226,228,255,0.72)',
  violet: '#8b5cf6',
  blue: '#4f7cff',
  cyan: '#22d3ee',
  green: '#34d399',
  android: '#3ddc84',
  grad: 'linear-gradient(100deg, #a78bfa 0%, #60a5fa 50%, #22d3ee 100%)',
};
export const FONT = 'Inter, -apple-system, system-ui, sans-serif';

export const clamp = { extrapolateLeft: 'clamp', extrapolateRight: 'clamp' } as const;
export const ease = Easing.bezier(0.22, 1, 0.36, 1);

/** 0→1 progress for an element appearing at scene-relative second `t`. */
export const useAppear = (t: number, dur = 0.5) => {
  const f = useCurrentFrame();
  const { fps } = useVideoConfig();
  return interpolate(f, [t * fps, (t + dur) * fps], [0, 1], { ...clamp, easing: ease });
};
export const useSpring = (t: number, damping = 14, mass = 0.7) => {
  const f = useCurrentFrame();
  const { fps } = useVideoConfig();
  return spring({ frame: f - t * fps, fps, config: { damping, mass } });
};

export const GradText: React.FC<{ children: React.ReactNode; style?: React.CSSProperties }> = ({ children, style }) => (
  <span style={{ background: C.grad, WebkitBackgroundClip: 'text', backgroundClip: 'text', color: 'transparent', ...style }}>
    {children}
  </span>
);

// ---------- background ----------
export const Background: React.FC = () => {
  const f = useCurrentFrame();
  const t = f / 30;
  const blob = (x: number, y: number, r: number, color: string, sp: number, ph: number) => (
    <div
      style={{
        position: 'absolute',
        left: x + Math.sin(t * sp + ph) * 120 - r,
        top: y + Math.cos(t * sp * 0.8 + ph) * 90 - r,
        width: r * 2,
        height: r * 2,
        borderRadius: '50%',
        background: `radial-gradient(circle, ${color} 0%, transparent 65%)`,
        filter: 'blur(30px)',
      }}
    />
  );
  return (
    <AbsoluteFill style={{ background: C.bg, overflow: 'hidden' }}>
      {blob(300, 250, 620, 'rgba(139,92,246,0.42)', 0.25, 0)}
      {blob(1650, 850, 680, 'rgba(34,211,238,0.30)', 0.2, 2)}
      {blob(1400, 180, 520, 'rgba(79,124,255,0.32)', 0.3, 4)}
      {blob(500, 950, 520, 'rgba(99,102,241,0.25)', 0.22, 1)}
      <AbsoluteFill
        style={{
          backgroundImage:
            'linear-gradient(rgba(255,255,255,0.035) 1px, transparent 1px), linear-gradient(90deg, rgba(255,255,255,0.035) 1px, transparent 1px)',
          backgroundSize: '80px 80px',
          backgroundPosition: `${(t * 6) % 80}px ${(t * 6) % 80}px`,
          maskImage: 'radial-gradient(ellipse at center, black 30%, transparent 80%)',
        }}
      />
      <AbsoluteFill style={{ background: 'radial-gradient(ellipse at center, transparent 55%, rgba(0,0,0,0.55) 100%)' }} />
    </AbsoluteFill>
  );
};

// ---------- icons (stroke) ----------
type IconName = 'mirror' | 'bell' | 'clipboard' | 'photo' | 'camera' | 'keyboard' | 'check' | 'mac' | 'phone' | 'wifi' | 'bolt' | 'cursor' | 'folder';
export const Icon: React.FC<{ name: IconName; size?: number; color?: string; sw?: number }> = ({ name, size = 40, color = '#fff', sw = 2 }) => {
  const p: Record<IconName, React.ReactNode> = {
    mirror: (
      <>
        <rect x="2" y="4" width="13" height="10" rx="1.5" />
        <path d="M6 18h5M8.5 14v4" />
        <rect x="17" y="7" width="5.5" height="11" rx="1.2" />
      </>
    ),
    bell: (
      <>
        <path d="M6 9a6 6 0 1 1 12 0c0 6 2.5 7.5 2.5 7.5h-17S6 15 6 9" />
        <path d="M10 20a2.2 2.2 0 0 0 4 0" />
      </>
    ),
    clipboard: (
      <>
        <rect x="5" y="4" width="14" height="17" rx="2" />
        <rect x="9" y="2.5" width="6" height="3.5" rx="1" />
        <path d="M9 11h6M9 15h4" />
      </>
    ),
    photo: (
      <>
        <rect x="3" y="4" width="18" height="16" rx="2.5" />
        <circle cx="9" cy="10" r="1.8" />
        <path d="m4 18 5-5 4 4 3-3 4 4" />
      </>
    ),
    folder: <path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z" />,
    camera: (
      <>
        <rect x="2.5" y="6" width="13" height="12" rx="2" />
        <path d="m15.5 10 6-3.5v11l-6-3.5" />
      </>
    ),
    keyboard: (
      <>
        <rect x="2" y="6" width="20" height="12" rx="2" />
        <path d="M6 10h.01M10 10h.01M14 10h.01M18 10h.01M7 14h10" />
      </>
    ),
    check: <path d="m5 12.5 4.5 4.5L19 7.5" />,
    mac: (
      <>
        <rect x="4" y="4" width="16" height="11" rx="1.5" />
        <path d="M2 19h20l-1.5-2.5h-17z" />
      </>
    ),
    phone: (
      <>
        <rect x="6.5" y="2" width="11" height="20" rx="2.5" />
        <path d="M11 18.5h2" />
      </>
    ),
    wifi: <path d="M2.5 9a14 14 0 0 1 19 0M5.5 12.5a9.5 9.5 0 0 1 13 0M8.5 16a5 5 0 0 1 7 0M12 19.5h.01" />,
    bolt: <path d="M13 2 4 14h7l-1 8 9-12h-7z" />,
    cursor: <path d="m5 3 14 7-6 2-2 6z" />,
  };
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={sw} strokeLinecap="round" strokeLinejoin="round">
      {p[name]}
    </svg>
  );
};

export const IconTile: React.FC<{ name: IconName; size?: number; style?: React.CSSProperties }> = ({ name, size = 96, style }) => (
  <div
    style={{
      width: size,
      height: size,
      borderRadius: size * 0.28,
      background: 'linear-gradient(145deg, #8b5cf6 0%, #4f7cff 55%, #22d3ee 100%)',
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'center',
      boxShadow: '0 20px 50px rgba(79,124,255,0.45), inset 0 1px 0 rgba(255,255,255,0.35)',
      ...style,
    }}
  >
    <Icon name={name} size={size * 0.5} sw={2.1} />
  </div>
);

// ---------- text blocks ----------
export const Kicker: React.FC<{ n: string; text: string; t?: number }> = ({ n, text, t = 0.15 }) => {
  const a = useAppear(t, 0.6);
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 16, opacity: a, transform: `translateX(${(1 - a) * -30}px)` }}>
      <div style={{ fontFamily: 'JetBrains Mono', fontWeight: 700, fontSize: 22, color: C.cyan }}>{n}</div>
      <div style={{ width: 46 * a, height: 2, background: C.grad }} />
      <div style={{ fontFamily: FONT, fontWeight: 700, fontSize: 21, letterSpacing: 4, color: 'rgba(255,255,255,0.8)' }}>{text}</div>
    </div>
  );
};

export const Title: React.FC<{ lines: React.ReactNode[]; t?: number; size?: number }> = ({ lines, t = 0.3, size = 78 }) => {
  const f = useCurrentFrame();
  return (
    <div style={{ fontFamily: FONT, fontWeight: 800, fontSize: size, lineHeight: 1.04, letterSpacing: -2.5, color: C.ink }}>
      {lines.map((l, i) => {
        const p = interpolate(f, [(t + i * 0.12) * 30, (t + i * 0.12 + 0.7) * 30], [0, 1], { ...clamp, easing: ease });
        return (
          <div key={i} style={{ overflow: 'hidden', paddingBottom: 8 }}>
            <div style={{ transform: `translateY(${(1 - p) * 110}%)`, opacity: p }}>{l}</div>
          </div>
        );
      })}
    </div>
  );
};

export const Chip: React.FC<{ t: number; icon?: IconName; children: React.ReactNode; accent?: boolean }> = ({ t, icon, children, accent }) => {
  const s = useSpring(t, 13);
  return (
    <div
      style={{
        display: 'inline-flex',
        alignItems: 'center',
        gap: 12,
        padding: '13px 22px 13px 16px',
        borderRadius: 999,
        background: accent ? 'linear-gradient(100deg, rgba(139,92,246,0.35), rgba(34,211,238,0.28))' : 'rgba(255,255,255,0.07)',
        border: '1px solid rgba(255,255,255,0.16)',
        backdropFilter: 'blur(10px)',
        fontFamily: FONT,
        fontWeight: 600,
        fontSize: 25,
        color: '#fff',
        opacity: Math.min(1, s * 1.5),
        transform: `translateY(${(1 - s) * 26}px) scale(${0.85 + 0.15 * s})`,
        transformOrigin: 'left center',
        whiteSpace: 'nowrap',
      }}
    >
      {icon && (
        <span style={{ width: 34, height: 34, borderRadius: 10, background: 'rgba(255,255,255,0.12)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
          <Icon name={icon} size={21} sw={2.3} />
        </span>
      )}
      {children}
    </div>
  );
};

export const Keycap: React.FC<{ label: string; size?: number }> = ({ label, size = 92 }) => (
  <div
    style={{
      minWidth: size,
      height: size,
      padding: '0 22px',
      borderRadius: size * 0.22,
      background: 'linear-gradient(180deg, #3a3d55 0%, #23253a 100%)',
      boxShadow: '0 8px 0 #12131f, 0 18px 40px rgba(0,0,0,0.5), inset 0 1px 0 rgba(255,255,255,0.2)',
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'center',
      fontFamily: FONT,
      fontWeight: 600,
      fontSize: size * 0.42,
      color: '#fff',
    }}
  >
    {label}
  </div>
);

// ---------- captions ----------
export const Captions: React.FC<{ words: Word[]; offset: number }> = ({ words, offset }) => {
  const f = useCurrentFrame();
  const now = f / 30 - offset;
  // chunk at punctuation or every 7 words
  const chunks: Word[][] = [];
  let cur: Word[] = [];
  words.forEach((w) => {
    cur.push(w);
    if (/[.,?!]$/.test(w.w) || cur.length >= 7) {
      chunks.push(cur);
      cur = [];
    }
  });
  if (cur.length) chunks.push(cur);
  const merged: Word[][] = [];
  chunks.forEach((c) => {
    const last = merged[merged.length - 1];
    if (last && last.length + c.length <= 6 && c.length <= 2) last.push(...c);
    else merged.push(c);
  });
  const idx = merged.findIndex((c, i) => now >= c[0].s - 0.05 && (i + 1 >= merged.length ? now <= c[c.length - 1].e + 0.5 : now < merged[i + 1][0].s - 0.05));
  if (idx < 0) return null;
  const c = merged[idx];
  const a = interpolate(now - c[0].s, [-0.05, 0.12], [0, 1], clamp);
  return (
    <div style={{ position: 'absolute', left: 0, right: 0, bottom: 46, display: 'flex', justifyContent: 'center', pointerEvents: 'none' }}>
      <div
        style={{
          padding: '12px 26px',
          borderRadius: 16,
          background: 'rgba(6,6,26,0.62)',
          border: '1px solid rgba(255,255,255,0.1)',
          backdropFilter: 'blur(12px)',
          fontFamily: FONT,
          fontWeight: 650,
          fontSize: 34,
          color: 'rgba(255,255,255,0.55)',
          opacity: a,
          transform: `translateY(${(1 - a) * 10}px)`,
          letterSpacing: -0.3,
        }}
      >
        {c.map((w, i) => {
          const on = now >= w.s - 0.03;
          return (
            <span key={i} style={{ color: on ? '#fff' : undefined, marginRight: i < c.length - 1 ? 10 : 0 }}>
              {w.w.replace(/[,]$/, '')}
            </span>
          );
        })}
      </div>
    </div>
  );
};

// ---------- scene entrance ----------
export const SceneIn: React.FC<{ children: React.ReactNode; first?: boolean }> = ({ children, first }) => {
  const f = useCurrentFrame();
  const p = first ? 1 : interpolate(f, [0, 15], [0, 1], { ...clamp, easing: ease });
  return (
    <AbsoluteFill style={{ opacity: p, transform: `scale(${1.06 - 0.06 * p})`, filter: p < 1 ? `blur(${(1 - p) * 14}px)` : undefined }}>
      {children}
    </AbsoluteFill>
  );
};

// ---------- demo footage ----------
/** Camera key: at source second `t`, frame centre on (cx, cy) (normalized) at zoom `s`. */
export type Key = [t: number, s: number, cx: number, cy: number];
/** Click highlight: at source second `t`, at normalized (x, y). `hold` draws a long-press ring. */
export type Tap = [t: number, x: number, y: number, hold?: boolean];

export type Seg = {
  src: string;
  from: number;
  to: number;
  w: number; // source pixel size
  h: number;
  keys?: Key[];
  taps?: Tap[];
};

const camAt = (keys: Key[] | undefined, t: number): [number, number, number] => {
  if (!keys || keys.length === 0) return [1, 0.5, 0.5];
  if (t <= keys[0][0]) return [keys[0][1], keys[0][2], keys[0][3]];
  for (let i = 1; i < keys.length; i++) {
    const [t1, s1, x1, y1] = keys[i];
    const [t0, s0, x0, y0] = keys[i - 1];
    if (t <= t1) {
      const k = Easing.inOut(Easing.cubic)((t - t0) / Math.max(0.001, t1 - t0));
      return [s0 + (s1 - s0) * k, x0 + (x1 - x0) * k, y0 + (y1 - y0) * k];
    }
  }
  const l = keys[keys.length - 1];
  return [l[1], l[2], l[3]];
};

/** Plays segments back-to-back on a fixed "screen", sped up uniformly to fill `dur` seconds,
 *  with a virtual camera that pans/zooms to the action and ripples on every click. */
export const Footage: React.FC<{
  segs: Seg[];
  start: number; // scene-relative seconds
  dur: number;
  box: { x: number; y: number; w: number; h: number };
  device?: 'laptop' | 'none';
  radius?: number;
}> = ({ segs, start, dur, box, device = 'laptop', radius = 14 }) => {
  const f = useCurrentFrame();
  const { fps } = useVideoConfig();
  const total = segs.reduce((a, s) => a + (s.to - s.from), 0);
  const rate = total / dur;
  const appear = interpolate(f, [start * fps, (start + 0.7) * fps], [0, 1], { ...clamp, easing: ease });
  const bez = device === 'laptop' ? 16 : 0;
  const SW = box.w - bez * 2;
  const SH = box.h - bez * 2;
  let cursor = start;
  const screens = segs.map((s, i) => {
    const len = (s.to - s.from) / rate;
    const segStart = cursor;
    cursor += len;
    const fit = Math.min(SW / s.w, SH / s.h);
    const cw = s.w * fit;
    const ch = s.h * fit;
    const srcT = s.from + ((f - segStart * fps) / fps) * rate;
    const [z, cx, cy] = camAt(s.keys, srcT);
    const W = cw * z;
    const H = ch * z;
    const tx = W >= SW ? Math.min(0, Math.max(SW - W, SW / 2 - cx * W)) : (SW - W) / 2;
    const ty = H >= SH ? Math.min(0, Math.max(SH - H, SH / 2 - cy * H)) : (SH - H) / 2;
    const cut = i === 0 ? 1 : interpolate(f - segStart * fps, [0, 8], [0, 1], clamp);
    return (
      <Sequence key={i} from={Math.round(segStart * fps)} durationInFrames={Math.round(len * fps) + (i === segs.length - 1 ? 60 : 1)} layout="none">
        <AbsoluteFill style={{ overflow: 'hidden' }}>
          <div style={{ position: 'absolute', left: tx, top: ty, width: W, height: H, transform: `scale(${1.04 - 0.04 * cut})`, opacity: 0.3 + 0.7 * cut }}>
            <OffthreadVideo src={staticFile(`clips/${s.src}.mp4`)} trimBefore={Math.round(s.from * fps)} playbackRate={rate} muted style={{ width: '100%', height: '100%' }} />
            {(s.taps ?? []).map(([tt, x, y, hold], k) => {
              const d = srcT - tt;
              if (d < -0.15 || d > 0.9) return null;
              const p = interpolate(d, [-0.15, 0.7], [0, 1], clamp);
              const dot = interpolate(d, [-0.15, 0, 0.5, 0.9], [0, 1, 1, 0], clamp);
              return (
                <div key={k} style={{ position: 'absolute', left: x * W, top: y * H, width: 0, height: 0 }}>
                  <div style={{ position: 'absolute', left: -22, top: -22, width: 44, height: 44, borderRadius: 22, background: 'rgba(34,211,238,0.35)', border: '2px solid rgba(255,255,255,0.9)', opacity: dot, transform: `scale(${hold ? 1.1 : 0.9})`, boxShadow: '0 0 24px rgba(34,211,238,0.8)' }} />
                  <div style={{ position: 'absolute', left: -40, top: -40, width: 80, height: 80, borderRadius: 40, border: `3px solid ${C.cyan}`, opacity: (1 - p) * 0.9, transform: `scale(${0.4 + p * (hold ? 1.6 : 1.2)})` }} />
                </div>
              );
            })}
          </div>
          <AbsoluteFill style={{ background: '#fff', opacity: (1 - cut) * 0.5, pointerEvents: 'none' }} />
        </AbsoluteFill>
      </Sequence>
    );
  });
  const y = box.y + (1 - appear) * 70;
  return (
    <div style={{ position: 'absolute', left: box.x, top: y, width: box.w, height: box.h, opacity: appear, transform: `perspective(1800px) rotateX(${(1 - appear) * 12}deg)` }}>
      {/* glow */}
      <div style={{ position: 'absolute', inset: -40, borderRadius: 60, background: 'radial-gradient(ellipse at center, rgba(99,102,241,0.45), transparent 70%)', filter: 'blur(30px)' }} />
      <div
        style={{
          position: 'absolute',
          inset: 0,
          borderRadius: device === 'laptop' ? 26 : radius,
          background: device === 'laptop' ? 'linear-gradient(180deg,#1a1b23,#0c0d12)' : '#000',
          boxShadow: '0 50px 120px rgba(0,0,0,0.65), 0 0 0 1.5px rgba(255,255,255,0.16)',
          padding: bez,
        }}
      >
        <div style={{ position: 'relative', width: SW, height: SH, borderRadius: device === 'laptop' ? 10 : radius, overflow: 'hidden', background: 'radial-gradient(ellipse at center,#14152a,#07070f)' }}>
          {screens}
          {/* glass reflection */}
          <AbsoluteFill style={{ background: 'linear-gradient(115deg, rgba(255,255,255,0.07) 0%, rgba(255,255,255,0) 35%)', pointerEvents: 'none' }} />
        </div>
        {device === 'laptop' && <div style={{ position: 'absolute', top: 5, left: '50%', marginLeft: -4, width: 8, height: 8, borderRadius: 4, background: '#2b2d3a' }} />}
      </div>
      {device === 'laptop' && (
        <div
          style={{
            position: 'absolute',
            left: -60,
            right: -60,
            top: box.h - 2,
            height: 24,
            borderRadius: '4px 4px 18px 18px',
            background: 'linear-gradient(180deg,#5a5d6e 0%,#2e3040 40%,#1a1b24 100%)',
            boxShadow: '0 20px 40px rgba(0,0,0,0.5)',
          }}
        >
          <div style={{ position: 'absolute', left: '50%', marginLeft: -90, top: 0, width: 180, height: 9, borderRadius: '0 0 10px 10px', background: '#23242f' }} />
        </div>
      )}
    </div>
  );
};

/** A light streak that sweeps across at scene changes. */
export const Sweep: React.FC = () => {
  const f = useCurrentFrame();
  const p = interpolate(f, [0, 20], [0, 1], { ...clamp, easing: ease });
  if (p >= 1) return null;
  return (
    <AbsoluteFill style={{ pointerEvents: 'none', overflow: 'hidden' }}>
      <div
        style={{
          position: 'absolute',
          top: -400,
          left: -900 + p * 3400,
          width: 500,
          height: 1900,
          transform: 'rotate(18deg)',
          background: 'linear-gradient(90deg, transparent, rgba(167,139,250,0.28), rgba(34,211,238,0.35), transparent)',
          filter: 'blur(20px)',
          opacity: Math.sin(p * Math.PI),
        }}
      />
    </AbsoluteFill>
  );
};
