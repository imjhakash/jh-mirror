import React from 'react';
import { AbsoluteFill, Img, interpolate, staticFile, useCurrentFrame } from 'remotion';
import { at } from '../timeline';
import { C, clamp, ease, FONT, GradText, Icon, IconTile, useAppear, useSpring } from '../ui';

// ---------------------------------------------------------------- HOOK
export const Hook: React.FC = () => {
  const f = useCurrentFrame();
  const tMac = at('hook', 'mac');
  const tGal = at('hook', 'android');
  const tSo = at('hook', 'so');
  const tStr = at('hook', 'strangers');
  const l1 = useAppear(at('hook', 'you') - 0.05, 0.45);
  const l2 = useAppear(at('hook', 'you', 1) - 0.05, 0.45);
  const l3 = useAppear(tSo - 0.05, 0.5);
  const up = interpolate(f, [tSo * 30 - 6, tSo * 30 + 10], [0, 1], { ...clamp, easing: ease });
  const mac = useSpring(tMac - 0.1, 12);
  const gal = useSpring(tGal - 0.1, 12);
  const glitch = f >= tStr * 30 && f < tStr * 30 + 9 ? Math.sin(f * 7) * 10 : 0;
  const apart = interpolate(f, [tStr * 30, tStr * 30 + 20], [0, 1], { ...clamp, easing: ease });
  const line = (txt: React.ReactNode, p: number, size = 92) => (
    <div style={{ opacity: p, transform: `translateY(${(1 - p) * 40}px)`, filter: `blur(${(1 - p) * 8}px)`, fontSize: size }}>{txt}</div>
  );
  return (
    <AbsoluteFill style={{ fontFamily: FONT, color: '#fff' }}>
      {/* devices */}
      <div style={{ position: 'absolute', left: 230 - apart * 70, top: 640, opacity: mac * 0.9, transform: `scale(${0.6 + 0.4 * mac})` }}>
        <Icon name="mac" size={250} color="rgba(167,139,250,0.9)" sw={0.9} />
      </div>
      <div style={{ position: 'absolute', right: 250 - apart * 70, top: 645, opacity: gal * 0.9, transform: `scale(${0.6 + 0.4 * gal})` }}>
        <Icon name="phone" size={240} color="rgba(61,220,132,0.95)" sw={0.9} />
      </div>
      {/* broken link between them */}
      <svg style={{ position: 'absolute', left: 0, top: 0 }} width={1920} height={1080}>
        <line x1={520} y1={770} x2={900 - apart * 80} y2={770} stroke="rgba(255,255,255,0.25)" strokeWidth={3} strokeDasharray="10 12" opacity={gal} />
        <line x1={1020 + apart * 80} y1={770} x2={1400} y2={770} stroke="rgba(255,255,255,0.25)" strokeWidth={3} strokeDasharray="10 12" opacity={gal} />
      </svg>
      <AbsoluteFill style={{ alignItems: 'center', justifyContent: 'center', textAlign: 'center', fontWeight: 800, letterSpacing: -3, lineHeight: 1.08, paddingBottom: 260 }}>
        <div style={{ transform: `translateY(${-up * 70}px) scale(${1 - up * 0.25})`, opacity: 1 - up * 0.55 }}>
          {line(
            <>
              You love your <GradText>Mac.</GradText>
            </>,
            l1,
          )}
          {line(
            <>
              You love your <span style={{ color: C.android }}>Android phone.</span>
            </>,
            l2,
          )}
        </div>
        <div style={{ height: 30 }} />
        {line(
          <span style={{ display: 'inline-block', transform: `translateX(${glitch}px)` }}>
            So why do they still feel like{' '}
            <span style={{ color: '#f472b6', textShadow: glitch ? `${glitch}px 0 #22d3ee, ${-glitch}px 0 #f43f5e` : undefined }}>strangers?</span>
          </span>,
          l3,
          64,
        )}
      </AbsoluteFill>
    </AbsoluteFill>
  );
};

