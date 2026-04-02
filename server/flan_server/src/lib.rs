use serde::{Deserialize, Serialize};
use std::{
    collections::{HashSet, VecDeque},
    io::{BufRead, BufReader, Read, Write as IoWrite},
    net::TcpStream,
    path::PathBuf,
    process::Command,
    sync::Arc,
    time::{Duration, Instant},
};

/// Strip ANSI/VT escape sequences and ASCII control characters from a string,
/// leaving only printable text suitable for TUI display.
pub fn strip_ansi(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let bytes = s.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'\x1b' {
            // ESC — consume the escape sequence
            i += 1;
            if i < bytes.len() {
                match bytes[i] {
                    // CSI: ESC [ ... final-byte (0x40–0x7E)
                    b'[' => {
                        i += 1;
                        while i < bytes.len() && !(0x40..=0x7e).contains(&bytes[i]) {
                            i += 1;
                        }
                        i += 1; // consume final byte
                    }
                    // OSC: ESC ] ... ST (BEL or ESC \)
                    b']' => {
                        i += 1;
                        while i < bytes.len() {
                            if bytes[i] == b'\x07' {
                                i += 1;
                                break;
                            }
                            if bytes[i] == b'\x1b' && i + 1 < bytes.len() && bytes[i + 1] == b'\\' {
                                i += 2;
                                break;
                            }
                            i += 1;
                        }
                    }
                    // Other two-char sequences: ESC <byte>
                    _ => { i += 1; }
                }
            }
        } else if bytes[i] < 0x20 || bytes[i] == 0x7f {
            // Skip other control characters (DEL, non-printable ASCII)
            i += 1;
        } else {
            // Find the end of this UTF-8 character and push it
            let ch_len = utf8_char_len(bytes[i]);
            if i + ch_len <= bytes.len() {
                out.push_str(&s[i..i + ch_len]);
            }
            i += ch_len;
        }
    }
    out
}

fn utf8_char_len(b: u8) -> usize {
    if b < 0x80 { 1 }
    else if b < 0xe0 { 2 }
    else if b < 0xf0 { 3 }
    else { 4 }
}
use tokio::sync::RwLock;

pub mod desktop_bridge;

