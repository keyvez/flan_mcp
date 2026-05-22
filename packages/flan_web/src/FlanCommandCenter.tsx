/**
 * FlanCommandCenter — mounts the keyboard shortcuts and all overlay
 * surfaces. Drop it once, inside <FlanProvider>, near the app root.
 */
import { useFlan } from './context.js';
import { useFlanShortcuts } from './useFlanShortcuts.js';
import { MessageOverlay } from './MessageOverlay.js';
import { AnnotationOverlay } from './AnnotationOverlay.js';
import { InspectorOverlay } from './InspectorOverlay.js';

export function FlanCommandCenter(): JSX.Element {
  const { mode, setMode } = useFlan();
  useFlanShortcuts(mode, setMode);

  return (
    <>
      <MessageOverlay />
      <AnnotationOverlay />
      <InspectorOverlay />
    </>
  );
}