// ---------------------------------------------------------------- INTRO
export const Intro: React.FC = () => {
  const f = useCurrentFrame();
  const logo = useSpring(0.25, 11, 0.8);
  const name = useAppear(at('intro', 'jh') - 0.05, 0.6);
  const tag = useAppear(at('intro', 'missing') - 0.1, 0.6);
  const macP = useSpring(at('intro', 'macos') - 0.1, 12);
  const andP = useSpring(at('intro', 'android') - 0.1, 12);
  const ring = interpolate(f, [8, 40], [0, 1], { ...clamp, easing: ease });
  const shine = interpolate(f, [18, 40], [-120, 220], clamp);
  const feats: { n: Parameters<typeof Icon>[0]['name']; l: string }[] = [
    { n: 'mirror', l: 'Mirroring' },
    { n: 'bell', l: 'Notifications' },
    { n: 'clipboard', l: 'Clipboard' },
    { n: 'photo', l: 'Gallery & Files' },
    { n: 'camera', l: 'Camera' },
  ];
  const tFeat = at('intro', 'android') + 0.3;
  return (
    <AbsoluteFill style={{ fontFamily: FONT, color: '#fff', alignItems: 'center' }}>
      {/* light burst */}
      <div
        style={{
          position: 'absolute',
          left: 960 - 700,
          top: 330 - 700,
          width: 1400,
          height: 1400,
          borderRadius: '50%',
          background: 'radial-gradient(circle, rgba(139,92,246,0.45) 0%, rgba(34,211,238,0.12) 35%, transparent 60%)',
          opacity: logo,
          transform: `scale(${0.5 + logo * 0.5})`,
        }}
      />
      {/* pulse rings */}
      {[0, 1].map((k) => (
        <div
          key={k}
          style={{
            position: 'absolute',
            left: 960 - 160,
            top: 330 - 160,
            width: 320,
            height: 320,
            borderRadius: '50%',
            border: '2px solid rgba(167,139,250,0.7)',
            opacity: (1 - ring) * 0.9 * (k ? 0.6 : 1),
            transform: `scale(${1 + ring * (k ? 1.6 : 1.1)})`,
          }}
        />
      ))}
      <div style={{ position: 'absolute', top: 330 - 130, left: 960 - 130, width: 260, height: 260, transform: `scale(${logo}) rotate(${(1 - logo) * -20}deg)` }}>
        <Img src={staticFile('img/logo.png')} style={{ width: 260, height: 260, filter: 'drop-shadow(0 30px 60px rgba(79,124,255,0.55))' }} />
        <div style={{ position: 'absolute', inset: 14, borderRadius: 56, overflow: 'hidden' }}>
          <div
            style={{
              position: 'absolute',
              top: -40,
              left: shine,
              width: 70,
              height: 360,
              background: 'linear-gradient(90deg, transparent, rgba(255,255,255,0.55), transparent)',
              transform: 'rotate(20deg)',
            }}
          />
        </div>
      </div>
      <div style={{ position: 'absolute', top: 500, textAlign: 'center' }}>
        <div style={{ fontWeight: 800, fontSize: 124, letterSpacing: -4, opacity: name, transform: `translateY(${(1 - name) * 30}px)`, filter: `blur(${(1 - name) * 10}px)` }}>
          JH <GradText>Mirror</GradText>
        </div>
        <div style={{ fontWeight: 500, fontSize: 38, color: C.sub, marginTop: 6, opacity: tag, transform: `translateY(${(1 - tag) * 20}px)` }}>
          The missing ecosystem between macOS and Android
        </div>
      </div>
      <div style={{ position: 'absolute', top: 760, display: 'flex', gap: 22 }}>
        {feats.map((x, i) => {
          const s = useSpring(tFeat + i * 0.12, 13);
          return (
            <div
              key={x.l}
              style={{
                display: 'flex',
                alignItems: 'center',
                gap: 12,
                padding: '14px 22px',
                borderRadius: 18,
                background: 'rgba(255,255,255,0.06)',
                border: '1px solid rgba(255,255,255,0.14)',
                fontWeight: 600,
                fontSize: 24,
                opacity: s,
                transform: `translateY(${(1 - s) * 30}px)`,
              }}
            >
              <Icon name={x.n} size={26} color="#a5b4fc" />
              {x.l}
            </div>
          );
        })}
      </div>
      <div style={{ position: 'absolute', top: 880, display: 'flex', alignItems: 'center', gap: 26 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 14, padding: '14px 28px', borderRadius: 999, background: 'rgba(167,139,250,0.16)', border: '1px solid rgba(167,139,250,0.55)', fontSize: 34, fontWeight: 700, opacity: macP, transform: `translateX(${(1 - macP) * -40}px)` }}>
          <Icon name="mac" size={34} color="#c4b5fd" /> macOS
        </div>
        <div style={{ fontSize: 40, fontWeight: 800, color: C.sub, opacity: andP }}>⇄</div>
        <div style={{ display: 'flex', alignItems: 'center', gap: 14, padding: '14px 28px', borderRadius: 999, background: 'rgba(61,220,132,0.14)', border: '1px solid rgba(61,220,132,0.6)', fontSize: 34, fontWeight: 700, color: '#fff', opacity: andP, transform: `translateX(${(1 - andP) * 40}px)` }}>
          <Icon name="phone" size={34} color={C.android} /> Android
        </div>
      </div>
    </AbsoluteFill>
  );
};