// ── Models ──────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ClaudeProcess {
    pub pid: u32,
    pub cwd: String,
    pub folder_name: String,
    pub last_message_preview: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FlutterApp {
    pub pid: u32,
    pub cwd: String,
    pub folder_name: String,
    pub vm_service_uri: Option<String>,
    pub device: Option<String>,
    #[serde(default)]
    pub queue_count: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CmuxSurface {
    pub id: String,
    pub title: String,
    pub pane_id: String,
    pub focused: bool,
    /// Working directory of the Claude process in this surface, if known.
    pub cwd: Option<String>,
}

/// A pane in the trm terminal emulator.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TrmPane {
    /// Zero-based pane index (used to send input via trm socket).
    pub index: usize,
    /// Folder name of the cwd (e.g. "charge/web"), or None if empty/unknown.
    pub folder_name: Option<String>,
    /// Full cwd path, if known.
    pub cwd: Option<String>,
    /// Whether a claude process is running in this pane.
    pub has_claude: bool,
    /// Surface ID from trm's RPC (e.g. "surface-13"), used for surface.focus.
    #[serde(default)]
    pub surface_id: Option<String>,
    /// Raw title from trm's surface.list, used as fallback display when cwd is unknown.
    #[serde(default)]
    pub title: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Association {
    pub id: String,
    pub claude_surface_id: String,
    pub flutter_pid: u32,
}

/// Represents the floss desktop agent (system-wide interaction target).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DesktopTarget {
    pub alive: bool,
    pub socket_path: String,
    pub version: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct LogEntry {
    pub timestamp: String,
    pub direction: &'static str,
    pub summary: String,
    pub detail: Option<String>,
    pub ok: bool,
}

// ── Shared Server State ─────────────────────────────────────────────────

pub const MAX_LOG_ENTRIES: usize = 200;

pub struct SharedState {
    pub associations: RwLock<Vec<Association>>,
    pub persistence_path: PathBuf,
    pub claude_cache: RwLock<Option<(Instant, Vec<ClaudeProcess>)>>,
    pub flutter_cache: RwLock<Option<(Instant, Vec<FlutterApp>)>>,
    pub desktop_cache: RwLock<Option<(Instant, DesktopTarget)>>,
    pub activity_log: RwLock<VecDeque<LogEntry>>,
}

impl SharedState {
    pub fn new() -> Self {
        let persistence_path = flan_dir().join("associations.json");
        let associations = load_associations(&persistence_path);
        Self {
            associations: RwLock::new(associations),
            persistence_path,
            claude_cache: RwLock::new(None),
            flutter_cache: RwLock::new(None),
            desktop_cache: RwLock::new(None),
            activity_log: RwLock::new(VecDeque::new()),
        }
    }

    pub async fn log(
        &self,
        direction: &'static str,
        summary: String,
        detail: Option<String>,
        ok: bool,
    ) {
        let entry = LogEntry {
            timestamp: chrono_now(),
            direction,
            summary,
            detail,
            ok,
        };
        let mut log = self.activity_log.write().await;
        if log.len() >= MAX_LOG_ENTRIES {
            log.pop_front();
        }
        log.push_back(entry);
    }
}

// ── HTTP Server (Router) ────────────────────────────────────────────────

mod server {
    use super::*;
    use axum::{
        extract::{Query, State},
        http::StatusCode,
        response::{Html, IntoResponse},
        routing::{delete, get, post},
        Json, Router,
    };
    use tower_http::cors::{Any, CorsLayer};
    use tower_http::trace::TraceLayer;

    #[derive(Debug, Deserialize)]
    struct CreateAssociation {
        claude_surface_id: String,
        flutter_pid: u32,
    }

    #[derive(Debug, Deserialize)]
    struct FlushRequest {
        flutter_pid: Option<u32>,
        vm_service_uri: Option<String>,
        /// "desktop" to route to floss instead of Flutter VM service.
        mode: Option<String>,
    }

    #[derive(Debug, Deserialize)]
    struct FocusSurfaceRequest {
        surface_id: String,
    }

    #[derive(Debug, Deserialize)]
    struct TestSendRequest {
        surface_id: String,
        text: Option<String>,
    }

    #[derive(Debug, Deserialize)]
    struct FocusAppRequest {
        device: String,
    }

    async fn get_claude_processes(
        State(state): State<Arc<SharedState>>,
    ) -> Json<Vec<ClaudeProcess>> {
        {
            let cache = state.claude_cache.read().await;
            if let Some((ts, ref data)) = *cache {
                if ts.elapsed() < Duration::from_secs(5) {
                    return Json(data.clone());
                }
            }
        }
        let procs = tokio::task::spawn_blocking(discover_claude_processes)
            .await
            .unwrap_or_default();
        *state.claude_cache.write().await = Some((Instant::now(), procs.clone()));
        Json(procs)
    }

    async fn get_flutter_apps(State(state): State<Arc<SharedState>>) -> Json<Vec<FlutterApp>> {
        {
            let cache = state.flutter_cache.read().await;
            if let Some((ts, ref data)) = *cache {
                if ts.elapsed() < Duration::from_secs(5) {
                    return Json(data.clone());
                }
            }
        }
        let apps = tokio::task::spawn_blocking(discover_flutter_apps)
            .await
            .unwrap_or_default();
        *state.flutter_cache.write().await = Some((Instant::now(), apps.clone()));
        Json(apps)
    }

    async fn get_desktop_target(
        State(state): State<Arc<SharedState>>,
    ) -> Json<DesktopTarget> {
        {
            let cache = state.desktop_cache.read().await;
            if let Some((ts, ref data)) = *cache {
                if ts.elapsed() < Duration::from_secs(5) {
                    return Json(data.clone());
                }
            }
        }
        let target = tokio::task::spawn_blocking(discover_desktop_target)
            .await
            .unwrap_or_else(|_| DesktopTarget {
                alive: false,
                socket_path: desktop_bridge::floss_socket_path()
                    .to_string_lossy()
                    .to_string(),
                version: None,
            });
        *state.desktop_cache.write().await = Some((Instant::now(), target.clone()));
        Json(target)
    }

    async fn get_cmux_surfaces() -> Json<Vec<CmuxSurface>> {
        Json(
            tokio::task::spawn_blocking(cmux_surface_list)
                .await
                .unwrap_or_default(),
        )
    }

    async fn get_associations(State(state): State<Arc<SharedState>>) -> Json<Vec<Association>> {
        Json(state.associations.read().await.clone())
    }

    async fn create_association_handler(
        State(state): State<Arc<SharedState>>,
        Json(body): Json<CreateAssociation>,
    ) -> impl IntoResponse {
        let assoc = Association {
            id: new_association_id(),
            claude_surface_id: body.claude_surface_id,
            flutter_pid: body.flutter_pid,
        };
        let mut assocs = state.associations.write().await;
        assocs.retain(|a| a.flutter_pid != assoc.flutter_pid);
        assocs.push(assoc.clone());
        save_associations(&state.persistence_path, &assocs);
        state
            .log(
                "in",
                format!(
                    "Link created: flutter PID {} → surface {}",
                    assoc.flutter_pid,
                    &assoc.claude_surface_id[..8]
                ),
                Some(format!(
                    "surface_id={}, flutter_pid={}",
                    assoc.claude_surface_id, assoc.flutter_pid
                )),
                true,
            )
            .await;
        (StatusCode::CREATED, Json(assoc))
    }

    async fn delete_association_handler(
        State(state): State<Arc<SharedState>>,
        axum::extract::Path(id): axum::extract::Path<String>,
    ) -> StatusCode {
        let mut assocs = state.associations.write().await;
        let before = assocs.len();
        assocs.retain(|a| a.id != id);
        if assocs.len() < before {
            save_associations(&state.persistence_path, &assocs);
            state
                .log("in", format!("Link deleted: {}", id), None, true)
                .await;
            StatusCode::NO_CONTENT
        } else {
            state
                .log(
                    "in",
                    format!("Link delete failed: {} not found", id),
                    None,
                    false,
                )
                .await;
            StatusCode::NOT_FOUND
        }
    }

    async fn handle_flush(
        State(state): State<Arc<SharedState>>,
        Json(body): Json<FlushRequest>,
    ) -> impl IntoResponse {
        tracing::info!("handle_flush: pid={:?} vm_service_uri={:?}", body.flutter_pid, body.vm_service_uri);
        let surfaces: Vec<CmuxSurface> = tokio::task::spawn_blocking(cmux_surface_list)
            .await
            .unwrap_or_default();
        let live_surface_ids: HashSet<String> =
            surfaces.iter().map(|s| s.id.clone()).collect();

        let mut assocs = state.associations.write().await;
        let before = assocs.len();
        assocs.retain(|a| {
            a.claude_surface_id.starts_with("trm:")
                || live_surface_ids.contains(&a.claude_surface_id)
        });
        if assocs.len() < before {
            save_associations(&state.persistence_path, &assocs);
        }

        let assoc = if let Some(pid) = body.flutter_pid {
            // Prefer an exact pid match; fall back to any saved association so
            // that a re-launched Flutter app (new pid) still routes to the
            // linked Claude surface.
            assocs.iter().find(|a| a.flutter_pid == pid)
                .or_else(|| assocs.first())
                .cloned()
        } else {
            assocs.first().cloned()
        };
        let pruned = before - assocs.len();
        drop(assocs);

        // Determine target surface: use association if one exists, otherwise
        // discover a Claude Code surface by title. The typical flow is that
        // flush is the *first contact* — no association exists yet. The
        // message sent here (`flan connect to <uri> ...`) causes Claude Code
        // to connect, which is what creates the association.
        let surface_id = if let Some(ref assoc) = assoc {
            Some(assoc.claude_surface_id.clone())
        } else {
            // Try to find the Claude Code surface whose cwd matches the
            // flutter app's cwd (or an ancestor/descendant), preferring an
            // exact match. Falls back to any Claude Code surface.
            let flutter_cwd = body.flutter_pid
                .map(|pid| get_process_cwd(pid))
                .unwrap_or_default();

            let cc_surfaces: Vec<&CmuxSurface> = surfaces
                .iter()
                .filter(|s| s.title.contains("Claude"))
                .collect();

            cc_surfaces
                .iter()
                .find(|s| {
                    if let (Some(ref scwd), false) = (&s.cwd, flutter_cwd.is_empty()) {
                        scwd == &flutter_cwd
                            || flutter_cwd.starts_with(&format!("{}/", scwd))
                            || scwd.starts_with(&format!("{}/", flutter_cwd))
                    } else {
                        false
                    }
                })
                .or_else(|| cc_surfaces.first())
                .map(|s| s.id.clone())
        };

        let Some(surface_id) = surface_id else {
            state
                .log(
                    "in",
                    "Flush failed: no association and no Claude Code surface found".into(),
                    None,
                    false,
                )
                .await;
            return (
                StatusCode::NOT_FOUND,
                Json(serde_json::json!({"error": "No association or Claude Code surface found"})),
            );
        };

        // Desktop mode: tell Claude to connect in desktop mode instead of Flutter
        let is_desktop = body.mode.as_deref() == Some("desktop")
            || (body.flutter_pid.is_none()
                && body.vm_service_uri.is_none()
                && desktop_bridge::floss_is_alive());

        // Resolve the VM service URI from the request body, association, or
        // by probing the Flutter process.
        let resolved_vm_uri = if is_desktop {
            None
        } else {
            body.vm_service_uri.clone().or_else(|| {
                let flutter_pid = assoc.as_ref().map(|a| a.flutter_pid)
                    .or(body.flutter_pid)?;
                if let Ok(cache) = state.flutter_cache.try_read() {
                    if let Some((_, ref apps)) = *cache {
                        if let Some(app) = apps.iter().find(|a| a.pid == flutter_pid) {
                            return app.vm_service_uri.clone();
                        }
                    }
                }
                probe_vm_service_uri(flutter_pid)
            })
        };

        state
            .log(
                "in",
                format!("Flush (channel) from surface {}…", &surface_id[..8.min(surface_id.len())]),
                resolved_vm_uri.as_ref().map(|u| format!("vm_uri: {}", u)),
                true,
            )
            .await;

        let mut resp = serde_json::json!({"ok": true, "surface_id": surface_id});
        if let Some(ref uri) = resolved_vm_uri {
            resp["vm_service_uri"] = serde_json::Value::String(uri.clone());
        }

        (StatusCode::OK, Json(resp))
    }

    async fn handle_focus_surface(
        State(state): State<Arc<SharedState>>,
        Json(body): Json<FocusSurfaceRequest>,
    ) -> impl IntoResponse {
        let sid = body.surface_id.clone();
        let ok = tokio::task::spawn_blocking(move || cmux_focus_surface(&sid))
            .await
            .unwrap_or(false);
        state
            .log(
                "out",
                format!(
                    "Focus surface {}…",
                    &body.surface_id[..8.min(body.surface_id.len())]
                ),
                None,
                ok,
            )
            .await;
        if ok {
            (StatusCode::OK, Json(serde_json::json!({"ok": true})))
        } else {
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({"error": "Failed to focus surface"})),
            )
        }
    }

    async fn handle_test_send(
        State(state): State<Arc<SharedState>>,
        Json(body): Json<TestSendRequest>,
    ) -> impl IntoResponse {
        let sid = body.surface_id.clone();
        let text = body
            .text
            .unwrap_or_else(|| "[flan test] hello from flan server".to_string());
        let t = text.clone();
        let ok = tokio::task::spawn_blocking(move || cmux_send_text(&sid, &t))
            .await
            .unwrap_or(false);
        state
            .log(
                "out",
                format!(
                    "Test send → {}…",
                    &body.surface_id[..8.min(body.surface_id.len())]
                ),
                Some(format!("text: {}", text)),
                ok,
            )
            .await;
        if ok {
            (
                StatusCode::OK,
                Json(serde_json::json!({"ok": true, "sent": text})),
            )
        } else {
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({"error": "Failed to send test text"})),
            )
        }
    }

    async fn handle_focus_app(
        State(state): State<Arc<SharedState>>,
        Json(body): Json<FocusAppRequest>,
    ) -> impl IntoResponse {
        let device = body.device.clone();
        let d = body.device;
        let ok = tokio::task::spawn_blocking(move || focus_app_by_device(&d))
            .await
            .unwrap_or(false);
        state
            .log("out", format!("Focus app: {}", device), None, ok)
            .await;
        if ok {
            (StatusCode::OK, Json(serde_json::json!({"ok": true})))
        } else {
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({"error": "Failed to focus app"})),
            )
        }
    }

    async fn handle_rescan(State(state): State<Arc<SharedState>>) -> impl IntoResponse {
        *state.claude_cache.write().await = None;
        *state.flutter_cache.write().await = None;
        *state.desktop_cache.write().await = None;
        (StatusCode::OK, Json(serde_json::json!({"ok": true})))
    }

    async fn get_status(
        State(state): State<Arc<SharedState>>,
        Query(params): Query<std::collections::HashMap<String, String>>,
    ) -> Json<serde_json::Value> {
        let flutter_pid: Option<u32> = params.get("pid").and_then(|s| s.parse().ok());
        let assocs = state.associations.read().await;

        // Find the association for this flutter pid (exact match, then any).
        let assoc = if let Some(pid) = flutter_pid {
            assocs.iter().find(|a| a.flutter_pid == pid)
                .or_else(|| assocs.first())
                .cloned()
        } else {
            assocs.first().cloned()
        };

        // Derive a short label from the claude_surface_id.
        // For trm panes, look up the surface's folder_name via discover_trm_panes.
        let linked_label: Option<String> = assoc.as_ref().map(|a| {
            let sid = &a.claude_surface_id;
            if sid.starts_with("trm:") {
                // Try to get the folder_name for this pane from live discovery.
                if let Ok(idx) = sid["trm:".len()..].parse::<usize>() {
                    let panes = discover_trm_panes();
                    panes.iter()
                        .find(|p| p.index == idx)
                        .and_then(|p| p.folder_name.clone())
                        .unwrap_or_else(|| sid.clone())
                } else {
                    sid.clone()
                }
            } else {
                // For cmux surfaces, use the last component of the surface id.
                sid[..8.min(sid.len())].to_string()
            }
        });

        Json(serde_json::json!({
            "has_association": assoc.is_some(),
            "association_count": assocs.len(),
            "linked_label": linked_label,
        }))
    }

    async fn get_activity_log(State(state): State<Arc<SharedState>>) -> impl IntoResponse {
        let log = state.activity_log.read().await;
        let entries: Vec<LogEntry> = log.iter().cloned().collect();
        Json(entries)
    }

    async fn serve_ui() -> Html<&'static str> {
        Html(include_str!("../static/index.html"))
    }

    /// Build the Axum router using the given shared state.
    pub fn build_router(state: Arc<SharedState>) -> Router {
        let cors = CorsLayer::new()
            .allow_origin(Any)
            .allow_methods(Any)
            .allow_headers(Any);

        Router::new()
            .route("/", get(serve_ui))
            .route("/api/claude-processes", get(get_claude_processes))
            .route("/api/flutter-apps", get(get_flutter_apps))
            .route("/api/desktop-target", get(get_desktop_target))
            .route("/api/cmux-surfaces", get(get_cmux_surfaces))
            .route(
                "/api/associations",
                get(get_associations).post(create_association_handler),
            )
            .route(
                "/api/associations/{id}",
                delete(delete_association_handler),
            )
            .route("/api/flush", post(handle_flush))
            .route("/api/focus-surface", post(handle_focus_surface))
            .route("/api/focus-app", post(handle_focus_app))
            .route("/api/test-send", post(handle_test_send))
            .route("/api/rescan", post(handle_rescan))
            .route("/api/status", get(get_status))
            .route("/api/logs", get(get_activity_log))
            .layer(cors)
            .layer(TraceLayer::new_for_http())
            .with_state(state)
    }
}

