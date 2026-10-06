use serde::{Deserialize, Serialize};
use std::{
    collections::{HashMap, HashSet, VecDeque},
    io::{BufRead, BufReader, Read, Seek, SeekFrom, Write as IoWrite},
    net::TcpStream,
    path::PathBuf,
    process::Command,
    sync::atomic::{AtomicU16, AtomicU64, Ordering},
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
use std::sync::{Mutex, OnceLock};
use tokio::sync::RwLock;

pub mod desktop_bridge;
pub mod watch;

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
    /// Whether an agent is currently CONNECTED to this app — the steady
    /// connection truth, distinct from a persisted association. Drives whether
    /// the TUI draws a connector line.
    #[serde(default)]
    pub connected: bool,
    /// The `--web-port` this app was launched with, if any. Used to identify a
    /// web app that flushes with only its origin (no vm_service_uri / pid).
    #[serde(default)]
    pub web_port: Option<u16>,
    /// Opaque app identity supplied by the environment. Unlike the browser's
    /// visible port, this remains stable when a tailnet proxy fronts the app.
    #[serde(default)]
    pub app_id: Option<String>,
    /// The machine the app is running on, when it is not this one.
    ///
    /// A remote app flushes its browser origin, which already carries the host
    /// — `http://m1.follow-ionian.ts.net:5105`. That host was being parsed for
    /// its port and otherwise discarded, so two apps on two machines rendered
    /// identically apart from a port number. `None` means the app was found
    /// locally (process table or listener), which is a statement about this
    /// machine rather than a missing value.
    #[serde(default)]
    pub host: Option<String>,
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

/// A live coding-agent session — the unit the TUI lists in its agent column.
///
/// Sessions come from three places, in decreasing order of richness:
///   * Claude Code's own registry at `~/.claude/sessions/<pid>.json`, which
///     knows every running session including those with no Flan wiring at all;
///   * flan-channel processes found in the process table, which supply the
///     loopback port that makes a session *reachable*;
///   * channels that registered over HTTP, for hosts where the process table
///     doesn't show them.
///
/// None of these needs a terminal multiplexer, which is the point: a detached
/// `zmx` session, plain ssh, or a cloud runner exposes no pane to discover.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentSession {
    /// Claude Code's session id. Stable for the life of the session — unlike a
    /// channel port, which is rebound on restart — so it is the identity a
    /// persisted link should hang off.
    #[serde(default)]
    pub session_id: Option<String>,
    /// PID of the agent process itself.
    #[serde(default)]
    pub agent_pid: Option<u32>,
    /// Product name ("Claude", "Codex", …).
    #[serde(default)]
    pub agent_name: Option<String>,
    /// Claude Code's own label for the session, e.g. "fasmac-40". The one
    /// handle that distinguishes several sessions sharing a repo.
    #[serde(default)]
    pub session_name: Option<String>,
    /// "busy", "idle", "shell", … as reported by the registry.
    #[serde(default)]
    pub status: Option<String>,
    /// Controlling tty, e.g. "ttys020".
    #[serde(default)]
    pub tty: Option<String>,
    #[serde(default)]
    pub cwd: Option<String>,
    /// Checked-out branch, and the linked-worktree name when the cwd is one.
    #[serde(default)]
    pub branch: Option<String>,
    #[serde(default)]
    pub worktree: Option<String>,
    /// What the session is working on: its AI-generated title, else the last
    /// prompt the user sent.
    #[serde(default)]
    pub summary: Option<String>,
    /// Artifacts published from this session, most recent last — the same
    /// names Claude Code shows in its status line. Often the clearest way to
    /// tell which of several sessions on one repo is which.
    #[serde(default)]
    pub artifacts: Vec<String>,
    /// Loopback port of this session's flan-channel. `None` means the session
    /// is visible but NOT reachable — it can be seen, not messaged.
    #[serde(default)]
    pub channel_port: Option<u16>,
    #[serde(default)]
    pub channel_pid: Option<u32>,
    /// trm surface id, when pane resolution happened to succeed. Informational.
    #[serde(default)]
    pub surface_id: Option<String>,
    /// Seconds since an HTTP-registered channel last checked in. Always 0 for
    /// sessions found by scanning.
    #[serde(default)]
    pub age_secs: u64,
}

/// A flan-channel that announced itself over HTTP.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChannelRegistration {
    pub port: u16,
    #[serde(default)]
    pub channel_pid: Option<u32>,
    #[serde(default)]
    pub agent_pid: Option<u32>,
    #[serde(default)]
    pub agent_name: Option<String>,
    #[serde(default)]
    pub tty: Option<String>,
    #[serde(default)]
    pub cwd: Option<String>,
    #[serde(default)]
    pub surface_id: Option<String>,
}

/// How long a registration stays listed without a heartbeat. The channel
/// re-registers every 30s, so three missed beats means it's gone.
pub const CHANNEL_TTL: Duration = Duration::from_secs(95);

/// How long an app that can only be seen when it talks stays listed. Nothing
/// heartbeats here — a browser tab flushes when the user sends a message and is
/// otherwise silent — so the window is generous. Too short and the row vanishes
/// between messages, taking the link with it.
pub const REMOTE_APP_TTL: Duration = Duration::from_secs(6 * 60 * 60);

/// Find the link that belongs to a flushing app.
///
/// Order matters. The app id comes first: it is the only identity an app
/// without a local process has, and for a local app it outlives a rebuild that
/// changes the pid. The cwd is last — it is a recovery path for an app that
/// restarted, not an identity, since two apps can share a directory.
///
/// There is deliberately no "if all else fails, use the first link" step: with
/// several linked apps that routes everyone's messages to one agent.
pub fn resolve_association(
    assocs: &[Association],
    app_id: Option<&str>,
    resolved_pid: Option<u32>,
    flutter_cwd: Option<&str>,
) -> Option<Association> {
    app_id
        .filter(|id| !id.is_empty())
        .and_then(|id| {
            assocs
                .iter()
                .find(|a| a.flutter_app_id.as_deref() == Some(id))
                .cloned()
        })
        .or_else(|| {
            // pid 0 means "no local process"; it must never match by pid, or
            // every remote app would collapse onto one link.
            let pid = resolved_pid.filter(|pid| *pid != 0)?;
            assocs.iter().find(|a| a.flutter_pid == pid).cloned()
        })
        .or_else(|| {
            let cwd = flutter_cwd.filter(|c| !c.is_empty())?;
            assocs
                .iter()
                .find(|a| a.flutter_cwd.as_deref() == Some(cwd))
                .cloned()
        })
}

/// Add remote apps that no local process already covers.
///
/// A local process is always the better row — it has a pid, a cwd, and a real
/// path — so a match on either identity keeps the local one. The port counts as
/// an identity here: a statically-served app is discovered by its port and
/// flushes by its id, and those are the same app seen from two sides.
///
/// A port only identifies an app *on the same host*. Two machines both running
/// `--web-port 5005` are two apps, and treating the port alone as the identity
/// silently hides whichever one is merged second — which is how an app on the
/// build host disappears because this machine happens to serve the same port.
pub fn merge_remote_apps(apps: &mut Vec<FlutterApp>, remote: Vec<FlutterApp>) {
    for app in remote {
        let same_id = app
            .app_id
            .as_ref()
            .is_some_and(|id| apps.iter().any(|a| a.app_id.as_ref() == Some(id)));
        let same_port = app
            .web_port
            .is_some_and(|port| {
                apps.iter()
                    .any(|a| a.web_port == Some(port) && a.host == app.host)
            });
        if !same_id && !same_port {
            apps.push(app);
        }
    }
}

/// Add the apps a peer flan server reports from its own process table.
///
/// Identity is `app_id`, or the host-and-port pair. A bare port is deliberately
/// not enough: see [merge_remote_apps].
///
/// Order matters at the call site. A peer row carries a pid, a cwd and a device,
/// so merging peers BEFORE [merge_remote_apps] lets the full row win over the
/// `pid 0` stub the same app left behind when it last flushed.
pub fn merge_peer_apps(apps: &mut Vec<FlutterApp>, peer: Vec<FlutterApp>) {
    for app in peer {
        let same_id = app
            .app_id
            .as_ref()
            .is_some_and(|id| apps.iter().any(|a| a.app_id.as_ref() == Some(id)));
        let same_place = app.web_port.is_some_and(|port| {
            apps.iter()
                .any(|a| a.web_port == Some(port) && a.host == app.host)
        });
        if !same_id && !same_place {
            apps.push(app);
        }
    }
}

/// Flutter web builds being served by a plain static server.
///
/// `flutter run` isn't the only way an app gets in front of a browser: a
/// release bundle served by python, nginx, or anything else has no Flutter
/// process at all, so process-name discovery never sees it. What it does have
/// is a listening port and a working directory full of Flutter build output —
/// enough to name it, place it, and route a flush by origin port.
pub fn discover_static_web_apps() -> Vec<FlutterApp> {
    // A watched port gets its own row (pointing at its proxy), so a Flutter
    // bundle that happens to sit behind one must not also appear here.
    let watched = watch::load_watched_ports();
    let mut apps = watch::discover_watched_web_apps(&watched);

    // pid → first listening port.
    let mut listeners: Vec<(u32, u16)> = Vec::new();
    for (pid, port) in listening_sockets() {
        if watched.contains(&port) {
            continue;
        }
        if !listeners.iter().any(|(known, _)| *known == pid) {
            listeners.push((pid, port));
        }
    }
    if listeners.is_empty() {
        return apps;
    }

    let pid_csv = listeners
        .iter()
        .map(|(pid, _)| pid.to_string())
        .collect::<Vec<_>>()
        .join(",");
    let cwds = process_cwds(&pid_csv);

    let static_apps: Vec<FlutterApp> =     listeners
        .into_iter()
        .filter_map(|(pid, port)| {
            let served = PathBuf::from(cwds.get(&pid)?);
            if !is_flutter_web_build(&served) {
                return None;
            }
            // Report the project directory, not `build/web`: that's what pairs
            // with an agent's cwd and what a human recognises.
            let root = flutter_project_root(&served);
            Some(FlutterApp {
                pid,
                folder_name: root
                    .file_name()
                    .map(|n| n.to_string_lossy().to_string())
                    .unwrap_or_default(),
                cwd: root.to_string_lossy().to_string(),
                vm_service_uri: None,
                device: Some("static".to_string()),
                queue_count: 0,
                connected: false,
                web_port: Some(port),
                app_id: None,
                host: None,
            })
        })
        .collect();
    apps.extend(static_apps);
    apps
}

/// Every `(pid, port)` pair with a listening TCP socket, as `lsof` reports.
pub fn listening_sockets() -> Vec<(u32, u16)> {
    let Ok(out) = Command::new("lsof")
        .args(["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpn"])
        .output()
    else {
        return Vec::new();
    };
    let mut sockets = Vec::new();
    let mut cur: Option<u32> = None;
    for line in String::from_utf8_lossy(&out.stdout).lines() {
        if let Some(pid) = line.strip_prefix('p') {
            cur = pid.parse().ok();
        } else if let Some(name) = line.strip_prefix('n') {
            let Some(port) = name.rsplit(':').next().and_then(|p| p.parse::<u16>().ok()) else {
                continue;
            };
            if let Some(pid) = cur {
                sockets.push((pid, port));
            }
        }
    }
    sockets
}

/// True if this directory is Flutter web build output. `flutter_bootstrap.js`
/// is emitted by current builds, `main.dart.js` by older ones.
fn is_flutter_web_build(dir: &std::path::Path) -> bool {
    dir.join("flutter_bootstrap.js").exists() || dir.join("main.dart.js").exists()
}

/// Strip the `build/web` tail a served bundle sits in, leaving the project.
fn flutter_project_root(served: &std::path::Path) -> PathBuf {
    let mut root = served.to_path_buf();
    for expected in ["web", "build"] {
        if root.file_name().map(|n| n == expected).unwrap_or(false) {
            root.pop();
        }
    }
    root
}

/// Build the row for an app known only by the identity it flushes with.
pub fn remote_app(app_id: &str, origin: Option<&str>) -> FlutterApp {
    // The id is conventionally "<project>:<worktree>"; the tail is the part
    // that distinguishes two apps from the same project.
    let folder_name = app_id.rsplit(':').next().unwrap_or(app_id).to_string();
    FlutterApp {
        // No local process: 0 marks "not a pid" rather than pretending.
        pid: 0,
        cwd: String::new(),
        folder_name,
        vm_service_uri: None,
        device: Some("remote".to_string()),
        queue_count: 0,
        connected: false,
        web_port: origin.and_then(parse_origin_port),
        app_id: Some(app_id.to_string()),
        host: origin.and_then(parse_origin_host),
    }
}

/// Walk up from `pid` to the nearest ancestor that looks like a coding agent,
/// returning `(pid, display name, tty)`.
///
/// An MCP server is spawned as a child of the agent process, so the agent is
/// always an ancestor of the flan-channel — usually the direct parent, but a
/// shell wrapper (`dart run …`) can sit in between, hence the walk.
pub fn find_agent_ancestor(pid: u32) -> Option<(u32, String, Option<String>)> {
    find_agent_ancestor_in(&process_table(), pid)
}

/// `pid → (ppid, tty, comm)` for every process, so a caller resolving many
/// pids pays for `ps` once.
pub fn process_table() -> HashMap<u32, (u32, String, String)> {
    let Ok(out) = Command::new("ps").args(["-eo", "pid=,ppid=,tty=,comm="]).output() else {
        return HashMap::new();
    };
    let text = String::from_utf8_lossy(&out.stdout);
    let mut procs: HashMap<u32, (u32, String, String)> = HashMap::new();
    for line in text.lines() {
        let mut it = line.split_whitespace();
        let Some(pid) = it.next().and_then(|v| v.parse::<u32>().ok()) else { continue };
        let Some(ppid) = it.next().and_then(|v| v.parse::<u32>().ok()) else { continue };
        let Some(tty) = it.next() else { continue };
        let comm = it.collect::<Vec<_>>().join(" ");
        procs.insert(pid, (ppid, tty.to_string(), comm));
    }
    procs
}

/// As [`find_agent_ancestor`], against an already-built process table.
pub fn find_agent_ancestor_in(
    procs: &HashMap<u32, (u32, String, String)>,
    pid: u32,
) -> Option<(u32, String, Option<String>)> {
    let mut cur = pid;
    for _ in 0..12 {
        let (ppid, tty, comm) = procs.get(&cur)?.clone();
        if let Some(name) = agent_name_from_comm(&comm) {
            let tty = (tty != "??" && !tty.is_empty()).then_some(tty);
            return Some((cur, name.to_string(), tty));
        }
        if ppid <= 1 {
            return None;
        }
        cur = ppid;
    }
    None
}

/// True if `pid` is still alive. `kill(pid, 0)` performs the permission and
/// existence checks without delivering a signal.
pub fn pid_is_alive(pid: u32) -> bool {
    pid != 0 && unsafe { libc::kill(pid as libc::pid_t, 0) } == 0
}

/// One entry of Claude Code's session registry.
#[derive(Debug, Clone, Deserialize)]
struct SessionRecord {
    pid: u32,
    #[serde(default)]
    #[serde(rename = "sessionId")]
    session_id: Option<String>,
    #[serde(default)]
    cwd: Option<String>,
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    status: Option<String>,
}

/// Every live agent session on this host, with the context needed to tell two
/// sessions in the same repo apart.
///
/// Listing only *reachable* sessions hid over half of them: a session without
/// the flan-channel MCP server has no port to find, but it is still running,
/// still worth seeing, and still the thing a user means when they ask which
/// agents are up. Reachability is a property to display, not a filter.
pub fn discover_agent_sessions() -> Vec<AgentSession> {
    let procs = process_table();
    let channels = discover_channel_processes(&procs);

    let mut sessions: Vec<AgentSession> = Vec::new();
    let mut claimed_ports: HashSet<u16> = HashSet::new();

    for record in read_session_registry() {
        if !pid_is_alive(record.pid) {
            continue;
        }
        let tty = procs
            .get(&record.pid)
            .map(|(_, tty, _)| tty.clone())
            .filter(|t| t != "??" && !t.is_empty());
        let agent_name = procs
            .get(&record.pid)
            .and_then(|(_, _, comm)| agent_name_from_comm(comm))
            .map(|n| n.to_string())
            .or_else(|| Some("Claude".to_string()));
        let channel = channels.iter().find(|c| c.agent_pid == Some(record.pid));
        if let Some(channel) = channel {
            claimed_ports.insert(channel.port);
        }
        let cwd = record.cwd.filter(|c| !c.is_empty());
        let (branch, worktree) = cwd.as_deref().map(git_context).unwrap_or((None, None));
        let transcript = match (cwd.as_deref(), record.session_id.as_deref()) {
            (Some(cwd), Some(sid)) => transcript_index(cwd, sid),
            _ => None,
        };
        sessions.push(AgentSession {
            session_id: record.session_id,
            agent_pid: Some(record.pid),
            agent_name,
            session_name: record.name,
            status: record.status,
            tty,
            cwd,
            branch,
            worktree,
            summary: transcript.as_ref().and_then(|t| t.summary()),
            artifacts: transcript.map(|t| t.artifacts).unwrap_or_default(),
            channel_port: channel.map(|c| c.port),
            channel_pid: channel.and_then(|c| c.channel_pid),
            surface_id: None,
            age_secs: 0,
        });
    }

    // Channels whose agent isn't in the registry — a non-Claude agent, or a
    // Claude old enough to predate it. Reachable, just less well described.
    for channel in &channels {
        if claimed_ports.contains(&channel.port) {
            continue;
        }
        let cwd = channel.agent_pid.and_then(|pid| {
            let cwd = get_process_cwd(pid);
            (!cwd.is_empty()).then_some(cwd)
        });
        let (branch, worktree) = cwd.as_deref().map(git_context).unwrap_or((None, None));
        sessions.push(AgentSession {
            session_id: None,
            agent_pid: channel.agent_pid,
            agent_name: channel.agent_name.clone(),
            session_name: None,
            status: None,
            tty: channel.tty.clone(),
            cwd,
            branch,
            worktree,
            summary: None,
            artifacts: Vec::new(),
            channel_port: Some(channel.port),
            channel_pid: channel.channel_pid,
            surface_id: None,
            age_secs: 0,
        });
    }

    sort_sessions(&mut sessions);
    sessions
}

impl AgentSession {
    /// The identity a link is stored against.
    ///
    /// The agent's pid: unique, constant for the life of the process, and
    /// independent of the channel port, so a link survives the flan-channel
    /// being restarted on a new port.
    ///
    /// NOT the Claude session id — two live agents can report the SAME one by
    /// resuming a session — and never the cwd, which sibling sessions share.
    pub fn entry_id(&self) -> String {
        match (self.agent_pid, self.channel_port) {
            (Some(pid), _) => format!("sess:{pid}"),
            (None, Some(port)) => format!("chan:{port}"),
            _ => "sess:unknown".to_string(),
        }
    }

    /// Short human label for this session, for logs and the app's status chip.
    pub fn label(&self) -> String {
        self.session_name
            .clone()
            .or_else(|| self.cwd.as_ref().map(|c| {
                c.rsplit('/').next().unwrap_or(c).to_string()
            }))
            .unwrap_or_else(|| self.entry_id())
    }
}

/// Stable display order, so rows don't shuffle between refreshes: by cwd, then
/// by the session's own name, then by pid.
pub fn sort_sessions(sessions: &mut [AgentSession]) {
    sessions.sort_by(|a, b| {
        a.cwd
            .cmp(&b.cwd)
            .then(a.session_name.cmp(&b.session_name))
            .then(a.agent_pid.cmp(&b.agent_pid))
    });
}

fn read_session_registry() -> Vec<SessionRecord> {
    let Ok(home) = std::env::var("HOME") else {
        return Vec::new();
    };
    let dir = PathBuf::from(home).join(".claude").join("sessions");
    let Ok(entries) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    entries
        .filter_map(|entry| {
            let path = entry.ok()?.path();
            if path.extension()? != "json" {
                return None;
            }
            serde_json::from_str(&std::fs::read_to_string(&path).ok()?).ok()
        })
        .collect()
}

/// A flan-channel process found in the process table.
#[derive(Debug, Clone)]
pub struct ChannelProcess {
    pub port: u16,
    pub channel_pid: Option<u32>,
    pub agent_pid: Option<u32>,
    pub agent_name: Option<String>,
    pub tty: Option<String>,
}

/// Find live flan-channel processes and read their bound port straight from
/// the kernel, without waiting to be told.
///
/// Registration-by-heartbeat only covers channels that know a relay URL and
/// started after it was configured. Every channel already running when the
/// server comes up would otherwise stay invisible even though its port is
/// right there in `lsof`.
pub fn discover_channel_processes(
    procs: &HashMap<u32, (u32, String, String)>,
) -> Vec<ChannelProcess> {
    let Ok(out) = Command::new("ps").args(["-eo", "pid=,args="]).output() else {
        return Vec::new();
    };
    let listing = String::from_utf8_lossy(&out.stdout);
    let channel_pids: Vec<u32> = listing
        .lines()
        .filter(|line| line.contains("flan_channel"))
        .filter_map(|line| line.split_whitespace().next()?.parse().ok())
        .collect();
    if channel_pids.is_empty() {
        return Vec::new();
    }

    // One lsof for every channel at once, rather than a spawn per process on a
    // loop that reruns every few seconds.
    let pid_csv = channel_pids
        .iter()
        .map(|p| p.to_string())
        .collect::<Vec<_>>()
        .join(",");
    let ports = channel_listen_ports(&pid_csv);

    channel_pids
        .iter()
        .filter_map(|&channel_pid| {
            let port = *ports.get(&channel_pid)?;
            let ancestry = find_agent_ancestor_in(procs, channel_pid);
            Some(ChannelProcess {
                port,
                channel_pid: Some(channel_pid),
                agent_pid: ancestry.as_ref().map(|(pid, _, _)| *pid),
                agent_name: ancestry.as_ref().map(|(_, name, _)| name.clone()),
                tty: ancestry.and_then(|(_, _, tty)| tty),
            })
        })
        .collect()
}

/// `pid → cwd` for the given comma-separated pids, in one `lsof`.
pub fn process_cwds(pid_csv: &str) -> HashMap<u32, String> {
    if pid_csv.is_empty() {
        return HashMap::new();
    }
    let Ok(out) = Command::new("lsof")
        .args(["-d", "cwd", "-a", "-Fpn", "-a", "-p", pid_csv])
        .output()
    else {
        return HashMap::new();
    };
    let mut cwds = HashMap::new();
    let mut cur: Option<u32> = None;
    for line in String::from_utf8_lossy(&out.stdout).lines() {
        if let Some(pid) = line.strip_prefix('p') {
            cur = pid.parse().ok();
        } else if let Some(path) = line.strip_prefix('n') {
            if path.starts_with('/') {
                if let Some(pid) = cur {
                    cwds.entry(pid).or_insert_with(|| strip_ansi(path));
                }
            }
        }
    }
    cwds
}

/// `pid → listening TCP port` for the given comma-separated pids.
fn channel_listen_ports(pid_csv: &str) -> HashMap<u32, u16> {
    let Ok(out) = Command::new("lsof")
        .args(["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", pid_csv, "-Fpn"])
        .output()
    else {
        return HashMap::new();
    };
    let mut ports = HashMap::new();
    let mut cur: Option<u32> = None;
    for line in String::from_utf8_lossy(&out.stdout).lines() {
        if let Some(pid) = line.strip_prefix('p') {
            cur = pid.parse().ok();
        } else if let Some(name) = line.strip_prefix('n') {
            let Some(port) = name.rsplit(':').next().and_then(|p| p.parse::<u16>().ok()) else {
                continue;
            };
            if let Some(pid) = cur {
                // First listener wins; a channel binds exactly one port.
                ports.entry(pid).or_insert(port);
            }
        }
    }
    ports
}

/// `(branch, worktree)` for a working directory, read from the git metadata
/// rather than by shelling out to `git` on every refresh.
///
/// A linked worktree has a `.git` *file* pointing into the main repo's
/// `worktrees/<name>` directory — which is exactly the name that distinguishes
/// sibling sessions on one repo, so it's worth surfacing alongside the branch.
pub fn git_context(cwd: &str) -> (Option<String>, Option<String>) {
    let mut dir = PathBuf::from(cwd);
    loop {
        let dot_git = dir.join(".git");
        if dot_git.is_dir() {
            return (head_branch(&dot_git), None);
        }
        if dot_git.is_file() {
            let Some(gitdir) = std::fs::read_to_string(&dot_git)
                .ok()
                .and_then(|s| s.trim().strip_prefix("gitdir:").map(|p| p.trim().to_string()))
            else {
                return (None, None);
            };
            let gitdir = PathBuf::from(gitdir);
            let worktree = gitdir
                .file_name()
                .map(|n| n.to_string_lossy().to_string());
            return (head_branch(&gitdir), worktree);
        }
        if !dir.pop() {
            return (None, None);
        }
    }
}

fn head_branch(gitdir: &std::path::Path) -> Option<String> {
    let head = std::fs::read_to_string(gitdir.join("HEAD")).ok()?;
    let head = head.trim();
    match head.strip_prefix("ref: refs/heads/") {
        Some(branch) => Some(branch.to_string()),
        // Detached HEAD: show the short sha rather than nothing.
        None => Some(head.chars().take(8).collect()),
    }
}

/// Claude Code's on-disk name for a project directory: every `/`, `_` and `.`
/// becomes `-`. Getting this wrong silently yields "no transcript" for any repo
/// with an underscore in its path — `flan_mcp`, for one.
pub fn claude_project_slug(cwd: &str) -> String {
    cwd.chars()
        .map(|c| if c == '/' || c == '_' || c == '.' { '-' } else { c })
        .collect()
}

