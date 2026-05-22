/**
 * Global keyboard shortcuts for toggling Flan overlay modes, mirroring
 * flan_flutter's bindings:
 *   - double-tap Alt   → message overlay
 *   - Ctrl+Shift+A     → annotation mode
 *   - Ctrl+Shift+H     → inspector mode
 *   - Escape           → close / return to idle
 */
import { useEffect } from 'react';
import type { FlanMode } from './context.js';

const DOUBLE_TAP_MS = 500;

export function useFlanShortcuts(
  mode: FlanMode,
  setMode: (mode: FlanMode) => void,
): void {
  useEffect(() => {
    let lastAltPress = 0;

    const onKeyDown = (e: KeyboardEvent): void => {
      // Double-tap Alt → message overlay.
      if (e.key === 'Alt' && !e.ctrlKey && !e.metaKey && !e.shiftKey) {
        const now = Date.now();
        if (now - lastAltPress < DOUBLE_TAP_MS) {
          lastAltPress = 0;
          e.preventDefault();
          setMode(mode === 'message' ? 'idle' : 'message');
        } else {
          lastAltPress = now;
        }
        return;
      }

      // Escape exits the active mode.
      if (e.key === 'Escape' && mode !== 'idle') {
        e.preventDefault();
        setMode('idle');
        return;
      }

      // Ctrl+Shift combos. Avoid Cmd/Meta to dodge browser shortcuts.
      if (!e.ctrlKey || !e.shiftKey || e.metaKey) return;

      const key = e.key.toLowerCase();
      if (key === 'a') {
        e.preventDefault();
        setMode(mode === 'annotation' ? 'idle' : 'annotation');
      } else if (key === 'h') {
        e.preventDefault();
        setMode(mode === 'inspector' ? 'idle' : 'inspector');
      }
    };

    window.addEventListener('keydown', onKeyDown);
    return () => window.removeEventListener('keydown', onKeyDown);
  }, [mode, setMode]);
}
