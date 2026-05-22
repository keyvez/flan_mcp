/**
 * flan_web — the React-side command center for Flan.
 *
 * Lets a web app send annotated UI feedback to an AI coding agent
 * through the Flan MCP server, the same way `flan_flutter` does for
 * Flutter apps.
 *
 * Usage:
 *   import { FlanProvider, FlanCommandCenter } from 'flan_web';
 *
 *   <FlanProvider serverUrl="ws://127.0.0.1:4050/ws">
 *     <App />
 *     <FlanCommandCenter />
 *   </FlanProvider>
 *
 * Shortcuts: double-tap Alt (message), Ctrl+Shift+A (annotations),
 * Ctrl+Shift+H (inspector), Esc (close).
 */
export { FlanProvider, useFlan } from './context.js';
export type {
  FlanContextValue,
  FlanMode,
  FlanProviderProps,
} from './context.js';
export { FlanCommandCenter } from './FlanCommandCenter.js';
export { MessageOverlay } from './MessageOverlay.js';
export { AnnotationOverlay } from './AnnotationOverlay.js';
export { InspectorOverlay } from './InspectorOverlay.js';
export { useFlanShortcuts } from './useFlanShortcuts.js';
export { FlanTransport } from './transport.js';
export type { FlanTransportOptions } from './transport.js';
export {
  cssSelectorFor,
  describeElement,
  elementAtPoint,
  sourceHintFor,
  componentNameFor,
} from './dom.js';
export type {
  FlanAnnotation,
  FlanConnectionStatus,
  FlanInspectorSelection,
  FlanMessageData,
  FlanServerStatus,
  FlanWebMessage,
} from './types.js';
