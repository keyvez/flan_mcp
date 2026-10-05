//! Watched ports: web apps the TUI is *told* about.
//!
//! Discovery finds Flutter processes and Flutter web bundles by what they
//! are. A plain dev server — wrangler, vite, a Rails app — is none of those,
//! and its pages carry no Flan code. Naming its port here does two things:
//!
//!   * the listener on that port gets a row in the app column, so it can be
//!     linked to an agent like any other app;
//!   * the server opens a reverse proxy in front of it that injects the
//!     standalone overlay bundle (`/flan.js`) into every HTML page, so the
//!     app gets the pick-and-annotate loop without touching its source.
//!
//! The proxy listens on a port derived from the upstream one — `:9689`
//! becomes `:49689` — and that is the URL to open. Only pages loaded through
//! it are instrumented.
//!
//! Ports come from `~/.flan/watched_ports.json`, `FLAN_WATCH_PORTS`
//! (comma-separated), and the TUI's `--watch` flag; new ones are persisted.

use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::time::{Duration, Instant};

use axum::body::Body;
use axum::extract::{Path, Request, State};
use axum::http::{header, HeaderValue, StatusCode, Uri};
use axum::response::{IntoResponse, Response};
use axum::{Json, Router};
use http_body_util::BodyExt;
use hyper_util::client::legacy::{connect::HttpConnector, Client};
use hyper_util::rt::{TokioExecutor, TokioIo};
use tokio::sync::Mutex;

use crate::{flan_dir, listening_sockets, process_cwds, FlutterApp, SharedState};

/// The standalone overlay bundle, built from `packages/flan_web` with
/// `npm run build:standalone`.
pub const FLAN_JS: &str = include_str!("../static/flan.js");

// ── Configuration ───────────────────────────────────────────────────────

pub fn watched_ports_path() -> PathBuf {
    flan_dir().join("watched_ports.json")
}

/// Persisted ports plus anything named in `FLAN_WATCH_PORTS`.
pub fn load_watched_ports() -> Vec<u16> {
    let mut ports: Vec<u16> = std::fs::read_to_string(watched_ports_path())
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default();
    if let Ok(env) = std::env::var("FLAN_WATCH_PORTS") {
        ports.extend(parse_port_list(&env));
    }
    ports.sort_unstable();
    ports.dedup();
    ports
}

/// "9689, 3000" → [9689, 3000]. Junk is skipped rather than fatal.
pub fn parse_port_list(list: &str) -> Vec<u16> {
    list.split(',')
        .filter_map(|p| p.trim().parse::<u16>().ok())
        .filter(|&p| p != 0)
        .collect()
}

fn save_watched_ports(ports: &[u16]) {
    if let Ok(json) = serde_json::to_string_pretty(ports) {
        let _ = std::fs::write(watched_ports_path(), json);
    }
}

/// Remember `port`; returns the full list afterwards.
pub fn add_watched_port(port: u16) -> Vec<u16> {
    let mut ports = load_watched_ports();
    if !ports.contains(&port) {
        ports.push(port);
        ports.sort_unstable();
    }
    save_watched_ports(&ports);
    ports
}

/// Forget `port`; returns the full list afterwards. A proxy already running
/// for it keeps running until restart — it is harmless without a listener.
pub fn remove_watched_port(port: u16) -> Vec<u16> {
    let ports: Vec<u16> = load_watched_ports().into_iter().filter(|&p| p != port).collect();
    save_watched_ports(&ports);
    ports
}

/// The proxy port for an upstream: `:9689` → `:49689`. Deterministic, so a
/// URL stays the same across restarts and reads as "the same app, shifted".
pub fn proxy_port_for(upstream: u16) -> u16 {
    if upstream <= 25_535 {
        upstream + 40_000
    } else {
        upstream - 10_000
    }
}

/// Identity the injected overlay flushes with and the discovered row carries.
/// The tail is the folder name, which is what `remote_app` shows if the row
/// ever has to be reconstructed from a flush alone.
pub fn app_id_for(port: u16, folder: &str) -> String {
    format!("web:{port}:{folder}")
}

