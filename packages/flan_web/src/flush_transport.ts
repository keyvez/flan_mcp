/**
 * HTTP transport that delivers messages through the Flan server's
 * `/api/flush` endpoint — the same path the Flutter overlay uses.
 *
 * Unlike the `/ws` queue (a single shared inbox any MCP server may drain),
 * a flush carries an `app_id` and the page origin, so the server can route
 * it to the agent the user linked to *this* app in the TUI. It is the
 * transport the injected standalone bundle uses.
 *
 * Messages that cannot be delivered (server down, no agent linked yet) are
 * kept and retried on every health tick, so drawing an annotation before
 * linking the agent loses nothing.
 */
import type { FlanConnectionStatus, FlanWebMessage } from './types.js';

export interface FlanFlushTransportOptions {
  /** Flan server HTTP base, e.g. `http://127.0.0.1:4050`. */
  serverUrl: string;
  /** Identity this page flushes as; must match the row the server shows. */
  appId: string;
  onStatus?: (status: FlanConnectionStatus) => void;
  onQueued?: (queued: number) => void;
}

const HEALTH_INTERVAL_MS = 10_000;

export class FlanFlushTransport {
  private readonly base: string;
  private readonly appId: string;
  private readonly onStatus?: (s: FlanConnectionStatus) => void;
  private readonly onQueued?: (q: number) => void;

  private status: FlanConnectionStatus = 'disconnected';
  private timer: ReturnType<typeof setInterval> | null = null;
  private readonly pending: FlanWebMessage[] = [];
  private flushing = false;

  constructor(options: FlanFlushTransportOptions) {
    this.base = options.serverUrl.replace(/\/+$/, '');
    this.appId = options.appId;
    this.onStatus = options.onStatus;
    this.onQueued = options.onQueued;
  }

  connect(): void {
    if (this.timer !== null) return;
    this.setStatus('connecting');
    void this.tick();
    this.timer = setInterval(() => void this.tick(), HEALTH_INTERVAL_MS);
  }

  close(): void {
    if (this.timer !== null) {
      clearInterval(this.timer);
      this.timer = null;
    }
    this.setStatus('disconnected');
  }

  getStatus(): FlanConnectionStatus {
    return this.status;
  }

  send(message: FlanWebMessage): void {
    this.pending.push(message);
    this.onQueued?.(this.pending.length);
    void this.flush();
  }

  private async tick(): Promise<void> {
    let ok = false;
    try {
      const res = await fetch(`${this.base}/api/health`, { cache: 'no-store' });
      ok = res.ok;
    } catch {
      ok = false;
    }
    this.setStatus(ok ? 'connected' : 'disconnected');
    if (ok && this.pending.length > 0) await this.flush();
  }

  private async flush(): Promise<void> {
    if (this.flushing || this.pending.length === 0) return;
    this.flushing = true;
    try {
      const messages = this.pending.slice();
      const res = await fetch(`${this.base}/api/flush`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          app_id: this.appId,
          origin: location.origin,
          messages,
        }),
      });
      if (res.ok) {
        this.pending.splice(0, messages.length);
        this.setStatus('connected');
      }
      // A 404 means "no linked receiver": keep the messages, the user can
      // link the agent in the TUI and the next tick delivers them.
    } catch {
      this.setStatus('disconnected');
    } finally {
      this.flushing = false;
      this.onQueued?.(this.pending.length);
    }
  }

  private setStatus(status: FlanConnectionStatus): void {
    if (this.status === status) return;
    this.status = status;
    this.onStatus?.(status);
  }
}