// ---------------------------------------------------------------- SETUP
const Toggle: React.FC<{ on: number }> = ({ on }) => (
  <div style={{ width: 74, height: 42, borderRadius: 21, background: on > 0.5 ? '#3e7bfa' : '#4b4d5c', position: 'relative', transition: 'none' }}>
    <div style={{ position: 'absolute', top: 4, left: 4 + on * 32, width: 34, height: 34, borderRadius: 17, background: '#fff', boxShadow: '0 2px 6px rgba(0,0,0,0.4)' }} />
  </div>
);

const PhoneMock: React.FC<{ title: string; rows: { l: string; sub?: string; toggle?: number; hi?: boolean }[] }> = ({ title, rows }) => (
  <div
    style={{
      width: 400,
      height: 820,
      borderRadius: 56,
      background: '#0b0b10',
      border: '10px solid #2a2b35',
      boxShadow: '0 40px 100px rgba(0,0,0,0.6), 0 0 80px rgba(99,102,241,0.3)',
      padding: '70px 22px 22px',
      fontFamily: FONT,
      color: '#fff',
      position: 'relative',
    }}
  >
    <div style={{ position: 'absolute', top: 18, left: 180, width: 20, height: 20, borderRadius: 10, background: '#1c1d25' }} />
    <div style={{ fontSize: 40, fontWeight: 700, margin: '40px 8px 34px' }}>{title}</div>
    <div style={{ background: '#1d1e26', borderRadius: 26, padding: '6px 0' }}>
      {rows.map((r, i) => (
        <div
          key={i}
          style={{
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'space-between',
            padding: '20px 22px',
            borderTop: i ? '1px solid rgba(255,255,255,0.06)' : undefined,
            background: r.hi ? 'rgba(62,123,250,0.16)' : undefined,
            borderRadius: r.hi ? 18 : undefined,
          }}
        >
          <div>
            <div style={{ fontSize: 24, fontWeight: 600 }}>{r.l}</div>
            {r.sub && <div style={{ fontSize: 17, color: 'rgba(255,255,255,0.5)', marginTop: 4 }}>{r.sub}</div>}
          </div>
          {r.toggle !== undefined && <Toggle on={r.toggle} />}
        </div>
      ))}
    </div>
  </div>
);