// ── Discovery ───────────────────────────────────────────────────────────

/// One row per watched port that currently has a listener. The row points
/// at the proxy port, because that is the URL the browser is on and the
/// origin its flushes carry.
pub fn discover_watched_web_apps(ports: &[u16]) -> Vec<FlutterApp> {
    if ports.is_empty() {
        return Vec::new();
    }
    let hits: Vec<(u32, u16)> = listening_sockets()
        .into_iter()
        .filter(|(_, port)| ports.contains(port))
        .collect();
    if hits.is_empty() {
        return Vec::new();
    }
    let pid_csv = hits
        .iter()
        .map(|(pid, _)| pid.to_string())
        .collect::<Vec<_>>()
        .join(",");
    let cwds = process_cwds(&pid_csv);

    let mut seen = HashSet::new();
    hits.into_iter()
        .filter_map(|(pid, port)| {
            if !seen.insert(port) {
                return None;
            }
            let cwd = cwds.get(&pid).cloned().unwrap_or_default();
            let folder_name = PathBuf::from(&cwd)
                .file_name()
                .map(|n| n.to_string_lossy().to_string())
                .unwrap_or_default();
            Some(FlutterApp {
                pid,
                app_id: Some(app_id_for(port, &folder_name)),
                host: None,
                folder_name,
                cwd,
                vm_service_uri: None,
                device: Some(format!("web:{port}")),
                queue_count: 0,
                connected: false,
                web_port: Some(proxy_port_for(port)),
            })
        })
        .collect()
}

// ── Proxy ───────────────────────────────────────────────────────────────

#[derive(Clone)]
struct ProxyTarget {
    upstream: u16,
    server_port: u16,
    client: Client<HttpConnector, Body>,
    /// The app id to stamp into pages, refreshed occasionally: it depends on
    /// the listener's cwd, which needs an `lsof` to learn.
    app_id: Arc<Mutex<Option<(Instant, String)>>>,
}

impl ProxyTarget {
    async fn app_id(&self) -> String {
        let mut cache = self.app_id.lock().await;
        if let Some((ts, id)) = &*cache {
            if ts.elapsed() < Duration::from_secs(15) {
                return id.clone();
            }
        }
        let port = self.upstream;
        let id = tokio::task::spawn_blocking(move || {
            discover_watched_web_apps(&[port])
                .into_iter()
                .next()
                .and_then(|app| app.app_id)
        })
        .await
        .ok()
        .flatten()
        .unwrap_or_else(|| app_id_for(port, ""));
        *cache = Some((Instant::now(), id.clone()));
        id
    }

    async fn script_tag(&self) -> String {
        let base = format!("http://127.0.0.1:{}", self.server_port);
        format!(
            "\n<script src=\"{base}/flan.js\" data-flan-server=\"{base}\" \
             data-flan-app-id=\"{}\"></script>\n",
            self.app_id().await
        )
    }
}

/// Start a proxy for every configured port. Called once at startup by both
/// the TUI and the standalone server; `server_port` is where `/flan.js` and
/// `/api/flush` live, which the injected tag has to point at.
pub async fn spawn_watch_proxies(state: Arc<SharedState>, server_port: u16) {
    state.server_port.store(server_port, Ordering::Relaxed);
    for port in load_watched_ports() {
        if let Err(err) = spawn_proxy(&state, port).await {
            tracing::warn!("watch :{port}: {err}");
        }
    }
}