pub use server::build_router;

// ── Utilities ───────────────────────────────────────────────────────────

pub fn chrono_now() -> String {
    let d = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default();
    let secs = d.as_secs();
    let h = (secs / 3600) % 24;
    let m = (secs / 60) % 60;
    let s = secs % 60;
    let ms = d.subsec_millis();
    format!("{:02}:{:02}:{:02}.{:03}", h, m, s, ms)
}

pub fn flan_dir() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".into());
    let p = PathBuf::from(home).join(".flan");
    std::fs::create_dir_all(&p).ok();
    p
}

pub fn load_associations(path: &PathBuf) -> Vec<Association> {
    std::fs::read_to_string(path)
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

pub fn save_associations(path: &PathBuf, associations: &[Association]) {
    if let Ok(json) = serde_json::to_string_pretty(associations) {
        std::fs::write(path, json).ok();
    }
}

pub fn new_association_id() -> String {
    format!(
        "{}",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis()
    )
}

// ── Discovery: Claude Processes ─────────────────────────────────────────

pub fn discover_claude_processes() -> Vec<ClaudeProcess> {
    let Ok(output) = Command::new("ps")
        .args(["-eo", "pid=,tty=,comm="])
        .output()
    else {
        return Vec::new();
    };

    let stdout = String::from_utf8_lossy(&output.stdout);
    let mut seen_cwds = HashSet::new();
    let mut processes = Vec::new();

    for line in stdout.lines() {
        let parts: Vec<&str> = line.trim().splitn(3, char::is_whitespace).collect();
        if parts.len() < 3 {
            continue;
        }
        let pid: u32 = match parts[0].trim().parse() {
            Ok(p) => p,
            Err(_) => continue,
        };
        let tty = parts[1].trim();
        let comm = parts[2].trim();

        if !comm.contains("claude") || comm.contains("flan") || tty == "??" {
            continue;
        }

        let cwd = get_process_cwd(pid);
        if cwd.is_empty() || seen_cwds.contains(&cwd) {
            continue;
        }
        seen_cwds.insert(cwd.clone());

        let folder_name = cwd.rsplit('/').next().unwrap_or(&cwd).to_string();
        let last_msg = find_last_claude_message(&cwd);

        processes.push(ClaudeProcess {
            pid,
            cwd,
            folder_name,
            last_message_preview: last_msg,
        });
    }

    processes
}

pub fn get_process_cwd(pid: u32) -> String {
    let Ok(output) = Command::new("lsof")
        .args(["-d", "cwd", "-a", "-Fn", "-a", "-p", &pid.to_string()])
        .output()
    else {
        return String::new();
    };

    let stdout = String::from_utf8_lossy(&output.stdout);
    for line in stdout.lines() {
        if let Some(path) = line.strip_prefix('n') {
            if path.starts_with('/') {
                return strip_ansi(path);
            }
        }
    }
    String::new()
}

pub fn find_last_claude_message(cwd: &str) -> Option<String> {
    let home = std::env::var("HOME").ok()?;
    let project_name = cwd.replace('/', "-");
    let project_dir = PathBuf::from(&home)
        .join(".claude")
        .join("projects")
        .join(&project_name);

    if !project_dir.exists() {
        return None;
    }

    let mut jsonl_files: Vec<_> = std::fs::read_dir(&project_dir)
        .ok()?
        .filter_map(|e| e.ok())
        .filter(|e| e.path().extension().is_some_and(|ext| ext == "jsonl"))
        .collect();

    jsonl_files.sort_by_key(|e| {
        std::cmp::Reverse(e.metadata().ok().and_then(|m| m.modified().ok()))
    });

    let latest = jsonl_files.first()?;
    let file = std::fs::File::open(latest.path()).ok()?;
    let reader = BufReader::new(file);
    let lines: Vec<String> = reader.lines().filter_map(|l| l.ok()).collect();

    for line in lines.iter().rev() {
        if let Ok(val) = serde_json::from_str::<serde_json::Value>(line) {
            if val.get("type").and_then(|t| t.as_str()) == Some("assistant") {
                if let Some(content) = val
                    .get("message")
                    .and_then(|m| m.get("content"))
                    .and_then(|c| c.as_array())
                {
                    for item in content {
                        if item.get("type").and_then(|t| t.as_str()) == Some("text") {
                            if let Some(text) = item.get("text").and_then(|t| t.as_str()) {
                                let preview: String = text.chars().take(120).collect();
                                return Some(preview);
                            }
                        }
                    }
                }
            }
        }
    }

    None
}

// ── Discovery: Flutter Apps ─────────────────────────────────────────────

pub fn discover_flutter_apps() -> Vec<FlutterApp> {
    let Ok(output) = Command::new("ps")
        .args(["-eo", "pid,command"])
        .output()
    else {
        return Vec::new();
    };

    let stdout = String::from_utf8_lossy(&output.stdout);
    let mut apps = Vec::new();

    for line in stdout.lines() {
        if !line.contains("flutter_tools.snapshot") || !line.contains(" run ") {
            continue;
        }
        let pid_str = line.trim().split_whitespace().next().unwrap_or("");
        let Ok(pid) = pid_str.parse::<u32>() else {
            continue;
        };

        let device = extract_device_flag(line);
        let cwd = get_process_cwd(pid);
        let folder_name = cwd.rsplit('/').next().unwrap_or(&cwd).to_string();
        let vm_uri = probe_vm_service_uri(pid);

        let queue_count = vm_uri
            .as_deref()
            .map(peek_flan_queue)
            .unwrap_or(0);
        apps.push(FlutterApp {
            pid,
            cwd,
            folder_name,
            vm_service_uri: vm_uri,
            device: Some(device),
            queue_count,
        });
    }

    apps
}

pub fn has_listening_ports(pid: u32) -> bool {
    Command::new("lsof")
        .args([
            "-i", "TCP", "-a", "-p", &pid.to_string(), "-a", "-s", "TCP:LISTEN", "-n", "-P",
        ])
        .output()
        .is_ok_and(|o| {
            String::from_utf8_lossy(&o.stdout)
                .lines()
                .any(|l| l.contains("LISTEN"))
        })
}

pub fn extract_device_flag(cmd_line: &str) -> String {
    let parts: Vec<&str> = cmd_line.split_whitespace().collect();
    for (i, part) in parts.iter().enumerate() {
        if *part == "-d" {
            if let Some(dev) = parts.get(i + 1) {
                return dev.to_string();
            }
        }
    }
    "unknown".to_string()
}

pub fn probe_vm_service_uri(pid: u32) -> Option<String> {
    // First try the process itself
    if let Some(uri) = probe_vm_service_uri_for_pid(pid) {
        return Some(uri);
    }
    // For macOS flutter_tools, the DDS child process holds the listen ports.
    // Check children for a `development-service` process.
    if let Some(uri) = probe_dds_child(pid) {
        return Some(uri);
    }
    None
}

fn probe_vm_service_uri_for_pid(pid: u32) -> Option<String> {
    let output = Command::new("lsof")
        .args([
            "-i", "TCP", "-a", "-p",
            &pid.to_string(),
            "-a", "-s", "TCP:LISTEN", "-n", "-P",
        ])
        .output()
        .ok()?;

    let stdout = String::from_utf8_lossy(&output.stdout);

    for line in stdout.lines() {
        if !line.contains("LISTEN") {
            continue;
        }
        if let Some(cap) = line.split("127.0.0.1:").nth(1) {
            if let Some(port_str) = cap.split_whitespace().next() {
                if let Ok(port) = port_str.parse::<u16>() {
                    if let Some(uri) = probe_port(port) {
                        return Some(uri);
                    }
                }
            }
        }
    }

    None
}

/// Find a `dart development-service` child of `parent_pid`, extract its
/// `--vm-service-uri=` flag, follow the HTTP redirect that the raw VM service
/// returns to discover the DDS URI (which includes the DDS auth token), and
/// return that as a `ws://` URI.
fn probe_dds_child(parent_pid: u32) -> Option<String> {
    let ps_out = Command::new("ps")
        .args(["-eo", "pid,ppid,command"])
        .output()
        .ok()?;
    let ps_str = String::from_utf8_lossy(&ps_out.stdout);

    for line in ps_str.lines() {
        if !line.contains("development-service") {
            continue;
        }
        // Columns: PID  PPID  COMMAND…
        let mut parts = line.trim().splitn(3, char::is_whitespace);
        let _child_pid = parts.next()?;
        let ppid: u32 = parts.next()?.trim().parse().ok()?;
        if ppid != parent_pid {
            continue;
        }
        let cmd = parts.next().unwrap_or("");

        // Extract --vm-service-uri=http://127.0.0.1:<port>/<token>/
        let raw_uri = cmd
            .split_whitespace()
            .find(|s| s.starts_with("--vm-service-uri="))?
            .trim_start_matches("--vm-service-uri=");

        // Parse host:port and path from the URI
        let after_http = raw_uri.trim_start_matches("http://");
        let slash = after_http.find('/')?;
        let host_port = &after_http[..slash];
        let path = &after_http[slash..];

        let port: u16 = host_port.split(':').nth(1)?.parse().ok()?;

        // Connect to the raw VM service; it will 302-redirect to the DDS URI
        let addr = format!("127.0.0.1:{}", port);
        let mut stream =
            TcpStream::connect_timeout(&addr.parse().ok()?, Duration::from_secs(2)).ok()?;
        let req = format!(
            "GET {} HTTP/1.1\r\nHost: {}\r\nConnection: close\r\n\r\n",
            path, host_port
        );
        stream.write_all(req.as_bytes()).ok()?;
        stream.set_read_timeout(Some(Duration::from_secs(3))).ok()?;
        let mut body = String::new();
        stream.read_to_string(&mut body).ok();

        // Look for Location: header.
        // The VM service redirects to a devtools URL like:
        //   http://127.0.0.1:<dds>/<token>/devtools/?uri=ws%3A%2F%2F…%2Fws
        // The WS URI we need is in the `uri=` query parameter.
        for hdr_line in body.lines() {
            if !hdr_line.to_lowercase().starts_with("location:") {
                continue;
            }
            let location = hdr_line[9..].trim();
            // Try to extract `uri=` query param (URL-encoded ws:// URI)
            if let Some(after_uri) = location.split("uri=").nth(1) {
                let encoded = after_uri.split('&').next().unwrap_or(after_uri);
                let decoded = percent_decode(encoded);
                if decoded.starts_with("ws://") {
                    return Some(decoded);
                }
            }
            // Fallback: plain http:// → ws:// conversion (no devtools redirect)
            if location.starts_with("http://") {
                let ws = location
                    .trim_end_matches('/')
                    .replace("http://", "ws://");
                return Some(format!("{}/ws", ws));
            }
        }
    }
    None
}

fn percent_decode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '%' {
            let h1 = chars.next().unwrap_or('0');
            let h2 = chars.next().unwrap_or('0');
            if let Ok(byte) = u8::from_str_radix(&format!("{}{}", h1, h2), 16) {
                out.push(byte as char);
            } else {
                out.push('%');
                out.push(h1);
                out.push(h2);
            }
        } else {
            out.push(c);
        }
    }
    out
}

