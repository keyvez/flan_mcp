use serde::{Deserialize, Serialize};
use std::{
    collections::{HashMap, HashSet, VecDeque},
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

// ── Coding Agent Detection ─────────────────────────────────────────────

/// Process name substrings that identify coding agent processes in `ps` output.
/// Checked against the `comm` field (case-sensitive).
const AGENT_PROCESS_NAMES: &[&str] = &["claude", "forge", "opencode", "codex", "gemini"];

/// Substrings that appear in terminal/pane titles when a coding agent is running.
/// Checked case-sensitively against the title.
const AGENT_TITLE_MARKERS: &[&str] = &["Claude", "Forge", "OpenCode", "Codex", "Gemini"];

/// Returns true if the process `comm` string looks like a coding agent.
pub fn is_agent_process(comm: &str) -> bool {
    AGENT_PROCESS_NAMES.iter().any(|name| comm.contains(name))
        && !comm.contains("flan")
}

/// Returns true if a terminal title contains a coding agent marker.
/// Matching is case-insensitive.
pub fn title_has_agent(title: &str) -> bool {
    let lower = title.to_lowercase();
    AGENT_PROCESS_NAMES.iter().any(|name| lower.contains(name))
}

/// Returns the display name of the agent detected in a title, or None.
/// Matching is case-insensitive; returns the canonical display name.
pub fn agent_name_from_title(title: &str) -> Option<&'static str> {
    let lower = title.to_lowercase();
    for (i, name) in AGENT_PROCESS_NAMES.iter().enumerate() {
        if lower.contains(name) {
            return Some(AGENT_TITLE_MARKERS[i]);
        }
    }
    None
}