/// Bind the proxy for one upstream port. Idempotent per port.
pub async fn spawn_proxy(state: &Arc<SharedState>, upstream: u16) -> Result<u16, String> {
    let proxy_port = proxy_port_for(upstream);
    {
        let mut active = state.watch_proxies.write().await;
        if active.contains(&upstream) {
            return Ok(proxy_port);
        }
        active.insert(upstream);
    }
    let listener = match tokio::net::TcpListener::bind(("127.0.0.1", proxy_port)).await {
        Ok(listener) => listener,
        Err(err) => {
            state.watch_proxies.write().await.remove(&upstream);
            return Err(format!("cannot bind proxy port {proxy_port}: {err}"));
        }
    };
    let target = ProxyTarget {
        upstream,
        server_port: state.server_port.load(Ordering::Relaxed),
        client: Client::builder(TokioExecutor::new()).build(HttpConnector::new()),
        app_id: Arc::new(Mutex::new(None)),
    };
    let app = Router::new().fallback(proxy_handler).with_state(target);
    tokio::spawn(async move {
        axum::serve(listener, app).await.ok();
    });
    tracing::info!("Watching :{upstream}; instrumented proxy on http://127.0.0.1:{proxy_port}");
    Ok(proxy_port)
}

async fn proxy_handler(State(target): State<ProxyTarget>, mut req: Request) -> Response {
    let path_q = req
        .uri()
        .path_and_query()
        .map(|p| p.as_str().to_string())
        .unwrap_or_else(|| "/".to_string());
    let uri: Uri = match format!("http://127.0.0.1:{}{}", target.upstream, path_q).parse() {
        Ok(uri) => uri,
        Err(_) => return StatusCode::BAD_REQUEST.into_response(),
    };

    // Take the client's upgrade handle *before* the request is consumed;
    // it is only honoured if the upstream actually switches protocols.
    let client_upgrade = req
        .headers()
        .contains_key(header::UPGRADE)
        .then(|| hyper::upgrade::on(&mut req));

    *req.uri_mut() = uri;
    // Identity encoding so HTML can be rewritten. The Host header is left as
    // the browser sent it: apps that key off the hostname (wildcard
    // subdomains) must keep seeing theirs.
    req.headers_mut().remove(header::ACCEPT_ENCODING);

    let mut resp = match target.client.request(req).await {
        Ok(resp) => resp,
        Err(err) => {
            return (
                StatusCode::BAD_GATEWAY,
                format!(
                    "flan proxy: nothing answered on 127.0.0.1:{} ({err})\n",
                    target.upstream
                ),
            )
                .into_response()
        }
    };

    if resp.status() == StatusCode::SWITCHING_PROTOCOLS {
        if let Some(client_upgrade) = client_upgrade {
            let upstream_upgrade = hyper::upgrade::on(&mut resp);
            tokio::spawn(async move {
                if let (Ok(client), Ok(upstream)) =
                    (client_upgrade.await, upstream_upgrade.await)
                {
                    let mut client = TokioIo::new(client);
                    let mut upstream = TokioIo::new(upstream);
                    let _ = tokio::io::copy_bidirectional(&mut client, &mut upstream).await;
                }
            });
        }
        let (parts, _) = resp.into_parts();
        return Response::from_parts(parts, Body::empty());
    }

    let (mut parts, body) = resp.into_parts();
    // The injected script would be refused under the app's own policy, and
    // dev is the one place relaxing it is fine.
    parts.headers.remove("content-security-policy");
    parts.headers.remove("content-security-policy-report-only");

    let header_has = |name: header::HeaderName, pred: &dyn Fn(&str) -> bool| {
        parts
            .headers
            .get(name)
            .and_then(|v| v.to_str().ok())
            .is_some_and(|v| pred(&v.to_ascii_lowercase()))
    };
    let is_html = header_has(header::CONTENT_TYPE, &|ct| ct.contains("text/html"));
    // We asked for identity; an upstream that compressed anyway can't be
    // rewritten without decoding, so it is passed through untouched.
    let is_encoded = header_has(header::CONTENT_ENCODING, &|enc| enc != "identity");
    if !is_html || is_encoded {
        return Response::from_parts(parts, Body::new(body));
    }

    let bytes = match body.collect().await {
        Ok(collected) => collected.to_bytes(),
        Err(err) => {
            return (StatusCode::BAD_GATEWAY, format!("flan proxy: upstream body failed: {err}\n"))
                .into_response()
        }
    };
    let page = inject_script(&bytes, target.script_tag().await.as_bytes());
    parts.headers.remove(header::TRANSFER_ENCODING);
    parts.headers.insert(header::CONTENT_LENGTH, HeaderValue::from(page.len()));
    Response::from_parts(parts, Body::from(page))
}