export const Setup: React.FC = () => {
  const f = useCurrentFrame();
  const t1 = at('setup', 'open');
  const t2 = at('setup', 'turn');
  const t3 = at('setup', 'switch');
  const t4 = at('setup', 'scan');
  const t5 = at('setup', "that's");
  const steps = [
    { t: t1, icon: 'mac' as const, l: 'Open JH Mirror on your Mac' },
    { t: t2, icon: 'phone' as const, l: 'Turn on Developer options' },
    { t: t3, icon: 'wifi' as const, l: 'Switch on Wireless debugging' },
    { t: t4, icon: 'cursor' as const, l: 'Scan the pairing code' },
    { t: t5, icon: 'bolt' as const, l: 'JH Mirror does the rest' },
  ];
  const active = steps.filter((s) => f / 30 >= s.t - 0.1).length - 1;
  const head = useAppear(0.1, 0.6);
  const timer = interpolate(f, [0, 15 * 30], [0, 1], clamp);
  // visual panel cross-fades
  const vis = (from: number, to: number) =>
    interpolate(f / 30, [from - 0.25, from + 0.15, to - 0.15, to + 0.2], [0, 1, 1, 0], clamp);
  const devOn = interpolate(f / 30, [at('setup', 'developer') + 0.2, at('setup', 'developer') + 0.5], [0, 1], { ...clamp, easing: ease });
  const wdOn = interpolate(f / 30, [at('setup', 'wireless') + 0.3, at('setup', 'wireless') + 0.6], [0, 1], { ...clamp, easing: ease });
  const scanY = ((f / 30 - t4) * 1.6) % 1;
  const done = (t: number) => useSpring(t, 12);
  const checks = [
    { t: at('setup', 'sets'), l: 'Companion app installed' },
    { t: at('setup', 'everything'), l: 'Permissions granted' },
    { t: at('setup', 'all'), l: 'Connected wirelessly' },
  ];
  const appS = useSpring(t1 + 0.1, 11);
  const click = interpolate(f / 30, [t1 + 0.9, t1 + 1.3], [0, 1], clamp);
  return (
    <AbsoluteFill style={{ fontFamily: FONT, color: '#fff' }}>
      <div style={{ position: 'absolute', left: 120, top: 120, opacity: head, transform: `translateY(${(1 - head) * -20}px)`, display: 'flex', alignItems: 'center', gap: 22 }}>
        <svg width={64} height={64} viewBox="0 0 64 64">
          <circle cx={32} cy={32} r={27} stroke="rgba(255,255,255,0.15)" strokeWidth={6} fill="none" />
          <circle cx={32} cy={32} r={27} stroke="url(#g)" strokeWidth={6} fill="none" strokeDasharray={170} strokeDashoffset={170 * (1 - timer)} strokeLinecap="round" transform="rotate(-90 32 32)" />
          <defs>
            <linearGradient id="g">
              <stop offset="0" stopColor="#a78bfa" />
              <stop offset="1" stopColor="#22d3ee" />
            </linearGradient>
          </defs>
        </svg>
        <div>
          <div style={{ fontFamily: 'JetBrains Mono', fontWeight: 700, fontSize: 21, letterSpacing: 4, color: C.cyan }}>EASY SETUP</div>
          <div style={{ fontWeight: 800, fontSize: 60, letterSpacing: -2 }}>
            Ready in about <GradText>a minute.</GradText>
          </div>
        </div>
      </div>
      {/* steps */}
      <div style={{ position: 'absolute', left: 120, top: 330, display: 'flex', flexDirection: 'column', gap: 22 }}>
        {steps.map((s, i) => {
          const p = useSpring(s.t - 0.15, 14);
          const on = i === active;
          const past = i < active;
          return (
            <div
              key={i}
              style={{
                display: 'flex',
                alignItems: 'center',
                gap: 22,
                width: 760,
                padding: '20px 26px',
                borderRadius: 22,
                background: on ? 'linear-gradient(100deg, rgba(139,92,246,0.32), rgba(34,211,238,0.18))' : 'rgba(255,255,255,0.05)',
                border: `1px solid ${on ? 'rgba(167,139,250,0.7)' : 'rgba(255,255,255,0.1)'}`,
                opacity: p * (on ? 1 : past ? 0.75 : 0.5),
                transform: `translateX(${(1 - p) * -40}px) scale(${on ? 1.03 : 1})`,
                transformOrigin: 'left center',
              }}
            >
              <div
                style={{
                  width: 54,
                  height: 54,
                  borderRadius: 16,
                  background: past ? C.green : on ? 'linear-gradient(145deg,#8b5cf6,#22d3ee)' : 'rgba(255,255,255,0.1)',
                  display: 'flex',
                  alignItems: 'center',
                  justifyContent: 'center',
                  fontWeight: 800,
                  fontSize: 26,
                }}
              >
                {past ? <Icon name="check" size={30} sw={3} /> : i + 1}
              </div>
              <Icon name={s.icon} size={30} color="rgba(255,255,255,0.75)" />
              <div style={{ fontSize: 32, fontWeight: 650 }}>{s.l}</div>
            </div>
          );
        })}
      </div>
      {/* visual panel */}
      <div style={{ position: 'absolute', left: 1000, top: 140, width: 800, height: 840 }}>
        {/* 1: app */}
        <AbsoluteFill style={{ opacity: vis(t1, t2), alignItems: 'center', justifyContent: 'center' }}>
          <div style={{ transform: `scale(${0.6 + 0.4 * appS}) scale(${1 - Math.sin(click * Math.PI) * 0.06})`, textAlign: 'center' }}>
            <Img src={staticFile('img/logo.png')} style={{ width: 300, filter: 'drop-shadow(0 30px 60px rgba(79,124,255,0.5))' }} />
            <div style={{ fontSize: 40, fontWeight: 700, marginTop: 10 }}>JH Mirror.app</div>
            <div style={{ fontSize: 24, color: C.sub, marginTop: 6 }}>One app on your Mac. That's all.</div>
          </div>
          <div style={{ position: 'absolute', left: 470, top: 470, transform: `translate(${(1 - click) * 120}px, ${(1 - click) * 90}px)`, opacity: appS }}>
            <svg width={44} height={44} viewBox="0 0 24 24">
              <path d="m5 3 14 7-6 2-2 6z" fill="#fff" stroke="#000" strokeWidth={1.2} strokeLinejoin="round" />
            </svg>
          </div>
        </AbsoluteFill>
        {/* 2: developer options */}
        <AbsoluteFill style={{ opacity: vis(t2, t3), alignItems: 'center', justifyContent: 'center' }}>
          <PhoneMock
            title="Settings"
            rows={[
              { l: 'Battery' },
              { l: 'About phone' },
              { l: 'Developer options', sub: 'Tap Build number 7 times', toggle: devOn, hi: true },
              { l: 'Software update' },
            ]}
          />
        </AbsoluteFill>
        {/* 3: wireless debugging */}
        <AbsoluteFill style={{ opacity: vis(t3, t4), alignItems: 'center', justifyContent: 'center' }}>
          <PhoneMock
            title="Developer options"
            rows={[
              { l: 'USB debugging', toggle: 0 },
              { l: 'Wireless debugging', sub: 'Same Wi-Fi as your Mac', toggle: wdOn, hi: true },
              { l: 'Pair device with QR code' },
              { l: 'Stay awake', toggle: 0 },
            ]}
          />
        </AbsoluteFill>
        {/* 4: real pairing window + scan */}
        <AbsoluteFill style={{ opacity: vis(t4, t5 + 0.3), alignItems: 'center', justifyContent: 'center' }}>
          <div style={{ position: 'relative', width: 560, height: 801 }}>
            <Img src={staticFile('img/pair.png')} style={{ width: 560, height: 801, borderRadius: 18, boxShadow: '0 40px 100px rgba(0,0,0,0.6)' }} />
            {/* scan line over the QR */}
            <div style={{ position: 'absolute', left: 205, top: 205 + scanY * 170, width: 150, height: 4, background: C.cyan, boxShadow: `0 0 20px ${C.cyan}`, borderRadius: 2 }} />
            <div style={{ position: 'absolute', left: 188, top: 196, width: 184, height: 192, border: `3px solid ${C.cyan}`, borderRadius: 16, opacity: 0.8 }} />
          </div>
        </AbsoluteFill>
        {/* 5: done */}
        <AbsoluteFill style={{ opacity: interpolate(f / 30, [t5 + 0.2, t5 + 0.6], [0, 1], clamp), alignItems: 'center', justifyContent: 'center' }}>
          <div style={{ width: 640, padding: 44, borderRadius: 36, background: 'rgba(255,255,255,0.06)', border: '1px solid rgba(255,255,255,0.14)', backdropFilter: 'blur(14px)' }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 24, marginBottom: 30 }}>
              <Img src={staticFile('img/logo.png')} style={{ width: 96 }} />
              <div>
                <div style={{ fontSize: 36, fontWeight: 800 }}>Jh's S23 Ultra</div>
                <div style={{ fontSize: 22, color: C.sub }}>Android 16 · Samsung Galaxy</div>
              </div>
            </div>
            {checks.map((c, i) => {
              const s = done(c.t);
              return (
                <div key={i} style={{ display: 'flex', alignItems: 'center', gap: 18, padding: '14px 0', opacity: s, transform: `translateX(${(1 - s) * 30}px)` }}>
                  <div style={{ width: 44, height: 44, borderRadius: 22, background: C.green, display: 'flex', alignItems: 'center', justifyContent: 'center', transform: `scale(${s})` }}>
                    <Icon name="check" size={26} sw={3.2} />
                  </div>
                  <div style={{ fontSize: 30, fontWeight: 600 }}>{c.l}</div>
                </div>
              );
            })}
          </div>
        </AbsoluteFill>
      </div>
    </AbsoluteFill>
  );
};