/// What we've learned from a session's transcript, and how far into the file
/// we got.
///
/// Transcripts reach tens of megabytes and only ever grow, so each pass reads
/// the bytes appended since the last one. Re-reading from the start every few
/// seconds would be hundreds of megabytes a minute; reading only the tail
/// would miss anything stated once and early — which is exactly where artifact
/// records live.
#[derive(Debug, Default, Clone)]
pub struct TranscriptIndex {
    /// Byte offset consumed so far, always on a line boundary.
    pub read_to: u64,
    pub title: Option<String>,
    pub last_prompt: Option<String>,
    /// Artifact names in publication order.
    pub artifacts: Vec<String>,
}

impl TranscriptIndex {
    /// The session's one-line description: its AI-generated title, falling
    /// back to the last prompt the user sent.
    pub fn summary(&self) -> Option<String> {
        self.title
            .clone()
            .or_else(|| self.last_prompt.clone())
            .map(|text| one_line(&text, 96))
    }
}

/// Fold a run of transcript lines into the index.
///
/// Only lines that can possibly matter are parsed — a substring check first,
/// `serde_json` second — because the overwhelming majority of a transcript is
/// tool traffic this doesn't care about.
pub fn absorb_transcript(index: &mut TranscriptIndex, text: &str) {
    for line in text.lines() {
        let interesting = line.contains("aiTitle")
            || line.contains("lastPrompt")
            || line.contains("frameUrl");
        if !interesting {
            continue;
        }
        let Ok(value) = serde_json::from_str::<serde_json::Value>(line) else {
            continue;
        };
        if let Some(title) = value.get("aiTitle").and_then(|v| v.as_str()) {
            index.title = Some(title.to_string());
        }
        if let Some(prompt) = value.get("lastPrompt").and_then(|v| v.as_str()) {
            index.last_prompt = Some(prompt.to_string());
        }
        // A published artifact is recorded as a "frame-link" naming the file it
        // was built from. The file stem is the name Claude Code's status line
        // shows, so it's the one a user will recognise.
        if value.get("frameUrl").is_some() {
            if let Some(name) = value
                .get("path")
                .and_then(|v| v.as_str())
                .and_then(artifact_name)
            {
                if !index.artifacts.contains(&name) {
                    index.artifacts.push(name);
                }
            }
        }
    }
}

fn artifact_name(path: &str) -> Option<String> {
    let file = path.rsplit('/').next()?;
    let stem = file.split('.').next()?;
    (!stem.is_empty()).then(|| stem.to_string())
}

/// Cached transcript state per session id. Pure derived data — a cache miss
/// costs time, never correctness — so it lives beside the reader rather than
/// being threaded through every caller.
fn transcript_cache() -> &'static Mutex<HashMap<String, TranscriptIndex>> {
    static CACHE: OnceLock<Mutex<HashMap<String, TranscriptIndex>>> = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Read whatever the session has appended since last time and return the
/// updated index.
pub fn transcript_index(cwd: &str, session_id: &str) -> Option<TranscriptIndex> {
    use std::io::{Read, Seek, SeekFrom};

    let home = std::env::var("HOME").ok()?;
    let path = PathBuf::from(home)
        .join(".claude")
        .join("projects")
        .join(claude_project_slug(cwd))
        .join(format!("{session_id}.jsonl"));

    let mut cache = transcript_cache().lock().ok()?;
    let index = cache.entry(session_id.to_string()).or_default();

    let mut file = std::fs::File::open(&path).ok()?;
    let len = file.metadata().ok()?.len();
    // Shorter than what we consumed means a different file wearing the same
    // name — start over rather than splicing two transcripts together.
    if len < index.read_to {
        *index = TranscriptIndex::default();
    }
    if len > index.read_to {
        file.seek(SeekFrom::Start(index.read_to)).ok()?;
        let mut buf = Vec::new();
        file.read_to_end(&mut buf).ok()?;
        // Stop at the last newline: the session may be mid-write, and half a
        // line would be parsed as garbage and then never re-read.
        if let Some(end) = buf.iter().rposition(|&b| b == b'\n') {
            let text = String::from_utf8_lossy(&buf[..=end]);
            absorb_transcript(index, &text);
            index.read_to += end as u64 + 1;
        }
    }
    Some(index.clone())
}

/// Collapse to a single line and clip to `max` chars, so a pasted wall of text
/// can't blow up a row.
fn one_line(text: &str, max: usize) -> String {
    let flat = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if flat.chars().count() <= max {
        return flat;
    }
    let clipped: String = flat.chars().take(max.saturating_sub(1)).collect();
    format!("{clipped}…")
}


/// Drop registrations whose agent has exited or that have gone quiet.
///
/// Both checks matter: liveness catches an agent that was killed a second ago,
/// while the heartbeat window catches one that vanished without its pid ever
/// being resolvable. A registration that outlives its process would otherwise
/// sit in the TUI as a link target that silently swallows flushes.
pub fn prune_channels(
    channels: &mut HashMap<u16, (Instant, ChannelRegistration)>,
    is_alive: impl Fn(u32) -> bool,
) -> Vec<(u64, ChannelRegistration)> {
    channels.retain(|_, (seen, reg)| {
        seen.elapsed() < CHANNEL_TTL && reg.agent_pid.map(&is_alive).unwrap_or(true)
    });
    let mut out: Vec<(u64, ChannelRegistration)> = channels
        .values()
        .map(|(seen, reg)| (seen.elapsed().as_secs(), reg.clone()))
        .collect();
    out.sort_by_key(|(_, reg)| reg.port);
    out
}

/// Fold HTTP registrations into the discovered list.
///
/// Discovery covers everything visible in the process table; a registration
/// only adds something when it doesn't — a channel this process can't see, on
/// a host where `ps` and `lsof` don't reach it.
pub fn merge_registrations(
    discovered: &mut Vec<AgentSession>,
    registrations: Vec<(u64, ChannelRegistration)>,
) {
    for (age_secs, reg) in registrations {
        if let Some(existing) = discovered.iter_mut().find(|s| {
            s.channel_port == Some(reg.port)
                || (reg.agent_pid.is_some() && s.agent_pid == reg.agent_pid)
        }) {
            // Known session: registration only adds the pane it resolved and,
            // if discovery somehow missed it, the port.
            existing.channel_port = existing.channel_port.or(Some(reg.port));
            existing.surface_id = existing.surface_id.take().or(reg.surface_id);
            continue;
        }
        discovered.push(AgentSession {
            session_id: None,
            agent_pid: reg.agent_pid,
            agent_name: reg.agent_name,
            session_name: None,
            status: None,
            tty: reg.tty,
            cwd: reg.cwd,
            branch: None,
            worktree: None,
            summary: None,
            artifacts: Vec::new(),
            channel_port: Some(reg.port),
            channel_pid: reg.channel_pid,
            surface_id: reg.surface_id,
            age_secs,
        });
    }
    sort_sessions(discovered);
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Association {
    pub id: String,
    pub claude_surface_id: String,
    pub flutter_pid: u32,
    /// The Flutter app's working directory at link time. Lets a rebuilt app
    /// (same cwd, new pid) re-resolve its association even though `flutter_pid`
    /// no longer matches. Optional for backward-compat with older persisted
    /// associations that predate this field.
    #[serde(default)]
    pub flutter_cwd: Option<String>,
    /// `FLAN_APP_ID`, when the app supplies one. The only identity that works
    /// for an app this host can't see as a process — served as a static bundle,
    /// or running on another machine and reaching the relay over the tailnet.
    /// It also outlives a rebuild, unlike the pid.
    #[serde(default)]
    pub flutter_app_id: Option<String>,
}

/// An annotated feedback message sent by a web (React) client over the
/// `/ws` WebSocket. Web apps have no Dart VM, so — unlike Flutter apps,
/// which host their own queue — their messages are queued server-side in
/// [`SharedState::web_queue`] and drained by the MCP server's
/// `process_queue` tool.
///
/// `text` is required; everything else is optional context the web
/// inspector/annotation tools attach. Unknown fields are preserved as
/// `extra` so the payload shape can evolve without a server change.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WebMessage {
    /// Server-assigned monotonic id, set on receipt (clients omit it).
    #[serde(default)]
    pub queue_id: u64,
    /// ISO-8601 receipt timestamp, set by the server.
    #[serde(default)]
    pub timestamp: String,
    /// Message kind, e.g. "user_feedback". Defaults to "user_feedback".
    #[serde(default = "default_web_message_type")]
    #[serde(rename = "type")]
    pub message_type: String,
    /// The user's message text (required).
    pub text: String,
    /// Optional structured context (annotations, selector, sourceHint,
    /// screenshot/drawing data URLs, etc.). Passed through verbatim.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub data: Option<serde_json::Value>,
}

fn default_web_message_type() -> String {
    "user_feedback".to_string()
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
    /// Channels that announced themselves over HTTP, keyed by port with the
    /// time of the last heartbeat. Discovery covers everything visible in the
    /// process table; this covers the rest.
    pub channels: RwLock<HashMap<u16, (Instant, ChannelRegistration)>>,
    /// Apps that have flushed with an `app_id` matching no local process,
    /// keyed by that id. An app served as a static bundle, or running on
    /// another machine, never appears in `ps` — but it is plainly real, since
    /// it just talked to us, and it needs a row to be linkable.
    pub remote_apps: RwLock<HashMap<String, (Instant, FlutterApp)>>,
    /// Where the remote-app list is kept between runs. These apps are only
    /// visible while they flush, so without this a restart erases every row a
    /// user could link to — and takes their links with it.
    pub remote_apps_path: PathBuf,
    /// Server-side message queue for web (React) clients. Web apps cannot
    /// host their own queue the way Flutter apps do, so annotated feedback
    /// arriving on `/ws` is buffered here and drained by the MCP server.
    pub web_queue: RwLock<Vec<WebMessage>>,
    /// Upstream ports this process has a watch proxy bound for.
    pub watch_proxies: RwLock<HashSet<u16>>,
    /// The port this server answers on, for URLs it hands to browsers.
    pub server_port: AtomicU16,
    /// Monotonic counter assigning `queue_id`s to web messages.
    pub web_queue_seq: AtomicU64,
}