pub fn probe_port(port: u16) -> Option<String> {
    let addr = format!("127.0.0.1:{}", port);
    let mut stream =
        TcpStream::connect_timeout(&addr.parse().ok()?, Duration::from_secs(2)).ok()?;

    let request = format!(
        "GET / HTTP/1.1\r\nHost: 127.0.0.1:{}\r\nConnection: close\r\n\r\n",
        port
    );
    stream.write_all(request.as_bytes()).ok()?;
    stream
        .set_read_timeout(Some(Duration::from_secs(3)))
        .ok()?;

    let mut body = String::new();
    stream.read_to_string(&mut body).ok();

    if body.contains("Dart Development Service") {
        if let Some(start) = body.find("http://") {
            let rest = &body[start..];
            if let Some(end) = rest.find("/.") {
                let url = &rest[..end + 1];
                let ws = url.replace("http://", "ws://");
                let ws = ws.trim_end_matches('/');
                return Some(format!("{}/ws", ws));
            }
        }
    }

    if body.contains("vm_service") || body.contains("getVM") {
        return Some(format!("ws://127.0.0.1:{}/ws", port));
    }

    None
}

/// Call ext.flutter.flan.peekUserMessages via the VM service WebSocket and
/// return the queue count, or 0 if unreachable / extension not registered.
pub fn peek_flan_queue(ws_uri: &str) -> usize {
    use tungstenite::connect;
    use tungstenite::Message;

    // ws_uri looks like ws://127.0.0.1:PORT/TOKEN/ws
    let (mut socket, _) = match connect(ws_uri) {
        Ok(v) => v,
        Err(_) => return 0,
    };

    let timeout = Duration::from_secs(3);

    // 1. Get the isolate id.
    let get_vm = serde_json::json!({
        "jsonrpc": "2.0", "method": "getVM", "id": "1"
    })
    .to_string();
    if socket.send(Message::Text(get_vm.into())).is_err() { return 0; }

    let isolate_id = 'outer: {
        let deadline = std::time::Instant::now() + timeout;
        loop {
            if std::time::Instant::now() > deadline { break 'outer None; }
            match socket.read() {
                Ok(Message::Text(t)) => {
                    if let Ok(v) = serde_json::from_str::<serde_json::Value>(&t) {
                        if let Some(id) = v["result"]["isolates"][0]["id"].as_str() {
                            break 'outer Some(id.to_string());
                        }
                    }
                }
                Ok(_) => continue,
                Err(_) => break 'outer None,
            }
        }
    };

    let isolate_id = match isolate_id {
        Some(id) => id,
        None => return 0,
    };

    // 2. Call peekUserMessages.
    let peek = serde_json::json!({
        "jsonrpc": "2.0",
        "method": "callServiceExtension",
        "params": {
            "isolateId": isolate_id,
            "method": "ext.flutter.flan.peekUserMessages",
        },
        "id": "2"
    })
    .to_string();
    if socket.send(Message::Text(peek.into())).is_err() { return 0; }

    let deadline = std::time::Instant::now() + timeout;
    loop {
        if std::time::Instant::now() > deadline { return 0; }
        match socket.read() {
            Ok(Message::Text(t)) => {
                if let Ok(v) = serde_json::from_str::<serde_json::Value>(&t) {
                    if v["id"] == "2" {
                        let count = v["result"]["count"].as_u64().unwrap_or(0) as usize;
                        let _ = socket.close(None);
                        return count;
                    }
                }
            }
            Ok(_) => continue,
            Err(_) => return 0,
        }
    }
}

