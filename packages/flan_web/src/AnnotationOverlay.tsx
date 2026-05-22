/**
 * Annotation overlay — drag to draw labeled rectangles over the page,
 * each paired with the DOM element under its center. Enter while drawing
 * commits the box and its label; the panel sends all annotations as one
 * message. Mirrors flan_flutter's annotation mode (Ctrl+Shift+A).
 */
import { useEffect, useRef, useState } from 'react';
import { useFlan } from './context.js';
import { cssSelectorFor, elementAtPoint, sourceHintFor } from './dom.js';
import type { FlanAnnotation } from './types.js';

const COLORS = {
  draw: 'rgba(255, 102, 0, 0.16)',
  drawBorder: '#FF6600',
  committed: 'rgba(255, 102, 0, 0.10)',
  committedBorder: '#FF6600',
  panel: '#201410',
  panelBorder: '#FF6600',
  text: '#FFC8A0',
  textBright: '#FFE0CC',
  accent: '#FF6600',
};

interface DrawRect {
  x: number;
  y: number;
  width: number;
  height: number;
}

let annotationSeq = 0;

function rectFromPoints(
  ax: number,
  ay: number,
  bx: number,
  by: number,
): DrawRect {
  return {
    x: Math.min(ax, bx),
    y: Math.min(ay, by),
    width: Math.abs(bx - ax),
    height: Math.abs(by - ay),
  };
}