impl SharedState {
    pub fn new() -> Self {
        let persistence_path = flan_dir().join("associations.json");
        let remote_apps_path = flan_dir().join("remote_apps.json");
        let mut associations = load_associations(&persistence_path);
        // One-time migration: older builds keyed trm associations by the
        // positional surface index (trm:<index>), which drifts as panes are
        // created/removed and silently re-points links at the wrong agent. The
        // key is now the stable trm:<pane_id>, and the old index→pane mapping
        // can't be faithfully recovered. Drop the legacy trm associations once
        // so the user re-links cleanly; cmux associations are untouched.
        migrate_drop_legacy_trm_associations(&persistence_path, &mut associations);
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
            channels: RwLock::new(HashMap::new()),
            remote_apps: RwLock::new(load_remote_apps(&remote_apps_path)),
            remote_apps_path,
            web_queue: RwLock::new(Vec::new()),
            web_queue_seq: AtomicU64::new(1),
            watch_proxies: RwLock::new(HashSet::new()),
            server_port: AtomicU16::new(4050),
        }
    }

    /// Live remote apps — those seen only when they flush — with ones that
    /// have gone quiet dropped.
    pub async fn remote_apps(&self) -> Vec<FlutterApp> {
        let mut remote = self.remote_apps.write().await;
        let before = remote.len();
        remote.retain(|_, (seen, _)| seen.elapsed() < REMOTE_APP_TTL);
        let mut apps: Vec<FlutterApp> = remote.values().map(|(_, app)| app.clone()).collect();
        apps.sort_by(|a, b| a.app_id.cmp(&b.app_id));
        if remote.len() != before {
            save_remote_apps(&self.remote_apps_path, &apps);
        }
        apps
    }

    /// Record an app that can only be seen when it talks to us.
    ///
    /// Sightings are merged, not replaced: not every flush carries an origin,
    /// and a later one that doesn't must not erase the port an earlier one
    /// taught us.
    pub async fn remember_remote_app(&self, app: FlutterApp) {
        let Some(app_id) = app.app_id.clone() else { return };
        let apps = {
            let mut remote = self.remote_apps.write().await;
            let mut app = app;
            if let Some((_, known)) = remote.get(&app_id) {
                app.web_port = app.web_port.or(known.web_port);
            }
            remote.insert(app_id, (Instant::now(), app));
            remote.values().map(|(_, a)| a.clone()).collect::<Vec<_>>()
        };
        save_remote_apps(&self.remote_apps_path, &apps);
    }

    /// The agent sessions to display: everything discovery found, plus any
    /// registration it couldn't see. Stale registrations — dead agent, or too
    /// many missed heartbeats — are dropped here, on read, so a vanished agent
    /// can't linger as a link target.
    pub async fn agent_sessions(&self, discovered: Vec<AgentSession>) -> Vec<AgentSession> {
        let registrations = {
            let mut channels = self.channels.write().await;
            prune_channels(&mut channels, pid_is_alive)
        };
        let mut sessions = discovered;
        merge_registrations(&mut sessions, registrations);
        sessions
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
        extract::{
            ws::{Message, WebSocket, WebSocketUpgrade},
            Query, State,
        },
        http::StatusCode,
        response::{Html, IntoResponse, Response},
        routing::{delete, get, post},
        Json, Router,
    };
    use tower_http::cors::{Any, CorsLayer};
    use tower_http::trace::TraceLayer;

    #[derive(Debug, Deserialize)]
    struct CreateAssociation {
        claude_surface_id: String,
        flutter_pid: u32,
        /// Identity of an app with no local pid. Required to link one at all,
        /// since every such app reports pid 0.
        #[serde(default)]
        flutter_app_id: Option<String>,
    }

    #[derive(Debug, Deserialize, Serialize)]
    struct FlushRequest {
        flutter_pid: Option<u32>,
        vm_service_uri: Option<String>,
        /// Stable identity supplied with `--dart-define=FLAN_APP_ID=...`.
        app_id: Option<String>,
        /// "desktop" to route to floss instead of Flutter VM service.
        mode: Option<String>,
        /// The web app's own origin (e.g. "http://localhost:5005"). Web apps
        /// can't read their vm_service_uri, so they send this; the server maps
        /// the port to the flutter app's --web-port.
        origin: Option<String>,
        /// Messages to relay to the loopback-only MCP channel.
        messages: Option<Vec<serde_json::Value>>,
        /// Set when a peer forwarded this flush to us. A relayed flush is never
        /// relayed on, which is what keeps two servers pointing at each other
        /// from bouncing one message between them forever.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        relayed_from: Option<String>,
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
    struct HotReloadRequest {
        /// The `flutter run` pid, as `/api/flutter-apps` reports it.
        pid: Option<u32>,
        /// Identity of an app with no local pid, supplied with
        /// `--dart-define=FLAN_APP_ID=...`.
        app_id: Option<String>,
        /// What the app itself knows about where it is: a native app posts this
        /// on every flush, and without `FLAN_APP_ID` it is the only name it has.
        vm_service_uri: Option<String>,
        /// The web app's own origin (`http://host:PORT`). A page has no pid and
        /// no VM service, so this is the only identifier it has beyond
        /// `FLAN_APP_ID` — the same reason [FlushRequest] carries it.
        origin: Option<String>,
        /// Ask for a hot RESTART instead: loses state, but picks up the changes
        /// a reload can't (new fields, globals, `main()`).
        #[serde(default)]
        full_restart: bool,
        /// Set when a peer forwarded this to us. A relayed request is never
        /// relayed on, which is what keeps two servers pointing at each other
        /// from bouncing one reload between them forever.
        #[serde(default)]
        relayed_from: Option<String>,
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

    /// Everything on this machine's own process table, and nothing else.
    ///
    /// This is what a peer asks for. It must never consult peers or the remote
    /// registry: two servers listing each other would otherwise recurse, and a
    /// peer has no use for rows about a third host it can't reach anyway.
    fn local_flutter_apps() -> Vec<FlutterApp> {
        let mut apps = discover_flutter_apps();
        merge_remote_apps(&mut apps, discover_static_web_apps());
        apps
    }

    async fn flutter_apps_snapshot(state: &Arc<SharedState>) -> Vec<FlutterApp> {
        {
            let cache = state.flutter_cache.read().await;
            if let Some((ts, ref data)) = *cache {
                if ts.elapsed() < Duration::from_secs(5) {
                    return data.clone();
                }
            }
        }
        let mut apps = tokio::task::spawn_blocking(|| {
            let mut apps = local_flutter_apps();
            // Peers before the registry: a peer row carries a pid and a cwd,
            // and should win over the stub the same app left when it flushed.
            merge_peer_apps(&mut apps, discover_peer_apps(&load_peers()));
            apps
        })
        .await
        .unwrap_or_default();
        merge_remote_apps(&mut apps, state.remote_apps().await);
        *state.flutter_cache.write().await = Some((Instant::now(), apps.clone()));
        apps
    }

    #[derive(Deserialize)]
    struct FlutterAppsQuery {
        /// Set by a peer: answer from this machine's process table alone.
        local: Option<String>,
    }

    async fn get_flutter_apps(
        State(state): State<Arc<SharedState>>,
        Query(query): Query<FlutterAppsQuery>,
    ) -> Json<Vec<FlutterApp>> {
        if query.local.is_some_and(|v| v != "0" && v != "false") {
            let apps = tokio::task::spawn_blocking(local_flutter_apps)
                .await
                .unwrap_or_default();
            return Json(apps);
        }
        Json(flutter_apps_snapshot(&state).await)
    }

    /// Which peers are configured and whether the last poll of each one
    /// actually got an answer. The question "is it empty or is it broken?" has
    /// to be answerable without reading the source.
    async fn get_peers(State(state): State<Arc<SharedState>>) -> Json<serde_json::Value> {
        // Peers are polled as part of discovery, so without this the answer is
        // empty until something else happens to ask for the app list — which
        // reads as "no peers configured" and is the opposite of the truth.
        let _ = flutter_apps_snapshot(&state).await;
        Json(serde_json::json!({
            "configured": load_peers(),
            "peers": peer_states(),
        }))
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
        // Capture the app's cwd so the link survives a rebuild (new pid, same
        // cwd). Resolved from the flutter cache when possible, else probed.
        let flutter_cwd = {
            let pid = body.flutter_pid;
            let cached = state.flutter_cache.try_read().ok().and_then(|c| {
                c.as_ref().and_then(|(_, apps)| {
                    apps.iter().find(|a| a.pid == pid).map(|a| a.cwd.clone())
                })
            });
            cached
                .filter(|c| !c.is_empty())
                .or_else(|| {
                    let c = get_process_cwd(pid);
                    if c.is_empty() { None } else { Some(c) }
                })
        };
        // Prefer the id the caller supplied; otherwise carry over whatever the
        // discovered app reports, so a link made against a locally-visible app
        // still survives that app being rebuilt with a new pid.
        let flutter_app_id = body.flutter_app_id.filter(|id| !id.is_empty()).or_else(|| {
            let pid = body.flutter_pid;
            state.flutter_cache.try_read().ok().and_then(|c| {
                c.as_ref()
                    .and_then(|(_, apps)| apps.iter().find(|a| a.pid == pid))
                    .and_then(|a| a.app_id.clone())
            })
        });
        let assoc = Association {
            id: new_association_id(),
            claude_surface_id: body.claude_surface_id,
            flutter_pid: body.flutter_pid,
            flutter_cwd,
            flutter_app_id,
        };
        let mut assocs = state.associations.write().await;
        // One link per app. Match on the app id when there is one — pid 0 is
        // shared by every remote app, so pid alone would clobber unrelated links.
        assocs.retain(|a| match (&a.flutter_app_id, &assoc.flutter_app_id) {
            (Some(existing), Some(new)) => existing != new,
            _ => a.flutter_pid != assoc.flutter_pid || assoc.flutter_pid == 0,
        });
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
        tracing::info!(
            "handle_flush: app_id={:?} pid={:?} vm_service_uri={:?} messages={}",
            body.app_id,
            body.flutter_pid,
            body.vm_service_uri,
            body.messages.as_ref().map_or(0, Vec::len),
        );
        // Log what the app said about itself, on the way in. When a flush
        // can't be routed, the identity it carried is the whole diagnosis, and
        // it is otherwise invisible from the outside.
        let identity = format!(
            "app_id={} origin={} pid={} vm_uri={}",
            body.app_id.as_deref().unwrap_or("-"),
            body.origin.as_deref().unwrap_or("-"),
            body.flutter_pid.map(|p| p.to_string()).unwrap_or_else(|| "-".into()),
            body.vm_service_uri.as_deref().unwrap_or("-"),
        );

        let apps = flutter_apps_snapshot(&state).await;
        let surfaces: Vec<CmuxSurface> = tokio::task::spawn_blocking(cmux_surface_list)
            .await
            .unwrap_or_default();
        let live_surface_ids: HashSet<String> =
            surfaces.iter().map(|s| s.id.clone()).collect();

        let mut assocs = state.associations.write().await;
        let before = assocs.len();
        // Drop links whose target this server has no way to resolve. A cmux id
        // is only meaningful while that surface is live; pane and session ids
        // are resolved further down, against discovery.
        //
        // This list must cover EVERY id form the TUI can store: an id missing
        // here isn't merely unroutable, it is deleted from disk on the first
        // flush, so the user's link silently disappears.
        assocs.retain(|a| {
            let id = &a.claude_surface_id;
            id.starts_with("trm:")
                || id.starts_with("sess:")
                || id.starts_with("chan:")
                || live_surface_ids.contains(id)
        });
        if assocs.len() < before {
            save_associations(&state.persistence_path, &assocs);
        }

        // The Flutter overlay flushes with only `vm_service_uri` (no pid — it
        // can't get its own flutter_tools pid, especially on web). Resolve the
        // pid from the vm_service_uri via the flutter cache so we can match the
        // association by pid. Without this, a vm-uri-only flush finds no
        // association and the app reports "no agent connected".
        //
        // On WEB there is no vm_service_uri either (dart:isolate unsupported),
        // so the app sends its own `origin` (http://host:PORT). We map that PORT
        // to the flutter app's --web-port. This is the only identifier a web app
        // actually has.
        let origin_port = body.origin.as_deref().and_then(parse_origin_port);
        let resolved_app = body
            .app_id
            .as_ref()
            // A local row first: a remembered remote row can carry a stale port
            // from an earlier sighting, and letting it win would resolve the app
            // to pid 0 and lose a perfectly good link.
            .and_then(|id| {
                apps.iter()
                    .find(|app| app.app_id.as_ref() == Some(id) && app.pid != 0)
                    .or_else(|| apps.iter().find(|app| app.app_id.as_ref() == Some(id)))
            })
            .or_else(|| {
                // Match by vm_service_uri (native/desktop debug apps).
                let uri = body.vm_service_uri.as_ref()?;
                apps.iter()
                    .find(|app| app.vm_service_uri.as_ref() == Some(uri))
            })
            .or_else(|| {
                // Match by web port only as a legacy fallback. A reverse proxy
                // can change the visible origin port, which is why app_id wins.
                let port = origin_port?;
                apps.iter().find(|app| app.web_port == Some(port))
            });
        // An app_id we can't place is not a mistake — it's an app this host
        // can't see as a process. Remember it so it gets a row to link to
        // instead of being unreachable forever.
        // Re-record on every sighting, not just the first: the row this
        // matched may BE the remembered one, and each flush can carry detail
        // (a fresh origin, a moved port) the stored copy predates.
        let needs_recording = resolved_app.map_or(true, |app| app.pid == 0);
        if let Some(app_id) = body.app_id.as_deref() {
            if needs_recording && !app_id.is_empty() {
                let entry = remote_app(app_id, body.origin.as_deref());
                tracing::info!("Remote app seen: app_id={} origin={:?}", app_id, body.origin);
                state.remember_remote_app(entry).await;
            }
        }

        let resolved_pid = body.flutter_pid.or_else(|| resolved_app.map(|app| app.pid));

        // The flushing app's own cwd, used both for the cwd-keyed association
        // fallback below and the surface-discovery fallback further down.
        let flutter_cwd = resolved_app
            .map(|app| app.cwd.clone())
            .filter(|cwd| !cwd.is_empty())
            .or_else(|| resolved_pid.map(get_process_cwd).filter(|cwd| !cwd.is_empty()));

        // Only an EXACT pid match counts as a primary association. We deliberately
        // do NOT fall back to `assocs.first()`: with multiple linked services
        // that would route every unmatched flush to whichever association sits
        // first in the vector — the "all tests go to the first agent" bug.
        //
        // When the pid doesn't match (the common case after an app rebuild —
        // new pid, same cwd), recover by matching the app's cwd against the cwd
        // captured when the link was created. This re-binds a rebuilt app to its
        // existing agent link automatically, no manual re-link needed. We still
        // require an EXACT cwd equality (not prefix) so two apps under sibling
        // dirs can't steal each other's link.
        let assoc = resolve_association(
            &assocs,
            body.app_id.as_deref(),
            resolved_pid,
            flutter_cwd.as_deref(),
        );
        drop(assocs);

        let cwd_channel_port = if let Some(cwd) = flutter_cwd.as_deref() {
            let ports = state.channel_ports_by_cwd.read().await;
            channel_port_for_cwd(&ports, cwd)
        } else {
            None
        };

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
            let cwd = flutter_cwd.clone().unwrap_or_default();

            let cc_surfaces: Vec<&CmuxSurface> = surfaces
                .iter()
                .filter(|s| title_has_agent(&s.title))
                .collect();

            cc_surfaces
                .iter()
                .find(|s| {
                    if let (Some(ref scwd), false) = (&s.cwd, cwd.is_empty()) {
                        scwd == &cwd
                            || cwd.starts_with(&format!("{}/", scwd))
                            || scwd.starts_with(&format!("{}/", cwd))
                    } else {
                        false
                    }
                })
                .or_else(|| {
                    // A cwd-registered channel is a stronger routing signal
                    // than an unrelated first surface on a multi-agent host.
                    cwd_channel_port.is_none().then(|| cc_surfaces.first()).flatten()
                })
                .map(|s| s.id.clone())
        };

        let surface_id = match surface_id {
            Some(surface_id) => surface_id,
            None if cwd_channel_port.is_some()
                && body.messages.as_ref().is_some_and(|items| !items.is_empty()) =>
            {
                "cwd-route".to_string()
            }
            None => {
                // The app posts to the flan server named by FLAN_SERVER_URL,
                // which `wt` points at the worktree's OWN server. The agent,
                // though, runs wherever the human is — often another machine.
                // Discovery already crosses that gap by pulling; without the
                // same hop for flushes, an app and the agent it is linked to
                // can see each other and still never exchange a word.
                if body.relayed_from.is_none() {
                    if let Some((peer, outcome)) = relay_flush_to_peers(&body, &load_peers()).await
                    {
                        let host = peer_host(&peer).unwrap_or_else(|| peer.clone());
                        state
                            .log(
                                "in",
                                format!("Flush relayed to {host}"),
                                Some(format!("{identity} · delivered={}", outcome.delivered)),
                                true,
                            )
                            .await;
                        return (
                            StatusCode::OK,
                            Json(serde_json::json!({
                                "accepted": outcome.accepted,
                                "delivered": outcome.delivered,
                                "relayed_to": peer,
                            })),
                        );
                    }
                }
                let relay_note = if body.relayed_from.is_some() {
                    " · arrived as a relay, so not relayed on".to_string()
                } else {
                    let peers = load_peers();
                    if peers.is_empty() {
                        " · no peers configured to relay to".to_string()
                    } else {
                        format!(" · no peer of {} took it", peers.len())
                    }
                };
                state
                    .log(
                        "in",
                        "Flush failed: no linked receiver".into(),
                        Some(format!(
                            "{identity} · apps={}{relay_note}",
                            apps.iter()
                                .map(|a| format!(
                                    "{}:{}",
                                    a.pid,
                                    a.web_port.map(|p| p.to_string()).unwrap_or_else(|| "-".into())
                                ))
                                .collect::<Vec<_>>()
                                .join(",")
                        )),
                        false,
                    )
                    .await;
                return (
                    StatusCode::NOT_FOUND,
                    Json(serde_json::json!({
                        "error": "No linked Flan receiver was found",
                    })),
                );
            }
        };

        // Teach the link the app's id. An app identifies itself by FLAN_APP_ID,
        // but a link made in the TUI is made against a row — which, for a
        // statically-served build, has no id to copy. Stamping it on the first
        // flush that resolves by any other means means a later flush carrying
        // only the id still finds its way home.
        if let (Some(app_id), Some(ref matched)) = (body.app_id.as_deref(), assoc.as_ref()) {
            if !app_id.is_empty() && matched.flutter_app_id.as_deref() != Some(app_id) {
                let mut assocs = state.associations.write().await;
                if let Some(entry) = assocs.iter_mut().find(|a| a.id == matched.id) {
                    entry.flutter_app_id = Some(app_id.to_string());
                    tracing::info!("Link {} learned app_id={}", entry.id, app_id);
                }
                save_associations(&state.persistence_path, &assocs);
            }
        }

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
                    .or(resolved_pid)?;
                if let Some(app) = apps.iter().find(|app| app.pid == flutter_pid) {
                    if app.vm_service_uri.is_some() {
                        return app.vm_service_uri.clone();
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

        let channel_port = state
            .channel_ports
            .read()
            .await
            .get(&surface_id)
            .copied();
        // A link made in the TUI's agent column is stored against a session id
        // (`sess:<pid>`), which the pane-keyed map above knows nothing about.
        // Resolve those against live discovery, so an explicit link routes
        // exactly where it says instead of silently falling through to the cwd
        // guess — which, with several agents on one repo, lands on the wrong one.
        let channel_port = match channel_port {
            Some(port) => Some(port),
            None if surface_id.starts_with("sess:") || surface_id.starts_with("chan:") => {
                let target = surface_id.clone();
                tokio::task::spawn_blocking(move || {
                    discover_agent_sessions()
                        .into_iter()
                        .find(|session| session.entry_id() == target)
                        .and_then(|session| session.channel_port)
                })
                .await
                .ok()
                .flatten()
            }
            None => None,
        };
        let channel_port = channel_port.or(cwd_channel_port);

        let mut resp = serde_json::json!({"ok": true, "surface_id": surface_id});
        if let Some(ref uri) = resolved_vm_uri {
            resp["vm_service_uri"] = serde_json::Value::String(uri.clone());
        }
        if let Some(port) = channel_port {
            resp["channel_port"] = serde_json::Value::Number(port.into());
        }

        // A Codex link can't take channel notifications — that protocol is
        // Claude Code's, and a flan-channel started under Codex rejects the
        // batch — so its messages go through `codex queue` into the thread
        // the Codex process has open. Checked before the channel requirement:
        // a Codex session usually DOES have a channel port, and it is the
        // wrong door.
        let codex_pid = {
            let target = surface_id.clone();
            tokio::task::spawn_blocking(move || codex_pid_for_target(&target))
                .await
                .ok()
                .flatten()
        };
        if let (Some(pid), Some(messages)) = (
            codex_pid,
            body.messages.as_ref().filter(|items| !items.is_empty()),
        ) {
            let thread = tokio::task::spawn_blocking(move || {
                codex_threads_for_pid(pid).into_iter().next()
            })
            .await
            .ok()
            .flatten();
            let Some(thread) = thread else {
                state
                    .log(
                        "out",
                        format!("Codex queue → pid {pid}: no open thread"),
                        Some(identity.clone()),
                        false,
                    )
                    .await;
                return (
                    StatusCode::SERVICE_UNAVAILABLE,
                    Json(serde_json::json!({
                        "ok": false,
                        "accepted": false,
                        "delivered": false,
                        "error": format!(
                            "Codex process {pid} has no open thread to queue into"
                        ),
                    })),
                );
            };
            resp["codex_pid"] = serde_json::Value::Number(pid.into());
            resp["codex_thread"] = serde_json::Value::String(thread.clone());

            let (text, images) =
                format_codex_message(messages, resolved_vm_uri.as_deref(), resolved_pid);
            let relay = {
                let thread = thread.clone();
                tokio::task::spawn_blocking(move || relay_codex_queue(&thread, &text, &images))
                    .await
                    .map_err(|error| format!("Codex queue task failed: {error}"))
                    .and_then(|result| result)
            };
            let summary = format!(
                "Codex queue → thread {}… (pid {pid})",
                &thread[..8.min(thread.len())]
            );
            match relay {
                Ok(outcome) => {
                    state
                        .log(
                            "out",
                            summary,
                            Some(format!("{} message(s)", messages.len())),
                            true,
                        )
                        .await;
                    resp["accepted"] = serde_json::Value::Bool(true);
                    resp["delivered"] = serde_json::Value::Bool(outcome.delivered);
                    return (StatusCode::OK, Json(resp));
                }
                Err(error) => {
                    state.log("out", summary, Some(error.clone()), false).await;
                    return (
                        StatusCode::BAD_GATEWAY,
                        Json(serde_json::json!({
                            "ok": false,
                            "accepted": false,
                            "delivered": false,
                            "error": error,
                            "codex_pid": pid,
                            "codex_thread": thread,
                        })),
                    );
                }
            }
        }

        if let Some(messages) = body.messages.as_ref().filter(|items| !items.is_empty()) {
            let Some(port) = channel_port else {
                return (
                    StatusCode::SERVICE_UNAVAILABLE,
                    Json(serde_json::json!({
                        "ok": false,
                        "accepted": false,
                        "delivered": false,
                        "error": "No linked Flan channel is available",
                    })),
                );
            };
            let mut channel_payload = serde_json::json!({"messages": messages});
            if let Some(uri) = resolved_vm_uri.as_ref() {
                channel_payload["vm_service_uri"] =
                    serde_json::Value::String(uri.clone());
            }
            if let Some(pid) = resolved_pid {
                channel_payload["flutter_pid"] =
                    serde_json::Value::Number(pid.into());
            }
            let payload = channel_payload.to_string();
            let relay = tokio::task::spawn_blocking(move || {
                relay_channel_flush(port, &payload)
            })
            .await
            .map_err(|error| format!("Flan channel relay task failed: {error}"))
            .and_then(|result| result);

            match relay {
                Ok(outcome) if outcome.accepted => {
                    resp["accepted"] = serde_json::Value::Bool(true);
                    resp["delivered"] = serde_json::Value::Bool(outcome.delivered);
                }
                Ok(_) => {
                    return (
                        StatusCode::BAD_GATEWAY,
                        Json(serde_json::json!({
                            "ok": false,
                            "accepted": false,
                            "delivered": false,
                            "error": "Flan channel rejected the message batch",
                        })),
                    );
                }
                Err(error) => {
                    return (
                        StatusCode::BAD_GATEWAY,
                        Json(serde_json::json!({
                            "ok": false,
                            "accepted": false,
                            "delivered": false,
                            "error": error,
                        })),
                    );
                }
            }
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
                    let key = format!("trm:{}", p.pane_id);
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
        let registered_cwd = body.cwd.clone().filter(|cwd| !cwd.is_empty());
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

        // Evict stale mappings that point at this same port BEFORE inserting the
        // fresh ones. A port belongs to exactly one live flan-channel process, so
        // any *other* key (surface/login/cwd) still pointing at `port` is a
        // leftover from a previous registration (pane closed, Claude restarted on
        // a new port, surface IDs shifted). Without this, step-1 surface-key
        // resolution in the TUI can hand one pane's port to a different pane —
        // e.g. `trm:3` (a Claude-less pane) inheriting flan_mcp's `trm:2` port —
        // and the test/flush lands on the wrong (or no) agent.
        {
            let mut surface_ports = state.channel_ports.write().await;
            surface_ports.retain(|k, &mut v| {
                let stale = v == port && surface_id.as_deref() != Some(k.as_str());
                if stale {
                    tracing::info!("Evicting stale surface mapping {} → {} (port reused)", k, port);
                }
                !stale
            });
        }
        {
            let mut login_ports = state.channel_ports_by_login.write().await;
            login_ports.retain(|_, &mut v| v != port);
        }
        {
            let mut cwd_ports = state.channel_ports_by_cwd.write().await;
            cwd_ports.retain(|_, &mut v| v != port);
        }

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
        if let Some(cwd) = registered_cwd {
            tracing::info!("Channel registered by client cwd: {} → port {}", cwd, port);
            state.channel_ports_by_cwd.write().await.insert(cwd, port);
        }

        // Record the channel as an agent in its own right. Everything above
        // tries to bind this port onto a *pane*; this records the agent even
        // when there is no pane to bind to — the headless case, where the trm
        // RPC is absent and pane discovery yields nothing at all.
        {
            let channel_pid = body.pid;
            let ancestry = match channel_pid {
                Some(pid) => tokio::task::spawn_blocking(move || {
                    let (agent_pid, name, tty) = find_agent_ancestor(pid)?;
                    Some((agent_pid, name, tty, get_process_cwd(agent_pid)))
                })
                .await
                .ok()
                .flatten(),
                None => None,
            };
            let (agent_pid, agent_name, tty, agent_cwd) = match ancestry {
                Some((pid, name, tty, cwd)) => {
                    (Some(pid), Some(name), tty, Some(cwd).filter(|c| !c.is_empty()))
                }
                None => (None, None, None, None),
            };
            let registration = ChannelRegistration {
                port,
                channel_pid,
                agent_pid,
                agent_name,
                tty,
                // The AGENT's cwd, not the channel's: an MCP server is often
                // launched from wherever its config lives (one shared flan_mcp
                // checkout serving every session), so the channel's own cwd
                // would collapse unrelated agents onto one directory and pair
                // them with the wrong Flutter app. Fall back to the reported
                // cwd only when the agent process can't be resolved.
                cwd: agent_cwd.or_else(|| body.cwd.clone().filter(|c| !c.is_empty())),
                surface_id: surface_id.clone(),
            };
            tracing::info!(
                "Channel registered: port={} agent={:?} pid={:?} tty={:?} cwd={:?}",
                registration.port, registration.agent_name, registration.agent_pid,
                registration.tty, registration.cwd
            );
            state.channels.write().await.insert(port, (Instant::now(), registration));
        }

        let sid_str = surface_id.as_deref().unwrap_or("(unresolved)");
        (StatusCode::OK, Json(serde_json::json!({"ok": true, "surface_id": sid_str})))
    }

    async fn get_agents(State(state): State<Arc<SharedState>>) -> Json<Vec<AgentSession>> {
        // Discover on read so the HTTP view matches the TUI's, which refreshes
        // on its own cycle.
        let discovered = tokio::task::spawn_blocking(discover_agent_sessions)
            .await
            .unwrap_or_default();
        Json(state.agent_sessions(discovered).await)
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

    /// POST /api/hot-reload — ask an app's `flutter run` to reload.
    ///
    /// The request only has to name the app; the discovered row carries the
    /// three things that decide how to ask it — a pid on this machine, a VM
    /// service URI, or a host that isn't us.
    async fn handle_hot_reload(
        State(state): State<Arc<SharedState>>,
        Json(body): Json<HotReloadRequest>,
    ) -> impl IntoResponse {
        let full_restart = body.full_restart;
        let verb = reload_verb(full_restart);
        let apps = flutter_apps_snapshot(&state).await;
        // The same ladder `handle_flush` climbs, and for the same reason: an app
        // names itself with whatever it has. A web page has neither pid nor VM
        // service, and only its origin places it.
        let app = body
            .pid
            .filter(|pid| *pid != 0)
            .and_then(|pid| apps.iter().find(|app| app.pid == pid))
            .or_else(|| {
                let id = body.app_id.as_ref()?;
                // A row with a live pid first: a remembered remote row can carry
                // a stale port from an earlier sighting.
                apps.iter()
                    .find(|app| app.app_id.as_ref() == Some(id) && app.pid != 0)
                    .or_else(|| apps.iter().find(|app| app.app_id.as_ref() == Some(id)))
            })
            .or_else(|| {
                let uri = body.vm_service_uri.as_ref()?;
                apps.iter().find(|app| app.vm_service_uri.as_ref() == Some(uri))
            })
            .or_else(|| {
                let port = body.origin.as_deref().and_then(parse_origin_port)?;
                apps.iter().find(|app| app.web_port == Some(port))
            })
            .cloned();

        let relayed = body.relayed_from.is_some();
        let label = app
            .as_ref()
            .filter(|app| !app.folder_name.is_empty())
            .map(|app| app.folder_name.clone())
            .or_else(|| body.app_id.clone())
            .unwrap_or_else(|| format!("pid {}", body.pid.unwrap_or(0)));
        let pid = body.pid.or_else(|| app.as_ref().map(|app| app.pid)).unwrap_or(0);
        let requested_uri = body.vm_service_uri.clone();

        let outcome = tokio::task::spawn_blocking(move || match app {
            // A relayed request stops here: this IS the machine that was asked,
            // so strip the host and reload it as a local one.
            Some(app) if relayed => hot_reload_app(
                &FlutterApp {
                    host: None,
                    ..app
                },
                full_restart,
            ),
            Some(app) => hot_reload_app(&app, full_restart),
            // Not in the snapshot: discovery may simply have missed it on this
            // tick, and either a live `flutter run` pid or the URI the app sent
            // is enough to act on by itself.
            None => hot_reload_local(pid, requested_uri.as_deref(), full_restart),
        })
        .await
        .unwrap_or_else(|error| HotReloadOutcome {
            ok: false,
            via: "none".into(),
            detail: format!("{verb} task failed: {error}"),
            needs_page_refresh: false,
        });

        state
            .log(
                "out",
                format!("{verb} {label} via {}", outcome.via),
                Some(outcome.detail.clone()),
                outcome.ok,
            )
            .await;

        let status = if outcome.ok {
            StatusCode::OK
        } else {
            StatusCode::INTERNAL_SERVER_ERROR
        };
        (status, Json(serde_json::json!(outcome)))
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
        let requested_pid: Option<u32> = params.get("pid").and_then(|s| s.parse().ok());
        let apps = flutter_apps_snapshot(&state).await;
        let flutter_pid = requested_pid.or_else(|| {
            let app_id = params.get("app_id")?;
            apps.iter()
                .find(|app| app.app_id.as_ref() == Some(app_id))
                .map(|app| app.pid)
        });
        let assocs = state.associations.read().await;

        // Prefer an exact pid match. If that fails (e.g. the app relaunched with
        // a new pid, or discovery momentarily lost it), fall back to matching by
        // working directory — the association whose own stored flutter app shares
        // this app's cwd. We deliberately do NOT fall back to assocs.first(),
        // which would mislabel an unmatched app as linked to the first agent
        // (the same root cause as the flush mis-routing bug).
        let assoc = flutter_pid.and_then(|pid| {
            if let Some(a) = assocs.iter().find(|a| a.flutter_pid == pid) {
                return Some(a.clone());
            }
            // cwd-based recovery: compare this app's cwd against the cwd of each
            // association's stored flutter app. Exact cwd equality only — no
            // first() guessing.
            let my_cwd = get_process_cwd(pid);
            if my_cwd.is_empty() {
                return None;
            }
            assocs
                .iter()
                .find(|a| get_process_cwd(a.flutter_pid) == my_cwd)
                .cloned()
        });

        // Derive a short label from the claude_surface_id.
        // For trm panes, look up the surface's folder_name via discover_trm_panes.
        let linked_label: Option<String> = assoc.as_ref().map(|a| {
            let sid = &a.claude_surface_id;
            if sid.starts_with("trm:") {
                // Try to get the folder_name for this pane from live discovery.
                if let Ok(pane_id) = sid["trm:".len()..].parse::<usize>() {
                    let panes = discover_trm_panes();
                    panes.iter()
                        .find(|p| p.pane_id == pane_id)
                        .and_then(|p| p.folder_name.clone())
                        .unwrap_or_else(|| sid.clone())
                } else {
                    sid.clone()
                }
            } else if sid.starts_with("sess:") || sid.starts_with("chan:") {
                // A linked agent session: show the name the TUI shows, so the
                // app's status chip and the TUI agree on what it's linked to.
                discover_agent_sessions()
                    .iter()
                    .find(|session| &session.entry_id() == sid)
                    .map(|session| session.label())
                    .unwrap_or_else(|| sid.clone())
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

    async fn get_health() -> Json<serde_json::Value> {
        Json(serde_json::json!({
            "ok": true,
            "version": RELAY_VERSION,
            "features": RELAY_FEATURES,
        }))
    }

    // ── Web channel (React clients) ─────────────────────────────────────
    //
    // A web app has no Dart VM and cannot host its own message queue the
    // way a Flutter app does. Instead, `flan_web` clients open a WebSocket
    // to `/ws` and push annotated feedback as JSON `WebMessage`s; the
    // server buffers them in `SharedState::web_queue`, and the MCP server
    // drains that queue through the `/api/web-messages/*` endpoints.

    /// Frame received on the `/ws` socket. A bare message (no `kind`) is
    /// treated as a `WebMessage`; `{"kind":"ping"}` is answered with a pong.
    #[derive(Debug, Deserialize)]
    #[serde(untagged)]
    enum WebSocketIncoming {
        Control { kind: String },
        Message(WebMessage),
    }

    /// GET /ws — upgrade to a WebSocket for a web (React) client.
    async fn handle_web_socket(
        ws: WebSocketUpgrade,
        State(state): State<Arc<SharedState>>,
    ) -> Response {
        ws.on_upgrade(move |socket| web_socket_loop(socket, state))
    }

    /// Per-connection loop: parse incoming frames, enqueue `WebMessage`s,
    /// and answer control pings. Server→client frames carry queue depth so
    /// the web overlay can show a "queued" indicator.
    async fn web_socket_loop(mut socket: WebSocket, state: Arc<SharedState>) {
        tracing::info!("web client connected on /ws");
        let _ = socket
            .send(Message::Text(web_status_frame(&state).await.into()))
            .await;

        while let Some(frame) = socket.recv().await {
            let Ok(frame) = frame else { break };
            match frame {
                Message::Text(text) => {
                    match serde_json::from_str::<WebSocketIncoming>(&text) {
                        Ok(WebSocketIncoming::Control { kind }) if kind == "ping" => {
                            let _ = socket
                                .send(Message::Text(
                                    r#"{"kind":"pong"}"#.to_string().into(),
                                ))
                                .await;
                        }
                        Ok(WebSocketIncoming::Control { kind }) => {
                            tracing::debug!("web /ws: ignoring control frame '{}'", kind);
                        }
                        Ok(WebSocketIncoming::Message(msg)) => {
                            let depth = enqueue_web_message(&state, msg).await;
                            // Echo back the new queue depth as an ack.
                            let _ = socket
                                .send(Message::Text(
                                    web_status_frame(&state).await.into(),
                                ))
                                .await;
                            tracing::info!("web /ws: queued message (depth={})", depth);
                        }
                        Err(err) => {
                            tracing::warn!("web /ws: bad frame: {err}");
                        }
                    }
                }
                Message::Ping(payload) => {
                    let _ = socket.send(Message::Pong(payload)).await;
                }
                Message::Close(_) => break,
                _ => {}
            }
        }
        tracing::info!("web client disconnected from /ws");
    }

    /// Assigns a queue id + timestamp to `msg`, appends it to `web_queue`,
    /// and returns the resulting queue depth.
    async fn enqueue_web_message(state: &Arc<SharedState>, mut msg: WebMessage) -> usize {
        msg.queue_id = state.web_queue_seq.fetch_add(1, Ordering::Relaxed);
        msg.timestamp = chrono_now();
        let preview: String = msg.text.chars().take(60).collect();
        state
            .log("in", format!("Web message: {preview}"), None, true)
            .await;
        let mut queue = state.web_queue.write().await;
        queue.push(msg);
        queue.len()
    }

    /// A small JSON status frame sent to web clients (current queue depth).
    async fn web_status_frame(state: &Arc<SharedState>) -> String {
        let depth = state.web_queue.read().await.len();
        format!(r#"{{"kind":"status","queued":{depth}}}"#)
    }

    /// GET /api/web-messages — peek the web queue without draining it.
    async fn get_web_messages(State(state): State<Arc<SharedState>>) -> impl IntoResponse {
        let queue = state.web_queue.read().await;
        Json(serde_json::json!({
            "count": queue.len(),
            "messages": &*queue,
        }))
    }

    /// POST /api/web-messages/consume — drain and return the web queue.
    async fn consume_web_messages(State(state): State<Arc<SharedState>>) -> impl IntoResponse {
        let drained: Vec<WebMessage> = {
            let mut queue = state.web_queue.write().await;
            std::mem::take(&mut *queue)
        };
        Json(serde_json::json!({
            "count": drained.len(),
            "messages": drained,
        }))
    }

    /// Accept a `WebMessage` over plain HTTP as well — useful for clients
    /// that cannot hold a WebSocket open, and for testing with `curl`.
    async fn post_web_message(
        State(state): State<Arc<SharedState>>,
        Json(msg): Json<WebMessage>,
    ) -> impl IntoResponse {
        let depth = enqueue_web_message(&state, msg).await;
        Json(serde_json::json!({ "ok": true, "queued": depth }))
    }

    /// POST /api/tunnel — make a peer's port reachable as localhost.
    ///
    /// DELIBERATELY ITS OWN ENDPOINT, and deliberately not a side effect of
    /// `/api/flutter-apps`. That route is a read, and the TUI polls it every
    /// few seconds: opening an ssh connection because somebody looked at a
    /// list is not something a list should do. Asking is an act, so it gets a
    /// POST somebody has to make.
    async fn post_tunnel(Json(body): Json<serde_json::Value>) -> impl IntoResponse {
        let host = body
            .get("host")
            .and_then(|v| v.as_str())
            .unwrap_or_default()
            .to_string();
        let port = body.get("port").and_then(|v| v.as_u64()).unwrap_or(0);
        if host.is_empty() || port == 0 || port > 65535 {
            return Json(serde_json::json!({
                "ok": false,
                "message": "host and port are required",
            }));
        }

        match tunnel_rpc(
            "tunnel.ensure",
            serde_json::json!({
                "host": host,
                "port": port,
                "open": body.get("open").and_then(|v| v.as_bool()).unwrap_or(true),
            }),
        ) {
            Some(reply) => Json(reply),
            // The extension not being there is a real and ordinary state, so
            // it says which socket it looked for rather than reporting a
            // failure the caller cannot act on.
            None => Json(serde_json::json!({
                "ok": false,
                "message": "trm auto-tunnel extension is not running \
                            (expected /tmp/trm-tunnel.sock)",
            })),
        }
    }

    /// Build the Axum router using the given shared state.
    pub fn build_router(state: Arc<SharedState>) -> Router {
        // Prune dead channel-port mappings every 2s. A flan-channel that has
        // exited won't accept a loopback TCP connection, so any surface/login/
        // cwd entry whose port refuses a connect is stale and gets dropped.
        // This keeps the routing maps honest without waiting for the owning
        // channel's 30s re-registration to evict collisions.
        {
            let state = state.clone();
            tokio::spawn(async move {
                let mut tick = tokio::time::interval(Duration::from_secs(2));
                loop {
                    tick.tick().await;

                    // Snapshot the unique ports under lock, probe them outside it.
                    let ports: std::collections::HashSet<u16> = {
                        let surface = state.channel_ports.read().await;
                        let login = state.channel_ports_by_login.read().await;
                        let cwd = state.channel_ports_by_cwd.read().await;
                        surface.values().chain(login.values()).chain(cwd.values())
                            .copied().collect()
                    };
                    if ports.is_empty() { continue; }

                    let dead: std::collections::HashSet<u16> =
                        tokio::task::spawn_blocking(move || {
                            ports.into_iter().filter(|&p| !port_is_live(p)).collect()
                        })
                        .await
                        .unwrap_or_default();
                    if dead.is_empty() { continue; }

                    state.channel_ports.write().await
                        .retain(|_, &mut v| !dead.contains(&v));
                    state.channel_ports_by_login.write().await
                        .retain(|_, &mut v| !dead.contains(&v));
                    state.channel_ports_by_cwd.write().await
                        .retain(|_, &mut v| !dead.contains(&v));
                    for p in &dead {
                        tracing::info!("Pruned dead channel port {} (no listener)", p);
                    }
                }
            });
        }

        let cors = CorsLayer::new()
            .allow_origin(Any)
            .allow_methods(Any)
            .allow_headers(Any);

        Router::new()
            .route("/", get(serve_ui))
            .route("/api/health", get(get_health))
            .route("/api/claude-processes", get(get_claude_processes))
            .route("/api/flutter-apps", get(get_flutter_apps))
            .route("/api/peers", get(get_peers))
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
            .route("/api/hot-reload", post(handle_hot_reload))
            .route("/api/test-send", post(handle_test_send))
            .route("/api/register-channel", post(handle_register_channel))
            .route("/api/agents", get(get_agents))
            .route("/api/rescan", post(handle_rescan))
            .route("/api/status", get(get_status))
            .route("/api/logs", get(get_activity_log))
            .route("/api/trm-debug", get(get_trm_debug))
            .route("/ws", get(handle_web_socket))
            .route("/flan.js", get(watch::serve_flan_js))
            .route(
                "/api/watch-ports",
                get(watch::get_watched_ports).post(watch::post_watched_port),
            )
            .route("/api/watch-ports/{port}", delete(watch::delete_watched_port))
            .route(
                "/api/web-messages",
                get(get_web_messages).post(post_web_message),
            )
            .route("/api/web-messages/consume", post(consume_web_messages))
            .route("/api/tunnel", post(post_tunnel))
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

pub fn load_remote_apps(path: &PathBuf) -> HashMap<String, (Instant, FlutterApp)> {
    let apps: Vec<FlutterApp> = std::fs::read_to_string(path)
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default();
    // The clock restarts with the process: how long ago an app last flushed
    // isn't worth persisting, and starting the window fresh is the forgiving
    // choice for something a user has linked.
    apps.into_iter()
        .filter_map(|app| Some((app.app_id.clone()?, (Instant::now(), app))))
        .collect()
}

pub fn save_remote_apps(path: &PathBuf, apps: &[FlutterApp]) {
    if let Ok(json) = serde_json::to_string_pretty(apps) {
        let _ = std::fs::write(path, json);
    }
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

/// One-time migration: remove `trm:`-keyed associations left over from the
/// positional-index scheme. Gated by a marker file in ~/.flan so it runs once.
/// Mutates `associations` in place and persists the result if anything changed.
pub fn migrate_drop_legacy_trm_associations(path: &PathBuf, associations: &mut Vec<Association>) {
    let marker = flan_dir().join(".trm_pane_id_migration_done");
    if marker.exists() {
        return;
    }
    let before = associations.len();
    associations.retain(|a| !a.claude_surface_id.starts_with("trm:"));
    let dropped = before - associations.len();
    if dropped > 0 {
        save_associations(path, associations);
        tracing::info!(
            "Migration: dropped {} legacy positional trm association(s); re-link affected services",
            dropped
        );
    }
    // Write the marker regardless, so the migration never runs again even if
    // there was nothing to drop.
    std::fs::write(&marker, "1").ok();
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
        let web_port = extract_web_port(line);
        let app_id = extract_flan_app_id(line);
        let cwd = get_process_cwd(pid);
        let folder_name = cwd.rsplit('/').next().unwrap_or(&cwd).to_string();
        let vm_uri = probe_vm_service_uri(pid);

        let peek = vm_uri
            .as_deref()
            .map(peek_flan)
            .unwrap_or_default();
        apps.push(FlutterApp {
            pid,
            cwd,
            folder_name,
            vm_service_uri: vm_uri,
            device: Some(device),
            queue_count: peek.queue_count,
            connected: peek.connected,
            web_port,
            app_id,
            // Discovered from this machine's process table, so it is here.
            host: None,
        });
    }

    apps
}

// ── Discovery: Peer hosts ───────────────────────────────────────────────
//
// `discover_flutter_apps` reads THIS machine's process table, so an app running
// on the build host is invisible to it. The remote-app registry is not a
// substitute: an app lands there only when it *flushes*, which means an app that
// is running but hasn't been talked to yet has no row at all, and the row it
// does get is a stub — pid 0, no cwd, no device.
//
// Each host already runs a flan server with a complete local view of itself.
// Asking it is the only way to list what is actually running there.

/// How long to wait on a peer before giving up on it this cycle. Discovery runs
/// on a 5-second tick, so a peer that is down must cost a fraction of that, not
/// a whole cycle.
const PEER_CONNECT_TIMEOUT: Duration = Duration::from_millis(800);
const PEER_READ_TIMEOUT: Duration = Duration::from_secs(2);

/// Relaying a flush is slower than reading a list — the peer has to resolve a
/// link and hand the message to an agent's channel before it answers — and it
/// happens on a user action rather than a timer, so it gets longer than a poll.
const PEER_RELAY_TIMEOUT: Duration = Duration::from_secs(10);

/// How long a peer's last good answer keeps being shown after the peer stops
/// answering. A 5-second poll over a LAN or a tailnet drops the occasional
/// request, and without a grace period every drop blinks every remote row out
/// of the list and back.
const PEER_GRACE: Duration = Duration::from_secs(45);

fn peers_path() -> PathBuf {
    flan_dir().join("peers.json")
}

/// Other flan servers to ask about their Flutter apps.
///
/// From `~/.flan/peers.json` (a JSON array of base URLs) plus `FLAN_PEERS` as a
/// comma-separated list, mirroring how watched ports are configured.
pub fn load_peers() -> Vec<String> {
    let mut peers: Vec<String> = std::fs::read_to_string(peers_path())
        .ok()
        .and_then(|s| serde_json::from_str::<Vec<String>>(&s).ok())
        .unwrap_or_default()
        .iter()
        .filter_map(|p| normalize_peer(p))
        .collect();
    if let Ok(env) = std::env::var("FLAN_PEERS") {
        peers.extend(parse_peer_list(&env));
    }
    peers.retain(|p| !is_self_peer(p));
    peers.sort();
    peers.dedup();
    peers
}

/// "m1:4050, http://laptop.example:4050" → two normalized base URLs. Junk is
/// skipped rather than fatal.
pub fn parse_peer_list(list: &str) -> Vec<String> {
    list.split(',').filter_map(normalize_peer).collect()
}

/// "m1" → "http://m1:4050". Accepts bare hosts, host:port, and full URLs so the
/// config file can hold whichever the user reaches the peer by.
pub fn normalize_peer(peer: &str) -> Option<String> {
    let (scheme, rest) = match peer.trim().split_once("://") {
        Some((scheme, rest)) if !scheme.is_empty() => (scheme, rest),
        Some(_) => return None,
        None => ("http", peer.trim()),
    };
    // Keep only the authority: a peer is a server, not a path.
    let authority = rest.split('/').next().unwrap_or("").trim();
    if authority.is_empty() {
        return None;
    }
    match authority.rsplit_once(':') {
        // A bracketed IPv6 literal with no port — the ':' found is inside it.
        Some(_) if authority.ends_with(']') => Some(format!("{scheme}://{authority}:4050")),
        // A port was given, so it has to be one.
        Some((host, port)) => (!host.is_empty() && port.parse::<u16>().is_ok())
            .then(|| format!("{scheme}://{authority}")),
        None => Some(format!("{scheme}://{authority}:4050")),
    }
}

/// Whether a peer URL names this very machine.
///
/// Polling yourself costs a round trip and, with the recursion guard in place,
/// returns rows you already have. Cheap to notice, so notice it.
pub fn is_self_peer(peer: &str) -> bool {
    let Some(host) = peer_host(peer) else {
        return false;
    };
    let host = host.to_ascii_lowercase();
    if host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]" {
        return true;
    }
    // Compare the first label: peers are written as tailnet FQDNs
    // ("m1.follow-ionian.ts.net") while `hostname -s` is the short name.
    let label = |h: &str| h.split('.').next().unwrap_or("").to_string();
    !host.is_empty() && label(&host) == local_hostname().to_ascii_lowercase()
}

/// The host part of a normalized peer URL, without the port.
pub fn peer_host(peer: &str) -> Option<String> {
    let rest = peer.split_once("://").map(|(_, r)| r).unwrap_or(peer);
    let authority = rest.split('/').next()?;
    // IPv6 literals are bracketed, so the last ':' is the port separator only
    // outside the brackets.
    let host = match authority.rfind(']') {
        Some(end) => &authority[..=end],
        None => authority.split(':').next()?,
    };
    (!host.is_empty()).then(|| host.to_string())
}

/// This machine's short hostname, read once. Used for apps discovered locally,
/// which by construction are running here.
pub fn local_hostname() -> String {
    static NAME: std::sync::OnceLock<String> = std::sync::OnceLock::new();
    NAME.get_or_init(|| {
        Command::new("hostname")
            .arg("-s")
            .output()
            .ok()
            .and_then(|o| String::from_utf8(o.stdout).ok())
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| "local".to_string())
    })
    .clone()
}

/// Ask every peer what it is running, in parallel, and label the answers with
/// the host they came from.
pub fn discover_peer_apps(peers: &[String]) -> Vec<FlutterApp> {
    // A peer dropped from the config must stop being reported, or the TUI keeps
    // warning about a machine nobody asked about any more.
    if let Ok(mut cache) = peer_cache().lock() {
        cache.retain(|peer, _| peers.iter().any(|configured| configured == peer));
    }
    if peers.is_empty() {
        return Vec::new();
    }
    let handles: Vec<_> = peers
        .iter()
        .cloned()
        .map(|peer| std::thread::spawn(move || (peer.clone(), fetch_peer_apps(&peer))))
        .collect();

    let mut apps = Vec::new();
    for handle in handles {
        // A panicked fetch is one peer's problem, not discovery's.
        let Ok((peer, fetched)) = handle.join() else {
            continue;
        };
        apps.extend(remember_peer_result(&peer, fetched));
    }
    apps
}

/// What the last poll of a peer found.
///
/// Kept because an unreachable peer and a peer with nothing running produce the
/// same empty list, and a TUI that can't tell them apart reads as broken. This
/// is the difference between "nothing is running there" and "I couldn't ask".
#[derive(Debug, Clone, Serialize)]
pub struct PeerState {
    pub peer: String,
    pub reachable: bool,
    pub app_count: usize,
    /// Seconds since this peer last answered, if it ever has.
    pub last_ok_secs: Option<u64>,
}

struct PeerRecord {
    /// When the peer last answered — `None` if it never has this run.
    last_ok: Option<Instant>,
    reachable: bool,
    apps: Vec<FlutterApp>,
}

/// Last good answer per peer, so a dropped request doesn't blink rows away.
fn peer_cache() -> &'static std::sync::Mutex<HashMap<String, PeerRecord>> {
    static CACHE: std::sync::OnceLock<std::sync::Mutex<HashMap<String, PeerRecord>>> =
        std::sync::OnceLock::new();
    CACHE.get_or_init(|| std::sync::Mutex::new(HashMap::new()))
}

/// Every peer's last known state, for `/api/peers` and the TUI's log.
pub fn peer_states() -> Vec<PeerState> {
    let Ok(cache) = peer_cache().lock() else {
        return Vec::new();
    };
    let mut states: Vec<PeerState> = cache
        .iter()
        .map(|(peer, record)| PeerState {
            peer: peer.clone(),
            reachable: record.reachable,
            app_count: record.apps.len(),
            last_ok_secs: record.last_ok.map(|at| at.elapsed().as_secs()),
        })
        .collect();
    states.sort_by(|a, b| a.peer.cmp(&b.peer));
    states
}

/// Record a successful fetch, or fall back to a recent one.
///
/// A peer that has been silent for longer than [PEER_GRACE] stops contributing
/// rows — at that point we genuinely don't know what it is running, and saying
/// nothing beats showing stale rows. The record itself is kept either way, so
/// the peer is still reported as unreachable rather than vanishing.
fn remember_peer_result(peer: &str, fetched: Option<Vec<FlutterApp>>) -> Vec<FlutterApp> {
    let Ok(mut cache) = peer_cache().lock() else {
        return fetched.unwrap_or_default();
    };
    match fetched {
        Some(apps) => {
            cache.insert(
                peer.to_string(),
                PeerRecord {
                    last_ok: Some(Instant::now()),
                    reachable: true,
                    apps: apps.clone(),
                },
            );
            apps
        }
        None => {
            let record = cache.entry(peer.to_string()).or_insert_with(|| PeerRecord {
                last_ok: None,
                reachable: false,
                apps: Vec::new(),
            });
            record.reachable = false;
            let within_grace = record
                .last_ok
                .is_some_and(|at| at.elapsed() < PEER_GRACE);
            if within_grace {
                record.apps.clone()
            } else {
                record.apps.clear();
                Vec::new()
            }
        }
    }
}

/// GET `<peer>/api/flutter-apps?local=1` and adopt the rows as remote.
///
/// `local=1` is what keeps two servers that list each other from recursing: the
/// peer answers from its process table alone and never re-asks us. `host` is
/// also forced to the peer, which drops any third-host row an older peer
/// (one that ignores the query) would otherwise forward.
fn fetch_peer_apps(peer: &str) -> Option<Vec<FlutterApp>> {
    let host = peer_host(peer)?;
    let body = peer_get(peer, "/api/flutter-apps?local=1")?;
    let apps: Vec<FlutterApp> = serde_json::from_str(&body).ok()?;
    Some(
        apps.into_iter()
            .filter(|app| app.host.is_none())
            .map(|mut app| {
                // A loopback VM service URI from another machine is worse than
                // none: on this host that port belongs to something else
                // entirely, and connecting would silently attach to it.
                app.vm_service_uri = app.vm_service_uri.map(|uri| {
                    uri.replace("127.0.0.1", &host)
                        .replace("localhost", &host)
                });
                app.host = Some(host.clone());
                app
            })
            .collect(),
    )
}

/// Hand a flush this host can't route to a peer that might be able to.
///
/// Returns the peer that took it, or `None` if none did. Peers are tried in
/// order and the first delivery wins — a message must reach one agent, not
/// every agent on the tailnet.
pub async fn relay_flush_to_peers<T: Serialize>(
    body: &T,
    peers: &[String],
) -> Option<(String, ChannelRelayOutcome)> {
    if peers.is_empty() {
        return None;
    }
    let payload = mark_relayed(body)?;

    for peer in peers {
        let peer = peer.clone();
        let payload = payload.clone();
        let Ok(result) =
            tokio::task::spawn_blocking(move || post_peer_flush(&peer, &payload)).await
        else {
            continue;
        };
        match result {
            Ok((peer, outcome)) if outcome.accepted || outcome.delivered => {
                return Some((peer, outcome));
            }
            Ok(_) => continue,
            Err(error) => {
                tracing::debug!("Flush relay declined: {error}");
                continue;
            }
        }
    }
    None
}

/// Stamp a flush payload as relayed, so the peer receiving it won't relay it on.
///
/// Without the stamp, two servers that list each other would hand the same
/// message back and forth until one of them timed out.
pub fn mark_relayed<T: Serialize>(body: &T) -> Option<String> {
    let mut payload = serde_json::to_value(body).ok()?;
    payload
        .as_object_mut()?
        .insert("relayed_from".into(), serde_json::json!(local_hostname()));
    serde_json::to_string(&payload).ok()
}

/// POST a flush payload to one peer's `/api/flush`.
fn post_peer_flush(peer: &str, payload: &str) -> Result<(String, ChannelRelayOutcome), String> {
    let (status, parsed) = post_peer_json(peer, "/api/flush", payload, PEER_RELAY_TIMEOUT)?;
    if status != 200 {
        return Err(format!("{peer}: no linked receiver there either"));
    }
    Ok((
        peer.to_string(),
        ChannelRelayOutcome {
            accepted: parsed["accepted"].as_bool().unwrap_or(false),
            delivered: parsed["delivered"].as_bool().unwrap_or(false),
        },
    ))
}

/// POST JSON to one peer and return its status and parsed body.
///
/// Hand-rolled for the same reason [peer_get] is, and the read timeout is the
/// caller's to pick: waiting for a peer to route a flush is a different wait
/// from waiting for one to finish a hot reload, which blocks on a compile.
fn post_peer_json(
    peer: &str,
    path: &str,
    payload: &str,
    read_timeout: Duration,
) -> Result<(u16, serde_json::Value), String> {
    use std::net::ToSocketAddrs;

    let rest = peer.split_once("://").map(|(_, r)| r).unwrap_or(peer);
    let authority = rest.split('/').next().unwrap_or("");
    let addr = authority
        .to_socket_addrs()
        .map_err(|error| format!("{peer}: {error}"))?
        .next()
        .ok_or_else(|| format!("{peer}: no address"))?;

    let mut stream = TcpStream::connect_timeout(&addr, PEER_CONNECT_TIMEOUT)
        .map_err(|error| format!("{peer}: {error}"))?;
    stream
        .set_read_timeout(Some(read_timeout))
        .map_err(|error| format!("{peer}: {error}"))?;
    stream
        .set_write_timeout(Some(read_timeout))
        .map_err(|error| format!("{peer}: {error}"))?;

    let request = format!(
        "POST {path} HTTP/1.1\r\n\
         Host: {authority}\r\n\
         Content-Type: application/json\r\n\
         Content-Length: {}\r\n\
         Connection: close\r\n\r\n{}",
        payload.len(),
        payload,
    );
    stream
        .write_all(request.as_bytes())
        .map_err(|error| format!("{peer}: {error}"))?;

    let mut response = String::new();
    let _ = stream.read_to_string(&mut response);

    let status = response
        .lines()
        .next()
        .and_then(|line| line.split_whitespace().nth(1))
        .and_then(|code| code.parse::<u16>().ok())
        .ok_or_else(|| format!("{peer}: no HTTP status"))?;
    let start = response
        .find('{')
        .ok_or_else(|| format!("{peer}: no JSON body"))?;
    let end = response
        .rfind('}')
        .ok_or_else(|| format!("{peer}: incomplete JSON"))?;
    let parsed: serde_json::Value = serde_json::from_str(&response[start..=end])
        .map_err(|error| format!("{peer}: {error}"))?;
    Ok((status, parsed))
}

/// A bounded blocking GET against a peer, returning the response body.
///
/// Hand-rolled for the same reason [relay_channel_flush] is: one small hop
/// doesn't justify a general-purpose HTTP client dependency, and the timeouts
/// here have to be tight enough that a dead peer can't stall a discovery tick.
fn peer_get(peer: &str, path: &str) -> Option<String> {
    let response = peer_get_body(peer, path)?;
    // The body is a JSON array; isolating it handles both Content-Length and
    // chunked framing without parsing HTTP properly.
    let start = response.find('[')?;
    let end = response.rfind(']')?;
    (start <= end).then(|| response[start..=end].to_string())
}

/// Like [peer_get], for an endpoint that answers a JSON object.
fn peer_get_object(peer: &str, path: &str) -> Option<String> {
    let response = peer_get_body(peer, path)?;
    let start = response.find('{')?;
    let end = response.rfind('}')?;
    (start <= end).then(|| response[start..=end].to_string())
}

/// The response body of a bounded blocking GET, or None unless it answered 200.
fn peer_get_body(peer: &str, path: &str) -> Option<String> {
    use std::net::ToSocketAddrs;

    let rest = peer.split_once("://").map(|(_, r)| r).unwrap_or(peer);
    let authority = rest.split('/').next()?;
    let addr = authority
        .to_socket_addrs()
        .ok()?
        .next()?;

    let mut stream = TcpStream::connect_timeout(&addr, PEER_CONNECT_TIMEOUT).ok()?;
    stream.set_read_timeout(Some(PEER_READ_TIMEOUT)).ok()?;
    stream.set_write_timeout(Some(PEER_READ_TIMEOUT)).ok()?;

    let request = format!(
        "GET {path} HTTP/1.1\r\nHost: {authority}\r\nAccept: application/json\r\n\
         Connection: close\r\n\r\n"
    );
    stream.write_all(request.as_bytes()).ok()?;

    let mut response = String::new();
    // A read timeout surfaces as an error AFTER some bytes may have arrived, so
    // a partial body is still worth parsing.
    let _ = stream.read_to_string(&mut response);

    let status_ok = response
        .lines()
        .next()
        .is_some_and(|line| line.split_whitespace().nth(1) == Some("200"));
    if !status_ok {
        tracing::debug!("Peer {peer} returned a non-200 response for {path}");
        return None;
    }
    Some(response)
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

/// Parse the `--web-port` from a flutter run command line. Web apps can't read
/// their own VM service URI (no dart:isolate), so they identify themselves to
/// the flan server by their web origin/port; this lets the server map that back
/// to the flutter process. Handles both `--web-port 5005` and `--web-port=5005`.
pub fn extract_web_port(cmd_line: &str) -> Option<u16> {
    let parts: Vec<&str> = cmd_line.split_whitespace().collect();
    for (i, part) in parts.iter().enumerate() {
        if let Some(rest) = part.strip_prefix("--web-port=") {
            return rest.parse().ok();
        }
        if *part == "--web-port" {
            return parts.get(i + 1).and_then(|p| p.parse().ok());
        }
    }
    None
}

/// Parse the stable app identity supplied to Flutter as a Dart define.
pub fn extract_flan_app_id(cmd_line: &str) -> Option<String> {
    let parts: Vec<&str> = cmd_line.split_whitespace().collect();
    for (index, part) in parts.iter().enumerate() {
        if let Some(value) = part.strip_prefix("--dart-define=FLAN_APP_ID=") {
            return non_empty_cli_value(value);
        }
        if *part == "--dart-define" {
            if let Some(value) = parts
                .get(index + 1)
                .and_then(|next| next.strip_prefix("FLAN_APP_ID="))
            {
                return non_empty_cli_value(value);
            }
        }
    }
    None
}

fn non_empty_cli_value(value: &str) -> Option<String> {
    let cleaned = value.trim_matches(['\'', '"']);
    (!cleaned.is_empty()).then(|| cleaned.to_string())
}

/// Extract the port from a web origin like "http://localhost:5005" or
/// "http://127.0.0.1:5005/". Returns None if no explicit port is present.
pub fn parse_origin_port(origin: &str) -> Option<u16> {
    // Strip scheme.
    let after_scheme = origin.split("://").nth(1).unwrap_or(origin);
    // Take the authority (up to the first '/').
    let authority = after_scheme.split('/').next().unwrap_or(after_scheme);
    // Port is after the last ':'.
    authority.rsplit(':').next().and_then(|p| p.parse().ok())
}

/// The host out of a browser origin: `http://m1.follow-ionian.ts.net:5105` →
/// `m1.follow-ionian.ts.net`. Returns `None` for a loopback origin, which
/// names no machine worth showing.
pub fn parse_origin_host(origin: &str) -> Option<String> {
    let after_scheme = origin.split("://").nth(1).unwrap_or(origin);
    let authority = after_scheme.split('/').next().unwrap_or(after_scheme);
    // Strip the port. Split from the left: an IPv6 literal is bracketed, and
    // everything else has at most one colon.
    let host = match authority.rsplit_once(':') {
        Some((h, p)) if p.chars().all(|c| c.is_ascii_digit()) && !h.is_empty() => h,
        _ => authority,
    };
    let host = host.trim_matches(|c| c == '[' || c == ']');
    if host.is_empty() || host == "localhost" || host == "127.0.0.1" || host == "::1" {
        return None;
    }
    Some(host.to_string())
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

/// Fast liveness check for a loopback channel port: just attempt a TCP
/// connect with a short timeout. A live flan-channel accepts instantly; a
/// dead one yields `ECONNREFUSED` immediately. No HTTP round-trip — kept cheap
/// because the prune loop calls this every 2s for every registered port.
pub fn port_is_live(port: u16) -> bool {
    let addr = match format!("127.0.0.1:{}", port).parse() {
        Ok(a) => a,
        Err(_) => return false,
    };
    TcpStream::connect_timeout(&addr, Duration::from_millis(200)).is_ok()
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ChannelRelayOutcome {
    pub accepted: bool,
    pub delivered: bool,
}

pub fn channel_port_for_cwd(
    registered_ports: &HashMap<String, u16>,
    app_cwd: &str,
) -> Option<u16> {
    let app = app_cwd.trim_end_matches('/');
    registered_ports
        .iter()
        .filter_map(|(registered_cwd, port)| {
            let registered = registered_cwd.trim_end_matches('/');
            (registered == app
                || registered.starts_with(&format!("{app}/"))
                || app.starts_with(&format!("{registered}/")))
                .then_some((registered.len(), *port))
        })
        .max_by_key(|(specificity, _)| *specificity)
        .map(|(_, port)| port)
}

/// Forward one message batch to a loopback-only flan-channel.
///
/// The public client talks only to the stable Rust server. Keeping this hop on
/// loopback avoids exposing per-agent channel ports to browsers or the tailnet.
// ── Delivery: Codex ─────────────────────────────────────────────────────
//
// A link to a Codex session can't be served by the flan-channel: that is
// Claude Code's `notifications/claude/channel` protocol, and a channel
// started under Codex refuses to push into it. Codex does take input from
// outside, though — `codex queue --thread <id> --message <text>` appends a
// user turn to a live thread through the app-server's control socket. The
// thread id is read off the rollout file the Codex process keeps open.

/// The thread id embedded in a Codex rollout path, e.g.
/// `~/.codex/sessions/2026/09/07/rollout-2026-09-07T21-29-32-01a07f47-471e-7122-a0e9-8efe01dd2268.jsonl`.
pub fn codex_thread_from_rollout_path(path: &str) -> Option<String> {
    let name = path.rsplit('/').next()?;
    let stem = name.strip_suffix(".jsonl")?.strip_prefix("rollout-")?;
    if stem.len() < 36 || !stem.is_char_boundary(stem.len() - 36) {
        return None;
    }
    let uuid = &stem[stem.len() - 36..];
    let shape_ok = uuid.split('-').map(str::len).eq([8, 4, 4, 4, 12]);
    let hex_ok = uuid.chars().all(|c| c == '-' || c.is_ascii_hexdigit());
    (shape_ok && hex_ok).then(|| uuid.to_string())
}

/// Threads a Codex process currently has open, most recently written first.
///
/// A TUI holds exactly one. An app-server (VS Code, the desktop app) holds
/// one per live thread, and the freshest is the one being worked in.
pub fn codex_threads_for_pid(pid: u32) -> Vec<String> {
    let Ok(out) = Command::new("lsof")
        .args(["-p", &pid.to_string(), "-Fn"])
        .output()
    else {
        return Vec::new();
    };
    let text = String::from_utf8_lossy(&out.stdout);
    let mut found: Vec<(std::time::SystemTime, String)> = Vec::new();
    for line in text.lines() {
        let Some(path) = line.strip_prefix('n') else { continue };
        let Some(thread) = codex_thread_from_rollout_path(path) else { continue };
        if found.iter().any(|(_, seen)| seen == &thread) {
            continue;
        }
        let modified = std::fs::metadata(path)
            .and_then(|m| m.modified())
            .unwrap_or(std::time::UNIX_EPOCH);
        found.push((modified, thread));
    }
    found.sort_by(|a, b| b.0.cmp(&a.0));
    found.into_iter().map(|(_, thread)| thread).collect()
}

fn is_codex_comm(comm: &str) -> bool {
    agent_name_from_comm(comm) == Some("Codex")
}

/// Nearest Codex process at or below `root` in the process tree.
fn codex_descendant_in(
    procs: &HashMap<u32, (u32, String, String)>,
    root: u32,
) -> Option<u32> {
    if procs.get(&root).is_some_and(|(_, _, comm)| is_codex_comm(comm)) {
        return Some(root);
    }
    let mut frontier = vec![root];
    for _ in 0..8 {
        let mut next = Vec::new();
        for parent in &frontier {
            for (pid, (ppid, _, comm)) in procs {
                if ppid == parent {
                    if is_codex_comm(comm) {
                        return Some(*pid);
                    }
                    next.push(*pid);
                }
            }
        }
        if next.is_empty() {
            break;
        }
        frontier = next;
    }
    None
}

/// The Codex process behind a link target, if the target is one.
///
/// `sess:<pid>` names the agent directly. `trm:<pane_id>` names a pane; its
/// login process is the root of everything running there, so Codex is found
/// underneath it. Any other id form (a cmux surface, the `cwd-route`
/// sentinel) carries no process to resolve.
pub fn codex_pid_for_target(target: &str) -> Option<u32> {
    let procs = process_table();
    if let Some(pid) = target.strip_prefix("sess:") {
        let pid: u32 = pid.parse().ok()?;
        return procs
            .get(&pid)
            .filter(|(_, _, comm)| is_codex_comm(comm))
            .map(|_| pid);
    }
    if let Some(pane_id) = target.strip_prefix("trm:") {
        let pane_id: usize = pane_id.parse().ok()?;
        let pane = discover_trm_panes()
            .into_iter()
            .find(|p| p.pane_id == pane_id)?;
        return codex_descendant_in(&procs, pane.login_pid?);
    }
    None
}

/// Where the `codex` CLI lives. The server is often started from a launcher
/// whose PATH lacks `~/.local/bin`, so the usual install spots are checked
/// too. `FLAN_CODEX_BIN` overrides everything.
pub fn codex_binary() -> PathBuf {
    if let Some(explicit) = std::env::var_os("FLAN_CODEX_BIN") {
        return PathBuf::from(explicit);
    }
    let mut candidates: Vec<PathBuf> = std::env::var_os("PATH")
        .map(|path| std::env::split_paths(&path).map(|dir| dir.join("codex")).collect())
        .unwrap_or_default();
    if let Ok(home) = std::env::var("HOME") {
        let home = PathBuf::from(home);
        candidates.push(home.join(".local/bin/codex"));
        candidates.push(home.join(".codex/packages/standalone/current/bin/codex"));
        candidates.push(home.join(".codex/packages/standalone/current/codex"));
    }
    candidates.push(PathBuf::from("/opt/homebrew/bin/codex"));
    candidates.push(PathBuf::from("/usr/local/bin/codex"));
    candidates
        .into_iter()
        .find(|candidate| candidate.is_file())
        .unwrap_or_else(|| PathBuf::from("codex"))
}

/// Decode standard or URL-safe base64, ignoring whitespace and a leading
/// `data:...;base64,` prefix. Small enough not to be worth a dependency.
pub fn decode_base64(input: &str) -> Option<Vec<u8>> {
    let payload = input
        .find(";base64,")
        .map(|at| &input[at + ";base64,".len()..])
        .unwrap_or(input);
    let mut out = Vec::with_capacity(payload.len() * 3 / 4);
    let mut acc: u32 = 0;
    let mut bits = 0u8;
    for c in payload.bytes() {
        let value = match c {
            b'A'..=b'Z' => c - b'A',
            b'a'..=b'z' => c - b'a' + 26,
            b'0'..=b'9' => c - b'0' + 52,
            b'+' | b'-' => 62,
            b'/' | b'_' => 63,
            b'=' | b'\n' | b'\r' | b' ' | b'\t' => continue,
            _ => return None,
        };
        acc = (acc << 6) | u32::from(value);
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push(((acc >> bits) & 0xff) as u8);
        }
    }
    Some(out)
}

/// Render a flushed batch as the text `codex queue` hands the thread.
///
/// The Claude channel formats the same fields on the Dart side and carries
/// the VM URI as an attribute; Codex gets plain text, so the URI goes in the
/// body along with what to do with it. Screenshots are decoded to PNG files
/// that get attached to the queued turn and named in the text.
pub fn format_codex_message(
    messages: &[serde_json::Value],
    vm_uri: Option<&str>,
    flutter_pid: Option<u32>,
) -> (String, Vec<PathBuf>) {
    let mut out = String::new();
    let mut images = Vec::new();

    out.push_str("[flan] Message from the linked Flutter app, relayed by the Flan TUI.\n");
    match vm_uri {
        Some(uri) => out.push_str(&format!(
            "vm_service_uri: {uri}\nIf you are not already connected to this app, call the \
             flan `connect` tool with that URI first, then act on the message.\n"
        )),
        None => out.push_str(
            "No VM service URI is attached; use the flan `list_apps` tool to find the app \
             if you need to connect.\n",
        ),
    }
    if let Some(pid) = flutter_pid {
        out.push_str(&format!("flutter_pid: {pid}\n"));
    }

    let total = messages.len();
    for (index, msg) in messages.iter().enumerate() {
        if total > 1 {
            out.push_str(&format!("\n--- message {} of {total} ---\n", index + 1));
        } else {
            out.push('\n');
        }
        let text = msg["text"].as_str().unwrap_or("");
        let kind = msg["type"].as_str().unwrap_or("message");
        if let Some(ts) = msg["timestamp"].as_str().filter(|t| !t.is_empty()) {
            out.push_str(&format!("[{ts}]\n"));
        }
        if kind != "user_feedback" {
            out.push_str(&format!("type: {kind}\n"));
        }
        out.push_str(text);
        out.push('\n');

        let Some(data) = msg["data"].as_object() else { continue };
        for (key, label) in [
            ("url", "URL"),
            ("routeStack", "Route stack"),
            ("currentRoute", "Current route"),
        ] {
            if let Some(value) = data.get(key).and_then(|v| v.as_str()).filter(|v| !v.is_empty()) {
                out.push_str(&format!("{label}: {value}\n"));
            }
        }
        if let Some(selection) = data.get("inspectorSelection").and_then(|v| v.as_object()) {
            out.push_str("Inspector selection:\n");
            for (key, label) in [
                ("widgetType", "Widget type"),
                ("widgetPath", "Widget path"),
                ("sourceLocation", "Source"),
                ("bounds", "Bounds"),
            ] {
                if let Some(value) = selection.get(key).filter(|v| !v.is_null()) {
                    let shown = value.as_str().map(str::to_owned).unwrap_or_else(|| value.to_string());
                    out.push_str(&format!("  {label}: {shown}\n"));
                }
            }
            if let Some(props) = selection.get("properties").filter(|v| !v.is_null()) {
                out.push_str(&format!("  Properties: {props}\n"));
            }
        }
        if let Some(annotations) = data.get("annotations").and_then(|v| v.as_array()) {
            if !annotations.is_empty() {
                out.push_str(&format!("Annotations: {}\n", serde_json::Value::Array(annotations.clone())));
            }
        }
        if let Some(turns) = data.get("turns").or_else(|| data.get("chatLog")).and_then(|v| v.as_array()) {
            if !turns.is_empty() {
                out.push_str(&format!("Chat log: {}\n", serde_json::Value::Array(turns.clone())));
            }
        }
        if let Some(encoded) = data.get("screenshot").and_then(|v| v.as_str()) {
            match write_codex_image(encoded, index) {
                Some(path) => {
                    out.push_str(&format!("Screenshot: {} (attached)\n", path.display()));
                    images.push(path);
                }
                None => out.push_str("Screenshot: attached image could not be decoded\n"),
            }
        }
    }

    (out, images)
}

/// Persist a base64 screenshot as a PNG the `codex queue --image` flag can
/// read. Files live under `~/.flan/codex-images` so they outlive the request.
fn write_codex_image(encoded: &str, index: usize) -> Option<PathBuf> {
    let bytes = decode_base64(encoded).filter(|b| !b.is_empty())?;
    let dir = flan_dir().join("codex-images");
    std::fs::create_dir_all(&dir).ok()?;
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);
    let path = dir.join(format!("flan-{stamp}-{index}.png"));
    std::fs::write(&path, bytes).ok()?;
    Some(path)
}

/// Run a command, killing it if it outlives `timeout`. `codex queue` should
/// return at once; a wedged app-server must not hang the flush handler.
fn run_with_timeout(
    mut cmd: Command,
    timeout: Duration,
) -> std::io::Result<std::process::Output> {
    use std::process::Stdio;
    cmd.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped());
    let mut child = cmd.spawn()?;
    let started = Instant::now();
    loop {
        if child.try_wait()?.is_some() {
            return child.wait_with_output();
        }
        if started.elapsed() > timeout {
            let _ = child.kill();
            let _ = child.wait();
            return Err(std::io::Error::new(
                std::io::ErrorKind::TimedOut,
                format!("timed out after {}s", timeout.as_secs()),
            ));
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// Append a user turn to a live Codex thread with `codex queue`.
///
/// `--remote unix://` reaches the app-server over its default control socket,
/// which is the one both the TUI and app-server-hosted threads hang off. When
/// attachments are refused the text is re-sent alone rather than dropped.
pub fn relay_codex_queue(
    thread: &str,
    message: &str,
    images: &[PathBuf],
) -> Result<ChannelRelayOutcome, String> {
    let bin = codex_binary();
    let build = |with_images: bool| {
        let mut cmd = Command::new(&bin);
        cmd.args(["queue", "--remote", "unix://", "--thread", thread, "--message", message]);
        if with_images {
            for image in images {
                cmd.arg("--image").arg(image);
            }
        }
        cmd
    };
    let timeout = Duration::from_secs(20);
    let mut output = run_with_timeout(build(!images.is_empty()), timeout)
        .map_err(|error| format!("Could not run {}: {error}", bin.display()))?;
    if !output.status.success() && !images.is_empty() {
        output = run_with_timeout(build(false), timeout)
            .map_err(|error| format!("Could not run {}: {error}", bin.display()))?;
    }
    if output.status.success() {
        return Ok(ChannelRelayOutcome { accepted: true, delivered: true });
    }
    let stderr = String::from_utf8_lossy(&output.stderr);
    let stdout = String::from_utf8_lossy(&output.stdout);
    let detail = stderr.trim().lines().last().or_else(|| stdout.trim().lines().last())
        .unwrap_or("no output")
        .to_string();
    Err(format!("codex queue failed ({}): {detail}", output.status))
}

pub fn relay_channel_flush(
    port: u16,
    payload: &str,
) -> Result<ChannelRelayOutcome, String> {
    let address = format!("127.0.0.1:{port}")
        .parse()
        .map_err(|error| format!("Invalid Flan channel address: {error}"))?;
    let mut stream = TcpStream::connect_timeout(&address, Duration::from_secs(2))
        .map_err(|error| format!("Flan channel is unavailable: {error}"))?;
    stream
        .set_read_timeout(Some(Duration::from_secs(5)))
        .map_err(|error| format!("Could not configure Flan channel read timeout: {error}"))?;
    stream
        .set_write_timeout(Some(Duration::from_secs(5)))
        .map_err(|error| format!("Could not configure Flan channel write timeout: {error}"))?;

    let request = format!(
        "POST /flush HTTP/1.1\r\n\
         Host: 127.0.0.1:{port}\r\n\
         Content-Type: application/json\r\n\
         Content-Length: {}\r\n\
         Connection: close\r\n\r\n{}",
        payload.len(),
        payload,
    );
    stream
        .write_all(request.as_bytes())
        .map_err(|error| format!("Could not write to Flan channel: {error}"))?;

    let mut response = String::new();
    stream
        .read_to_string(&mut response)
        .map_err(|error| format!("Could not read Flan channel response: {error}"))?;
    let status_ok = response
        .lines()
        .next()
        .is_some_and(|line| line.split_whitespace().nth(1) == Some("200"));
    if !status_ok {
        let error = response.find('{').zip(response.rfind('}'))
            .and_then(|(start, end)| serde_json::from_str::<serde_json::Value>(
                &response[start..=end]).ok())
            .and_then(|body| body["error"].as_str().map(str::to_owned))
            .unwrap_or_else(|| "Flan channel returned a non-success response".into());
        return Err(error);
    }

    // Dart's HttpServer may use either Content-Length or chunked encoding.
    // Isolating the outermost JSON object handles both without exposing a
    // general-purpose HTTP client dependency for this local-only hop.
    let start = response
        .find('{')
        .ok_or_else(|| "Flan channel returned no JSON body".to_string())?;
    let end = response
        .rfind('}')
        .ok_or_else(|| "Flan channel returned incomplete JSON".to_string())?;
    let body: serde_json::Value = serde_json::from_str(&response[start..=end])
        .map_err(|error| format!("Invalid Flan channel response: {error}"))?;

    Ok(ChannelRelayOutcome {
        accepted: body["accepted"].as_bool().unwrap_or(false)
            || body["ok"].as_bool().unwrap_or(false),
        delivered: body["delivered"].as_bool().unwrap_or(false),
    })
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

/// Result of probing a Flutter app's flan extension.
#[derive(Debug, Clone, Copy, Default)]
pub struct FlanPeek {
    /// Number of queued user messages awaiting the agent.
    pub queue_count: usize,
    /// Whether an agent is currently CONNECTED to this app — the steady
    /// connection truth (true from `connect` until disconnect), as opposed to a
    /// mere persisted association. Drives the TUI connector line.
    pub connected: bool,
}

/// Backwards-compatible helper returning just the queue count.
pub fn peek_flan_queue(ws_uri: &str) -> usize {
    peek_flan(ws_uri).queue_count
}

/// Call ext.flutter.flan.peekUserMessages via the VM service WebSocket and
/// return the queue count and live listening state. Returns the default
/// (count 0, not listening) if unreachable / extension not registered.
/// Open a VM service WebSocket, with every step bounded by a timeout.
///
/// We do NOT use tungstenite's `connect()` helper because it has no
/// connect/read timeout — a VM service that accepts the TCP connection but
/// never completes the handshake or never replies (seen with native macOS apps
/// whose auth-gated port stalls) would block `read()` forever, hanging the
/// entire discovery cycle and taking down /api/flutter-apps. Instead, open the
/// TCP stream with connect_timeout, set a read timeout so every read is
/// bounded, then run the WS handshake on it.
///
/// `read` is separate from `connect` because the two have nothing to do with
/// each other: reaching a VM service should take milliseconds, while waiting
/// for it to finish a hot reload can take seconds.
fn connect_vm_service(
    ws_uri: &str,
    connect: Duration,
    read: Duration,
) -> Option<tungstenite::WebSocket<TcpStream>> {
    use std::net::ToSocketAddrs;

    // ws_uri looks like ws://127.0.0.1:PORT/TOKEN/ws
    let host_port = ws_uri
        .trim_start_matches("ws://")
        .split('/')
        .next()
        .unwrap_or("");
    let addr = host_port.to_socket_addrs().ok()?.next()?;
    let tcp = TcpStream::connect_timeout(&addr, connect).ok()?;
    tcp.set_read_timeout(Some(read)).ok()?;
    let (socket, _) = tungstenite::client(ws_uri, tcp).ok()?;
    Some(socket)
}

pub fn peek_flan(ws_uri: &str) -> FlanPeek {
    use tungstenite::Message;

    let timeout = Duration::from_secs(3);

    let Some(mut socket) = connect_vm_service(ws_uri, timeout, timeout) else {
        return FlanPeek::default();
    };

    // 1. Get the isolate id.
    let get_vm = serde_json::json!({
        "jsonrpc": "2.0", "method": "getVM", "id": "1"
    })
    .to_string();
    if socket.send(Message::Text(get_vm.into())).is_err() { return FlanPeek::default(); }

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
        None => return FlanPeek::default(),
    };

    // 2. Call peekUserMessages. Service extensions are invoked DIRECTLY by their
    //    registered method name — NOT wrapped in `callServiceExtension` (that
    //    yields -32601 "Unknown method" on this VM service, which silently
    //    dropped count + connected to defaults).
    let peek = serde_json::json!({
        "jsonrpc": "2.0",
        "method": "ext.flutter.flan.peekUserMessages",
        "params": {
            "isolateId": isolate_id,
        },
        "id": "2"
    })
    .to_string();
    if socket.send(Message::Text(peek.into())).is_err() { return FlanPeek::default(); }

    let deadline = std::time::Instant::now() + timeout;
    loop {
        if std::time::Instant::now() > deadline { return FlanPeek::default(); }
        match socket.read() {
            Ok(Message::Text(t)) => {
                if let Ok(v) = serde_json::from_str::<serde_json::Value>(&t) {
                    if v["id"] == "2" {
                        let count = v["result"]["count"].as_u64().unwrap_or(0) as usize;
                        // Prefer the steady `connected` (isHostConnected). Fall
                        // back to the transient `listening` for older app builds
                        // that don't send `connected`. Missing both → false.
                        let connected = v["result"]["connected"].as_bool()
                            .or_else(|| v["result"]["listening"].as_bool())
                            .unwrap_or(false);
                        let _ = socket.close(None);
                        return FlanPeek { queue_count: count, connected };
                    }
                }
            }
            Ok(_) => continue,
            Err(_) => return FlanPeek::default(),
        }
    }
}

// ── What this relay can do ──────────────────────────────────────────────
//
// Several flan-servers run at once — one per worktree, one systemd service per
// host, one inside each TUI — and they are separate binaries that go stale
// independently. A caller that only gets `{"ok": true}` from an old one learns
// nothing until a request 404s, which reads as "the feature is broken" rather
// than "this relay is three days old". So the relay says who it is.
//
// Add a name here when you add a capability a client can ask for; clients test
// for the name, never for a version number.

/// Build identity. The crate version plus the day it was built, because every
/// one of these binaries reports 0.1.0.
pub const RELAY_VERSION: &str = concat!(env!("CARGO_PKG_VERSION"), "+", env!("FLAN_BUILD_DATE"));

/// Capabilities a client can test for by name.
pub const RELAY_FEATURES: &[&str] = &[
    // POST /api/hot-reload exists at all.
    "hot-reload",
    // ...and takes `full_restart`.
    "hot-restart",
    // ...and resolves a web app by its `origin`, which is the only identity a
    // page has.
    "origin-match",
    // ...and answers with what `flutter run` actually printed.
    "reload-verdict",
];

// ── Relay version drift ─────────────────────────────────────────────────
//
// The reason this exists: an app posts to ONE relay — whichever
// `FLAN_SERVER_URL` names, usually its own worktree's — and that relay is a
// separate binary from the one in the TUI, from the host's systemd service,
// and from every other worktree's. They go stale independently, and a stale
// one answers 404 for an endpoint that shipped days ago. Every time, the
// symptom is "hot reload is broken" and the cause is "that relay is old".
//
// So the TUI asks every relay it can see what it can do, and says which ones
// are behind it. Nothing here restarts anything: which relay a worktree runs
// is wt's business, and a TUI that silently replaced somebody's running
// service would be worse than the problem.

/// What one relay answered when asked who it is.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RelayCheck {
    /// `http://host:port`, as a caller would reach it.
    pub endpoint: String,
    pub reachable: bool,
    pub version: Option<String>,
    /// Capabilities this binary has and that one lacks. Empty means current.
    pub missing: Vec<String>,
}

impl RelayCheck {
    pub fn is_stale(&self) -> bool {
        self.reachable && !self.missing.is_empty()
    }

    /// One line a human can act on.
    pub fn summary(&self) -> String {
        if !self.reachable {
            return format!("{}: unreachable", self.endpoint);
        }
        if self.missing.is_empty() {
            return format!("{}: current", self.endpoint);
        }
        format!(
            "{} is behind this build ({}) — missing {}",
            self.endpoint,
            self.version.as_deref().unwrap_or("unknown build"),
            self.missing.join(", "),
        )
    }
}

/// Ask one relay what it can do.
pub fn check_relay(endpoint: &str) -> RelayCheck {
    let parsed = peer_get_object(endpoint, "/api/health")
        .and_then(|body| serde_json::from_str::<serde_json::Value>(&body).ok());
    let Some(value) = parsed else {
        return RelayCheck {
            endpoint: endpoint.to_string(),
            reachable: false,
            version: None,
            missing: Vec::new(),
        };
    };

    let features: Vec<String> = value["features"]
        .as_array()
        .map(|list| {
            list.iter()
                .filter_map(|f| f.as_str().map(str::to_string))
                .collect()
        })
        .unwrap_or_default();
    // A relay old enough to predate this endpoint answers `{"ok": true}` and no
    // features — which is itself the answer: it has none of them.
    let missing = RELAY_FEATURES
        .iter()
        .filter(|ours| !features.iter().any(|theirs| theirs == *ours))
        .map(|f| f.to_string())
        .collect();

    RelayCheck {
        endpoint: endpoint.to_string(),
        reachable: true,
        version: value["version"].as_str().map(str::to_string),
        missing,
    }
}

/// Every flan-server listening on this machine, as `http://127.0.0.1:PORT`.
///
/// Found by process name rather than by a list of known ports: the whole point
/// is the relays nobody remembered were running — a worktree's, a leftover from
/// a branch deleted last week.
pub fn local_relay_endpoints() -> Vec<String> {
    let flan_pids: HashSet<u32> = relay_process_ids();
    let mut ports: Vec<u16> = listening_sockets()
        .into_iter()
        .filter(|(pid, _)| flan_pids.contains(pid))
        .map(|(_, port)| port)
        .collect();
    ports.sort_unstable();
    ports.dedup();
    ports
        .into_iter()
        .map(|port| format!("http://127.0.0.1:{port}"))
        .collect()
}

/// PIDs of flan-server and flan-tui processes (the TUI embeds a relay).
fn relay_process_ids() -> HashSet<u32> {
    let Ok(output) = Command::new("ps").args(["-eo", "pid,comm"]).output() else {
        return HashSet::new();
    };
    String::from_utf8_lossy(&output.stdout)
        .lines()
        .filter_map(|line| {
            let mut parts = line.split_whitespace();
            let pid: u32 = parts.next()?.parse().ok()?;
            let comm = parts.next()?;
            let name = comm.rsplit('/').next().unwrap_or(comm);
            (name == "flan-server" || name == "flan-tui").then_some(pid)
        })
        .collect()
}

/// Check every relay we can see — this machine's, and each peer's.
pub fn check_all_relays(peers: &[String]) -> Vec<RelayCheck> {
    let mut endpoints = local_relay_endpoints();
    endpoints.extend(peers.iter().cloned());
    endpoints.into_iter().map(|e| check_relay(&e)).collect()
}

// ── Hot reload ──────────────────────────────────────────────────────────
//
// Two ways in, and which one is right depends on what we know about the app.
//
// The signal is the cheap one: `flutter run`'s TerminalHandler installs
// handlers for SIGUSR1 (hot reload) and SIGUSR2 (hot restart), and
// `flutter run --pid-file` documents them as the supported way for another
// process to ask. It is one syscall against a pid discovery already has, needs
// no handshake, and still works when a VM service port accepts a connection and
// then stalls — the auth-gated native-macOS case `peek_flan` guards against.
// What it cannot do is tell us anything: flutter_tools prints the compile errors
// in its own terminal and answers nobody.
//
// The VM service is the one that answers. flutter_tools registers its reload
// under a service name on the VM service, and invoking that returns success or
// the reason it failed. It is also the only option for an app we have a URI for
// but no local `flutter run` pid.
//
// An app on another machine is neither: only that host's own flan server can
// see its pid, and its loopback VM service port means nothing here. That one
// gets handed to the peer, the same way a flush it can't route is.

/// How long to wait for flutter_tools' verdict on a reload. A reload compiles
/// and pushes a kernel delta, and the first one of a session is routinely a few
/// seconds; this is the point at which we stop believing an answer is coming.
const RELOAD_VERDICT_TIMEOUT: Duration = Duration::from_secs(20);

/// What a hot reload request did, in words a caller can show as-is.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HotReloadOutcome {
    pub ok: bool,
    /// How it was asked: "signal", the VM service method, or `host:via` for one
    /// a peer carried out.
    pub via: String,
    pub detail: String,
    /// The code compiled and reached nobody: a web app whose page has no debug
    /// client attached. Said as a field rather than left for the client to find
    /// in the prose, because the app acts on it — refreshing the page is the
    /// one step that finishes the job, and only the app can take it.
    #[serde(default)]
    pub needs_page_refresh: bool,
}

/// The flutter_tools service that performs each kind of reload.
fn reload_service_name(full_restart: bool) -> &'static str {
    if full_restart {
        "hotRestart"
    } else {
        "reloadSources"
    }
}

/// How to name each kind of reload in a log line or a toast.
fn reload_verb(full_restart: bool) -> &'static str {
    if full_restart {
        "Hot restart"
    } else {
        "Hot reload"
    }
}

/// The full command line of `pid`, or None if it is gone.
pub fn process_command_line(pid: u32) -> Option<String> {
    let output = Command::new("ps")
        .args(["-p", &pid.to_string(), "-o", "command="])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let cmd = String::from_utf8_lossy(&output.stdout).trim().to_string();
    (!cmd.is_empty()).then_some(cmd)
}

/// Whether a `flutter run` command line is one that installed the SIGUSR
/// handlers.
///
/// This matters more than it looks: the default disposition of SIGUSR1 is to
/// TERMINATE the process. flutter_tools installs its handlers only when the run
/// is resident and the device supports both the service protocol and restart, so
/// a `--release` or `--profile` run — or one started `--no-resident` — would be
/// killed by the very signal meant to reload it. Decide from the command line,
/// never from the pid alone.
pub fn command_line_accepts_reload_signal(cmd: &str) -> bool {
    cmd.contains("flutter_tools.snapshot")
        && cmd.contains(" run")
        && !cmd.contains("--release")
        && !cmd.contains("--profile")
        && !cmd.contains("--no-resident")
        && !cmd.contains("--trace-startup")
}

/// Whether `pid` is a `flutter run` that can be signalled for a reload.
pub fn accepts_reload_signal(pid: u32) -> bool {
    pid != 0
        && process_command_line(pid)
            .is_some_and(|cmd| command_line_accepts_reload_signal(&cmd))
}

/// SIGUSR1 asks a `flutter run` for a hot reload, SIGUSR2 for a hot restart.
///
/// The target is the TOOL process — the `dart … flutter_tools.snapshot run` that
/// owns the incremental compiler — which is exactly what [discover_flutter_apps]
/// records as `FlutterApp::pid`. Signalling the app process instead does
/// nothing; on most devices it isn't even on this machine.
///
/// Call [accepts_reload_signal] first. This function only delivers the signal.
pub fn hot_reload_signal(pid: u32, full_restart: bool) -> bool {
    let sig = if full_restart {
        libc::SIGUSR2
    } else {
        libc::SIGUSR1
    };
    pid != 0 && unsafe { libc::kill(pid as libc::pid_t, sig) } == 0
}

/// One read of a VM service socket: a text frame, nothing yet, or done for.
enum VmFrame {
    Text(String),
    /// Nothing to act on — a non-text frame, or the read slice simply elapsed.
    Idle,
    Failed(String),
}

/// Read one frame, treating a read timeout as "not yet" rather than a failure.
///
/// The socket's read timeout is a slice, not the budget: each loop below keeps
/// its own deadline. Conflating the two is how waiting for a service
/// registration that never came reported "Resource temporarily unavailable"
/// instead of saying which service was missing.
fn read_vm_frame(socket: &mut tungstenite::WebSocket<TcpStream>) -> VmFrame {
    match socket.read() {
        Ok(tungstenite::Message::Text(text)) => VmFrame::Text(text.to_string()),
        Ok(_) => VmFrame::Idle,
        Err(tungstenite::Error::Io(error))
            if matches!(
                error.kind(),
                std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
            ) =>
        {
            VmFrame::Idle
        }
        Err(error) => VmFrame::Failed(format!("VM service read failed: {error}")),
    }
}

/// How long one read of a VM service socket may block before the loop around it
/// gets to re-check its own deadline.
const VM_READ_SLICE: Duration = Duration::from_secs(1);

/// Ask flutter_tools to reload over the VM service, and wait for its verdict.
///
/// The VM's own `reloadSources` RPC is not a substitute: a Flutter app's VM has
/// no compiler, so nothing would recompile the edited sources. What does the
/// work is the service flutter_tools REGISTERS under that name, which the VM
/// service exposes to other clients under a per-client prefix
/// (`s0.reloadSources`). That prefix is only learnable from a `ServiceRegistered`
/// event on the `_Service` stream, which is replayed to each client as it
/// subscribes — hence subscribe first, then watch for the name.
pub fn hot_reload_via_vm_service(ws_uri: &str, full_restart: bool) -> Result<(), String> {
    use tungstenite::Message;

    let service = reload_service_name(full_restart);
    let mut socket = connect_vm_service(ws_uri, Duration::from_secs(3), VM_READ_SLICE)
        .ok_or_else(|| format!("VM service unreachable at {ws_uri}"))?;

    let subscribe = serde_json::json!({
        "jsonrpc": "2.0", "id": "1",
        "method": "streamListen",
        "params": {"streamId": "_Service"},
    })
    .to_string();
    let get_vm = serde_json::json!({
        "jsonrpc": "2.0", "id": "2", "method": "getVM",
    })
    .to_string();
    for request in [subscribe, get_vm] {
        socket
            .send(Message::Text(request.into()))
            .map_err(|error| format!("VM service write failed: {error}"))?;
    }

    // The isolate id and the prefixed method arrive on different messages, in
    // no guaranteed order.
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut isolate_id: Option<String> = None;
    let mut method: Option<String> = None;
    while isolate_id.is_none() || method.is_none() {
        if Instant::now() > deadline {
            break;
        }
        match read_vm_frame(&mut socket) {
            VmFrame::Text(text) => {
                let Ok(value) = serde_json::from_str::<serde_json::Value>(&text) else {
                    continue;
                };
                if value["id"] == "2" {
                    isolate_id = value["result"]["isolates"][0]["id"]
                        .as_str()
                        .map(str::to_string);
                }
                let event = &value["params"]["event"];
                if event["kind"] == "ServiceRegistered" && event["service"] == service {
                    method = event["method"].as_str().map(str::to_string);
                }
            }
            VmFrame::Idle => continue,
            VmFrame::Failed(error) => return Err(error),
        }
    }

    let isolate_id =
        isolate_id.ok_or_else(|| format!("VM service at {ws_uri} reported no isolate"))?;
    let method = method.ok_or_else(|| {
        format!(
            "No `{service}` service on this VM service — a {} needs a resident \
             `flutter run` attached in debug mode",
            reload_verb(full_restart).to_lowercase()
        )
    })?;

    let call = serde_json::json!({
        "jsonrpc": "2.0", "id": "3",
        "method": method,
        // `reloadSources` requires the isolate; `hotRestart` ignores it.
        "params": {"isolateId": isolate_id},
    })
    .to_string();
    socket
        .send(Message::Text(call.into()))
        .map_err(|error| format!("VM service write failed: {error}"))?;

    let deadline = Instant::now() + RELOAD_VERDICT_TIMEOUT;
    loop {
        if Instant::now() > deadline {
            return Err(format!(
                "flutter_tools did not answer within {}s",
                RELOAD_VERDICT_TIMEOUT.as_secs()
            ));
        }
        match read_vm_frame(&mut socket) {
            VmFrame::Text(text) => {
                let Ok(value) = serde_json::from_str::<serde_json::Value>(&text) else {
                    continue;
                };
                if value["id"] != "3" {
                    continue;
                }
                let _ = socket.close(None);
                if value["result"]["type"] == "Success" {
                    return Ok(());
                }
                // A compile failure comes back as a JSON-RPC error, and its
                // message is the only account of what is wrong with the code.
                return Err(value["error"]["message"]
                    .as_str()
                    .or_else(|| value["error"]["data"]["details"].as_str())
                    .map(str::to_string)
                    .unwrap_or_else(|| value.to_string()));
            }
            VmFrame::Idle => continue,
            VmFrame::Failed(error) => return Err(error),
        }
    }
}

// ── Reading the tool's own verdict ──────────────────────────────────────
//
// A signal has no reply channel, so flutter_tools answers nobody: it prints
// "Restarted application in 223ms." — or three pages of compile errors — to its
// own stdout and carries on. That used to be the end of it, and an app whose
// restart never happened was told "Hot restart requested".
//
// But `flutter run` under `wt` (and under nohup, and under systemd) has its
// stdout on a FILE, and a file can be read. Note its length before signalling,
// then watch what gets appended. When stdout is a TTY or a pipe there is
// nothing to read and the old wording stands — which is the honest answer in
// that case rather than a worse one.

/// How long to wait for a `flutter run` to say what happened. A restart of a
/// large web app took ~5s on the build host; past this we stop claiming to know.
const SIGNAL_VERDICT_TIMEOUT: Duration = Duration::from_secs(12);

/// What a `flutter run` said about the reload it was just asked for.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ToolVerdict {
    /// It finished, in its own words ("Restarted application in 223ms.").
    Done(String),
    /// It refused or failed, in its own words (the first compile error).
    Failed(String),
    /// It said nothing we recognise before the deadline.
    Silent,
    /// It started and hadn't finished when we stopped waiting. Distinct from
    /// [Silent]: we know the signal landed, which rules out everything the
    /// "requested" wording leaves open.
    Pending,
}

/// Where a process's stdout goes, when it goes to a regular file.
///
/// `/proc` on Linux, `lsof` on macOS, and `None` for a TTY, a pipe or anything
/// else we can't read a verdict from.
pub fn process_stdout_file(pid: u32) -> Option<PathBuf> {
    if pid == 0 {
        return None;
    }
    let proc_fd = PathBuf::from(format!("/proc/{pid}/fd/1"));
    if let Ok(target) = std::fs::read_link(&proc_fd) {
        return target.is_file().then_some(target);
    }

    // macOS: `-F ftn` prints one field per line — f<fd>, t<type>, n<name>.
    let output = Command::new("lsof")
        .args(["-p", &pid.to_string(), "-a", "-d", "1", "-F", "ftn"])
        .output()
        .ok()?;
    let stdout = String::from_utf8_lossy(&output.stdout);
    let mut is_regular = false;
    for line in stdout.lines() {
        match line.split_at(1) {
            ("t", kind) => is_regular = kind == "REG",
            ("n", name) if is_regular => {
                let path = PathBuf::from(name);
                if path.is_file() {
                    return Some(path);
                }
            }
            _ => {}
        }
    }
    None
}

/// Classify whatever a `flutter run` printed after being signalled.
///
/// Order matters: a failed reload prints "Performing hot reload..." first and
/// the error afterwards, so an error anywhere in the chunk outranks a start
/// line, and only a completion line counts as success.
pub fn verdict_from_output(output: &str) -> ToolVerdict {
    // Progress is written with carriage returns and spinners, so lines have to
    // be split on both terminators before anything can be matched.
    let lines: Vec<String> = output
        .split(['\n', '\r'])
        .map(|line| strip_ansi(line).trim().to_string())
        .filter(|line| !line.is_empty())
        .collect();

    // The compiler's own format: `path.dart:12:34: Error: message`.
    if let Some(error) = lines.iter().find(|line| line.contains(": Error:")) {
        return ToolVerdict::Failed(error.clone());
    }
    if let Some(line) = lines
        .iter()
        .find(|line| line.contains("Hot reload rejected") || line.contains("Try again after fixing"))
    {
        return ToolVerdict::Failed(line.clone());
    }
    // flutter_tools drops a request made while it is still handling one.
    if let Some(line) = lines.iter().find(|line| line.contains("Ignoring signal")) {
        return ToolVerdict::Failed(line.clone());
    }
    // A web app with no debug client attached: the code compiled and reached
    // nobody. Reported as a failure because from the page's point of view that
    // is what happened — nothing changed, and refreshing it is the way out.
    if let Some(line) = lines.iter().find(|line| line.contains("No client connected")) {
        return ToolVerdict::Failed(line.clone());
    }
    // Two wordings, and only matching one of them reported a web reload that
    // plainly worked ("Reloaded application in 847ms.") as merely "requested":
    //
    //   Reloaded 1 of 1482 libraries in 349ms.   (a VM app)
    //   Reloaded application in 847ms.           (web)
    if let Some(line) = lines
        .iter()
        .find(|line| line.contains("Restarted application in") || line.starts_with("Reloaded "))
    {
        return ToolVerdict::Done(line.clone());
    }
    ToolVerdict::Silent
}

/// Whether the tool has at least acknowledged the request by starting work.
fn output_shows_work_started(output: &str) -> bool {
    output.contains("Performing hot reload") || output.contains("Performing hot restart")
}

/// Watch `log` from `offset` until it says what happened, or until `timeout`.
pub fn await_tool_verdict(log: &std::path::Path, offset: u64, timeout: Duration) -> ToolVerdict {
    let deadline = Instant::now() + timeout;
    let mut seen = String::new();
    let mut started = false;
    loop {
        if let Ok(mut file) = std::fs::File::open(log) {
            // A rotated or truncated log restarts the story rather than
            // appending to it, so a shrunken file is read from the beginning.
            let len = file.metadata().map(|m| m.len()).unwrap_or(0);
            let from = if len < offset { 0 } else { offset };
            if len > from && file.seek(SeekFrom::Start(from)).is_ok() {
                seen.clear();
                let _ = file.take(256 * 1024).read_to_string(&mut seen);
                started |= output_shows_work_started(&seen);
                match verdict_from_output(&seen) {
                    ToolVerdict::Silent | ToolVerdict::Pending => {}
                    verdict => return verdict,
                }
            }
        }
        if Instant::now() >= deadline {
            return if started {
                ToolVerdict::Pending
            } else {
                ToolVerdict::Silent
            };
        }
        std::thread::sleep(Duration::from_millis(150));
    }
}

/// The size of a `flutter run`'s stdout file right now, so that only what it
/// prints AFTER the signal is read as its answer.
fn tool_output_mark(pid: u32) -> Option<(PathBuf, u64)> {
    let path = process_stdout_file(pid)?;
    let len = std::fs::metadata(&path).ok()?.len();
    Some((path, len))
}

/// Reload an app running on THIS machine: signal if we can, VM service if not.
pub fn hot_reload_local(pid: u32, vm_uri: Option<&str>, full_restart: bool) -> HotReloadOutcome {
    let verb = reload_verb(full_restart);
    if accepts_reload_signal(pid) {
        // Marked BEFORE the signal, or the verdict could be the previous
        // reload's.
        let mark = tool_output_mark(pid);
        if hot_reload_signal(pid, full_restart) {
            let signal = if full_restart { "SIGUSR2" } else { "SIGUSR1" };
            let verdict = mark
                .map(|(log, offset)| await_tool_verdict(&log, offset, SIGNAL_VERDICT_TIMEOUT))
                .unwrap_or(ToolVerdict::Silent);
            return match verdict {
                ToolVerdict::Done(line) => HotReloadOutcome {
                    ok: true,
                    via: "signal".into(),
                    detail: line,
                    needs_page_refresh: false,
                },
                ToolVerdict::Failed(line) => HotReloadOutcome {
                    // The code compiled; nobody received it. The page is one
                    // refresh away from running the new build, and the app is
                    // the only thing that can do that.
                    needs_page_refresh: line.contains("No client connected"),
                    ok: false,
                    via: "signal".into(),
                    detail: line,
                },
                // It started and hadn't finished. Saying "requested" here would
                // hide the one thing worth knowing — that the tool took the
                // request and is stuck on it, which is what a broken debug
                // client looks like from outside.
                ToolVerdict::Pending => HotReloadOutcome {
                    ok: false,
                    via: "signal".into(),
                    detail: format!(
                        "{verb} started but hadn't finished after {}s — still \
                         compiling, or the app's debug client isn't answering",
                        SIGNAL_VERDICT_TIMEOUT.as_secs()
                    ),
                    needs_page_refresh: false,
                },
                // Either stdout isn't a file we can read, or it said nothing we
                // recognise. "Requested" is then the whole truth: the signal
                // was delivered and flutter_tools answers nobody.
                ToolVerdict::Silent => HotReloadOutcome {
                    ok: true,
                    via: "signal".into(),
                    detail: format!("{verb} requested — {signal} → pid {pid}"),
                    needs_page_refresh: false,
                },
            };
        }
    }

    let service = reload_service_name(full_restart);
    match vm_uri {
        Some(uri) => match hot_reload_via_vm_service(uri, full_restart) {
            Ok(()) => HotReloadOutcome {
                ok: true,
                via: service.into(),
                detail: format!("{verb} complete"),
                needs_page_refresh: false,
            },
            Err(error) => HotReloadOutcome {
                ok: false,
                via: service.into(),
                detail: error,
                needs_page_refresh: false,
            },
        },
        None => HotReloadOutcome {
            ok: false,
            via: "none".into(),
            detail: format!(
                "No signalable `flutter run` here (pid {pid}) and no VM service URI to ask"
            ),
            needs_page_refresh: false,
        },
    }
}

/// Hand a reload for an app on another machine to the flan server that can
/// actually perform it.
///
/// Only that host's own server can see the `flutter run` pid, and the loopback
/// VM service URI it reported means nothing here — the same reason
/// [discover_peer_apps] asks a peer rather than guessing.
pub fn hot_reload_on_peer(
    host: &str,
    pid: u32,
    app_id: Option<&str>,
    full_restart: bool,
) -> HotReloadOutcome {
    let fail = |detail: String| HotReloadOutcome {
        ok: false,
        via: host.to_string(),
        detail,
        needs_page_refresh: false,
    };
    let Some(peer) = load_peers()
        .into_iter()
        .find(|peer| peer_host(peer).as_deref() == Some(host))
    else {
        return fail(format!("{host} is not a configured peer"));
    };
    hot_reload_via_peer(&peer, host, pid, app_id, full_restart)
}

/// The hop itself, against an already-resolved peer URL.
fn hot_reload_via_peer(
    peer: &str,
    host: &str,
    pid: u32,
    app_id: Option<&str>,
    full_restart: bool,
) -> HotReloadOutcome {
    let payload = serde_json::json!({
        "pid": pid,
        "app_id": app_id,
        "full_restart": full_restart,
        // Stamped so the peer reloads locally instead of relaying onward: two
        // servers listing each other would otherwise bounce it between them.
        "relayed_from": local_hostname(),
    })
    .to_string();

    match post_peer_json(peer, "/api/hot-reload", &payload, RELOAD_VERDICT_TIMEOUT) {
        Ok((_, value)) => HotReloadOutcome {
            ok: value["ok"].as_bool().unwrap_or(false),
            via: format!("{host}:{}", value["via"].as_str().unwrap_or("?")),
            detail: value["detail"]
                .as_str()
                .unwrap_or("peer gave no detail")
                .to_string(),
            needs_page_refresh: value["needs_page_refresh"].as_bool().unwrap_or(false),
        },
        Err(error) => HotReloadOutcome {
            ok: false,
            via: host.to_string(),
            detail: error,
            needs_page_refresh: false,
        },
    }
}

/// Why this app cannot be hot reloaded by anyone, when that is a property of
/// how it is being served rather than a failure to reach it.
///
/// A static bundle — `flutter build web` behind an http server, or a watched
/// port — is files on disk: no flutter_tools, no compiler, no VM service.
/// Nothing can reload it. Saying "no signalable `flutter run` here (pid 0)"
/// is true but sends people hunting for a bug in flan instead of telling them
/// the build they are looking at was never going to reload.
pub fn unreloadable_reason(app: &FlutterApp) -> Option<String> {
    let device = app.device.as_deref().unwrap_or_default();
    if device != "static" && !device.starts_with("web:") {
        return None;
    }
    let name = if app.folder_name.is_empty() {
        "This app".to_string()
    } else {
        app.folder_name.clone()
    };
    let served = app
        .web_port
        .map(|port| format!(" on :{port}"))
        .unwrap_or_default();
    Some(format!(
        "{name}{served} is a pre-built bundle served over HTTP — there is no \
         `flutter run` behind it to reload. Start it with `flutter run -d chrome` \
         (or `-d web-server`) to get hot reload."
    ))
}

/// Reload one discovered app, wherever it is running.
pub fn hot_reload_app(app: &FlutterApp, full_restart: bool) -> HotReloadOutcome {
    if let Some(host) = app.host.as_deref() {
        return hot_reload_on_peer(host, app.pid, app.app_id.as_deref(), full_restart);
    }
    let outcome = hot_reload_local(app.pid, app.vm_service_uri.as_deref(), full_restart);
    if outcome.ok {
        return outcome;
    }
    match unreloadable_reason(app) {
        Some(detail) => HotReloadOutcome {
            ok: false,
            via: "none".into(),
            detail,
            needs_page_refresh: false,
        },
        None => outcome,
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
    //
    // `title_suggests_agent` is only a *prefilter* — terminal titles are
    // unreliable (a project dir named `codex`/`gemini` substring-matches, a
    // spinner glyph trips the heuristic, and a stale title still says
    // "Claude Code" after the agent exited).  It decides which panes are
    // worth attempting login→process resolution on; the authoritative
    // `has_claude` is computed later from process evidence only.
    struct RawPane {
        surface_id: String,
        pane_id: usize,
        window_id: String,
        title: String,
        title_suggests_agent: bool,
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
        let title_suggests_agent = title_has_agent(&title)
            || (starts_with_spinner && !clean.starts_with('~') && !clean.starts_with('/'));
        // Prefer trm's authoritative per-surface `pwd` (Ghostty tracks it) over
        // the unreliable title-derived path. This is the exact pane→cwd key, so
        // a path-less "Claude Code" pane still resolves to its real repo and
        // routes by cwd correctly — no tty/process-tree guessing. Older trm
        // builds omit `pwd` (or send null); fall back to the title path then.
        let pwd = s.get("pwd").and_then(|v| v.as_str())
            .filter(|p| !p.is_empty())
            .map(|p| p.to_string());
        let own_cwd = pwd.or_else(|| expand_title_path(&title));
        Some(RawPane { surface_id, pane_id, window_id, title, title_suggests_agent, own_cwd })
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
            // Map login → raw pane by matching the login's shell cwd against the
            // pane's title-derived path, or — for path-less Claude panes — by
            // pairing the login's claude-child cwd to the pane the agent_cwd_map
            // already associates. The old `tty_number == pane_id` heuristic was a
            // coincidence that mis-mapped sibling logins (all children of one trm
            // process, tty numbers unrelated to pane_id), so it's now a LAST
            // resort, applied only when nothing better claims the pane.
            let mut login_pane_ids: HashMap<u32, usize> = HashMap::new();

            // tty fallback (kept, but lowest priority — see loop below).
            for (&login_pid, tty) in &login_ttys {
                let suffix_str = tty.trim_start_matches(|c: char| !c.is_numeric());
                if let Ok(n) = suffix_str.parse::<usize>() {
                    if let Some(raw_idx) = raw.iter().position(|rp| rp.pane_id == n) {
                        login_pane_ids.insert(login_pid, raw_idx);
                    }
                }
            }

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

            // Match surfaces to logins by cwd↔shell_cwd.
            //
            // Two passes so a Claude pane and a sibling shell pane that share a
            // cwd (e.g. two `~/dev/fasmac` panes, one running the agent) don't
            // fight over the wrong login: Claude-bearing panes claim
            // Claude-bearing logins FIRST, then everything else fills in. This
            // is what makes routing robust now that `own_cwd` comes from trm's
            // authoritative `pwd` even for path-less "Claude Code" titles.
            let mut claimed_logins: HashSet<u32> = HashSet::new();
            let mut surface_to_login: HashMap<usize, usize> = HashMap::new(); // raw_idx → login_info idx

            let cwd_matches = |tp: &str, li: &LoginInfo| -> bool {
                let tp_clean = tp.trim_end_matches('/');
                let cwd_clean = li.shell_cwd.trim_end_matches('/');
                if tp_clean.starts_with('…') {
                    let suffix = &tp_clean[tp_clean.char_indices().nth(1).map(|(i, _)| i).unwrap_or(1)..];
                    cwd_clean.ends_with(suffix)
                } else {
                    cwd_clean == tp_clean || cwd_clean.starts_with(&format!("{}/", tp_clean))
                }
            };

            // (require_claude_login, only_agent_panes)
            for &(require_claude, agent_panes_only) in &[(true, true), (false, false)] {
                for (raw_idx, rp) in raw.iter().enumerate() {
                    if surface_to_login.contains_key(&raw_idx) { continue; }
                    if agent_panes_only && !rp.title_suggests_agent { continue; }
                    let Some(ref tp) = rp.own_cwd else { continue };
                    let matched = login_infos.iter().enumerate().find(|(_, li)| {
                        if claimed_logins.contains(&li.login_pid) { return false; }
                        if require_claude && !li.has_claude_child { return false; }
                        cwd_matches(tp, li)
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
                .filter(|(i, rp)| rp.title_suggests_agent && rp.own_cwd.is_none() && !surface_to_login.contains_key(i))
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
        if !rp.title_suggests_agent || rp.own_cwd.is_some() || login_resolved_cwds[i].is_some() {
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
        let RawPane { surface_id, pane_id, title, title_suggests_agent: _, own_cwd, .. } = rp;
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

        // `has_claude` is authoritative and must rest on actual process
        // evidence — never on the terminal title alone (titles go stale and a
        // project dir named `codex`/`gemini` substring-matches the heuristic).
        //
        // The only sound signal is login→shell→process resolution finding an
        // *agent child* of this pane's own shell. `login_resolved_agents[i]`
        // is set exactly in that case (unlike `login_resolved_pids`, which is
        // also set for plain path-bearing shells with no agent child).
        //
        // A cwd match against a live agent process is deliberately NOT used
        // here: it cannot tell which of several panes sharing one project
        // directory is the real agent, so it flags every co-located shell
        // (e.g. an editor pane next to a Claude pane in the same repo). The
        // title heuristic survives only as the pass-1 prefilter that decided
        // whether login resolution was attempted at all.
        let has_claude = login_resolved_agents[i].is_some();

        // Determine agent display name. Prefer the login-resolved name (ground
        // truth from the process tree); fall back to a cwd match, then the
        // terminal title. These fallbacks are display-only and never affect
        // `has_claude` — a non-agent pane stays out of the agent column.
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

    if let Some((sid, how)) =
        pick_pane_for_login(&panes, target_login, effective_cwd, &surface_to_login)
    {
        tracing::info!("resolve_trm_pane_for_pid: pid {} → {} ({})", target_pid, sid, how);
        return Some(sid);
    }

    tracing::warn!(
        "resolve_trm_pane_for_pid: pid {} — no match (login={}, cwd={}, claimed={:?})",
        target_pid, target_login, effective_cwd, claimed_logins
    );
    None
}

/// Pure pane-selection ladder, factored out of `resolve_trm_pane_for_pid` so it
/// can be unit-tested without spawning `ps`/`lsof`/`trm`. Given the discovered
/// panes and a channel's resolved trm login PID, return the surface id
/// (`trm:<pane_id>`) of the pane that owns the channel, plus a short tag naming
/// which rule matched (for log breadcrumbs).
///
/// Priority — login PID first, by design:
///   1. login PID — a 1:1 identifier for a pane. Authoritative even when
///      several panes share one cwd (a Claude pane + sibling shell panes in the
///      same repo). This is the regression fix: the cwd-based rules below are
///      ambiguous there and would map a shell pane's channel onto the Claude
///      pane's surface key, stealing the route so app flushes land on the wrong
///      (or a Claude-less) pane.
///   2. title↔cwd surface match (`surface_to_login`) — for panes the login walk
///      couldn't place but whose title path matched a login's shell cwd.
///   3. exact pane cwd — last-resort match against a has_claude pane.
fn pick_pane_for_login(
    panes: &[TrmPane],
    target_login: u32,
    effective_cwd: &str,
    surface_to_login: &HashMap<usize, u32>,
) -> Option<(String, &'static str)> {
    // 1. Login PID — see the rationale above.
    if let Some(pane) = panes.iter().find(|p| p.login_pid == Some(target_login)) {
        return Some((format!("trm:{}", pane.pane_id), "login pid"));
    }

    // 2. title↔cwd surface match.
    if let Some((&raw_idx, _)) = surface_to_login.iter().find(|(_, &lp)| lp == target_login) {
        if let Some(pane) = panes.get(raw_idx) {
            return Some((format!("trm:{}", pane.pane_id), "title↔cwd"));
        }
    }

    // 3. Exact pane cwd against a has_claude pane.
    let effective_clean = effective_cwd.trim_end_matches('/');
    if let Some(pane) = panes.iter().find(|p| {
        p.has_claude
            && p.cwd.as_deref()
                .map(|c| c.trim_end_matches('/') == effective_clean)
                .unwrap_or(false)
    }) {
        return Some((format!("trm:{}", pane.pane_id), "pane cwd exact"));
    }

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

/// Ask trm's `auto-tunnel` extension to make a peer's port reachable as
/// localhost, and open it.
///
/// Same envelope and the same shape as [`trm_rpc`] — a different socket is the
/// only difference, because the tunnel manager is an extension rather than trm
/// itself. Kept as a sibling rather than a parameter on `trm_rpc` so the two
/// sockets cannot be confused at a call site.
///
/// **Why flan is the one asking.** An app discovered on a PEER is not on this
/// machine, so a browser here cannot reach it — and for a Flutter debug build
/// it does not merely fail, it kills the server: DWDS dies on a remote browser
/// connection (`Bad state: No element` in `DebugService._wrapHandler`) and
/// takes `flutter run` with it. flan is the only thing that knows an app is
/// remote, so flan is what asks.
///
/// `None` means the extension is not installed or not running. That is not an
/// error and must not be treated as one: discovery still works and the remote
/// URL still prints, the browser is simply not opened for you.
pub fn tunnel_rpc(method: &str, params: serde_json::Value) -> Option<serde_json::Value> {
    use std::os::unix::net::UnixStream;

    let socket = std::env::var("TRM_TUNNEL_SOCKET")
        .unwrap_or_else(|_| "/tmp/trm-tunnel.sock".to_string());
    let mut stream = UnixStream::connect(&socket).ok()?;
    // Longer than trm_rpc's 5s: this one waits on an ssh handshake to another
    // machine, not on a local window manager.
    stream.set_read_timeout(Some(Duration::from_secs(20))).ok()?;

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

#[cfg(test)]
mod web_identity_tests {
    use super::*;

    #[test]
    fn extract_web_port_both_forms() {
        assert_eq!(extract_web_port("dart flutter run -d chrome --web-port 5005 --foo"), Some(5005));
        assert_eq!(extract_web_port("flutter run --web-port=3001 -d chrome"), Some(3001));
        assert_eq!(extract_web_port("flutter run -d chrome"), None);
    }

    #[test]
    fn extract_flan_app_id_both_forms() {
        assert_eq!(
            extract_flan_app_id(
                "flutter run --dart-define=FLAN_APP_ID=worktree-003",
            ),
            Some("worktree-003".into()),
        );
        assert_eq!(
            extract_flan_app_id(
                "flutter run --dart-define FLAN_APP_ID=fasmac:feature-a",
            ),
            Some("fasmac:feature-a".into()),
        );
        assert_eq!(extract_flan_app_id("flutter run -d chrome"), None);
    }

    #[test]
    fn parse_origin_port_variants() {
        assert_eq!(parse_origin_port("http://localhost:5005"), Some(5005));
        assert_eq!(parse_origin_port("http://127.0.0.1:3001/"), Some(3001));
        assert_eq!(parse_origin_port("http://localhost"), None); // no explicit port
        assert_eq!(parse_origin_port("https://example.com:8080/path"), Some(8080));
    }

    #[test]
    fn parse_origin_host_names_the_machine() {
        assert_eq!(
            parse_origin_host("http://m1.follow-ionian.ts.net:5105").as_deref(),
            Some("m1.follow-ionian.ts.net")
        );
        assert_eq!(
            parse_origin_host("https://example.com/path").as_deref(),
            Some("example.com")
        );
        // Loopback names no machine worth showing: the row falls back to this
        // host's own name rather than printing "localhost" on every line.
        assert_eq!(parse_origin_host("http://localhost:5005"), None);
        assert_eq!(parse_origin_host("http://127.0.0.1:3001/"), None);
        assert_eq!(parse_origin_host("http://[::1]:8080"), None);
    }

    #[test]
    fn remote_app_carries_the_host_it_flushed_from() {
        let app = remote_app("fasmac:worktree-002", Some("http://m1.follow-ionian.ts.net:5105"));
        assert_eq!(app.host.as_deref(), Some("m1.follow-ionian.ts.net"));
        assert_eq!(app.web_port, Some(5105));
        // A local origin leaves it unset, so the TUI shows this machine.
        let here = remote_app("fasmac:worktree-168", Some("http://localhost:7305"));
        assert_eq!(here.host, None);
        assert_eq!(here.web_port, Some(7305));
    }
}

#[cfg(test)]
mod channel_relay_tests {
    use super::*;
    use std::net::TcpListener;
    use std::thread;

    #[test]
    fn cwd_channel_matches_a_flutter_subdirectory() {
        let ports = HashMap::from([
            ("/workspace/fasmac".to_string(), 43123),
            ("/workspace/fasmac/frontend".to_string(), 43124),
        ]);

        assert_eq!(
            channel_port_for_cwd(&ports, "/workspace/fasmac/frontend"),
            Some(43124),
        );
        assert_eq!(
            channel_port_for_cwd(&ports, "/workspace/other/frontend"),
            None,
        );
    }

    #[test]
    fn codex_thread_is_read_off_the_rollout_filename() {
        let path = "/Users/g/.codex/sessions/2026/09/07/\
                    rollout-2026-09-07T21-29-32-01a07f47-471e-7122-a0e9-8efe01dd2268.jsonl";
        assert_eq!(
            codex_thread_from_rollout_path(path).as_deref(),
            Some("01a07f47-471e-7122-a0e9-8efe01dd2268"),
        );
        // Not a rollout, not a jsonl, or no uuid at the end: nothing.
        assert_eq!(codex_thread_from_rollout_path("/Users/g/.codex/history.jsonl"), None);
        assert_eq!(codex_thread_from_rollout_path("/tmp/rollout-2026-09-07T21-29-32.jsonl"), None);
        assert_eq!(
            codex_thread_from_rollout_path("/tmp/rollout-x-01a07f47-471e-7122-a0e9-8efe01dd2268.log"),
            None,
        );
    }

    #[test]
    fn base64_decodes_plain_and_data_uri_forms() {
        assert_eq!(decode_base64("aGVsbG8=").unwrap(), b"hello");
        assert_eq!(decode_base64("aGVsbG8").unwrap(), b"hello");
        assert_eq!(decode_base64("data:image/png;base64,aGVs\nbG8=").unwrap(), b"hello");
        assert_eq!(decode_base64("aGV$bG8="), None);
    }

    #[test]
    fn codex_message_carries_uri_context_and_batch_fields() {
        let messages = vec![
            serde_json::json!({
                "text": "the button is misaligned",
                "type": "user_feedback",
                "timestamp": "2026-09-07T22:00:00Z",
                "data": {
                    "url": "/settings/profile",
                    "currentRoute": "profile",
                    "inspectorSelection": {
                        "widgetType": "ElevatedButton",
                        "sourceLocation": "lib/profile.dart:42",
                    },
                    "annotations": [{"kind": "arrow"}],
                },
            }),
            serde_json::json!({"text": "second", "type": "note"}),
        ];
        let (text, images) =
            format_codex_message(&messages, Some("ws://127.0.0.1:1234/abc=/ws"), Some(4321));
        assert!(images.is_empty());
        assert!(text.starts_with("[flan] Message from the linked Flutter app"));
        assert!(text.contains("vm_service_uri: ws://127.0.0.1:1234/abc=/ws"));
        assert!(text.contains("flutter_pid: 4321"));
        assert!(text.contains("--- message 1 of 2 ---"));
        assert!(text.contains("[2026-09-07T22:00:00Z]\nthe button is misaligned"));
        // user_feedback is the default kind and isn't labelled; others are.
        assert!(!text.contains("type: user_feedback"));
        assert!(text.contains("type: note\nsecond"));
        assert!(text.contains("URL: /settings/profile"));
        assert!(text.contains("Current route: profile"));
        assert!(text.contains("  Widget type: ElevatedButton"));
        assert!(text.contains("  Source: lib/profile.dart:42"));
        assert!(text.contains(r#"Annotations: [{"kind":"arrow"}]"#));
    }

    #[test]
    fn codex_target_resolution_ignores_non_process_ids() {
        assert_eq!(codex_pid_for_target("cwd-route"), None);
        assert_eq!(codex_pid_for_target("chan:60999"), None);
        assert_eq!(codex_pid_for_target("sess:unknown"), None);
        // Our own pid is a test binary, not Codex.
        assert_eq!(codex_pid_for_target(&format!("sess:{}", std::process::id())), None);
    }

    #[test]
    fn relay_preserves_unsupported_client_error() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            stream.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
            let mut request = [0_u8; 4096];
            stream.read(&mut request).unwrap();
            let body = r#"{"ok":false,"accepted":false,"delivered":false,"error":"Codex must use process_queue"}"#;
            let response = format!(
                "HTTP/1.1 409 Conflict\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                body.len(), body,
            );
            stream.write_all(response.as_bytes()).unwrap();
        });
        let error = relay_channel_flush(port, r#"{"messages":[{"text":"hello"}]}"#)
            .unwrap_err();
        assert_eq!(error, "Codex must use process_queue");
        server.join().unwrap();
    }

    #[test]
    fn relay_accepts_chunked_queued_response() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            stream
                .set_read_timeout(Some(Duration::from_secs(2)))
                .unwrap();
            let mut request = [0_u8; 4096];
            let bytes_read = stream.read(&mut request).unwrap();
            let request = String::from_utf8_lossy(&request[..bytes_read]);
            assert!(request.starts_with("POST /flush HTTP/1.1"));
            assert!(request.contains("\"text\":\"hello\""));

            let body = r#"{"ok":true,"accepted":true,"delivered":false}"#;
            let response = format!(
                "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n{:x}\r\n{}\r\n0\r\n\r\n",
                body.len(),
                body,
            );
            stream.write_all(response.as_bytes()).unwrap();
        });

        let outcome = relay_channel_flush(
            port,
            r#"{"messages":[{"text":"hello"}]}"#,
        )
        .unwrap();

        assert_eq!(
            outcome,
            ChannelRelayOutcome {
                accepted: true,
                delivered: false,
            },
        );
        server.join().unwrap();
    }
}

#[cfg(test)]
mod pane_routing_tests {
    use super::*;

    fn pane(pane_id: usize, login_pid: u32, cwd: &str, has_claude: bool) -> TrmPane {
        TrmPane {
            index: pane_id,
            pane_id,
            folder_name: None,
            cwd: Some(cwd.to_string()),
            has_claude,
            agent_name: None,
            surface_id: None,
            title: None,
            channel_port: None,
            login_pid: Some(login_pid),
            has_dev_channels: false,
        }
    }

    // The regression: four panes share one cwd — a Claude pane plus sibling
    // shell panes opened in the same repo. The cwd-only rule can't tell them
    // apart, so resolving a channel by cwd could map a shell pane's channel onto
    // the Claude pane's surface key, stealing the route. Anchoring on the login
    // PID resolves each channel to the pane it actually runs in.
    #[test]
    fn shared_cwd_resolves_by_login_not_cwd() {
        let repo = "/Users/gaurav/dev/fasmac";
        let panes = vec![
            pane(0, 44111, repo, true),   // the Claude pane
            pane(20, 43392, repo, false), // sibling shell
            pane(28, 43399, repo, false), // sibling shell (was stealing trm:0)
        ];
        let surface_to_login = HashMap::new();

        // The shell pane's channel must resolve to its OWN pane, not the Claude
        // pane — this is the exact mis-route that sent app flushes nowhere.
        let (sid, how) = pick_pane_for_login(&panes, 43399, repo, &surface_to_login).unwrap();
        assert_eq!(sid, "trm:28");
        assert_eq!(how, "login pid");

        // And the Claude pane's channel resolves to the Claude pane.
        let (sid, _) = pick_pane_for_login(&panes, 44111, repo, &surface_to_login).unwrap();
        assert_eq!(sid, "trm:0");
    }

    // When the login walk couldn't place the pane (no login_pid match), fall
    // back to the title↔cwd surface map, then to an exact has_claude cwd match.
    #[test]
    fn falls_back_when_login_absent() {
        let repo = "/Users/gaurav/dev/tow";
        let panes = vec![
            pane(14, 44112, repo, true),
            pane(16, 43395, "/Users/gaurav/dev/tow/dispatch", false),
        ];

        // Unknown login → title↔cwd surface map points raw index 0 at it.
        let mut surface_to_login = HashMap::new();
        surface_to_login.insert(0usize, 99999u32);
        let (sid, how) = pick_pane_for_login(&panes, 99999, repo, &surface_to_login).unwrap();
        assert_eq!(sid, "trm:14");
        assert_eq!(how, "title↔cwd");

        // No login, no surface entry → exact has_claude cwd match (trailing
        // slash tolerated).
        let empty = HashMap::new();
        let (sid, how) =
            pick_pane_for_login(&panes, 99999, "/Users/gaurav/dev/tow/", &empty).unwrap();
        assert_eq!(sid, "trm:14");
        assert_eq!(how, "pane cwd exact");
    }

    // A shell-only repo (no has_claude pane) and an unmatched login resolves to
    // nothing rather than silently grabbing an unrelated pane.
    #[test]
    fn no_match_returns_none() {
        let panes = vec![pane(5, 12345, "/Users/gaurav/dev/x", false)];
        let empty = HashMap::new();
        assert!(pick_pane_for_login(&panes, 67890, "/Users/gaurav/dev/y", &empty).is_none());
    }
}

#[cfg(test)]
mod channel_registry_tests {
    use super::*;

    fn reg(port: u16, agent_pid: Option<u32>) -> ChannelRegistration {
        ChannelRegistration {
            port,
            channel_pid: Some(port as u32 + 1),
            agent_pid,
            agent_name: Some("Claude".into()),
            tty: Some("ttys006".into()),
            cwd: Some("/repo".into()),
            surface_id: None,
        }
    }

    fn registry(entries: Vec<(u64, ChannelRegistration)>) -> HashMap<u16, (Instant, ChannelRegistration)> {
        entries
            .into_iter()
            .map(|(age_secs, r)| {
                let seen = Instant::now()
                    .checked_sub(Duration::from_secs(age_secs))
                    .expect("test clock underflow");
                (r.port, (seen, r))
            })
            .collect()
    }

    fn session(port: Option<u16>, agent_pid: Option<u32>, cwd: &str) -> AgentSession {
        AgentSession {
            session_id: agent_pid.map(|p| format!("session-{p}")),
            agent_pid,
            agent_name: Some("Claude".into()),
            session_name: Some("repo-01".into()),
            status: Some("idle".into()),
            tty: Some("ttys006".into()),
            cwd: Some(cwd.into()),
            branch: Some("main".into()),
            worktree: None,
            summary: None,
            artifacts: Vec::new(),
            channel_port: port,
            channel_pid: None,
            surface_id: None,
            age_secs: 0,
        }
    }

    #[test]
    fn a_dead_agent_stops_being_a_link_target_immediately() {
        // pid 1 is always alive; the dead one heartbeat a moment ago, so only
        // the liveness check can catch it.
        let mut channels = registry(vec![(1, reg(60365, Some(1))), (1, reg(60604, Some(4242)))]);

        let live = prune_channels(&mut channels, |pid| pid == 1);

        assert_eq!(live.len(), 1);
        assert_eq!(live[0].1.port, 60365);
        assert!(!channels.contains_key(&60604), "dead agent must be evicted, not just hidden");
    }

    #[test]
    fn a_channel_that_stopped_heartbeating_is_dropped_even_if_the_pid_survives() {
        // Agent process still exists (a wedged session, or a pid reused) but
        // the channel has missed several 30s beats.
        let mut channels = registry(vec![(CHANNEL_TTL.as_secs() + 5, reg(60365, Some(1)))]);

        let live = prune_channels(&mut channels, |_| true);

        assert!(live.is_empty());
    }

    #[test]
    fn a_registration_with_no_resolvable_agent_survives_on_its_heartbeat() {
        // Headless agents we can't resolve a pid for still register; the
        // heartbeat is the only liveness signal available, so trust it.
        let mut channels = registry(vec![(10, reg(60365, None))]);

        let live = prune_channels(&mut channels, |_| false);

        assert_eq!(live.len(), 1);
        assert_eq!(live[0].0, 10, "age should be reported for display");
    }

    /// The same channel seen twice — once by scanning, once by registration —
    /// is one agent, and the discovered row is the richer of the two.
    #[test]
    fn a_registration_for_an_already_discovered_session_does_not_duplicate_it() {
        let mut sessions = vec![session(Some(60365), Some(4242), "/repo")];

        merge_registrations(&mut sessions, vec![(3, reg(60365, Some(4242)))]);

        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].session_name.as_deref(), Some("repo-01"));
    }

    /// A registration discovery couldn't see must still produce a row —
    /// that's the only reason registration still exists.
    #[test]
    fn a_registration_discovery_missed_becomes_its_own_session() {
        let mut sessions = vec![session(Some(60365), Some(4242), "/repo")];

        merge_registrations(&mut sessions, vec![(3, reg(60999, Some(777)))]);

        assert_eq!(sessions.len(), 2);
        let added = sessions.iter().find(|s| s.channel_port == Some(60999)).unwrap();
        assert_eq!(added.agent_pid, Some(777));
        assert_eq!(added.age_secs, 3);
    }

    /// A session with no channel is listed, just not reachable — hiding it is
    /// what made half the running agents invisible.
    #[test]
    fn a_session_without_a_channel_is_still_a_session() {
        let mut sessions = vec![session(None, Some(4242), "/repo")];

        merge_registrations(&mut sessions, vec![]);

        assert_eq!(sessions.len(), 1);
        assert!(sessions[0].channel_port.is_none());
    }

    #[test]
    fn display_order_is_stable_across_refreshes() {
        let mut sessions = vec![
            session(None, Some(3), "/repo/b"),
            session(None, Some(1), "/repo/a"),
            session(None, Some(2), "/repo/a"),
        ];

        sort_sessions(&mut sessions);

        let pids: Vec<Option<u32>> = sessions.iter().map(|s| s.agent_pid).collect();
        assert_eq!(pids, vec![Some(1), Some(2), Some(3)]);
    }

    #[test]
    fn project_slug_replaces_every_separator_git_style() {
        // An underscore in the path silently broke transcript lookup before.
        assert_eq!(claude_project_slug("/Users/g/dev/flan_mcp"), "-Users-g-dev-flan-mcp");
        assert_eq!(
            claude_project_slug("/Users/g/dev/fasmac/.worktrees/feature/genui-a2ui"),
            "-Users-g-dev-fasmac--worktrees-feature-genui-a2ui"
        );
    }

    /// Artifact records are written once, early, in transcripts that grow to
    /// tens of megabytes — the case that ruled out reading only the tail.
    #[test]
    fn artifacts_and_title_are_picked_out_of_transcript_lines() {
        let mut index = TranscriptIndex::default();

        absorb_transcript(&mut index, concat!(
            r#"{"type":"assistant","message":{"content":"noise"}}"#, "\n",
            r#"{"type":"frame-link","path":"/tmp/x/scratchpad/extracted-tree-panel.html","frameUrl":"https://claude.ai/code/artifact/abc","title":"Extracted Tree Panel"}"#, "\n",
            r#"{"type":"frame-link","path":"/tmp/x/scratchpad/cache-economics.html","frameUrl":"https://claude.ai/code/artifact/def","title":"Growth"}"#, "\n",
            r#"{"aiTitle":"Candidate stats view","type":"snapshot"}"#, "\n",
        ));

        assert_eq!(index.artifacts, vec!["extracted-tree-panel", "cache-economics"]);
        assert_eq!(index.summary().as_deref(), Some("Candidate stats view"));
    }

    /// The index is fed in chunks as the session appends to its transcript, so
    /// later reads must build on earlier ones rather than replace them.
    #[test]
    fn a_later_chunk_adds_to_what_earlier_chunks_found() {
        let mut index = TranscriptIndex::default();
        absorb_transcript(&mut index, concat!(
            r#"{"type":"frame-link","path":"/tmp/extraction-audit.html","frameUrl":"u1"}"#, "\n",
            r#"{"aiTitle":"First title"}"#, "\n",
        ));

        absorb_transcript(&mut index, concat!(
            r#"{"lastPrompt":"and now something else"}"#, "\n",
            r#"{"type":"frame-link","path":"/tmp/reasoning-tax.html","frameUrl":"u2"}"#, "\n",
        ));

        assert_eq!(index.artifacts, vec!["extraction-audit", "reasoning-tax"]);
        // A title already seen still wins over a newer prompt.
        assert_eq!(index.summary().as_deref(), Some("First title"));
    }

    /// Republishing the same artifact re-emits the record; it is one artifact.
    #[test]
    fn republishing_an_artifact_does_not_list_it_twice() {
        let mut index = TranscriptIndex::default();
        let line = concat!(r#"{"type":"frame-link","path":"/tmp/a/cache-economics.html","frameUrl":"u"}"#, "\n");

        absorb_transcript(&mut index, line);
        absorb_transcript(&mut index, line);

        assert_eq!(index.artifacts, vec!["cache-economics"]);
    }

    #[test]
    fn summaries_are_flattened_and_clipped() {
        assert_eq!(one_line("  keep   it   tidy \n now ", 40), "keep it tidy now");
        let long = "x".repeat(200);
        let clipped = one_line(&long, 20);
        assert_eq!(clipped.chars().count(), 20);
        assert!(clipped.ends_with('…'));
    }
}

#[cfg(test)]
mod remote_app_tests {
    use super::*;

    fn link(id: &str, pid: u32, cwd: Option<&str>, app_id: Option<&str>) -> Association {
        Association {
            id: id.into(),
            claude_surface_id: format!("sess:{pid}"),
            flutter_pid: pid,
            flutter_cwd: cwd.map(str::to_string),
            flutter_app_id: app_id.map(str::to_string),
        }
    }

    /// An app served statically, or running on another machine, never appears
    /// in `ps` — its FLAN_APP_ID is the only handle it has.
    #[test]
    fn an_app_with_no_local_process_is_matched_by_its_id() {
        let assocs = vec![link("1", 0, None, Some("fasmac:worktree-003"))];

        let found = resolve_association(&assocs, Some("fasmac:worktree-003"), None, None);

        assert_eq!(found.map(|a| a.claude_surface_id), Some("sess:0".to_string()));
    }

    /// Every app without a local process reports pid 0. Matching on that would
    /// hand one app's messages to whatever agent another app is linked to.
    #[test]
    fn pid_zero_never_matches_another_apps_link() {
        let assocs = vec![link("1", 0, None, Some("fasmac:worktree-003"))];

        let found = resolve_association(&assocs, Some("other:app"), Some(0), None);

        assert!(found.is_none());
    }

    /// A rebuilt app keeps its id but gets a new pid; the link must follow.
    #[test]
    fn the_id_wins_over_a_stale_pid_match() {
        let assocs = vec![
            link("1", 16595, Some("/repo/frontend"), Some("fasmac:worktree-003")),
            link("2", 30007, Some("/repo/other"), Some("fasmac:worktree-009")),
        ];

        let found = resolve_association(
            &assocs,
            Some("fasmac:worktree-009"),
            Some(16595),
            Some("/repo/frontend"),
        );

        assert_eq!(found.map(|a| a.id), Some("2".to_string()));
    }

    #[test]
    fn without_an_id_it_falls_back_to_pid_then_cwd() {
        let assocs = vec![link("1", 16595, Some("/repo/frontend"), None)];

        let by_pid = resolve_association(&assocs, None, Some(16595), None);
        let by_cwd = resolve_association(&assocs, None, Some(99999), Some("/repo/frontend"));
        let no_match = resolve_association(&assocs, None, Some(99999), Some("/elsewhere"));

        assert_eq!(by_pid.map(|a| a.id), Some("1".to_string()));
        assert_eq!(by_cwd.map(|a| a.id), Some("1".to_string()));
        assert!(no_match.is_none());
    }

    /// A local process is the better row — it has a pid, a cwd and a VM
    /// service — so a remote sighting of the same app must not duplicate it.
    #[test]
    fn a_remote_sighting_of_a_local_app_does_not_duplicate_it() {
        let mut apps = vec![FlutterApp {
            pid: 16595,
            cwd: "/repo/frontend".into(),
            folder_name: "frontend".into(),
            vm_service_uri: None,
            device: Some("web-server".into()),
            queue_count: 0,
            connected: false,
            web_port: Some(5305),
            app_id: Some("fasmac:worktree-003".into()),
            host: None,
        }];

        merge_remote_apps(
            &mut apps,
            vec![
                remote_app("fasmac:worktree-003", Some("http://host:5305")),
                remote_app("fasmac:worktree-009", Some("http://host:5309")),
            ],
        );

        assert_eq!(apps.len(), 2);
        assert_eq!(apps[0].pid, 16595, "the local row must survive");
        assert_eq!(apps[1].app_id.as_deref(), Some("fasmac:worktree-009"));
        assert_eq!(apps[1].folder_name, "worktree-009");
        assert_eq!(apps[1].web_port, Some(5309));
    }

    fn peer_app(app_id: &str, port: u16, host: &str) -> FlutterApp {
        FlutterApp {
            pid: 60027,
            cwd: format!("/home/g/ci/fasmac/{app_id}"),
            folder_name: "frontend".into(),
            vm_service_uri: None,
            device: Some("web-server".into()),
            queue_count: 0,
            connected: false,
            web_port: Some(port),
            app_id: Some(app_id.into()),
            host: Some(host.into()),
        }
    }

    fn local_app(app_id: Option<&str>, port: u16) -> FlutterApp {
        FlutterApp {
            pid: 28719,
            cwd: "/Users/g/dev/fasmac/frontend".into(),
            folder_name: "frontend".into(),
            vm_service_uri: None,
            device: Some("web-server".into()),
            queue_count: 0,
            connected: false,
            web_port: Some(port),
            app_id: app_id.map(str::to_owned),
            host: None,
        }
    }

    /// The bug this whole path exists for: `--web-port 5005` on the build host
    /// and 5005 here are two apps, and the build host's one used to vanish.
    #[test]
    fn an_app_on_a_peer_survives_a_local_app_on_the_same_port() {
        let mut apps = vec![local_app(Some("fasmac:worktree-003"), 5005)];

        merge_peer_apps(
            &mut apps,
            vec![peer_app("fasmac:worktree-001", 5005, "m1.follow-ionian.ts.net")],
        );

        assert_eq!(apps.len(), 2, "same port on two hosts is two apps");
        assert_eq!(apps[1].app_id.as_deref(), Some("fasmac:worktree-001"));
        assert_eq!(apps[1].host.as_deref(), Some("m1.follow-ionian.ts.net"));
    }

    /// Same hazard, reached through the registry rather than a peer.
    #[test]
    fn a_remote_sighting_is_not_hidden_by_a_local_app_on_the_same_port() {
        let mut apps = vec![local_app(Some("fasmac:worktree-003"), 5005)];

        merge_remote_apps(
            &mut apps,
            vec![remote_app("fasmac:worktree-001", Some("http://m1.example:5005"))],
        );

        assert_eq!(apps.len(), 2);
        assert_eq!(apps[1].app_id.as_deref(), Some("fasmac:worktree-001"));
    }

    /// A static app and its own flush stub share a port AND a (blank) host, so
    /// port-as-identity must keep working for the case it was written for.
    #[test]
    fn a_local_static_app_still_absorbs_its_own_flush_stub() {
        let mut apps = vec![local_app(None, 7305)];

        merge_remote_apps(
            &mut apps,
            vec![remote_app("fasmac:worktree-168", Some("http://localhost:7305"))],
        );

        assert_eq!(apps.len(), 1, "one app seen from two sides is one row");
        assert_eq!(apps[0].pid, 28719);
    }

    /// The reason peers are merged before the registry: the peer knows the pid,
    /// the cwd and the device; the stub knows only the id it flushed with.
    #[test]
    fn a_peer_row_wins_over_the_stub_the_same_app_left_behind() {
        let mut apps = vec![peer_app("fasmac:worktree-002", 5105, "m1.example")];

        merge_remote_apps(
            &mut apps,
            vec![remote_app("fasmac:worktree-002", Some("http://m1.example:5105"))],
        );

        assert_eq!(apps.len(), 1);
        assert_eq!(apps[0].pid, 60027, "the row with a pid and a cwd must win");
        assert!(!apps[0].cwd.is_empty());
    }

    /// Two peers, two rows, even when neither carries an app_id.
    #[test]
    fn peers_on_different_hosts_do_not_collapse_without_an_app_id() {
        let mut apps = Vec::new();
        let mut a = peer_app("x", 5005, "m1.example");
        a.app_id = None;
        let mut b = peer_app("y", 5005, "laptop.example");
        b.app_id = None;

        merge_peer_apps(&mut apps, vec![a, b]);

        assert_eq!(apps.len(), 2);
    }

    #[test]
    fn a_peer_is_written_however_the_user_reaches_it() {
        assert_eq!(normalize_peer("m1"), Some("http://m1:4050".into()));
        assert_eq!(normalize_peer(" m1:4050 "), Some("http://m1:4050".into()));
        assert_eq!(
            normalize_peer("http://m1.follow-ionian.ts.net:4050/"),
            Some("http://m1.follow-ionian.ts.net:4050".into())
        );
        // A path is not part of a peer's address.
        assert_eq!(
            normalize_peer("http://m1:4050/api/flutter-apps"),
            Some("http://m1:4050".into())
        );
        assert_eq!(normalize_peer("https://m1:443"), Some("https://m1:443".into()));
        assert_eq!(normalize_peer(""), None);
        assert_eq!(normalize_peer("   "), None);
        assert_eq!(normalize_peer("http://"), None);
    }

    #[test]
    fn a_peer_list_skips_junk_rather_than_failing() {
        assert_eq!(
            parse_peer_list("m1, , http://laptop:4050/,"),
            vec!["http://m1:4050".to_string(), "http://laptop:4050".to_string()]
        );
    }

    #[test]
    fn a_peers_port_is_not_mistaken_for_part_of_its_host() {
        assert_eq!(peer_host("http://m1:4050"), Some("m1".into()));
        assert_eq!(
            peer_host("http://m1.follow-ionian.ts.net:4050"),
            Some("m1.follow-ionian.ts.net".into())
        );
        assert_eq!(peer_host("http://[::1]:4050"), Some("[::1]".into()));
    }

    /// The peer cache is process-global, so this walks the whole lifecycle in
    /// one test rather than racing three against each other.
    #[test]
    fn a_peers_reachability_is_reported_not_guessed_at() {
        let quiet = "http://unreachable-test-host:4050";
        let flaky = "http://flaky-test-host:4050";
        let state_of = |peer: &str| peer_states().into_iter().find(|s| s.peer == peer);

        // A peer that has never answered must still be REPORTED. If the record
        // vanished, the TUI could not tell "that machine is running nothing"
        // from "I never got an answer" — the confusion this caused once already.
        assert!(remember_peer_result(quiet, None).is_empty());
        let s = state_of(quiet).expect("an unreachable peer must still be reported");
        assert!(!s.reachable);
        assert_eq!(s.app_count, 0);
        assert_eq!(s.last_ok_secs, None, "it has never answered");

        // A single dropped request must not blink a known app out of the list,
        // but it is still a failure and must be said so.
        remember_peer_result(flaky, Some(vec![peer_app("fasmac:worktree-001", 5005, "flaky")]));
        assert!(state_of(flaky).unwrap().reachable);
        let during_blip = remember_peer_result(flaky, None);
        assert_eq!(during_blip.len(), 1, "a blip must not drop a known app");
        let s = state_of(flaky).unwrap();
        assert!(!s.reachable, "the blip is still a failure");
        assert!(s.last_ok_secs.is_some(), "it answered a moment ago");

        // A tick in which neither peer is configured any more.
        discover_peer_apps(&[]);
        assert!(
            state_of(quiet).is_none() && state_of(flaky).is_none(),
            "an unconfigured peer must not keep warning"
        );
    }

    /// Two servers listing each other must not bounce one message forever.
    #[test]
    fn a_relayed_flush_is_stamped_so_it_is_never_relayed_on() {
        let body = serde_json::json!({
            "app_id": "fasmac:worktree-003",
            "origin": "http://m1.follow-ionian.ts.net:5205",
            "messages": [{"text": "hello"}],
        });

        let stamped: serde_json::Value =
            serde_json::from_str(&mark_relayed(&body).expect("payload must serialize")).unwrap();

        assert_eq!(stamped["relayed_from"], serde_json::json!(local_hostname()));
        // Everything the app sent has to survive the hop untouched.
        assert_eq!(stamped["app_id"], "fasmac:worktree-003");
        assert_eq!(stamped["messages"][0]["text"], "hello");
    }

    /// A payload that isn't a JSON object has no field to stamp, and relaying it
    /// unstamped would be the loop this guard exists to prevent.
    #[test]
    fn an_unstampable_payload_is_refused_rather_than_relayed_bare() {
        assert!(mark_relayed(&serde_json::json!(["not", "an", "object"])).is_none());
    }

    #[tokio::test]
    async fn with_no_peers_there_is_nothing_to_relay_to() {
        let body = serde_json::json!({"app_id": "x"});
        assert!(relay_flush_to_peers(&body, &[]).await.is_none());
    }

    #[test]
    fn this_machine_is_not_its_own_peer() {
        assert!(is_self_peer("http://localhost:4050"));
        assert!(is_self_peer("http://127.0.0.1:4050"));
        assert!(is_self_peer("http://[::1]:4050"));
        // The short hostname and its tailnet FQDN name the same machine.
        let me = local_hostname();
        assert!(is_self_peer(&format!("http://{me}:4050")));
        assert!(is_self_peer(&format!("http://{me}.follow-ionian.ts.net:4050")));
        assert!(!is_self_peer("http://definitely-not-this-host:4050"));
    }
}

#[cfg(test)]
mod hot_reload_tests {
    use super::*;
    use std::net::TcpListener;
    use std::thread;
    use tungstenite::Message;

    /// The decisive property: SIGUSR1's default disposition is to KILL. A run
    /// that didn't install the handlers must never be signalled.
    #[test]
    fn only_a_resident_debug_run_is_signalled() {
        let debug = "/Users/g/flutter/bin/cache/dart-sdk/bin/dart \
                     /Users/g/flutter/bin/cache/flutter_tools.snapshot run -d macos";
        assert!(command_line_accepts_reload_signal(debug));

        for refused in [
            // No handlers: the device has no service protocol in release mode.
            "… flutter_tools.snapshot run --release -d macos",
            // No handlers: profile builds don't support restart.
            "… flutter_tools.snapshot run --profile -d macos",
            // No handlers: nothing stays resident to receive them.
            "… flutter_tools.snapshot run --no-resident -d macos",
            "… flutter_tools.snapshot run --trace-startup -d macos",
            // Not a `flutter run` at all — signalling this kills somebody's app.
            "/Applications/MyApp.app/Contents/MacOS/MyApp",
            "… flutter_tools.snapshot test",
        ] {
            assert!(
                !command_line_accepts_reload_signal(refused),
                "should refuse to signal: {refused}"
            );
        }
    }

    #[test]
    fn a_host_that_is_not_a_peer_cannot_be_asked() {
        let outcome = hot_reload_on_peer("no-such-host.invalid", 1234, None, false);
        assert!(!outcome.ok);
        assert!(
            outcome.detail.contains("not a configured peer"),
            "got: {}",
            outcome.detail
        );
    }

    fn web_app(device: &str, port: u16) -> FlutterApp {
        FlutterApp {
            pid: 0,
            cwd: "/Users/g/dev/pe/app_next".into(),
            folder_name: "app_next".into(),
            vm_service_uri: None,
            device: Some(device.into()),
            queue_count: 0,
            connected: false,
            web_port: Some(port),
            app_id: None,
            host: None,
        }
    }

    /// The report that sent somebody hunting for a bug in flan: a `flutter build
    /// web` behind `python3 -m http.server` has no compiler anywhere near it, and
    /// "no signalable `flutter run` here (pid 0)" reads as a failure to find one.
    #[test]
    fn a_static_bundle_is_told_why_it_cannot_reload() {
        let outcome = hot_reload_app(&web_app("static", 8087), false);

        assert!(!outcome.ok);
        assert!(outcome.detail.contains("app_next"), "{}", outcome.detail);
        assert!(outcome.detail.contains(":8087"), "{}", outcome.detail);
        assert!(
            outcome.detail.contains("flutter run"),
            "it has to say what to do instead: {}",
            outcome.detail
        );

        // A watched plain dev server is the same story.
        assert!(unreloadable_reason(&web_app("web:3000", 3000)).is_some());
    }

    /// A real `flutter run` that merely can't be reached must NOT be explained
    /// away as unreloadable — that is the case where something is wrong.
    #[test]
    fn a_real_run_keeps_its_own_failure() {
        let mut app = web_app("chrome", 5005);
        app.pid = 999_999; // long gone
        assert_eq!(unreloadable_reason(&app), None);
        assert!(hot_reload_app(&app, false).detail.contains("pid 999999"));
    }

    /// A relayed reload has to carry the stamp, or the peer relays it back and
    /// the two servers bounce it between them.
    #[test]
    fn a_relayed_reload_is_stamped_and_its_verdict_carried_back() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            stream
                .set_read_timeout(Some(Duration::from_secs(2)))
                .unwrap();
            let mut buffer = [0_u8; 4096];
            let read = stream.read(&mut buffer).unwrap();
            let request = String::from_utf8_lossy(&buffer[..read]).to_string();

            let body = r#"{"ok":true,"via":"signal","detail":"Hot reload requested — SIGUSR1 → pid 77"}"#;
            let response = format!(
                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                body.len(),
                body,
            );
            stream.write_all(response.as_bytes()).unwrap();
            request
        });

        let outcome =
            hot_reload_via_peer(&format!("http://127.0.0.1:{port}"), "m1", 77, None, false);
        let request = server.join().unwrap();

        assert!(request.starts_with("POST /api/hot-reload HTTP/1.1"), "{request}");
        assert!(
            request.contains(&format!("\"relayed_from\":\"{}\"", local_hostname())),
            "{request}"
        );
        assert!(outcome.ok);
        // The peer's own account of how it did it, attributed to the peer.
        assert_eq!(outcome.via, "m1:signal");
        assert!(outcome.detail.contains("SIGUSR1"), "{}", outcome.detail);
    }

    /// Verbatim from the frontend that prompted this: a restart that compiled
    /// nothing and restarted nothing, while the app was told "requested".
    const FAILED_RESTART: &str = "\
Performing hot restart...                                       \r
lib/screens/settings/feature_requests_screen.dart:115:39: Error: The method 'withdraw' isn't defined for the type 'FeatureRequestsProvider'.
 - 'FeatureRequestsProvider' is from 'package:resume_parser_frontend/providers/feature_requests_provider.dart'.
Try correcting the name to the name of an existing method, or defining a method named 'withdraw'.
";

    /// The noise that surrounds it. None of this is a verdict, and reading
    /// "Error thrown by handler" as one would fail every reload on this app.
    const DWDS_NOISE: &str = "\
ERROR - 2026-10-03 15:55:57.034470
GET /
Error thrown by handler.
Bad state: No element
dart:core                                            _Array.first
";

    #[test]
    fn a_compile_failure_is_read_off_the_tools_own_output() {
        match verdict_from_output(FAILED_RESTART) {
            ToolVerdict::Failed(line) => {
                assert!(line.contains("withdraw"), "{line}");
                assert!(line.starts_with("lib/screens"), "name the file: {line}");
            }
            other => panic!("expected a failure, got {other:?}"),
        }
    }

    #[test]
    fn a_finished_reload_or_restart_is_a_success() {
        assert_eq!(
            verdict_from_output("Performing hot restart...\r\nRestarted application in 223ms."),
            ToolVerdict::Done("Restarted application in 223ms.".into()),
        );
        assert_eq!(
            verdict_from_output("Reloaded 1 of 1482 libraries in 349ms."),
            ToolVerdict::Done("Reloaded 1 of 1482 libraries in 349ms.".into()),
        );
        // The web runner's wording, taken from a real frontend's log. It counts
        // no libraries, and requiring that word reported this as "requested".
        assert_eq!(
            verdict_from_output("Performing hot reload...   847ms\rReloaded application in 847ms."),
            ToolVerdict::Done("Reloaded application in 847ms.".into()),
        );
    }

    /// `flutter run -d web-server` with no Dart debug client: it compiles and
    /// the page never hears about it. "Requested" would be technically true and
    /// practically a lie — nothing happened.
    #[test]
    fn a_recompile_that_reached_no_client_is_not_a_success() {
        assert!(matches!(
            verdict_from_output(
                "Performing hot reload...\r\nRecompile complete. No client connected."
            ),
            ToolVerdict::Failed(line) if line.contains("No client connected"),
        ));
    }

    #[test]
    fn a_request_dropped_while_busy_is_not_a_success() {
        assert!(matches!(
            verdict_from_output("Ignoring signal: \"SIGUSR2\" because we are busy."),
            ToolVerdict::Failed(_)
        ));
    }

    /// Nothing recognisable means we say what we actually know, not that the
    /// reload failed.
    #[test]
    fn unrelated_output_is_no_verdict_at_all() {
        assert_eq!(verdict_from_output(DWDS_NOISE), ToolVerdict::Silent);
        assert_eq!(verdict_from_output(""), ToolVerdict::Silent);
    }

    /// `flutter run -d web-server` owns no browser, so a reload reaches the page
    /// only through a debug client. When there is none the code compiles and
    /// nothing changes on screen — and the app, which is the only thing that can
    /// refresh the page, needs to be told so in a field rather than by reading
    /// the prose.
    #[test]
    fn a_recompile_with_no_client_asks_the_app_to_refresh() {
        let log = std::env::temp_dir().join(format!("flan-noclient-{}.log", std::process::id()));
        std::fs::write(&log, "").unwrap();
        let verdict = verdict_from_output(
            "Performing hot reload...\r\nRecompile complete. No client connected.",
        );
        let _ = std::fs::remove_file(&log);

        let outcome = match verdict {
            ToolVerdict::Failed(line) => HotReloadOutcome {
                needs_page_refresh: line.contains("No client connected"),
                ok: false,
                via: "signal".into(),
                detail: line,
            },
            other => panic!("expected a failure, got {other:?}"),
        };
        assert!(outcome.needs_page_refresh);

        // A compile error is NOT a refresh: the page would come back on the
        // same old build and the user would think the reload worked.
        let compile_error = match verdict_from_output(FAILED_RESTART) {
            ToolVerdict::Failed(line) => line,
            other => panic!("expected a failure, got {other:?}"),
        };
        assert!(!compile_error.contains("No client connected"));
    }

    /// The case that prompted it: the tool takes the signal, prints that it is
    /// working, and then never finishes. "Requested" would hide exactly the
    /// fact that matters.
    #[test]
    fn work_that_starts_and_never_finishes_is_not_silence() {
        let log = std::env::temp_dir().join(format!("flan-pending-{}.log", std::process::id()));
        std::fs::write(&log, "").unwrap();
        std::fs::write(&log, "Performing hot reload...      10.1s\n").unwrap();

        assert_eq!(
            await_tool_verdict(&log, 0, Duration::from_millis(300)),
            ToolVerdict::Pending,
        );
        let _ = std::fs::remove_file(&log);
    }

    /// The offset is the whole reason this is trustworthy: a log full of
    /// earlier successes must not answer for the reload just asked for.
    #[test]
    fn only_what_was_printed_after_the_signal_counts() {
        let log = std::env::temp_dir().join(format!(
            "flan-verdict-{}-{:?}.log",
            std::process::id(),
            std::thread::current().id()
        ));
        std::fs::write(&log, "Restarted application in 10ms.\n").unwrap();
        let offset = std::fs::metadata(&log).unwrap().len();

        // Nothing new: the earlier success is not this reload's verdict.
        assert_eq!(
            await_tool_verdict(&log, offset, Duration::from_millis(300)),
            ToolVerdict::Silent,
        );

        // Appended a moment later, as a compile does.
        let appending = log.clone();
        let writer = thread::spawn(move || {
            thread::sleep(Duration::from_millis(200));
            let mut file = std::fs::OpenOptions::new()
                .append(true)
                .open(&appending)
                .unwrap();
            file.write_all(FAILED_RESTART.as_bytes()).unwrap();
        });
        let verdict = await_tool_verdict(&log, offset, Duration::from_secs(5));
        writer.join().unwrap();
        let _ = std::fs::remove_file(&log);

        assert!(
            matches!(verdict, ToolVerdict::Failed(line) if line.contains("withdraw")),
            "the new bytes are the verdict",
        );
    }

    /// Serve one /api/health response and return the port.
    fn fake_relay(body: &'static str) -> (u16, thread::JoinHandle<()>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            stream
                .set_read_timeout(Some(Duration::from_secs(2)))
                .unwrap();
            let mut buffer = [0_u8; 2048];
            let _ = stream.read(&mut buffer);
            let response = format!(
                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                body.len(),
                body,
            );
            stream.write_all(response.as_bytes()).unwrap();
        });
        (port, server)
    }

    /// Every relay built before this feature answers exactly `{"ok": true}` —
    /// which is the answer: it has none of the capabilities.
    #[test]
    fn a_relay_that_predates_the_feature_reports_as_stale() {
        let (port, server) = fake_relay(r#"{"ok":true}"#);
        let check = check_relay(&format!("http://127.0.0.1:{port}"));
        server.join().unwrap();

        assert!(check.reachable);
        assert!(check.is_stale());
        assert!(check.missing.contains(&"hot-reload".to_string()));
        assert!(check.summary().contains("missing"), "{}", check.summary());
    }

    #[test]
    fn a_relay_with_every_capability_is_not_stale() {
        let (port, server) = fake_relay(
            r#"{"ok":true,"version":"0.1.0+2026-10-05","features":["hot-reload","hot-restart","origin-match","reload-verdict"]}"#,
        );
        let check = check_relay(&format!("http://127.0.0.1:{port}"));
        server.join().unwrap();

        assert!(!check.is_stale(), "{}", check.summary());
        assert_eq!(check.version.as_deref(), Some("0.1.0+2026-10-05"));
    }

    /// A relay that isn't listening is not a stale relay — nothing to restart,
    /// and warning about it would cry wolf on every machine that is simply off.
    #[test]
    fn an_unreachable_relay_is_not_reported_as_stale() {
        let check = check_relay("http://127.0.0.1:1");
        assert!(!check.reachable);
        assert!(!check.is_stale());
    }

    /// Serve the handshake a real VM service performs, and answer the reload
    /// call with `answer`. Returns the port and the thread, which yields the
    /// reload request the client actually sent.
    fn fake_vm_service(
        answer: serde_json::Value,
    ) -> (u16, thread::JoinHandle<Option<serde_json::Value>>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let server = thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut ws = tungstenite::accept(stream).unwrap();
            let mut call: Option<serde_json::Value> = None;
            for _ in 0..3 {
                let Ok(Message::Text(text)) = ws.read() else {
                    break;
                };
                let request: serde_json::Value = serde_json::from_str(&text).unwrap();
                let id = request["id"].clone();
                let reply = match request["method"].as_str().unwrap_or("") {
                    "streamListen" => {
                        ws.send(Message::Text(
                            serde_json::json!({
                                "jsonrpc": "2.0", "id": id,
                                "result": {"type": "Success"},
                            })
                            .to_string()
                            .into(),
                        ))
                        .unwrap();
                        // What makes the whole thing work: the prefix is only
                        // knowable from this replayed registration.
                        serde_json::json!({
                            "jsonrpc": "2.0", "method": "streamNotify",
                            "params": {
                                "streamId": "_Service",
                                "event": {
                                    "kind": "ServiceRegistered",
                                    "service": "reloadSources",
                                    "method": "s7.reloadSources",
                                    "alias": "Flutter Tools",
                                },
                            },
                        })
                    }
                    "getVM" => serde_json::json!({
                        "jsonrpc": "2.0", "id": id,
                        "result": {"isolates": [{"id": "isolates/42"}]},
                    }),
                    _ => {
                        call = Some(request.clone());
                        let mut reply = answer.clone();
                        reply["id"] = id;
                        reply
                    }
                };
                ws.send(Message::Text(reply.to_string().into())).unwrap();
            }
            call
        });
        (port, server)
    }

    #[test]
    fn reload_invokes_the_prefixed_service_flutter_tools_registered() {
        let (port, server) = fake_vm_service(serde_json::json!({
            "jsonrpc": "2.0", "result": {"type": "Success"},
        }));

        hot_reload_via_vm_service(&format!("ws://127.0.0.1:{port}/ws"), false).unwrap();

        let call = server.join().unwrap().expect("a reload call");
        // Not the bare `reloadSources` RPC — that one has no compiler behind it.
        assert_eq!(call["method"], "s7.reloadSources");
        assert_eq!(call["params"]["isolateId"], "isolates/42");
    }

    /// The reason this path exists at all: the signal can't tell you the code
    /// didn't compile, and this can.
    #[test]
    fn a_compile_failure_comes_back_as_its_message() {
        let (port, server) = fake_vm_service(serde_json::json!({
            "jsonrpc": "2.0",
            "error": {"code": 1005, "message": "lib/main.dart:7:3: Error: Expected ';'"},
        }));

        let error =
            hot_reload_via_vm_service(&format!("ws://127.0.0.1:{port}/ws"), false).unwrap_err();

        assert!(error.contains("Expected ';'"), "got: {error}");
        server.join().unwrap();
    }
}