// ── Discovery: trm Panes ────────────────────────────────────────────────

pub fn discover_trm_panes() -> Vec<TrmPane> {
    // surface.list returns surface_id, pane_id, title, focused, and pid (shell child pid).
    // We use the pid directly to look up cwd and claude subprocess — no positional pairing needed.
    let surfaces = trm_rpc("surface.list", serde_json::json!({}))
        .and_then(|r| r.get("result")?.get("surfaces")?.as_array().cloned())
        .unwrap_or_default();

    if surfaces.is_empty() {
        return Vec::new();
    }

    // Build pid→ppid→comm map for all processes (used to find claude children of the shell).
    let Ok(ps_all) = Command::new("ps").args(["-eo", "pid,ppid,comm"]).output() else {
        return Vec::new();
    };
    let ps_all_str = String::from_utf8_lossy(&ps_all.stdout);
    let all_procs: Vec<(u32, u32, String)> = ps_all_str
        .lines()
        .skip(1)
        .filter_map(|l| {
            let mut it = l.split_whitespace();
            let pid: u32 = it.next()?.parse().ok()?;
            let ppid: u32 = it.next()?.parse().ok()?;
            let comm = it.next()?.to_string();
            Some((pid, ppid, comm))
        })
        .collect();

    // Collect all live claude process cwds via lsof (trm pid=0 always, so we enumerate ourselves).
    let home = std::env::var("HOME").unwrap_or_default();
    let claude_cwds: std::collections::HashSet<String> = all_procs
        .iter()
        .filter(|(_, _, comm)| comm.contains("claude") && !comm.contains("flan"))
        .filter_map(|(pid, _, _)| {
            let cwd = get_process_cwd(*pid);
            if cwd.is_empty() { None } else { Some(cwd) }
        })
        .collect();

    // Build a map of (window_id, pane_id) → title for adjacency lookups.
    let pane_titles: std::collections::HashMap<(String, usize), String> = surfaces.iter()
        .filter_map(|s| {
            let window_id = s.get("window_id").and_then(|v| v.as_str())?.to_string();
            let pane_id: usize = s.get("pane_id").and_then(|v| v.as_str())?.parse().ok()?;
            let title = strip_ansi(s.get("title").and_then(|v| v.as_str()).unwrap_or(""));
            Some(((window_id, pane_id), title))
        })
        .collect();

    // Expand a trm title token to a full absolute path where possible.
    let expand_title_path = |t: &str| -> Option<String> {
        let tok = t.split_whitespace()
            .find(|tok| tok.starts_with('/') || tok.starts_with('~') || tok.starts_with('…'))?;
        if tok.starts_with('~') && !home.is_empty() {
            Some(format!("{}{}", home, &tok[1..]))
        } else {
            Some(tok.to_string())
        }
    };

    // Check if a resolved cwd (which may be absolute or "…"-prefixed) matches a claude cwd.
    // "…/dev/foo" matches "/Users/x/dev/foo" because the suffix agrees.
    let cwd_has_claude = |cwd: &str| -> bool {
        if cwd.starts_with('…') {
            let suffix = &cwd[cwd.char_indices().nth(1).map(|(i, _)| i).unwrap_or(1)..];
            claude_cwds.iter().any(|c| c.ends_with(suffix))
        } else {
            claude_cwds.contains(cwd)
        }
    };

    // --- Pass 1: classify each surface and resolve own-title cwds ---
    struct RawPane {
        surface_id: String,
        pane_id: usize,
        window_id: String,
        title: String,
        has_claude: bool,
        own_cwd: Option<String>,
    }
    let raw: Vec<RawPane> = surfaces.iter().filter_map(|s| {
        let surface_id = s.get("surface_id").and_then(|v| v.as_str())?.to_string();
        let pane_id: usize = s.get("pane_id").and_then(|v| v.as_str())?.parse().ok()?;
        let window_id = s.get("window_id").and_then(|v| v.as_str()).unwrap_or("").to_string();
        let title = strip_ansi(s.get("title").and_then(|v| v.as_str()).unwrap_or(""));
        let starts_with_spinner = title.chars().next()
            .map(|c| !c.is_ascii() && c != '~' && c != '/' && c != '…')
            .unwrap_or(false);
        let clean = title.trim_start_matches(|c: char| {
            !c.is_alphanumeric() && c != '~' && c != '/'
        }).trim();
        let has_claude = title.contains("Claude")
            || (starts_with_spinner && !clean.starts_with('~') && !clean.starts_with('/'));
        let own_cwd = expand_title_path(&title);
        Some(RawPane { surface_id, pane_id, window_id, title, has_claude, own_cwd })
    }).collect();

    // --- Pass 2: for Claude panes without own_cwd, find nearest unclaimed path-pane neighbor ---
    // Sort Claude panes by distance to their nearest path neighbor so closer ones get priority.
    let mut claimed_path_panes: std::collections::HashSet<(String, usize)> = Default::default();

    // Pre-mark path panes that have own-cwd Claude panes (they don't need to borrow).
    // Also pre-mark path pane keys whose Claude pane already has own_cwd (no borrowing needed).

    // Build the borrowed_cwd for each raw pane index, processing Claude panes in order of
    // their nearest available neighbor distance (closest-first globally).
    let mut borrowed_cwds: Vec<Option<String>> = vec![None; raw.len()];

    // Collect (distance, claude_idx, neighbor_pane_id, window_id, path) candidates.
    let mut candidates: Vec<(usize, usize, usize, String, String)> = Vec::new();
    for (i, rp) in raw.iter().enumerate() {
        if !rp.has_claude || rp.own_cwd.is_some() {
            continue;
        }
        for delta in 1usize..=3 {
            for neighbor_id in [rp.pane_id + delta, rp.pane_id.saturating_sub(delta)] {
                if neighbor_id == rp.pane_id { continue; }
                let key = (rp.window_id.clone(), neighbor_id);
                if let Some(t) = pane_titles.get(&key) {
                    if let Some(p) = expand_title_path(t) {
                        candidates.push((delta, i, neighbor_id, rp.window_id.clone(), p));
                    }
                }
            }
        }
    }
    // Sort by distance so closer neighbors are assigned first.
    candidates.sort_by_key(|(dist, _, _, _, _)| *dist);
    for (_, claude_idx, neighbor_id, window_id, path) in candidates {
        let key = (window_id, neighbor_id);
        if claimed_path_panes.contains(&key) || borrowed_cwds[claude_idx].is_some() {
            continue;
        }
        claimed_path_panes.insert(key);
        borrowed_cwds[claude_idx] = Some(path);
    }

    let mut panes: Vec<TrmPane> = Vec::new();

    for (i, rp) in raw.into_iter().enumerate() {
        let RawPane { surface_id, pane_id, title, has_claude, own_cwd, .. } = rp;
        let resolved_cwd = own_cwd.or_else(|| borrowed_cwds[i].clone());

        let (folder_name, cwd) = if let Some(ref c) = resolved_cwd {
            let clean = c.trim_end_matches('/');
            let parts: Vec<&str> = clean.rsplitn(3, '/').collect();
            let short = match parts.len() {
                0 => c.clone(),
                1 => parts[0].to_string(),
                _ => format!("{}/{}", parts[1], parts[0]),
            };
            (Some(short), Some(c.clone()))
        } else {
            (None, None)
        };

        tracing::debug!(
            surface_id = %surface_id,
            pane_id = pane_id,
            title = %title,
            has_claude = has_claude,
            cwd = ?cwd,
            "discover_trm_panes: pane"
        );

        panes.push(TrmPane {
            index: i,
            folder_name,
            cwd,
            has_claude,
            surface_id: Some(surface_id),
            title: if title.is_empty() { None } else { Some(title) },
        });
    }

    panes
}

