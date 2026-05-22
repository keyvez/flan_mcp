/**
 * The message overlay — a centered modal with a textarea for free-form
 * feedback. Enter (or Cmd/Ctrl+Enter) sends; Shift+Enter inserts a
 * newline; Escape closes. Mirrors flan_flutter's command overlay.
 */
import { useEffect, useRef, useState } from 'react';
import { useFlan } from './context.js';
import type { FlanConnectionStatus } from './types.js';

const COLORS = {
  backdrop: 'rgba(0, 0, 0, 0.53)',
  panel: '#1A1A2E',
  border: '#00AAFF',
  text: '#E0E0E0',
  textDim: 'rgba(224, 224, 232, 0.5)',
  accent: '#00AAFF',
  green: '#00B894',
  red: '#E17055',
};

function statusColor(status: FlanConnectionStatus): string {
  if (status === 'connected') return COLORS.green;
  if (status === 'connecting') return COLORS.accent;
  return COLORS.red;
}

export function MessageOverlay(): JSX.Element | null {
  const { mode, setMode, send, status, queued } = useFlan();
  const [text, setText] = useState('');
  const textareaRef = useRef<HTMLTextAreaElement>(null);

  const visible = mode === 'message';

  useEffect(() => {
    if (visible) {
      // Focus after paint so the textarea is mounted.
      const id = requestAnimationFrame(() => textareaRef.current?.focus());
      return () => cancelAnimationFrame(id);
    }
    return undefined;
  }, [visible]);

  if (!visible) return null;

  const submit = (): void => {
    const trimmed = text.trim();
    if (!trimmed) {
      setMode('idle');
      return;
    }
    send(trimmed);
    setText('');
    setMode('idle');
  };

  const onKeyDown = (e: React.KeyboardEvent<HTMLTextAreaElement>): void => {
    if (e.key === 'Enter' && !e.shiftKey) {
      // Plain Enter or Cmd/Ctrl+Enter both send. Shift+Enter = newline.
      e.preventDefault();
      submit();
    } else if (e.key === 'Escape') {
      e.preventDefault();
      setMode('idle');
    }
  };

  return (
    <div
      data-flan-overlay="message"
      onClick={() => setMode('idle')}
      style={{
        position: 'fixed',
        inset: 0,
        background: COLORS.backdrop,
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        zIndex: 2147483600,
        fontFamily:
          '-apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif',
      }}
    >
      <div
        onClick={(e) => e.stopPropagation()}
        style={{
          width: 480,
          maxWidth: '90vw',
          background: COLORS.panel,
          borderRadius: 12,
          border: `1.5px solid ${COLORS.border}`,
          boxShadow: '0 8px 24px rgba(0, 0, 0, 0.53)',
          overflow: 'hidden',
        }}
      >
        <div
          style={{
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'space-between',
            padding: '12px 16px',
            borderBottom: '1px solid #333344',
          }}
        >
          <span
            style={{
              color: COLORS.accent,
              fontSize: 13,
              fontWeight: 600,
            }}
          >
            Send message to agent
          </span>
          <span
            style={{
              display: 'flex',
              alignItems: 'center',
              gap: 6,
              color: COLORS.textDim,
              fontSize: 11,
            }}
          >
            <span
              style={{
                width: 8,
                height: 8,
                borderRadius: '50%',
                background: statusColor(status),
              }}
            />
            {status}
            {queued > 0 ? ` · ${queued} queued` : ''}
          </span>
        </div>

        <div style={{ padding: 12 }}>
          <textarea
            ref={textareaRef}
            value={text}
            onChange={(e) => setText(e.target.value)}
            onKeyDown={onKeyDown}
            placeholder="Describe what you want changed…"
            rows={4}
            style={{
              width: '100%',
              boxSizing: 'border-box',
              resize: 'vertical',
              background: 'transparent',
              color: COLORS.text,
              fontSize: 14,
              lineHeight: 1.5,
              border: 'none',
              outline: 'none',
              fontFamily: 'inherit',
            }}
          />
        </div>

        <div
          style={{
            padding: '6px 12px',
            borderTop: '1px solid #333344',
            color: COLORS.textDim,
            fontSize: 11,
          }}
        >
          Enter to send · Shift+Enter for new line · Esc to close
        </div>
      </div>
    </div>
  );
}