// ---------------------------------------------------------------- OUTRO
export const Outro: React.FC = () => {
  const f = useCurrentFrame();
  const feats: { n: Parameters<typeof Icon>[0]['name']; l: string; w: string }[] = [
    { n: 'mirror', l: 'Mirroring', w: 'mirroring' },
    { n: 'bell', l: 'Notifications', w: 'notifications' },
    { n: 'clipboard', l: 'Clipboard', w: 'clipboard' },
    { n: 'photo', l: 'Files', w: 'files' },
    { n: 'camera', l: 'Camera', w: 'camera' },
  ];
  const tEco = at('outro', 'seamless') - 0.4;
  const tNow = at('outro', 'now');
  const tJH = at('outro', 'jh') - 0.1;
  const tTag = at('outro', 'your');
  const rowUp = interpolate(f / 30, [tEco, tEco + 0.6], [0, 1], { ...clamp, easing: ease });
  const eco = useAppear(tEco + 0.1, 0.6);
  const nowP = useAppear(tNow - 0.05, 0.5);
  const clear = interpolate(f / 30, [tJH - 0.25, tJH], [1, 0], clamp);
  const logo = useSpring(tJH, 10, 0.9);
  const flash = interpolate(f / 30, [tJH, tJH + 0.35], [0.7, 0], clamp);
  const tag = useAppear(tTag - 0.05, 0.7);
  const credit = useAppear(tTag + 1.6, 0.8);
  const out = interpolate(f, [17.9 * 30 - 24, 17.9 * 30], [1, 0], clamp);
  return (
    <AbsoluteFill style={{ fontFamily: FONT, color: '#fff', opacity: out }}>
      <AbsoluteFill style={{ opacity: clear }}>
        <div
          style={{
            position: 'absolute',
            top: 380 - rowUp * 170,
            left: 0,
            right: 0,
            display: 'flex',
            justifyContent: 'center',
            gap: 46,
            transform: `scale(${1 - rowUp * 0.25})`,
          }}
        >
          {feats.map((x) => {
            const s = useSpring(at('outro', x.w) - 0.05, 11);
            return (
              <div key={x.l} style={{ textAlign: 'center', opacity: s, transform: `translateY(${(1 - s) * 50}px) scale(${0.6 + 0.4 * s})` }}>
                <IconTile name={x.n} size={150} />
                <div style={{ marginTop: 22, fontSize: 30, fontWeight: 700 }}>{x.l}</div>
              </div>
            );
          })}
        </div>
        <div style={{ position: 'absolute', top: 600, left: 0, right: 0, textAlign: 'center', fontWeight: 800, letterSpacing: -2.5 }}>
          <div style={{ fontSize: 64, opacity: eco, transform: `translateY(${(1 - eco) * 30}px)` }}>The seamless ecosystem you thought only iPhone could have,</div>
          <div style={{ fontSize: 92, marginTop: 10, opacity: nowP, transform: `scale(${0.9 + 0.1 * nowP})` }}>
            now on <span style={{ color: C.android }}>Android.</span>
          </div>
        </div>
      </AbsoluteFill>
      {/* end card */}
      <AbsoluteFill style={{ alignItems: 'center', opacity: f / 30 >= tJH - 0.05 ? 1 : 0 }}>
        <div
          style={{
            position: 'absolute',
            left: 960 - 650,
            top: 330 - 650,
            width: 1300,
            height: 1300,
            borderRadius: '50%',
            background: 'radial-gradient(circle, rgba(139,92,246,0.4) 0%, rgba(34,211,238,0.1) 38%, transparent 62%)',
            transform: `scale(${logo})`,
          }}
        />
        <Img src={staticFile('img/logo.png')} style={{ position: 'absolute', top: 190, width: 280, transform: `scale(${logo})`, filter: 'drop-shadow(0 30px 70px rgba(79,124,255,0.6))' }} />
        <div style={{ position: 'absolute', top: 500, fontWeight: 800, fontSize: 130, letterSpacing: -4, transform: `scale(${0.8 + 0.2 * logo})`, opacity: logo }}>
          JH <GradText>Mirror</GradText>
        </div>
        <div style={{ position: 'absolute', top: 680, fontSize: 50, fontWeight: 600, opacity: tag, transform: `translateY(${(1 - tag) * 24}px)`, letterSpacing: -1 }}>
          Your <span style={{ color: C.android }}>Android</span>, at home on your <GradText>Mac.</GradText>
        </div>
        <div style={{ position: 'absolute', top: 820, textAlign: 'center', opacity: credit, transform: `translateY(${(1 - credit) * 16}px)` }}>
          <div style={{ fontSize: 21, color: 'rgba(226,228,255,0.55)', letterSpacing: 0.5 }}>
            Developed by <span style={{ color: 'rgba(255,255,255,0.8)', fontWeight: 600 }}>Johirul Hoq Akash</span>
          </div>
          <div style={{ display: 'flex', gap: 14, justifyContent: 'center', marginTop: 20 }}>
            {['macOS', 'Android', 'Wireless', 'Encrypted'].map((x) => (
              <div key={x} style={{ padding: '8px 18px', borderRadius: 999, border: '1px solid rgba(255,255,255,0.2)', fontSize: 20, fontWeight: 600, color: 'rgba(255,255,255,0.8)' }}>
                {x}
              </div>
            ))}
          </div>
        </div>
      </AbsoluteFill>
      <AbsoluteFill style={{ background: '#fff', opacity: f / 30 >= tJH ? flash : 0 }} />
    </AbsoluteFill>
  );
};