// ── Discovery: Floss Desktop ──────────────────────────────────────────

pub fn discover_desktop_target() -> DesktopTarget {
    let socket_path = desktop_bridge::floss_socket_path()
        .to_string_lossy()
        .to_string();

    let result = desktop_bridge::floss_rpc("flan.ping", serde_json::json!({}));
    match result {
        Some(resp) => {
            let version = resp
                .get("version")
                .and_then(|v| v.as_str())
                .map(|s| s.to_string());
            DesktopTarget {
                alive: true,
                socket_path,
                version,
            }
        }
        None => DesktopTarget {
            alive: false,
            socket_path,
            version: None,
        },
    }
}

// ── trm ──────────────────────────────────────────────────────────────────

/// Returns the active trm socket path.
/// Prefers `/tmp/trm.sock` (release build); falls back to `/tmp/trm-debug.sock`.
fn trm_socket_path() -> String {
    let release = "/tmp/trm.sock";
    if std::path::Path::new(release).exists() {
        release.to_string()
    } else {
        "/tmp/trm-debug.sock".to_string()
    }
}

/// Same protocol as cmux_rpc but targets the trm socket.
pub fn trm_rpc(method: &str, params: serde_json::Value) -> Option<serde_json::Value> {
    use std::os::unix::net::UnixStream;

    let socket = std::env::var("TRM_SOCKET_PATH").unwrap_or_else(|_| trm_socket_path());
    let mut stream = UnixStream::connect(&socket).ok()?;
    stream.set_read_timeout(Some(Duration::from_secs(5))).ok()?;

    let password =
        std::env::var("CMUX_SOCKET_PASSWORD").unwrap_or_else(|_| "flan".to_string());
    let request = serde_json::json!({
        "id": method,
        "method": method,
        "params": params,
        "password": password,
    });
    let mut msg = serde_json::to_string(&request).ok()?;
    msg.push('\n');
    stream.write_all(msg.as_bytes()).ok()?;
    stream.flush().ok()?;
    stream.shutdown(std::net::Shutdown::Write).ok()?;

    let reader = BufReader::new(&stream);
    let line = reader.lines().next()?.ok()?;

    if line.starts_with("ERROR") {
        return None;
    }
    serde_json::from_str(&line).ok()
}

