/**
 * WebSocket transport to the Flan server's `/ws` endpoint.
 *
 * Auto-reconnects with capped exponential backoff, sends periodic pings,
 * and exposes connection status plus the server-reported queue depth.
 * Messages sent while disconnected are buffered and flushed on reconnect.
 */
import type {
  FlanConnectionStatus,
  FlanWebMessage,
} from './types.js';

export interface FlanTransportOptions {
  /** Full ws:// or wss:// URL of the Flan server's /ws endpoint. */
  url: string;
  /** Called whenever the connection status changes. */
  onStatus?: (status: FlanConnectionStatus) => void;
  /** Called with the server-reported queue depth. */
  onQueued?: (queued: number) => void;
}

const PING_INTERVAL_MS = 20_000;
const MAX_BACKOFF_MS = 15_000;
const INITIAL_BACKOFF_MS = 500;

export class FlanTransport {
  private readonly url: string;
  private readonly onStatus?: (s: FlanConnectionStatus) => void;
  private readonly onQueued?: (q: number) => void;

  private socket: WebSocket | null = null;
  private status: FlanConnectionStatus = 'disconnected';
  private backoffMs = INITIAL_BACKOFF_MS;
  private pingTimer: ReturnType<typeof setInterval> | null = null;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private closedByUser = false;
  /** Messages queued locally while the socket was down. */
  private readonly pending: FlanWebMessage[] = [];

  constructor(options: FlanTransportOptions) {
    this.url = options.url;
    this.onStatus = options.onStatus;
    this.onQueued = options.onQueued;
  }

  /** Opens the connection (idempotent). */
  connect(): void {
    this.closedByUser = false;
    if (
      this.socket &&
      (this.socket.readyState === WebSocket.OPEN ||
        this.socket.readyState === WebSocket.CONNECTING)
    ) {
      return;
    }
    this.openSocket();
  }

  /** Closes the connection and stops reconnecting. */
  close(): void {
    this.closedByUser = true;
    this.clearTimers();
    if (this.socket) {
      try {
        this.socket.close();
      } catch {
        /* ignore */
      }
      this.socket = null;
    }
    this.setStatus('disconnected');
  }

  /** Current connection status. */
  getStatus(): FlanConnectionStatus {
    return this.status;
  }

  /**
   * Sends a feedback message. If the socket is not open, the message is
   * buffered and flushed when the connection is (re)established.
   */
  send(message: FlanWebMessage): void {
    if (this.socket && this.socket.readyState === WebSocket.OPEN) {
      this.socket.send(JSON.stringify(message));
    } else {
      this.pending.push(message);
      this.connect();
    }
  }

  private openSocket(): void {
    this.setStatus('connecting');
    let socket: WebSocket;
    try {
      socket = new WebSocket(this.url);
    } catch {
      this.scheduleReconnect();
      return;
    }
    this.socket = socket;

    socket.onopen = () => {
      this.backoffMs = INITIAL_BACKOFF_MS;
      this.setStatus('connected');
      this.startPing();
      this.flushPending();
    };

    socket.onmessage = (event) => {
      this.handleFrame(event.data);
    };

    socket.onerror = () => {
      // onclose fires next; reconnection is handled there.
    };

    socket.onclose = () => {
      this.stopPing();
      this.socket = null;
      this.setStatus('disconnected');
      if (!this.closedByUser) {
        this.scheduleReconnect();
      }
    };
  }

  private handleFrame(raw: unknown): void {
    if (typeof raw !== 'string') return;
    let parsed: unknown;
    try {
      parsed = JSON.parse(raw);
    } catch {
      return;
    }
    if (
      parsed &&
      typeof parsed === 'object' &&
      (parsed as { kind?: string }).kind === 'status'
    ) {
      const queued = (parsed as { queued?: number }).queued;
      if (typeof queued === 'number') {
        this.onQueued?.(queued);
      }
    }
    // {"kind":"pong"} frames need no handling.
  }

  private flushPending(): void {
    if (!this.socket || this.socket.readyState !== WebSocket.OPEN) return;
    while (this.pending.length > 0) {
      const msg = this.pending.shift()!;
      this.socket.send(JSON.stringify(msg));
    }
  }

  private startPing(): void {
    this.stopPing();
    this.pingTimer = setInterval(() => {
      if (this.socket && this.socket.readyState === WebSocket.OPEN) {
        this.socket.send(JSON.stringify({ kind: 'ping' }));
      }
    }, PING_INTERVAL_MS);
  }

  private stopPing(): void {
    if (this.pingTimer !== null) {
      clearInterval(this.pingTimer);
      this.pingTimer = null;
    }
  }

  private scheduleReconnect(): void {
    if (this.closedByUser || this.reconnectTimer !== null) return;
    const delay = this.backoffMs;
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      this.openSocket();
    }, delay);
    this.backoffMs = Math.min(this.backoffMs * 2, MAX_BACKOFF_MS);
  }

  private clearTimers(): void {
    this.stopPing();
    if (this.reconnectTimer !== null) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
  }

  private setStatus(status: FlanConnectionStatus): void {
    if (this.status === status) return;
    this.status = status;
    this.onStatus?.(status);
  }
}
