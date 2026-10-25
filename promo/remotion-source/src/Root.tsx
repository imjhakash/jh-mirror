import React from 'react';
import { Composition } from 'remotion';
import { Promo } from './Promo';
import { FPS, TOTAL } from './timeline';

export const RemotionRoot: React.FC = () => (
  <Composition id="JHMirrorPromo" component={Promo} durationInFrames={TOTAL} fps={FPS} width={1920} height={1080} />
);