pub fn cmux_rpc(method: &str, params: serde_json::Value) -> Option<serde_json::Value> {
    use std::os::unix::net::UnixStream;

    let socket =
        std::env::var("CMUX_SOCKET_PATH").unwrap_or_else(|_| "/tmp/cmux.sock".into());
    let mut stream = UnixStream::connect(&socket).ok()?;
    stream
        .set_read_timeout(Some(Duration::from_secs(5)))
        .ok()?;

    let password =
        std::env::var("CMUX_SOCKET_PASSWORD").unwrap_or_else(|_| "flan".to_string());
    let request = serde_json::json!({
        "id": method,
        "method": method,
        "params": params,
        "password": password,
    });
    let mut msg = serde_json::to_string(&request).ok()?;
    msg.push('\n');
    stream.write_all(msg.as_bytes()).ok()?;
    stream.flush().ok()?;
    stream.shutdown(std::net::Shutdown::Write).ok()?;

    let reader = BufReader::new(&stream);
    let line = reader.lines().next()?.ok()?;

    if line.starts_with("ERROR") {
        return None;
    }
    serde_json::from_str(&line).ok()
}

pub fn cmux_surface_list() -> Vec<CmuxSurface> {
    let Some(resp) = cmux_rpc("surface.list", serde_json::json!({})) else {
        return Vec::new();
    };

    let Some(surfaces) = resp
        .get("result")
        .and_then(|r| r.get("surfaces"))
        .and_then(|s| s.as_array())
    else {
        return Vec::new();
    };

    // Parse all surfaces first (without cwd).
    let mut result: Vec<CmuxSurface> = surfaces
        .iter()
        .filter_map(|s| {
            Some(CmuxSurface {
                id: s.get("id")?.as_str()?.to_string(),
                title: strip_ansi(s.get("title")?.as_str()?),
                pane_id: s.get("pane_id")?.as_str()?.to_string(),
                focused: s.get("focused")?.as_bool()?,
                cwd: None,
            })
        })
        .collect();

    // Resolve cwd for each Claude Code surface using pane siblings.
    // A pane sibling whose title looks like an absolute or home path gives
    // us the cwd of the claude process in that pane.
    let home = std::env::var("HOME").unwrap_or_default();

    for i in 0..result.len() {
        if !result[i].title.contains("Claude") {
            continue;
        }
        let pane = result[i].pane_id.clone();

        // Collect path-like sibling titles in the same pane.
        let sibling_path = result
            .iter()
            .filter(|s| s.pane_id == pane && s.id != result[i].id)
            .find_map(|s| {
                let t = &s.title;
                // Expand ~ prefix so we can use it as a real path.
                if t.starts_with("~/") || t == "~" {
                    Some(format!("{}{}", home, &t[1..]))
                } else if t.starts_with('/') {
                    Some(t.clone())
                } else if t.starts_with('…') {
                    // Truncated path like "…/dev/pe/admin" — try to resolve
                    // by finding a claude process whose cwd ends with the suffix.
                    None
                } else {
                    None
                }
            });

        if let Some(path) = sibling_path {
            result[i].cwd = Some(path);
            continue;
        }

        // Fallback: try to match by truncated "…/suffix" sibling title against
        // running claude process cwds.
        let truncated_suffix = result
            .iter()
            .filter(|s| s.pane_id == pane && s.id != result[i].id)
            .find_map(|s| {
                s.title.strip_prefix('…').map(|suf| suf.to_string())
            });

        if let Some(suffix) = truncated_suffix {
            // Find a claude process whose cwd ends with this suffix.
            let claude_cwd = discover_claude_processes()
                .into_iter()
                .find(|p| p.cwd.ends_with(&suffix))
                .map(|p| p.cwd);
            result[i].cwd = claude_cwd;
        }
    }

    result
}

