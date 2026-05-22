/**
 * Inspector overlay — hover to highlight any DOM element, click to lock a
 * selection, then type a message about it. The agent receives the tag
 * name, CSS selector, source hint, component name, and bounding box.
 * Mirrors flan_flutter's inspector (Ctrl+Shift+H).
 */
import { useEffect, useRef, useState } from 'react';
import { useFlan } from './context.js';
import { describeElement, elementAtPoint } from './dom.js';
import type { FlanInspectorSelection } from './types.js';

const COLORS = {
  highlight: 'rgba(0, 170, 255, 0.18)',
  highlightBorder: '#00AAFF',
  locked: 'rgba(0, 184, 148, 0.18)',
  lockedBorder: '#00B894',
  panel: '#1A1A2E',
  text: '#E0E0E0',
  textDim: 'rgba(224, 224, 232, 0.6)',
  accent: '#00AAFF',
};

interface Box {
  x: number;
  y: number;
  width: number;
  height: number;
}

export function InspectorOverlay(): JSX.Element | null {
  const { mode, setMode, send } = useFlan();
  const [hoverBox, setHoverBox] = useState<Box | null>(null);
  const [locked, setLocked] = useState<FlanInspectorSelection | null>(null);
  const [text, setText] = useState('');
  const inputRef = useRef<HTMLInputElement>(null);

  const active = mode === 'inspector';

  // Track the element under the pointer while nothing is locked.
  useEffect(() => {
    if (!active || locked) return undefined;

    const onMove = (e: MouseEvent): void => {
      const el = elementAtPoint(e.clientX, e.clientY);
      if (!el) {
        setHoverBox(null);
        return;
      }
      const r = el.getBoundingClientRect();
      setHoverBox({
        x: r.x,
        y: r.y,
        width: r.width,
        height: r.height,
      });
    };
    window.addEventListener('mousemove', onMove);
    return () => window.removeEventListener('mousemove', onMove);
  }, [active, locked]);

  // Focus the message input once an element is locked.
  useEffect(() => {
    if (locked) {
      const id = requestAnimationFrame(() => inputRef.current?.focus());
      return () => cancelAnimationFrame(id);
    }
    return undefined;
  }, [locked]);

  // Reset transient state whenever inspector mode is exited.
  useEffect(() => {
    if (!active) {
      setHoverBox(null);
      setLocked(null);
      setText('');
    }
  }, [active]);

  if (!active) return null;

  const onCapturePointer = (e: React.MouseEvent): void => {
    if (locked) return;
    e.preventDefault();
    e.stopPropagation();
    const el = elementAtPoint(e.clientX, e.clientY);
    if (el) setLocked(describeElement(el));
  };

  const submit = (): void => {
    if (!locked) return;
    const trimmed = text.trim();
    const summary =
      trimmed ||
      `Inspect ${locked.tagName}${
        locked.componentName ? ` (${locked.componentName})` : ''
      }`;
    send(summary, {
      selector: locked.selector,
      sourceHint: locked.sourceHint,
      componentName: locked.componentName,
    });
    setMode('idle');
  };

  const box = locked
    ? {
        x: locked.box[0],
        y: locked.box[1],
        width: locked.box[2],
        height: locked.box[3],
      }
    : hoverBox;

  return (
    <div
      data-flan-overlay="inspector"
      onClick={onCapturePointer}
      style={{
        position: 'fixed',
        inset: 0,
        zIndex: 2147483600,
        cursor: locked ? 'default' : 'crosshair',
        fontFamily:
          '-apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif',
      }}
    >
      {box && (
        <div
          style={{
            position: 'fixed',
            left: box.x,
            top: box.y,
            width: box.width,
            height: box.height,
            background: locked ? COLORS.locked : COLORS.highlight,
            border: `1.5px solid ${
              locked ? COLORS.lockedBorder : COLORS.highlightBorder
            }`,
            boxSizing: 'border-box',
            pointerEvents: 'none',
          }}
        />
      )}

      {!locked && (
        <div
          style={{
            position: 'fixed',
            top: 16,
            left: '50%',
            transform: 'translateX(-50%)',
            background: COLORS.panel,
            color: COLORS.accent,
            fontSize: 12,
            fontWeight: 600,
            padding: '6px 12px',
            borderRadius: 999,
            border: `1px solid ${COLORS.accent}`,
          }}
        >
          Inspector — click an element · Esc to exit
        </div>
      )}

      {locked && (
        <div
          onClick={(e) => e.stopPropagation()}
          style={{
            position: 'fixed',
            bottom: 24,
            left: '50%',
            transform: 'translateX(-50%)',
            width: 460,
            maxWidth: '90vw',
            background: COLORS.panel,
            borderRadius: 10,
            border: `1.5px solid ${COLORS.accent}`,
            boxShadow: '0 8px 24px rgba(0, 0, 0, 0.5)',
            padding: 12,
          }}
        >
          <div
            style={{
              color: COLORS.textDim,
              fontSize: 11,
              marginBottom: 8,
              lineHeight: 1.5,
              wordBreak: 'break-all',
            }}
          >
            <strong style={{ color: COLORS.text }}>
              &lt;{locked.tagName}&gt;
            </strong>
            {locked.componentName ? ` · ${locked.componentName}` : ''}
            <br />
            {locked.selector}
            {locked.sourceHint ? (
              <>
                <br />
                {locked.sourceHint}
              </>
            ) : null}
          </div>
          <input
            ref={inputRef}
            value={text}
            onChange={(e) => setText(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === 'Enter') {
                e.preventDefault();
                submit();
              } else if (e.key === 'Escape') {
                e.preventDefault();
                setMode('idle');
              }
            }}
            placeholder="Message about this element… (Enter to send)"
            style={{
              width: '100%',
              boxSizing: 'border-box',
              background: 'transparent',
              color: COLORS.text,
              fontSize: 14,
              border: '1px solid #333344',
              borderRadius: 6,
              padding: '8px 10px',
              outline: 'none',
              fontFamily: 'inherit',
            }}
          />
        </div>
      )}
    </div>
  );
}