/// Insert `tag` before `</body>`, else before `</html>`, else at the end.
pub fn inject_script(html: &[u8], tag: &[u8]) -> Vec<u8> {
    let lower = html.to_ascii_lowercase();
    let at = find(&lower, b"</body>")
        .or_else(|| find(&lower, b"</html>"))
        .unwrap_or(html.len());
    let mut out = Vec::with_capacity(html.len() + tag.len());
    out.extend_from_slice(&html[..at]);
    out.extend_from_slice(tag);
    out.extend_from_slice(&html[at..]);
    out
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|w| w == needle)
}

// ── HTTP surface ────────────────────────────────────────────────────────

pub async fn serve_flan_js() -> Response {
    (
        [
            (header::CONTENT_TYPE, "application/javascript; charset=utf-8"),
            (header::CACHE_CONTROL, "no-cache"),
        ],
        FLAN_JS,
    )
        .into_response()
}

#[derive(serde::Serialize)]
pub struct WatchedPort {
    pub port: u16,
    pub proxy_port: u16,
    /// Whether this server has the proxy bound right now.
    pub active: bool,
}

async fn describe(state: &Arc<SharedState>) -> Vec<WatchedPort> {
    let active = state.watch_proxies.read().await;
    load_watched_ports()
        .into_iter()
        .map(|port| WatchedPort {
            port,
            proxy_port: proxy_port_for(port),
            active: active.contains(&port),
        })
        .collect()
}

pub async fn get_watched_ports(State(state): State<Arc<SharedState>>) -> Json<Vec<WatchedPort>> {
    Json(describe(&state).await)
}

#[derive(serde::Deserialize)]
pub struct WatchPortRequest {
    pub port: u16,
}

pub async fn post_watched_port(
    State(state): State<Arc<SharedState>>,
    Json(body): Json<WatchPortRequest>,
) -> Response {
    if body.port == 0 {
        return (StatusCode::BAD_REQUEST, "port must be 1-65535").into_response();
    }
    add_watched_port(body.port);
    state.log("out", format!("Watching port :{}", body.port), None, true).await;
    match spawn_proxy(&state, body.port).await {
        Ok(_) => Json(describe(&state).await).into_response(),
        Err(err) => (StatusCode::CONFLICT, err).into_response(),
    }
}

pub async fn delete_watched_port(
    State(state): State<Arc<SharedState>>,
    Path(port): Path<u16>,
) -> Json<Vec<WatchedPort>> {
    remove_watched_port(port);
    Json(describe(&state).await)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn proxy_port_is_stable_and_in_range() {
        assert_eq!(proxy_port_for(9689), 49689);
        assert_eq!(proxy_port_for(3000), 43000);
        assert_eq!(proxy_port_for(25535), 65535);
        assert_eq!(proxy_port_for(25536), 15536);
        assert_eq!(proxy_port_for(65535), 55535);
    }

    #[test]
    fn injects_before_body_close_case_insensitively() {
        let out = inject_script(b"<html><BODY>hi</BODY></html>", b"<script></script>");
        assert_eq!(out, b"<html><BODY>hi<script></script></BODY></html>");
    }

    #[test]
    fn injects_before_html_close_or_appends() {
        assert_eq!(inject_script(b"<html>x</html>", b"T"), b"<html>xT</html>");
        assert_eq!(inject_script(b"fragment", b"T"), b"fragmentT");
    }

    #[test]
    fn parses_port_lists_forgivingly() {
        assert_eq!(parse_port_list("9689, 3000,junk,0,"), vec![9689, 3000]);
    }
}
