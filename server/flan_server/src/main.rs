use axum::{
    extract::State,
    http::StatusCode,
    response::{Html, IntoResponse},
    routing::{delete, get, post},
    Json, Router,
};
use serde::{Deserialize, Serialize};
use std::{
    collections::VecDeque,
    io::{BufRead, BufReader, Read, Write as IoWrite},
    net::TcpStream,
    path::PathBuf,
    process::Command,
    sync::Arc,
    time::{Duration, Instant},
};
use tokio::sync::RwLock;
use tower_http::cors::{Any, CorsLayer};
use tower_http::trace::TraceLayer;

// ── Models ──────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
struct ClaudeProcess {
    pid: u32,
    cwd: String,
    folder_name: String,
    last_message_preview: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct FlutterApp {
    pid: u32,
    cwd: String,
    folder_name: String,
    vm_service_uri: Option<String>,
    device: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct CmuxSurface {
    id: String,
    title: String,
    pane_id: String,
    focused: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct Association {
    id: String,
    claude_surface_id: String,
    flutter_pid: u32,
}

#[derive(Debug, Deserialize)]
struct CreateAssociation {
    claude_surface_id: String,
    flutter_pid: u32,
}

#[derive(Debug, Deserialize)]
struct FlushRequest {
    flutter_pid: Option<u32>,
    vm_service_uri: Option<String>,
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

// ── Activity Log ────────────────────────────────────────────────────────

const MAX_LOG_ENTRIES: usize = 200;

#[derive(Debug, Clone, Serialize)]
struct LogEntry {
    timestamp: String,
    /// "in" for requests arriving at the server, "out" for actions the server sends
    direction: &'static str,
    summary: String,
    detail: Option<String>,
    ok: bool,
}

// ── App State ───────────────────────────────────────────────────────────

struct AppState {
    associations: RwLock<Vec<Association>>,
    persistence_path: PathBuf,
    claude_cache: RwLock<Option<(Instant, Vec<ClaudeProcess>)>>,
    flutter_cache: RwLock<Option<(Instant, Vec<FlutterApp>)>>,
    activity_log: RwLock<VecDeque<LogEntry>>,
}

impl AppState {
    fn new() -> Self {
        let persistence_path = flan_dir().join("associations.json");
        let associations = load_associations(&persistence_path);
        Self {
            associations: RwLock::new(associations),
            persistence_path,
            claude_cache: RwLock::new(None),
            flutter_cache: RwLock::new(None),
            activity_log: RwLock::new(VecDeque::new()),
        }
    }

    async fn log(&self, direction: &'static str, summary: String, detail: Option<String>, ok: bool) {
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

fn chrono_now() -> String {
    // Simple ISO-ish timestamp using std
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

fn flan_dir() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".into());
    let p = PathBuf::from(home).join(".flan");
    std::fs::create_dir_all(&p).ok();
    p
}

fn load_associations(path: &PathBuf) -> Vec<Association> {
    std::fs::read_to_string(path)
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

fn save_associations(path: &PathBuf, associations: &[Association]) {
    if let Ok(json) = serde_json::to_string_pretty(associations) {
        std::fs::write(path, json).ok();
    }
}

// ── Discovery: Claude Processes ─────────────────────────────────────────

fn discover_claude_processes() -> Vec<ClaudeProcess> {
    let Ok(output) = Command::new("ps")
        .args(["-eo", "pid=,tty=,comm="])
        .output()
    else {
        return Vec::new();
    };

    let stdout = String::from_utf8_lossy(&output.stdout);
    let mut seen_cwds = std::collections::HashSet::new();
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

fn get_process_cwd(pid: u32) -> String {
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
                return path.to_string();
            }
        }
    }
    String::new()
}

fn find_last_claude_message(cwd: &str) -> Option<String> {
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
        .filter(|e| {
            e.path()
                .extension()
                .is_some_and(|ext| ext == "jsonl")
        })
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

fn discover_flutter_apps() -> Vec<FlutterApp> {
    let Ok(output) = Command::new("ps").args(["-eo", "pid,command"]).output() else {
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

        // Skip zombie flutter processes with no listening ports.
        if !has_listening_ports(pid) {
            continue;
        }

        let device = extract_device_flag(line);
        let cwd = get_process_cwd(pid);
        let folder_name = cwd.rsplit('/').next().unwrap_or(&cwd).to_string();
        let vm_uri = probe_vm_service_uri(pid);

        apps.push(FlutterApp {
            pid,
            cwd,
            folder_name,
            vm_service_uri: vm_uri,
            device: Some(device),
        });
    }

    apps
}

fn has_listening_ports(pid: u32) -> bool {
    Command::new("lsof")
        .args([
            "-i", "TCP", "-a", "-p", &pid.to_string(),
            "-a", "-s", "TCP:LISTEN", "-n", "-P",
        ])
        .output()
        .is_ok_and(|o| {
            String::from_utf8_lossy(&o.stdout).lines().any(|l| l.contains("LISTEN"))
        })
}

fn extract_device_flag(cmd_line: &str) -> String {
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

fn probe_vm_service_uri(pid: u32) -> Option<String> {
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
        // Match 127.0.0.1:PORT
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

fn probe_port(port: u16) -> Option<String> {
    let addr = format!("127.0.0.1:{}", port);
    let mut stream = TcpStream::connect_timeout(
        &addr.parse().ok()?,
        Duration::from_secs(2),
    ).ok()?;

    let request = format!(
        "GET / HTTP/1.1\r\nHost: 127.0.0.1:{}\r\nConnection: close\r\n\r\n",
        port
    );
    stream.write_all(request.as_bytes()).ok()?;
    stream.set_read_timeout(Some(Duration::from_secs(3))).ok()?;

    let mut body = String::new();
    stream.read_to_string(&mut body).ok();

    if body.contains("Dart Development Service") {
        // Parse: http://HOST:PORT/AUTH/
        if let Some(start) = body.find("http://") {
            let rest = &body[start..];
            // Find end of URL (ends with /.)
            if let Some(end) = rest.find("/.") {
                let url = &rest[..end + 1]; // include trailing /
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

// ── cmux Client ─────────────────────────────────────────────────────────

fn cmux_rpc(method: &str, params: serde_json::Value) -> Option<serde_json::Value> {
    use std::os::unix::net::UnixStream;
    use std::io::Write;

    let socket = std::env::var("CMUX_SOCKET_PATH").unwrap_or_else(|_| "/tmp/cmux.sock".into());
    let mut stream = match UnixStream::connect(&socket) {
        Ok(s) => s,
        Err(e) => {
            tracing::warn!("cmux_rpc: connect failed: {}", e);
            return None;
        }
    };
    stream.set_read_timeout(Some(Duration::from_secs(5))).ok()?;

    let password = std::env::var("CMUX_SOCKET_PASSWORD")
        .unwrap_or_else(|_| "flan".to_string());
    let request = serde_json::json!({
        "id": method,
        "method": method,
        "params": params,
        "password": password,
    });
    let mut msg = serde_json::to_string(&request).ok()?;
    msg.push('\n');
    tracing::debug!("cmux_rpc: sending to {}", socket);
    stream.write_all(msg.as_bytes()).ok()?;
    stream.flush().ok()?;
    stream.shutdown(std::net::Shutdown::Write).ok()?;

    let reader = BufReader::new(&stream);
    let line = match reader.lines().next() {
        Some(Ok(l)) => l,
        Some(Err(e)) => {
            tracing::warn!("cmux_rpc: read error: {}", e);
            return None;
        }
        None => {
            tracing::warn!("cmux_rpc: no response");
            return None;
        }
    };
    tracing::debug!("cmux_rpc: response len={}", line.len());

    if line.starts_with("ERROR") {
        tracing::warn!("cmux_rpc: {}", line);
        return None;
    }
    serde_json::from_str(&line).ok()
}

fn cmux_surface_list() -> Vec<CmuxSurface> {
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

    surfaces
        .iter()
        .filter_map(|s| {
            Some(CmuxSurface {
                id: s.get("id")?.as_str()?.to_string(),
                title: s.get("title")?.as_str()?.to_string(),
                pane_id: s.get("pane_id")?.as_str()?.to_string(),
                focused: s.get("focused")?.as_bool()?,
            })
        })
        .collect()
}

fn cmux_send_text(surface_id: &str, text: &str) -> bool {
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

fn focus_app_by_device(device: &str) -> bool {
    let app_name = match device.to_lowercase().as_str() {
        "chrome" => "Google Chrome",
        "safari" => "Safari",
        "edge" => "Microsoft Edge",
        "firefox" => "Firefox",
        "web-server" | "web" => "Google Chrome",
        "macos" => return focus_macos_app(),
        d if d.contains("iphone") || d.contains("ipad") || d.contains("simulator") => "Simulator",
        _ => "Google Chrome",
    };

    Command::new("osascript")
        .args(["-e", &format!("tell application \"{}\" to activate", app_name)])
        .output()
        .is_ok_and(|o| o.status.success())
}

fn focus_macos_app() -> bool {
    // For macOS target, find the most recently launched Flutter macOS app.
    // Look for processes whose command contains the Flutter build path.
    let Ok(output) = Command::new("ps").args(["-eo", "pid,comm"]).output() else {
        return false;
    };
    let stdout = String::from_utf8_lossy(&output.stdout);
    for line in stdout.lines() {
        if line.contains("build/macos") && line.contains(".app/Contents/MacOS/") {
            // Extract the .app name
            if let Some(app_start) = line.find(".app/Contents/MacOS/") {
                let before = &line[..app_start];
                if let Some(slash) = before.rfind('/') {
                    let app_name = &before[slash + 1..];
                    return Command::new("osascript")
                        .args(["-e", &format!("tell application \"{}\" to activate", app_name)])
                        .output()
                        .is_ok_and(|o| o.status.success());
                }
            }
        }
    }
    false
}

fn cmux_focus_surface(surface_id: &str) -> bool {
    cmux_rpc(
        "surface.focus",
        serde_json::json!({ "surface_id": surface_id }),
    )
    .and_then(|r| r.get("ok")?.as_bool())
    .unwrap_or(false)
}

// ── Route Handlers ──────────────────────────────────────────────────────

async fn get_claude_processes(State(state): State<Arc<AppState>>) -> Json<Vec<ClaudeProcess>> {
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

async fn get_flutter_apps(State(state): State<Arc<AppState>>) -> Json<Vec<FlutterApp>> {
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

async fn get_cmux_surfaces() -> Json<Vec<CmuxSurface>> {
    Json(
        tokio::task::spawn_blocking(cmux_surface_list)
            .await
            .unwrap_or_default(),
    )
}

async fn get_associations(State(state): State<Arc<AppState>>) -> Json<Vec<Association>> {
    Json(state.associations.read().await.clone())
}

async fn create_association(
    State(state): State<Arc<AppState>>,
    Json(body): Json<CreateAssociation>,
) -> impl IntoResponse {
    let assoc = Association {
        id: format!(
            "{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_millis()
        ),
        claude_surface_id: body.claude_surface_id,
        flutter_pid: body.flutter_pid,
    };

    let mut assocs = state.associations.write().await;
    assocs.retain(|a| a.flutter_pid != assoc.flutter_pid);
    assocs.push(assoc.clone());
    save_associations(&state.persistence_path, &assocs);

    state.log(
        "in",
        format!("Link created: flutter PID {} → surface {}", assoc.flutter_pid, &assoc.claude_surface_id[..8]),
        Some(format!("surface_id={}, flutter_pid={}", assoc.claude_surface_id, assoc.flutter_pid)),
        true,
    ).await;

    (StatusCode::CREATED, Json(assoc))
}

async fn delete_association(
    State(state): State<Arc<AppState>>,
    axum::extract::Path(id): axum::extract::Path<String>,
) -> StatusCode {
    let mut assocs = state.associations.write().await;
    let before = assocs.len();
    assocs.retain(|a| a.id != id);
    if assocs.len() < before {
        save_associations(&state.persistence_path, &assocs);
        state.log("in", format!("Link deleted: {}", id), None, true).await;
        StatusCode::NO_CONTENT
    } else {
        state.log("in", format!("Link delete failed: {} not found", id), None, false).await;
        StatusCode::NOT_FOUND
    }
}

async fn handle_flush(
    State(state): State<Arc<AppState>>,
    Json(body): Json<FlushRequest>,
) -> impl IntoResponse {
    // Fetch live cmux surfaces to validate associations.
    let live_surface_ids: std::collections::HashSet<String> =
        tokio::task::spawn_blocking(|| {
            cmux_surface_list().into_iter().map(|s| s.id).collect()
        })
        .await
        .unwrap_or_default();

    let mut assocs = state.associations.write().await;

    // Prune associations whose surface no longer exists in cmux.
    let before = assocs.len();
    assocs.retain(|a| live_surface_ids.contains(&a.claude_surface_id));
    if assocs.len() < before {
        save_associations(&state.persistence_path, &assocs);
        tracing::info!(
            "Pruned {} stale association(s) during flush",
            before - assocs.len()
        );
    }

    let assoc = if let Some(pid) = body.flutter_pid {
        assocs.iter().find(|a| a.flutter_pid == pid).cloned()
    } else {
        assocs.first().cloned()
    };

    let pruned = before - assocs.len();

    let Some(assoc) = assoc else {
        state.log("in", "Flush failed: no valid association".into(), None, false).await;
        return (
            StatusCode::NOT_FOUND,
            Json(serde_json::json!({"error": "No association found (all surfaces stale or none registered)"})),
        );
    };

    let flutter_pid = assoc.flutter_pid;
    drop(assocs);

    // Resolve VM service URI: prefer explicit, then discover from flutter PID.
    let vm_uri = body.vm_service_uri.clone().or_else(|| {
        // Check flutter cache first
        if let Ok(cache) = state.flutter_cache.try_read() {
            if let Some((_, ref apps)) = *cache {
                if let Some(app) = apps.iter().find(|a| a.pid == flutter_pid) {
                    return app.vm_service_uri.clone();
                }
            }
        }
        // Fall back to live probe
        probe_vm_service_uri(flutter_pid)
    });

    let text = match &vm_uri {
        Some(uri) => format!("flan connect to {} and process queue once connected", uri),
        None => "process queue".to_string(),
    };

    let surface_id = assoc.claude_surface_id.clone();
    let t = text.clone();
    let sid = surface_id.clone();

    let ok = tokio::task::spawn_blocking(move || {
        if cmux_send_text(&sid, &t) {
            cmux_send_text(&sid, "\n")
        } else {
            false
        }
    })
    .await
    .unwrap_or(false);

    if ok {
        tracing::info!("Flushed to surface {}: {}", surface_id, text);
        let pruned_note = if pruned > 0 { format!(" (pruned {} stale)", pruned) } else { String::new() };
        state.log(
            "out",
            format!("Flush → surface {}…{}", &surface_id[..8], pruned_note),
            Some(format!("sent: {}", text)),
            true,
        ).await;
        (StatusCode::OK, Json(serde_json::json!({"ok": true, "surface_id": surface_id})))
    } else {
        state.log(
            "out",
            format!("Flush failed → surface {}…", &surface_id[..8]),
            Some("cmux send_text returned false".into()),
            false,
        ).await;
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(serde_json::json!({"error": "Failed to send to cmux"})),
        )
    }
}

async fn handle_focus_surface(
    State(state): State<Arc<AppState>>,
    Json(body): Json<FocusSurfaceRequest>,
) -> impl IntoResponse {
    let sid = body.surface_id.clone();
    let ok = tokio::task::spawn_blocking(move || cmux_focus_surface(&sid))
        .await
        .unwrap_or(false);

    state.log("out", format!("Focus surface {}…", &body.surface_id[..8.min(body.surface_id.len())]), None, ok).await;

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
    State(state): State<Arc<AppState>>,
    Json(body): Json<TestSendRequest>,
) -> impl IntoResponse {
    let sid = body.surface_id.clone();
    let text = body.text.unwrap_or_else(|| "[flan test] hello from flan server".to_string());
    let t = text.clone();

    let ok = tokio::task::spawn_blocking(move || cmux_send_text(&sid, &t))
        .await
        .unwrap_or(false);

    state.log("out", format!("Test send → {}…", &body.surface_id[..8.min(body.surface_id.len())]), Some(format!("text: {}", text)), ok).await;

    if ok {
        (StatusCode::OK, Json(serde_json::json!({"ok": true, "sent": text})))
    } else {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(serde_json::json!({"error": "Failed to send test text"})),
        )
    }
}

async fn handle_focus_app(
    State(state): State<Arc<AppState>>,
    Json(body): Json<FocusAppRequest>,
) -> impl IntoResponse {
    let device = body.device.clone();
    let d = body.device;
    let ok = tokio::task::spawn_blocking(move || focus_app_by_device(&d))
        .await
        .unwrap_or(false);

    state.log("out", format!("Focus app: {}", device), None, ok).await;

    if ok {
        (StatusCode::OK, Json(serde_json::json!({"ok": true})))
    } else {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(serde_json::json!({"error": "Failed to focus app"})),
        )
    }
}

async fn handle_rescan(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    *state.claude_cache.write().await = None;
    *state.flutter_cache.write().await = None;
    (StatusCode::OK, Json(serde_json::json!({"ok": true})))
}

async fn get_activity_log(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let log = state.activity_log.read().await;
    let entries: Vec<LogEntry> = log.iter().cloned().collect();
    Json(entries)
}

async fn serve_ui() -> Html<&'static str> {
    Html(include_str!("../static/index.html"))
}

// ── Main ────────────────────────────────────────────────────────────────

#[tokio::main]
async fn main() {
    // Ignore SIGPIPE so child processes (cmux CLI) don't get killed when writing
    // to pipes. This is standard for network servers.
    unsafe { libc::signal(libc::SIGPIPE, libc::SIG_IGN); }

    // Log to ~/.flan/server.log so we can debug even when cmux respawns the server.
    let log_path = flan_dir().join("server.log");
    let log_file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&log_path)
        .expect("failed to open server.log");

    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "flan_server=debug,tower_http=debug".parse().unwrap()),
        )
        .with_writer(std::sync::Mutex::new(log_file))
        .with_ansi(false)
        .init();

    let state = Arc::new(AppState::new());

    let cors = CorsLayer::new()
        .allow_origin(Any)
        .allow_methods(Any)
        .allow_headers(Any);

    let app = Router::new()
        .route("/", get(serve_ui))
        .route("/api/claude-processes", get(get_claude_processes))
        .route("/api/flutter-apps", get(get_flutter_apps))
        .route("/api/cmux-surfaces", get(get_cmux_surfaces))
        .route(
            "/api/associations",
            get(get_associations).post(create_association),
        )
        .route("/api/associations/{id}", delete(delete_association))
        .route("/api/flush", post(handle_flush))
        .route("/api/focus-surface", post(handle_focus_surface))
        .route("/api/focus-app", post(handle_focus_app))
        .route("/api/test-send", post(handle_test_send))
        .route("/api/rescan", post(handle_rescan))
        .route("/api/logs", get(get_activity_log))
        .layer(cors)
        .layer(TraceLayer::new_for_http())
        .with_state(state);

    let port: u16 = std::env::var("FLAN_SERVER_PORT")
        .ok()
        .and_then(|p| p.parse().ok())
        .unwrap_or(4050);

    tracing::info!("Flan server on http://localhost:{}", port);

    let listener = tokio::net::TcpListener::bind(format!("0.0.0.0:{}", port))
        .await
        .unwrap();
    axum::serve(listener, app).await.unwrap();
}