/// Returns the display name of the agent detected from a process comm, or None.
pub fn agent_name_from_comm(comm: &str) -> Option<&'static str> {
    for (i, name) in AGENT_PROCESS_NAMES.iter().enumerate() {
        if comm.contains(name) && !comm.contains("flan") {
            return Some(AGENT_TITLE_MARKERS[i]);
        }
    }
    None
}

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
    /// Zero-based position in the surface.list array (used for "trm:N" surface keys).
    pub index: usize,
    /// The actual pane_id from trm's surface.list (used to send input via the trm socket).
    /// This may differ from `index` when pane IDs are non-contiguous (e.g. after pane deletion).
    #[serde(default)]
    pub pane_id: usize,
    /// Folder name of the cwd (e.g. "charge/web"), or None if empty/unknown.
    pub folder_name: Option<String>,
    /// Full cwd path, if known.
    pub cwd: Option<String>,
    /// Whether a coding agent process is running in this pane.
    pub has_claude: bool,
    /// Display name of the detected agent (e.g. "Claude", "Forge"), derived
    /// from the actual running process when possible, falling back to the title.
    #[serde(default)]
    pub agent_name: Option<String>,
    /// Surface ID from trm's RPC (e.g. "surface-13"), used for surface.focus.
    #[serde(default)]
    pub surface_id: Option<String>,
    /// Raw title from trm's surface.list, used as fallback display when cwd is unknown.
    #[serde(default)]
    pub title: Option<String>,
    /// Channel port for the flan-channel MCP server running in this pane, if registered.
    #[serde(default)]
    pub channel_port: Option<u16>,
    /// The trm login PID that owns this pane (trm → login → shell → ...).
    /// Used to match registered flan-channel processes to panes reliably.
    #[serde(default)]
    pub login_pid: Option<u32>,
    /// True if the Claude process in this pane was started with
    /// --dangerously-load-development-channels, meaning channel notifications work.
    #[serde(default)]
    pub has_dev_channels: bool,
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
    /// Registered flan-channel ports by surface id (e.g. "trm:0" → 4051).
    pub channel_ports: RwLock<HashMap<String, u16>>,
    /// Registered flan-channel ports by shell cwd (ground truth from lsof).
    /// Used when surface_id resolution isn't possible; the TUI matches
    /// registered shell cwds against claude process cwds at display time.
    pub channel_ports_by_cwd: RwLock<HashMap<String, u16>>,
    /// Registered flan-channel ports by login PID (most reliable match key).
    /// login_pid is the trm-direct-child login that is an ancestor of the
    /// flan-channel process.
    pub channel_ports_by_login: RwLock<HashMap<u32, u16>>,
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
            channel_ports: RwLock::new(HashMap::new()),
            channel_ports_by_cwd: RwLock::new(HashMap::new()),
            channel_ports_by_login: RwLock::new(HashMap::new()),
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

    #[derive(Debug, Deserialize)]
    struct RegisterChannelRequest {
        surface_id: Option<String>,
        port: u16,
        /// PID of the channel process — used to resolve its trm pane when
        /// `surface_id` is not provided.
        pid: Option<u32>,
        /// Working directory of the channel process — used as a fallback
        /// when PID-based resolution fails.
        cwd: Option<String>,
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
                .filter(|s| title_has_agent(&s.title))
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

        let channel_port = state.channel_ports.read().await
            .get(&surface_id).copied();

        let mut resp = serde_json::json!({"ok": true, "surface_id": surface_id});
        if let Some(ref uri) = resolved_vm_uri {
            resp["vm_service_uri"] = serde_json::Value::String(uri.clone());
        }
        if let Some(port) = channel_port {
            resp["channel_port"] = serde_json::Value::Number(port.into());
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

    async fn get_trm_debug(
        State(state): State<Arc<SharedState>>,
    ) -> impl IntoResponse {
        let panes = tokio::task::spawn_blocking(discover_trm_panes)
            .await
            .unwrap_or_default();
        let login_ports = state.channel_ports_by_login.read().await.clone();
        let cwd_ports = state.channel_ports_by_cwd.read().await.clone();
        let surface_ports = state.channel_ports.read().await.clone();

        let pane_info: Vec<serde_json::Value> = panes.iter().map(|p| {
            // Compute what channel_port apply_discovery would assign.
            let assigned_port = p.login_pid
                .and_then(|lp| login_ports.get(&lp).copied())
                .or_else(|| {
                    let key = format!("trm:{}", p.index);
                    surface_ports.get(&key).copied()
                })
                .or_else(|| {
                    p.cwd.as_ref().and_then(|pane_cwd| {
                        let pane_clean = pane_cwd.trim_end_matches('/');
                        cwd_ports.iter().find_map(|(reg_cwd, &port)| {
                            let reg_clean = reg_cwd.trim_end_matches('/');
                            if reg_clean == pane_clean
                                || reg_clean.starts_with(&format!("{}/", pane_clean))
                                || pane_clean.starts_with(&format!("{}/", reg_clean))
                            {
                                Some(port)
                            } else {
                                None
                            }
                        })
                    })
                });

            serde_json::json!({
                "index": p.index,
                "pane_id": p.pane_id,
                "title": p.title,
                "cwd": p.cwd,
                "folder_name": p.folder_name,
                "has_claude": p.has_claude,
                "login_pid": p.login_pid,
                "channel_port_assigned": assigned_port,
            })
        }).collect();

        (StatusCode::OK, Json(serde_json::json!({
            "panes": pane_info,
            "channel_ports_by_login": login_ports.iter().map(|(k, v)| (k.to_string(), v)).collect::<std::collections::HashMap<_,_>>(),
            "channel_ports_by_cwd": cwd_ports,
            "channel_ports_by_surface": surface_ports,
        })))
    }

    async fn handle_register_channel(
        State(state): State<Arc<SharedState>>,
        Json(body): Json<RegisterChannelRequest>,
    ) -> impl IntoResponse {
        // Resolve surface_id: use the explicit value, or look up which trm pane
        // the given PID belongs to.
        let surface_id = if let Some(sid) = body.surface_id {
            Some(sid)
        } else if let Some(channel_pid) = body.pid {
            let cwd_hint = body.cwd.clone();
            tokio::task::spawn_blocking(move || resolve_trm_pane_for_pid(channel_pid, cwd_hint.as_deref()))
                .await
                .ok()
                .flatten()
        } else {
            None
        };

        let port = body.port;

        if let Some(ref sid) = surface_id {
            tracing::info!("Channel registered: surface_id={} port={}", sid, port);
            state.channel_ports.write().await.insert(sid.clone(), port);
        }

        // Also register by login PID and shell cwd — used for matching when
        // surface_id resolution fails (e.g. pane title has no path).
        if let Some(channel_pid) = body.pid {
            let (login_pid, shell_cwd) = tokio::task::spawn_blocking(move || {
                let login = find_login_pid(channel_pid)?;
                let ps_out = Command::new("ps").args(["-eo", "pid,ppid,comm"]).output().ok()?;
                let ps_str = String::from_utf8_lossy(&ps_out.stdout);
                let shell_pid: u32 = ps_str.lines().skip(1).find_map(|l| {
                    let mut it = l.split_whitespace();
                    let pid: u32 = it.next()?.parse().ok()?;
                    let ppid: u32 = it.next()?.parse().ok()?;
                    let comm = it.collect::<Vec<_>>().join(" ");
                    if ppid == login && (comm.contains("zsh") || comm.contains("bash") || comm.contains("fish")) {
                        Some(pid)
                    } else {
                        None
                    }
                })?;
                let cwd = get_process_cwd(shell_pid);
                Some((login, if cwd.is_empty() { None } else { Some(cwd) }))
            }).await.ok().flatten().unwrap_or((0, None));

            if login_pid != 0 {
                tracing::info!("Channel registered by login: {} → port {}", login_pid, port);
                state.channel_ports_by_login.write().await.insert(login_pid, port);
            }
            if let Some(cwd) = shell_cwd {
                tracing::info!("Channel registered by cwd: {} → port {}", cwd, port);
                state.channel_ports_by_cwd.write().await.insert(cwd, port);
            }
        }

        let sid_str = surface_id.as_deref().unwrap_or("(unresolved)");
        (StatusCode::OK, Json(serde_json::json!({"ok": true, "surface_id": sid_str})))
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
            .route("/api/register-channel", post(handle_register_channel))
            .route("/api/rescan", post(handle_rescan))
            .route("/api/status", get(get_status))
            .route("/api/logs", get(get_activity_log))
            .route("/api/trm-debug", get(get_trm_debug))
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

        if !is_agent_process(comm) || tty == "??" {
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

    // Collect all live agent process cwds via lsof, mapping cwd → agent display name.
    let home = std::env::var("HOME").unwrap_or_default();
    let agent_cwd_map: HashMap<String, &'static str> = all_procs
        .iter()
        .filter(|(_, _, comm)| is_agent_process(comm))
        .filter_map(|(pid, _, comm)| {
            let cwd = get_process_cwd(*pid);
            let name = agent_name_from_comm(comm)?;
            if cwd.is_empty() { None } else { Some((cwd, name)) }
        })
        .collect();
    let claude_cwds: std::collections::HashSet<String> = agent_cwd_map.keys().cloned().collect();

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

    // Look up the agent display name for a cwd that matches a live agent process.
    let agent_name_for_cwd = |cwd: &str| -> Option<&'static str> {
        if cwd.starts_with('…') {
            let suffix = &cwd[cwd.char_indices().nth(1).map(|(i, _)| i).unwrap_or(1)..];
            agent_cwd_map.iter()
                .find(|(c, _)| c.ends_with(suffix))
                .map(|(_, name)| *name)
        } else {
            agent_cwd_map.get(cwd).copied()
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
        let has_claude = title_has_agent(&title)
            || (starts_with_spinner && !clean.starts_with('~') && !clean.starts_with('/'));
        let own_cwd = expand_title_path(&title);
        Some(RawPane { surface_id, pane_id, window_id, title, has_claude, own_cwd })
    }).collect();

    // --- Pass 2a: resolve cwds for Claude panes via login→shell→cwd ---
    //
    // Each trm surface is spawned by trm → login → shell.  For Claude panes
    // whose title doesn't contain a path (own_cwd is None), we match by
    // finding which trm login has a shell that is an ancestor of a `claude`
    // process whose cwd matches a known claude_cwd.
    //
    // We then correlate surfaces ↔ logins by matching title-derived paths
    // from path-bearing surfaces against login shell cwds.  Unmatched Claude
    // surfaces get the remaining Claude-bearing logins' cwds.
    let mut login_resolved_cwds: Vec<Option<String>> = vec![None; raw.len()];
    let mut login_resolved_agents: Vec<Option<&str>> = vec![None; raw.len()];
    let mut login_resolved_pids: Vec<Option<u32>> = vec![None; raw.len()];
    let mut login_resolved_dev_channels: Vec<bool> = vec![false; raw.len()];
    {
        // Find the trm process PID.
        let trm_pid = all_procs.iter()
            .find(|(_, _, c)| c.contains("trm.app") || c.ends_with("/trm") || c.ends_with("trm"))
            .map(|(p, _, _)| *p);

        if let Some(trm_pid) = trm_pid {
            // Get all login children of trm and their shell cwds.
            let logins: Vec<u32> = all_procs.iter()
                .filter(|(_, pp, c)| *pp == trm_pid && c.contains("login"))
                .map(|(p, _, _)| *p)
                .collect();

            // Resolve login → shell cwd by tty: each login has a specific tty,
            // and all processes in the same pane share that tty.  We use this
            // to match logins to pane_ids reliably.
            // Step: get tty for every login process.
            let login_ttys: HashMap<u32, String> = {
                let pid_args = logins.iter().map(|p| p.to_string()).collect::<Vec<_>>();
                let mut m = HashMap::new();
                if !pid_args.is_empty() {
                    let mut cmd_args = vec!["-p".to_string(), pid_args.join(","), "-o".to_string(), "pid=,tty=".to_string()];
                    if let Ok(out) = Command::new("ps").args(&cmd_args).output() {
                        for line in String::from_utf8_lossy(&out.stdout).lines() {
                            let parts: Vec<&str> = line.split_whitespace().collect();
                            if parts.len() >= 2 {
                                if let Ok(pid) = parts[0].parse::<u32>() {
                                    m.insert(pid, parts[1].to_string());
                                }
                            }
                        }
                    }
                }
                m
            };

            // Build a tty → pane_id map by getting the tty for each Claude/agent process
            // and matching it against the raw pane's surface_id.
            // Since Claude processes share a tty with their login, we can map:
            // login_tty → pane_id by finding which Claude process has this tty
            // and which raw pane contains this cwd via agent_cwd_map.
            // Simpler: use tty of logins to match login → raw pane by checking
            // all processes on the same tty. Each raw pane has a pane_id.
            // We get pane_id→tty from: the login that spawned it is the trm child
            // whose tty matches pane_id (if tty suffix == pane_id), OR we match
            // via the shell CWD that we already know.
            //
            // Key insight: we already know login→shell_cwd. We can match
            // login → raw pane by finding the raw pane whose cwd matches the
            // login's shell_cwd. For panes with own_cwd this is done above. For
            // panes without own_cwd (spinner titles), we use tty matching.
            //
            // Build login_pid → pane_id by checking: for each login, which raw
            // pane has a process (via all_procs) on the same tty?
            let login_pane_ids: HashMap<u32, usize> = {
                // Get tty for ALL processes to find which pane each process is in.
                // We look for Claude/agent processes whose tty matches a login's tty,
                // then map to the raw pane whose pane_id we know from surface.list.
                //
                // Actually: we know each login's tty. We know each raw pane's pane_id.
                // We need: login_tty → pane_id.
                //
                // Approach: look up tty for each shell (child of login). Then check
                // which raw pane corresponds to that shell's cwd (already in shell_cwds_map).
                // For panes with own_cwd that already matched, we skip.
                // For remaining, we check if any raw pane has processes on the same tty.
                //
                // Fallback: match by inspecting which Claude process is on each tty,
                // then map that Claude process's cwd to the matching raw pane.
                let mut m: HashMap<u32, usize> = HashMap::new();
                // For each login: get its tty, find a Claude/agent child on that tty,
                // then find the raw pane by pane_id (if tty suffix matches).
                for (&login_pid, tty) in &login_ttys {
                    // tty is like "ttys003" — extract numeric suffix.
                    let suffix_str = tty.trim_start_matches(|c: char| !c.is_numeric());
                    if let Ok(n) = suffix_str.parse::<usize>() {
                        // Find a raw pane whose pane_id matches this number.
                        if let Some(raw_idx) = raw.iter().position(|rp| rp.pane_id == n) {
                            m.insert(login_pid, raw_idx);
                        }
                    }
                }
                m
            };

            // For each login, find its shell child and get the cwd.
            // Also check if the shell has a claude descendant.
            let shell_pids: Vec<(u32, u32)> = logins.iter()
                .filter_map(|&lp| {
                    all_procs.iter()
                        .find(|(_, pp, c)| *pp == lp && (c.contains("zsh") || c.contains("bash") || c.contains("fish")))
                        .map(|(sp, _, _)| (lp, *sp))
                })
                .collect();

            // Batch lsof for all shells.
            let pid_arg = shell_pids.iter().map(|(_, sp)| sp.to_string()).collect::<Vec<_>>().join(",");
            let shell_cwds_map: HashMap<u32, String> = if pid_arg.is_empty() {
                HashMap::new()
            } else {
                Command::new("lsof")
                    .args(["-d", "cwd", "-a", "-Fn", "-a", "-p", &pid_arg])
                    .output()
                    .map(|o| {
                        let mut map = HashMap::new();
                        let out = String::from_utf8_lossy(&o.stdout);
                        let mut cur_pid: Option<u32> = None;
                        for line in out.lines() {
                            if let Some(p) = line.strip_prefix('p') {
                                cur_pid = p.parse().ok();
                            } else if let Some(path) = line.strip_prefix('n') {
                                if path.starts_with('/') {
                                    if let Some(pid) = cur_pid {
                                        map.insert(pid, path.to_string());
                                    }
                                }
                            }
                        }
                        map
                    })
                    .unwrap_or_default()
            };

            struct LoginInfo {
                login_pid: u32,
                shell_cwd: String,
                has_claude_child: bool,
                /// Display name of the agent child (e.g. "Claude", "Forge"), if any.
                agent_child_name: Option<&'static str>,
                /// True if the Claude child was started with --dangerously-load-development-channels.
                has_dev_channels: bool,
                /// raw array index derived from the login's tty (reliable login↔pane mapping).
                tty_raw_idx: Option<usize>,
            }

            let login_infos: Vec<LoginInfo> = shell_pids.iter()
                .filter_map(|(lp, sp)| {
                    let cwd = shell_cwds_map.get(sp)?.clone();
                    // Check if this shell has a coding agent descendant and which one.
                    let agent_child = all_procs.iter()
                        .find(|(_, pp, c)| *pp == *sp && is_agent_process(c))
                        .and_then(|(_, _, c)| agent_name_from_comm(c));
                    // Check if the Claude child was launched with --dangerously-load-development-channels.
                    let has_dev_channels = all_procs.iter()
                        .find(|(_, pp, c)| *pp == *sp && c.ends_with("claude"))
                        .map(|(claude_pid, _, _)| {
                            Command::new("ps")
                                .args(["-p", &claude_pid.to_string(), "-o", "args="])
                                .output()
                                .map(|o| String::from_utf8_lossy(&o.stdout)
                                    .contains("dangerously-load-development-channels"))
                                .unwrap_or(false)
                        })
                        .unwrap_or(false);
                    Some(LoginInfo {
                        login_pid: *lp,
                        shell_cwd: cwd,
                        has_claude_child: agent_child.is_some(),
                        agent_child_name: agent_child,
                        has_dev_channels,
                        tty_raw_idx: login_pane_ids.get(lp).copied(),
                    })
                })
                .collect();

            // Match path-bearing surfaces to logins by title↔cwd.
            let mut claimed_logins: HashSet<u32> = HashSet::new();
            let mut surface_to_login: HashMap<usize, usize> = HashMap::new(); // raw_idx → login_info idx

            for (raw_idx, rp) in raw.iter().enumerate() {
                if let Some(ref tp) = rp.own_cwd {
                    let tp_clean = tp.trim_end_matches('/');
                    let matched = login_infos.iter().enumerate().find(|(_, li)| {
                        if claimed_logins.contains(&li.login_pid) { return false; }
                        let cwd_clean = li.shell_cwd.trim_end_matches('/');
                        if tp_clean.starts_with('…') {
                            let suffix = &tp_clean[tp_clean.char_indices().nth(1).map(|(i, _)| i).unwrap_or(1)..];
                            cwd_clean.ends_with(suffix)
                        } else {
                            cwd_clean == tp_clean
                                || cwd_clean.starts_with(&format!("{}/", tp_clean))
                        }
                    });
                    if let Some((li_idx, li)) = matched {
                        claimed_logins.insert(li.login_pid);
                        surface_to_login.insert(raw_idx, li_idx);
                        login_resolved_pids[raw_idx] = Some(li.login_pid);
                        login_resolved_dev_channels[raw_idx] = li.has_dev_channels;
                        if let Some(name) = li.agent_child_name {
                            login_resolved_agents[raw_idx] = Some(name);
                        }
                    }
                }
            }

            // Assign unclaimed logins to Claude panes without own_cwd.
            // Priority 1: match by tty-derived pane_id (most reliable).
            // Priority 2: positional zip (best-effort fallback).
            let unclaimed_claude_logins: Vec<usize> = login_infos.iter().enumerate()
                .filter(|(_, li)| li.has_claude_child && !claimed_logins.contains(&li.login_pid))
                .map(|(i, _)| i)
                .collect();

            let unresolved_claude_panes: Vec<usize> = raw.iter().enumerate()
                .filter(|(i, rp)| rp.has_claude && rp.own_cwd.is_none() && !surface_to_login.contains_key(i))
                .map(|(i, _)| i)
                .collect();

            let mut tty_matched_raw_idxs: HashSet<usize> = HashSet::new();
            for &li_info_idx in &unclaimed_claude_logins {
                let li = &login_infos[li_info_idx];
                if let Some(raw_idx) = li.tty_raw_idx {
                    if unresolved_claude_panes.contains(&raw_idx) && !tty_matched_raw_idxs.contains(&raw_idx) {
                        tty_matched_raw_idxs.insert(raw_idx);
                        claimed_logins.insert(li.login_pid);
                        login_resolved_cwds[raw_idx] = Some(li.shell_cwd.clone());
                        login_resolved_pids[raw_idx] = Some(li.login_pid);
                        login_resolved_dev_channels[raw_idx] = li.has_dev_channels;
                        if let Some(name) = li.agent_child_name {
                            login_resolved_agents[raw_idx] = Some(name);
                        }
                        tracing::debug!(
                            "discover_trm_panes: tty-matched raw_idx={} via login {} → {} (agent: {:?})",
                            raw_idx, li.login_pid, li.shell_cwd, li.agent_child_name
                        );
                    }
                }
            }

            // Positional zip fallback for any remaining unmatched logins/panes.
            let remaining_logins: Vec<usize> = login_infos.iter().enumerate()
                .filter(|(_, li)| li.has_claude_child && !claimed_logins.contains(&li.login_pid))
                .map(|(i, _)| i)
                .collect();
            let remaining_panes: Vec<usize> = unresolved_claude_panes.iter()
                .filter(|&&raw_idx| !tty_matched_raw_idxs.contains(&raw_idx))
                .copied()
                .collect();

            for (&raw_idx, li_idx) in remaining_logins.iter().zip(remaining_panes.iter()) {
                // raw_idx is login info index, li_idx is pane index — swap naming
                let li = &login_infos[raw_idx];
                login_resolved_cwds[*li_idx] = Some(li.shell_cwd.clone());
                login_resolved_pids[*li_idx] = Some(li.login_pid);
                login_resolved_dev_channels[*li_idx] = li.has_dev_channels;
                if let Some(name) = li.agent_child_name {
                    login_resolved_agents[*li_idx] = Some(name);
                }
                tracing::debug!(
                    "discover_trm_panes: positional-matched pane {} via login {} → {} (agent: {:?})",
                    *li_idx, li.login_pid, li.shell_cwd, li.agent_child_name
                );
            }
        }
    }

    // --- Pass 2b: for remaining Claude panes without cwd, try neighbor borrowing ---
    let mut claimed_path_panes: std::collections::HashSet<(String, usize)> = Default::default();
    let mut borrowed_cwds: Vec<Option<String>> = vec![None; raw.len()];

    let mut candidates: Vec<(usize, usize, usize, String, String)> = Vec::new();
    for (i, rp) in raw.iter().enumerate() {
        if !rp.has_claude || rp.own_cwd.is_some() || login_resolved_cwds[i].is_some() {
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
        // Prefer login-resolved cwd (ground truth), then own_cwd (from title),
        // then borrowed cwd (from neighbor).
        let resolved_cwd = login_resolved_cwds[i].take()
            .or(own_cwd)
            .or_else(|| borrowed_cwds[i].clone());

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

        // Upgrade has_claude if the resolved cwd matches a live claude process cwd.
        // This catches panes running Claude Code with --dangerously-load-development-channels
        // where the title shows the task description instead of "Claude Code".
        let has_claude = has_claude
            || cwd.as_deref().map(|c| cwd_has_claude(c)).unwrap_or(false);

        // Determine agent display name.  Prefer process-derived sources (login
        // chain or cwd match) because the terminal title may be stale (e.g.
        // still shows "forge" after Claude Code replaced it in the same pane).
        let agent_name = login_resolved_agents[i]
            .map(|s| s.to_string())
            .or_else(|| cwd.as_deref().and_then(|c| agent_name_for_cwd(c)).map(|s| s.to_string()))
            .or_else(|| agent_name_from_title(&title).map(|s| s.to_string()));

        tracing::debug!(
            surface_id = %surface_id,
            pane_id = pane_id,
            title = %title,
            has_claude = has_claude,
            agent_name = ?agent_name,
            cwd = ?cwd,
            "discover_trm_panes: pane"
        );

        panes.push(TrmPane {
            index: i,
            pane_id,
            folder_name,
            cwd,
            has_claude,
            agent_name,
            surface_id: Some(surface_id),
            title: if title.is_empty() { None } else { Some(title) },
            channel_port: None,
            login_pid: login_resolved_pids[i],
            has_dev_channels: login_resolved_dev_channels[i],
        });
    }

    panes
}

/// Resolve a PID to its `trm:N` surface ID.
///
/// Walks the target PID's ancestor chain to find its `login` ancestor under
/// trm, then maps that login to a surface by correlating each login's shell
/// cwd with surface titles (which contain path information).
/// Find the login PID that is the ancestor of `target_pid` under the trm process.
pub fn find_login_pid(target_pid: u32) -> Option<u32> {
    let Ok(ps_out) = Command::new("ps").args(["-eo", "pid,ppid,comm"]).output() else {
        return None;
    };
    let ps_str = String::from_utf8_lossy(&ps_out.stdout);
    let procs: Vec<(u32, u32, String)> = ps_str
        .lines()
        .skip(1)
        .filter_map(|l| {
            let mut it = l.split_whitespace();
            let pid: u32 = it.next()?.parse().ok()?;
            let ppid: u32 = it.next()?.parse().ok()?;
            let comm = it.collect::<Vec<_>>().join(" ");
            Some((pid, ppid, comm))
        })
        .collect();

    let trm_pid = procs.iter()
        .find(|(_, _, c)| c.contains("trm.app") || c.ends_with("/trm"))
        .map(|(p, _, _)| *p)?;

    let mut cur = target_pid;
    let mut visited = HashSet::new();
    for _ in 0..50 {
        if !visited.insert(cur) { break; }
        if let Some((_, pp, _)) = procs.iter().find(|(p, _, _)| *p == cur) {
            if *pp == trm_pid {
                return Some(cur);
            }
            if *pp <= 1 { break; }
            cur = *pp;
        } else {
            break;
        }
    }
    None
}

pub fn resolve_trm_pane_for_pid(target_pid: u32, cwd_hint: Option<&str>) -> Option<String> {
    let Ok(ps_out) = Command::new("ps").args(["-eo", "pid,ppid,comm"]).output() else {
        return None;
    };
    let ps_str = String::from_utf8_lossy(&ps_out.stdout);
    let procs: Vec<(u32, u32, String)> = ps_str
        .lines()
        .skip(1)
        .filter_map(|l| {
            let mut it = l.split_whitespace();
            let pid: u32 = it.next()?.parse().ok()?;
            let ppid: u32 = it.next()?.parse().ok()?;
            let comm = it.collect::<Vec<_>>().join(" ");
            Some((pid, ppid, comm))
        })
        .collect();

    // Find the trm process.
    let trm_pid = procs.iter()
        .find(|(_, _, c)| c.contains("trm.app") || c.ends_with("/trm"))
        .map(|(p, _, _)| *p)?;

    // Walk the target PID's ancestor chain to find the login child of trm.
    let mut cur = target_pid;
    let mut visited = HashSet::new();
    let mut target_login: Option<u32> = None;
    for _ in 0..50 {
        if !visited.insert(cur) { break; }
        // Check if `cur` is a direct child of trm
        if let Some((_, pp, _)) = procs.iter().find(|(p, _, _)| *p == cur) {
            if *pp == trm_pid {
                target_login = Some(cur);
                break;
            }
            if *pp <= 1 { break; }
            cur = *pp;
        } else {
            break;
        }
    }

    let target_login = target_login?;

    // Get the target login's shell cwd — this is the ground truth.
    let target_shell_cwd = procs.iter()
        .find(|(_, pp, c)| *pp == target_login && (c.contains("zsh") || c.contains("bash") || c.contains("fish")))
        .map(|(p, _, _)| get_process_cwd(*p))
        .unwrap_or_default();

    // Use cwd_hint as fallback if shell cwd lookup failed.
    let effective_cwd = if !target_shell_cwd.is_empty() {
        target_shell_cwd.as_str()
    } else if let Some(hint) = cwd_hint {
        hint
    } else {
        tracing::warn!("resolve_trm_pane_for_pid: pid {} — found login {} but no cwd", target_pid, target_login);
        return None;
    };

    // Get all trm logins and their shell cwds.
    let all_logins: Vec<u32> = procs.iter()
        .filter(|(_, pp, c)| *pp == trm_pid && c.contains("login"))
        .map(|(p, _, _)| *p)
        .collect();

    let shell_pids: Vec<(u32, u32)> = all_logins.iter()
        .filter_map(|&lp| {
            procs.iter()
                .find(|(_, pp, c)| *pp == lp && (c.contains("zsh") || c.contains("bash") || c.contains("fish")))
                .map(|(sp, _, _)| (lp, *sp))
        })
        .collect();

    let pid_arg = shell_pids.iter().map(|(_, sp)| sp.to_string()).collect::<Vec<_>>().join(",");
    let shell_cwds: HashMap<u32, String> = if pid_arg.is_empty() {
        HashMap::new()
    } else {
        Command::new("lsof")
            .args(["-d", "cwd", "-a", "-Fn", "-a", "-p", &pid_arg])
            .output()
            .map(|o| {
                let mut map = HashMap::new();
                let out = String::from_utf8_lossy(&o.stdout);
                let mut cur_pid: Option<u32> = None;
                for line in out.lines() {
                    if let Some(p) = line.strip_prefix('p') {
                        cur_pid = p.parse().ok();
                    } else if let Some(path) = line.strip_prefix('n') {
                        if path.starts_with('/') {
                            if let Some(pid) = cur_pid {
                                map.insert(pid, path.to_string());
                            }
                        }
                    }
                }
                map
            })
            .unwrap_or_default()
    };

    let login_cwds: HashMap<u32, String> = shell_pids.iter()
        .filter_map(|(lp, sp)| {
            shell_cwds.get(sp).map(|cwd| (*lp, cwd.clone()))
        })
        .collect();

    // Get surfaces from trm.
    let surfaces = trm_rpc("surface.list", serde_json::json!({}))
        .and_then(|r| r.get("result")?.get("surfaces")?.as_array().cloned())
        .unwrap_or_default();

    let home = std::env::var("HOME").unwrap_or_default();
    let expand = |t: &str| -> Option<String> {
        let tok = t.split_whitespace()
            .find(|tok| tok.starts_with('/') || tok.starts_with('~') || tok.starts_with('…'))?;
        if tok.starts_with('~') && !home.is_empty() {
            Some(format!("{}{}", home, &tok[1..]))
        } else {
            Some(tok.to_string())
        }
    };

    // Match each surface to a login by comparing title-derived path ↔ login shell cwd.
    let mut claimed_logins: HashSet<u32> = HashSet::new();
    let mut surface_to_login: HashMap<usize, u32> = HashMap::new(); // raw index → login

    for (raw_idx, s) in surfaces.iter().enumerate() {
        let title = strip_ansi(s.get("title").and_then(|v| v.as_str()).unwrap_or(""));
        let Some(tp) = expand(&title) else { continue };
        let tp_clean = tp.trim_end_matches('/');

        let matched = login_cwds.iter().find(|(lp, cwd)| {
            if claimed_logins.contains(lp) { return false; }
            let cwd_clean = cwd.trim_end_matches('/');
            if tp_clean.starts_with('…') {
                let suffix = &tp_clean[tp_clean.char_indices().nth(1).map(|(i, _)| i).unwrap_or(1)..];
                cwd_clean.ends_with(suffix)
            } else {
                cwd_clean == tp_clean
                    || cwd_clean.starts_with(&format!("{}/", tp_clean))
            }
        });
        if let Some((lp, _)) = matched {
            claimed_logins.insert(*lp);
            surface_to_login.insert(raw_idx, *lp);
        }
    }

    // Use discover_trm_panes for consistent index mapping.
    let panes = discover_trm_panes();

    // If target_login was matched to a surface, return it.
    if let Some((&raw_idx, _)) = surface_to_login.iter().find(|(_, &lp)| lp == target_login) {
        if let Some(pane) = panes.get(raw_idx) {
            let sid = format!("trm:{}", pane.index);
            tracing::info!("resolve_trm_pane_for_pid: pid {} → {} (title↔cwd)", target_pid, sid);
            return Some(sid);
        }
    }

    // target_login wasn't matched via title. Try matching by cwd against
    // discover_trm_panes results (which includes neighbor-derived cwds).
    let effective_clean = effective_cwd.trim_end_matches('/');
    // Exact match
    if let Some(pane) = panes.iter().find(|p| {
        p.has_claude && p.cwd.as_deref()
            .map(|c| c.trim_end_matches('/') == effective_clean)
            .unwrap_or(false)
    }) {
        let sid = format!("trm:{}", pane.index);
        tracing::info!("resolve_trm_pane_for_pid: pid {} → {} (pane cwd exact)", target_pid, sid);
        return Some(sid);
    }

    tracing::warn!(
        "resolve_trm_pane_for_pid: pid {} — no match (login={}, cwd={}, claimed={:?})",
        target_pid, target_login, effective_cwd, claimed_logins
    );
    None
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
        if !title_has_agent(&result[i].title) {
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

/// Send `text` to a trm pane by its pane_id (from surface.list), then submit with Enter.
/// Uses the trm Unix socket protocol: `{"type":"send","pane":N,"text":"..."}\n`.
/// The server responds with `{"status":"queued"}` on success.
pub fn trm_send_to_pane(pane_id: usize, text: &str) -> bool {
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
        let msg = format!("{}\n", serde_json::json!({"type":"send","pane":pane_id,"text":text_with_cr}));
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