pub fn cmux_send_text(surface_id: &str, text: &str) -> bool {
    cmux_rpc(
        "surface.send_text",
        serde_json::json!({
            "surface_id": surface_id,
            "text": text,
        }),
    )
    .and_then(|r| r.get("ok")?.as_bool())
    .unwrap_or(false)
}

/// Focus a specific trm pane by its surface ID, then bring trm to the front.
///
/// trm speaks the same RPC protocol as cmux on `/tmp/trm.sock`, so we call
/// `surface.focus` there, then activate the app via osascript.
pub fn trm_focus_pane_by_surface(surface_id: &str) -> bool {
    let focused = trm_rpc(
        "surface.focus",
        serde_json::json!({ "surface_id": surface_id }),
    )
    .and_then(|r| r.get("ok")?.as_bool())
    .unwrap_or(false);

    // Always bring trm to the foreground regardless of the RPC result.
    let _ = Command::new("osascript")
        .args(["-e", "tell application \"trm\" to activate"])
        .output();

    focused
}

pub fn trm_focus_pane(_index: usize) -> bool {
    // Fallback used when no surface_id is available — just bring trm forward.
    Command::new("osascript")
        .args(["-e", "tell application \"trm\" to activate"])
        .output()
        .is_ok_and(|o| o.status.success())
}

pub fn cmux_focus_surface(surface_id: &str) -> bool {
    cmux_rpc(
        "surface.focus",
        serde_json::json!({ "surface_id": surface_id }),
    )
    .and_then(|r| r.get("ok")?.as_bool())
    .unwrap_or(false)
}

/// Send `text` to a trm pane by zero-based index, then submit with Enter.
/// Uses the trm Unix socket protocol: `{"type":"send","pane":N,"text":"..."}\n`.
/// The server responds with `{"status":"queued"}` on success.
pub fn trm_send_to_pane(index: usize, text: &str) -> bool {
    use std::io::{BufRead, BufReader, Write};
    use std::os::unix::net::UnixStream;
    use std::time::Duration;

    let socket_path = std::env::var("TRM_SOCKET_PATH")
        .unwrap_or_else(|_| trm_socket_path());
    (|| {
        let mut stream = UnixStream::connect(&socket_path).ok()?;
        stream.set_read_timeout(Some(Duration::from_secs(2))).ok()?;
        // Append \r (carriage return) to submit the command in the terminal.
        let text_with_cr = format!("{}\r", text);
        let msg = format!("{}\n", serde_json::json!({"type":"send","pane":index,"text":text_with_cr}));
        stream.write_all(msg.as_bytes()).ok()?;
        stream.flush().ok()?;
        let mut buf = String::new();
        BufReader::new(&stream).read_line(&mut buf).ok()?;
        let v: serde_json::Value = serde_json::from_str(&buf).ok()?;
        v.get("status").and_then(|s| s.as_str()).map(|s| s == "queued")
    })()
    .unwrap_or(false)
}

pub fn focus_app_by_device(device: &str) -> bool {
    let app_name = match device.to_lowercase().as_str() {
        "chrome" => "Google Chrome",
        "safari" => "Safari",
        "edge" => "Microsoft Edge",
        "firefox" => "Firefox",
        "web-server" | "web" => "Google Chrome",
        "macos" => return focus_macos_app(),
        d if d.contains("iphone") || d.contains("ipad") || d.contains("simulator") => {
            "Simulator"
        }
        _ => "Google Chrome",
    };

    Command::new("osascript")
        .args([
            "-e",
            &format!("tell application \"{}\" to activate", app_name),
        ])
        .output()
        .is_ok_and(|o| o.status.success())
}

pub fn focus_macos_app() -> bool {
    let Ok(output) = Command::new("ps").args(["-eo", "pid,comm"]).output() else {
        return false;
    };
    let stdout = String::from_utf8_lossy(&output.stdout);
    for line in stdout.lines() {
        if line.contains("build/macos") && line.contains(".app/Contents/MacOS/") {
            if let Some(app_start) = line.find(".app/Contents/MacOS/") {
                let before = &line[..app_start];
                if let Some(slash) = before.rfind('/') {
                    let app_name = &before[slash + 1..];
                    return Command::new("osascript")
                        .args([
                            "-e",
                            &format!("tell application \"{}\" to activate", app_name),
                        ])
                        .output()
                        .is_ok_and(|o| o.status.success());
                }
            }
        }
    }
    false
}
