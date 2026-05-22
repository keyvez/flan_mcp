/**
 * FlanProvider — the React context that owns the transport, tracks the
 * active overlay mode, and exposes the API the overlay components and
 * host app use.
 */
import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from 'react';
import { FlanTransport } from './transport.js';
import type {
  FlanConnectionStatus,
  FlanMessageData,
  FlanWebMessage,
} from './types.js';

/** Which Flan overlay is currently active. */
export type FlanMode = 'idle' | 'message' | 'annotation' | 'inspector';

export interface FlanContextValue {
  /** Connection status of the WebSocket transport. */
  status: FlanConnectionStatus;
  /** Server-reported number of messages queued for the agent. */
  queued: number;
  /** Currently active overlay mode. */
  mode: FlanMode;
  /** Switches the active overlay mode. */
  setMode: (mode: FlanMode) => void;
  /** Sends a feedback message to the agent via the Flan server. */
  send: (text: string, data?: FlanMessageData) => void;
}

const FlanContext = createContext<FlanContextValue | null>(null);

export interface FlanProviderProps {
  /**
   * Flan server WebSocket URL. Defaults to `ws://127.0.0.1:4050/ws`,
   * matching the Flan server's default port.
   */
  serverUrl?: string;
  /** Whether the in-app command center is active. Defaults to true. */
  enabled?: boolean;
  children?: ReactNode;
}

const DEFAULT_SERVER_URL = 'ws://127.0.0.1:4050/ws';

export function FlanProvider(props: FlanProviderProps): JSX.Element {
  const { serverUrl = DEFAULT_SERVER_URL, enabled = true, children } = props;

  const [status, setStatus] = useState<FlanConnectionStatus>('disconnected');
  const [queued, setQueued] = useState(0);
  const [mode, setMode] = useState<FlanMode>('idle');
  const transportRef = useRef<FlanTransport | null>(null);

  useEffect(() => {
    if (!enabled) return undefined;
    const transport = new FlanTransport({
      url: serverUrl,
      onStatus: setStatus,
      onQueued: setQueued,
    });
    transportRef.current = transport;
    transport.connect();
    return () => {
      transport.close();
      transportRef.current = null;
    };
  }, [serverUrl, enabled]);

  const send = useCallback((text: string, data?: FlanMessageData) => {
    const transport = transportRef.current;
    if (!transport) return;
    const message: FlanWebMessage = {
      type: 'user_feedback',
      text,
      data: {
        url: typeof location !== 'undefined' ? location.href : undefined,
        ...data,
      },
    };
    transport.send(message);
  }, []);

  const value = useMemo<FlanContextValue>(
    () => ({ status, queued, mode, setMode, send }),
    [status, queued, mode, send],
  );

  return (
    <FlanContext.Provider value={value}>{children}</FlanContext.Provider>
  );
}

/** Hook returning the Flan context. Throws if used outside FlanProvider. */
export function useFlan(): FlanContextValue {
  const ctx = useContext(FlanContext);
  if (!ctx) {
    throw new Error('useFlan must be used within a <FlanProvider>');
  }
  return ctx;
}
