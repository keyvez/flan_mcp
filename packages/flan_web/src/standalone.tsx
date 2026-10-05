/**
 * Standalone entry — the bundle the Flan server serves as `/flan.js` and
 * injects into pages it proxies for a watched port.
 *
 * The host page has no React and no Flan wiring, so this file brings both:
 * it mounts its own root at the end of <body> and reads its configuration
 * from the script tag's data attributes:
 *
 *   <script src="http://127.0.0.1:4050/flan.js"
 *           data-flan-server="http://127.0.0.1:4050"
 *           data-flan-app-id="web:9689:career-site"></script>
 *
 * With an app id the overlay flushes to `/api/flush` (routed to the linked
 * agent); without one it falls back to the shared `/ws` queue.
 */
import { createRoot } from 'react-dom/client';
import { FlanProvider } from './context.js';
import { FlanCommandCenter } from './FlanCommandCenter.js';

// `currentScript` is only set while the script is executing, so read it
// now rather than inside the (possibly deferred) boot.
const script = document.currentScript as HTMLScriptElement | null;
const serverUrl = script?.dataset.flanServer || 'http://127.0.0.1:4050';
const appId = script?.dataset.flanAppId || undefined;

const FLAG = '__flanStandaloneMounted';

function boot(): void {
  const w = window as unknown as Record<string, unknown>;
  if (w[FLAG]) return;
  w[FLAG] = true;

  const host = document.createElement('div');
  host.id = 'flan-root';
  document.body.appendChild(host);
  createRoot(host).render(
    <FlanProvider serverUrl={serverUrl} appId={appId}>
      <FlanCommandCenter />
    </FlanProvider>,
  );
}

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', boot);
} else {
  boot();
}
