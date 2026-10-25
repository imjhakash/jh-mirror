// Local font files (public/fonts) so rendering never calls a font API.
import React, { useEffect, useState } from 'react';
import { loadFont } from '@remotion/fonts';
import { continueRender, delayRender, staticFile } from 'remotion';

const inter = [400, 500, 600, 700, 800].map((w) =>
  loadFont({ family: 'Inter', url: staticFile(`fonts/inter-latin-${w}-normal.woff2`), weight: String(w), format: 'woff2' }),
);
const mono = [500, 700].map((w) =>
  loadFont({
    family: 'JetBrains Mono',
    url: staticFile(`fonts/jetbrains-mono-latin-${w}-normal.woff2`),
    weight: String(w),
    format: 'woff2',
  }),
);

export const fontsReady = Promise.all([...inter, ...mono]);

// Render children only after fonts load, so text measurement is never cached
// against a fallback font.
export const FontGate: React.FC<{ children: React.ReactNode }> = ({ children }) => {
  const [handle] = useState(() => delayRender('Loading local fonts'));
  const [ready, setReady] = useState(false);
  useEffect(() => {
    fontsReady.then(() => {
      setReady(true);
      continueRender(handle);
    });
  }, [handle]);
  return ready ? React.createElement(React.Fragment, null, children) : null;
};