export function AnnotationOverlay(): JSX.Element | null {
  const { mode, setMode, send } = useFlan();
  const [annotations, setAnnotations] = useState<FlanAnnotation[]>([]);
  const [drawing, setDrawing] = useState<DrawRect | null>(null);
  const [pendingRect, setPendingRect] = useState<DrawRect | null>(null);
  const [labelText, setLabelText] = useState('');
  const dragStart = useRef<{ x: number; y: number } | null>(null);
  const labelRef = useRef<HTMLInputElement>(null);

  const active = mode === 'annotation';

  // Reset all transient state when annotation mode is exited.
  useEffect(() => {
    if (!active) {
      setAnnotations([]);
      setDrawing(null);
      setPendingRect(null);
      setLabelText('');
      dragStart.current = null;
    }
  }, [active]);

  // Focus the label input once a rectangle has been drawn.
  useEffect(() => {
    if (pendingRect) {
      const id = requestAnimationFrame(() => labelRef.current?.focus());
      return () => cancelAnimationFrame(id);
    }
    return undefined;
  }, [pendingRect]);

  if (!active) return null;

  const onPointerDown = (e: React.MouseEvent): void => {
    if (pendingRect) return; // finishing a label — ignore new drags
    dragStart.current = { x: e.clientX, y: e.clientY };
    setDrawing({ x: e.clientX, y: e.clientY, width: 0, height: 0 });
  };

  const onPointerMove = (e: React.MouseEvent): void => {
    const start = dragStart.current;
    if (!start) return;
    setDrawing(
      rectFromPoints(start.x, start.y, e.clientX, e.clientY),
    );
  };

  const onPointerUp = (): void => {
    const rect = drawing;
    dragStart.current = null;
    setDrawing(null);
    if (rect && rect.width > 6 && rect.height > 6) {
      setPendingRect(rect);
    }
  };

  const commitAnnotation = (): void => {
    const rect = pendingRect;
    if (!rect) return;
    const cx = rect.x + rect.width / 2;
    const cy = rect.y + rect.height / 2;
    const el = elementAtPoint(cx, cy);
    const annotation: FlanAnnotation = {
      id: `flan-ann-${++annotationSeq}`,
      text: labelText.trim() || '(no label)',
      box: [
        Math.round(rect.x),
        Math.round(rect.y),
        Math.round(rect.width),
        Math.round(rect.height),
      ],
      selector: el ? cssSelectorFor(el) : undefined,
      sourceHint: el ? sourceHintFor(el) : undefined,
    };
    setAnnotations((prev) => [...prev, annotation]);
    setPendingRect(null);
    setLabelText('');
  };

  const sendAll = (): void => {
    if (annotations.length === 0) {
      setMode('idle');
      return;
    }
    const summary =
      `${annotations.length} annotation(s) on the page:\n` +
      annotations
        .map(
          (a) =>
            `  - "${a.text}"${
              a.selector ? ` @ ${a.selector}` : ''
            }`,
        )
        .join('\n');
    send(summary, { annotations });
    setMode('idle');
  };

  return (
    <div
      data-flan-overlay="annotation"
      onMouseDown={onPointerDown}
      onMouseMove={onPointerMove}
      onMouseUp={onPointerUp}
      style={{
        position: 'fixed',
        inset: 0,
        zIndex: 2147483600,
        cursor: pendingRect ? 'default' : 'crosshair',
        fontFamily:
          '-apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif',
      }}
    >
      {/* Committed annotations. */}
      {annotations.map((a) => (
        <div
          key={a.id}
          style={{
            position: 'fixed',
            left: a.box[0],
            top: a.box[1],
            width: a.box[2],
            height: a.box[3],
            background: COLORS.committed,
            border: `1.5px solid ${COLORS.committedBorder}`,
            boxSizing: 'border-box',
            pointerEvents: 'none',
          }}
        >
          <div
            style={{
              position: 'absolute',
              top: -20,
              left: 0,
              background: COLORS.committedBorder,
              color: '#fff',
              fontSize: 11,
              padding: '1px 6px',
              borderRadius: 3,
              whiteSpace: 'nowrap',
              maxWidth: 240,
              overflow: 'hidden',
              textOverflow: 'ellipsis',
            }}
          >
            {a.text}
          </div>
        </div>
      ))}

      {/* In-progress drag rectangle. */}
      {drawing && (
        <div
          style={{
            position: 'fixed',
            left: drawing.x,
            top: drawing.y,
            width: drawing.width,
            height: drawing.height,
            background: COLORS.draw,
            border: `1.5px dashed ${COLORS.drawBorder}`,
            boxSizing: 'border-box',
            pointerEvents: 'none',
          }}
        />
      )}

      {/* Label input for a freshly-drawn rectangle. */}
      {pendingRect && (
        <div
          onMouseDown={(e) => e.stopPropagation()}
          style={{
            position: 'fixed',
            left: Math.min(pendingRect.x, window.innerWidth - 260),
            top: Math.min(
              pendingRect.y + pendingRect.height + 4,
              window.innerHeight - 44,
            ),
            width: 248,
          }}
        >
          <input
            ref={labelRef}
            value={labelText}
            onChange={(e) => setLabelText(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === 'Enter') {
                e.preventDefault();
                commitAnnotation();
              } else if (e.key === 'Escape') {
                e.preventDefault();
                setPendingRect(null);
                setLabelText('');
              }
            }}
            placeholder="Label this annotation… (Enter)"
            style={{
              width: '100%',
              boxSizing: 'border-box',
              background: COLORS.panel,
              color: COLORS.textBright,
              fontSize: 13,
              border: `1px solid ${COLORS.panelBorder}`,
              borderRadius: 4,
              padding: '6px 8px',
              outline: 'none',
              fontFamily: 'inherit',
            }}
          />
        </div>
      )}

      {/* Status / send bar. */}
      <div
        onMouseDown={(e) => e.stopPropagation()}
        style={{
          position: 'fixed',
          top: 16,
          left: '50%',
          transform: 'translateX(-50%)',
          display: 'flex',
          alignItems: 'center',
          gap: 10,
          background: COLORS.panel,
          color: COLORS.text,
          fontSize: 12,
          fontWeight: 600,
          padding: '6px 12px',
          borderRadius: 999,
          border: `1px solid ${COLORS.panelBorder}`,
        }}
      >
        <span>
          Annotation mode — drag to draw
          {annotations.length > 0
            ? ` · ${annotations.length} drawn`
            : ''}
        </span>
        {annotations.length > 0 && (
          <button
            onClick={sendAll}
            style={{
              background: COLORS.accent,
              color: '#fff',
              border: 'none',
              borderRadius: 4,
              fontSize: 11,
              fontWeight: 700,
              padding: '3px 10px',
              cursor: 'pointer',
            }}
          >
            Send
          </button>
        )}
      </div>
    </div>
  );
}
