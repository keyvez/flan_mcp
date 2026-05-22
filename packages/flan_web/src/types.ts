/**
 * Shared types for flan_web — the React-side command center that sends
 * annotated UI feedback to an AI agent through the Flan MCP server.
 */

/** An annotation: a labeled rectangle drawn over a DOM element. */
export interface FlanAnnotation {
  /** Stable client-generated id. */
  id: string;
  /** The user's label for this annotation. */
  text: string;
  /** Bounding box in viewport (CSS) pixels: [x, y, width, height]. */
  box: [number, number, number, number];
  /** CSS selector path of the element under the annotation's center. */
  selector?: string;
  /** "file:line" source hint, if a build-time plugin stamped it. */
  sourceHint?: string;
  /** React component display name, if resolvable. */
  componentName?: string;
}

/** A located DOM element captured by the inspector. */
export interface FlanInspectorSelection {
  /** Lowercase tag name, e.g. "button". */
  tagName: string;
  /** CSS selector path from document root to the element. */
  selector: string;
  /** Trimmed text content (truncated). */
  text?: string;
  /** Bounding box in viewport pixels: [x, y, width, height]. */
  box: [number, number, number, number];
  /** "file:line" source hint, if available. */
  sourceHint?: string;
  /** React component display name, if resolvable. */
  componentName?: string;
}

/**
 * Structured context attached to a message's `data` field. Mirrors the
 * fields the MCP server's `_appendWebContext` formatter reads.
 */
export interface FlanMessageData {
  /** Current page URL (location.href). */
  url?: string;
  /** CSS selector of the primary selected element. */
  selector?: string;
  /** "file:line" source hint for the selected element. */
  sourceHint?: string;
  /** React component display name. */
  componentName?: string;
  /** Annotations drawn for this message. */
  annotations?: FlanAnnotation[];
  /** A data-URL PNG of a free-hand sketch, if drawn. */
  drawingImage?: string;
  /** Allow forward-compatible extra fields. */
  [key: string]: unknown;
}

/**
 * A feedback message sent to the server. Matches the Rust `WebMessage`
 * deserializer: only `text` is required; the server assigns `queue_id`
 * and `timestamp`.
 */
export interface FlanWebMessage {
  type?: string;
  text: string;
  data?: FlanMessageData;
}

/** Connection lifecycle state of the WebSocket transport. */
export type FlanConnectionStatus =
  | 'connecting'
  | 'connected'
  | 'disconnected';

/** A server→client status frame ({"kind":"status","queued":N}). */
export interface FlanServerStatus {
  kind: 'status';
  queued: number;
}
