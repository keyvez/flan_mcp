use crossterm::{
    event::{self, Event, KeyCode, KeyEvent, KeyModifiers},
    execute,
    terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen},
};
use std::fs::OpenOptions;
use flan_server::*;
use futures::StreamExt;
use ratatui::{
    layout::{Constraint, Layout, Rect},
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, List, ListItem, ListState, Paragraph},
    Frame, Terminal,
};
use std::{
    io,
    sync::Arc,
    time::{Duration, Instant},
};
use tokio::sync::mpsc;

// ── Colors (matching browser CSS variables) ─────────────────────────────

const BG: Color = Color::Rgb(10, 10, 15);
const SURFACE_BG: Color = Color::Rgb(18, 18, 26);
const BORDER: Color = Color::Rgb(42, 42, 58);
const TEXT: Color = Color::Rgb(224, 224, 232);
const TEXT2: Color = Color::Rgb(136, 136, 153);
const ACCENT: Color = Color::Rgb(108, 92, 231);
const ACCENT2: Color = Color::Rgb(162, 155, 254);
const GREEN: Color = Color::Rgb(0, 184, 148);
const ORANGE: Color = Color::Rgb(253, 203, 110);
const RED: Color = Color::Rgb(225, 112, 85);

const CONNECTOR: &str = "──────";

// ── Unified Row Model ───────────────────────────────────────────────────

struct Row {
    flutter: Option<usize>,
    /// Surface (agent) rendered in the right column on THIS row, if any.
    surface: Option<usize>,
    /// Surface (agent) this row's Flutter app is *linked* to. Usually equals
    /// `surface`, but when several apps share one agent the agent is rendered
    /// once (on the group's head row) and the other rows carry `link_si`
    /// pointing at that same surface so the connector column can draw an
    /// orthogonal bus joining them. `None` when the app isn't linked.
    link_si: Option<usize>,
    /// Whether this row's Flutter app has a LIVE agent connection (an agent has
    /// called `connect`), as opposed to a mere persisted association. The
    /// connector line is drawn only when this is true — an association alone is
    /// not enough.
    ///
    /// "Reachable" = the linked agent (surface) has a live flan-channel
    /// registered (a channel_port), so the app's messages can actually be
    /// delivered to it. We deliberately do NOT require the agent to have called
    /// the VM-service `connect` tool: the normal flow delivers messages over the
    /// channel and the agent never needs to VM-connect, so isHostConnected stays
    /// false even while the agent is actively handling the app's messages.
    connected: bool,
}

fn build_rows(app: &App) -> Vec<Row> {
    let entries = app.claude_entries();
    let entry_ids: Vec<String> = entries.iter().map(|e| e.id()).collect();
    let entry_cwds: Vec<Option<&str>> = entries.iter().map(|e| e.cwd()).collect();
    // An entry is "reachable" if it's a trm pane with a registered channel port.
    let entry_reachable: Vec<bool> = entries
        .iter()
        .map(|e| match e {
            ClaudeEntry::Trm(p) => p.channel_port.is_some(),
            // A session is reachable only if it has a flan-channel. Sessions
            // without one are listed but can't be messaged.
            ClaudeEntry::Session(a) => a.channel_port.is_some(),
            // cmux/cloud agents reachability isn't tracked on the synced
            // snapshot yet; trm panes and channels are the linkable agents in
            // practice.
            ClaudeEntry::Cmux(_) => false,
        })
        .collect();
    let flutter: Vec<(u32, &str)> = app
        .flutter_apps
        .iter()
        .map(|f| (f.pid, f.cwd.as_str()))
        .collect();
    build_rows_inner(&flutter, &entry_reachable, &entry_ids, &entry_cwds, &app.associations)
}

/// Pure core of `build_rows`, factored out so it can be unit-tested without an
/// `App`/`SharedState`. Pairs Flutter apps with Claude entries:
///   1. by explicit association (one app ↔ one agent),
///   2. then unlinked apps by cwd proximity,
///   3. then any remainder as single-sided rows.
///
/// INVARIANT: every Flutter app appears in exactly one row. A Flutter app must
/// never be silently dropped — e.g. when two apps are linked to the SAME agent,
/// the second can't claim that (already-used) surface, but it must still surface
/// as its own row rather than vanish from the list.
fn build_rows_inner(
    flutter: &[(u32, &str)],
    entry_reachable: &[bool],
    entry_ids: &[String],
    entry_cwds: &[Option<&str>],
    associations: &[Association],
) -> Vec<Row> {
    let mut used_flutter: Vec<bool> = vec![false; flutter.len()];
    let mut used_surface: Vec<bool> = vec![false; entry_ids.len()];
    let mut rows = Vec::new();

    // Linked pass. Group Flutter apps by the agent (surface) they link to, so
    // apps sharing one agent render as a contiguous block: the agent appears
    // once on the block's head row, and the remaining rows carry `link_si`
    // (but no `surface`) so the connector column can join them with an
    // orthogonal bus. Association order is preserved for the head of each group.
    for assoc in associations {
        let Some(fi) = flutter.iter().position(|(pid, _)| *pid == assoc.flutter_pid)
        else { continue };
        if used_flutter[fi] {
            continue; // app already placed (duplicate association for same pid)
        }
        let si = entry_ids.iter().position(|id| *id == assoc.claude_surface_id);

        match si {
            Some(si) => {
                if used_surface[si] {
                    // Agent already heads an existing group — append this app to
                    // that group as a linked (but agent-less) row. Insert it
                    // right after the group's existing members so the block stays
                    // contiguous.
                    used_flutter[fi] = true;
                    let insert_at = rows
                        .iter()
                        .rposition(|r: &Row| r.surface == Some(si) || r.link_si == Some(si))
                        .map(|p| p + 1)
                        .unwrap_or(rows.len());
                    rows.insert(insert_at, Row {
                        flutter: Some(fi),
                        surface: None,
                        link_si: Some(si),
                        connected: entry_reachable.get(si).copied().unwrap_or(false),
                    });
                } else {
                    // First app for this agent — it becomes the group head and
                    // renders the agent.
                    used_flutter[fi] = true;
                    used_surface[si] = true;
                    rows.push(Row {
                        flutter: Some(fi),
                        surface: Some(si),
                        link_si: Some(si),
                        connected: entry_reachable.get(si).copied().unwrap_or(false),
                    });
                }
            }
            None => {
                // Association points at an agent that no longer exists. Keep the
                // app visible on its own row so it is never silently dropped.
                used_flutter[fi] = true;
                rows.push(Row { flutter: Some(fi), surface: None, link_si: None, connected: false });
            }
        }
    }

    // Unlinked: pair by cwd proximity (Claude cwd == Flutter cwd or a parent),
    // then overflow the remainder as single-sided rows.
    let mut unlinked_flutter: Vec<usize> = Vec::new();
    let mut unlinked_surface: Vec<usize> = Vec::new();

    for (i, used) in used_flutter.iter().enumerate() {
        if !used {
            unlinked_flutter.push(i);
        }
    }
    for (i, used) in used_surface.iter().enumerate() {
        if !used {
            unlinked_surface.push(i);
        }
    }

    // Greedily pair each Flutter app with the best-matching Claude entry.
    // "Best" = longest Claude cwd that is a prefix of the Flutter cwd.
    let mut used_surface2 = vec![false; unlinked_surface.len()];
    let mut leftover_flutter: Vec<usize> = Vec::new();

    for &fi in &unlinked_flutter {
        let flutter_cwd = flutter[fi].1;
        let best = unlinked_surface
            .iter()
            .enumerate()
            .filter(|(j, _)| !used_surface2[*j])
            .filter_map(|(j, &si)| {
                let claude_cwd = entry_cwds[si].unwrap_or("");
                if claude_cwd.is_empty() {
                    return None;
                }
                // Claude cwd must equal or be a parent of the Flutter cwd.
                let matches = flutter_cwd == claude_cwd
                    || flutter_cwd.starts_with(&format!("{}/", claude_cwd));
                if matches { Some((j, si, claude_cwd.len())) } else { None }
            })
            .max_by_key(|&(_, _, len)| len);

        if let Some((j, si, _)) = best {
            used_surface2[j] = true;
            // cwd-proximity pairing — purely a layout hint to place a likely
            // app/agent pair on the same row. It is NOT an explicit link, so it
            // draws NO connector line (link_si: None). A line means a real
            // association, established via the `l` key.
            rows.push(Row {
                flutter: Some(fi),
                surface: Some(si),
                link_si: None,
                connected: false,
            });
        } else {
            leftover_flutter.push(fi);
        }
    }

    // Remaining unmatched surfaces.
    let leftover_surface: Vec<usize> = unlinked_surface
        .iter()
        .enumerate()
        .filter(|(j, _)| !used_surface2[*j])
        .map(|(_, &si)| si)
        .collect();

    // Zip any leftover Flutter and Claude entries side-by-side. This is just
    // visual co-location with no real or proximity link, so `link_si` stays
    // None and no connector is drawn.
    let paired = leftover_flutter.len().min(leftover_surface.len());
    for j in 0..paired {
        rows.push(Row {
            flutter: Some(leftover_flutter[j]),
            surface: Some(leftover_surface[j]),
            link_si: None,
            connected: false,
        });
    }
    for &fi in &leftover_flutter[paired..] {
        rows.push(Row { flutter: Some(fi), surface: None, link_si: None, connected: false });
    }
    for &si in &leftover_surface[paired..] {
        rows.push(Row { flutter: None, surface: Some(si), link_si: None, connected: false });
    }

    rows
}

fn row_has_column(row: &Row, col: Column) -> bool {
    match col {
        Column::Flutter => row.flutter.is_some(),
        Column::Claude => row.surface.is_some(),
    }
}

/// Build the connector column as a vector of `inner_height` strings (one per
/// visible line), each exactly `conn_w` columns wide, using box-drawing glyphs.
///
/// Connectors are ORTHOGONAL. For a single linked row, a straight horizontal
/// run `───────` joins the app to its agent. When several apps share one agent,
/// the agent is rendered once (on the group's head row) and the connectors form
/// a vertical bus with right-angle corners, e.g.:
/// ```text
///   app A ──┐
///           ├── agent
///   app B ──┘
/// ```
/// The bus sits at a fixed center column; each member row gets a horizontal stub
/// from the left edge to the bus, the agent row gets a stub from the bus to the
/// right edge, and the bus is joined vertically between the topmost and
/// bottommost anchored lines in the group.
fn build_connector_glyphs(
    rows: &[Row],
    row_heights: &[usize],
    scroll_offset: usize,
    inner_height: usize,
    conn_w: usize,
) -> Vec<String> {
    // grid[line][col] glyph; ' ' = empty.
    let mut grid: Vec<Vec<char>> = vec![vec![' '; conn_w]; inner_height];
    if conn_w == 0 || inner_height == 0 {
        return vec![" ".repeat(conn_w); inner_height];
    }
    let bus = conn_w / 2; // bus column

    // Compute the absolute visible-line index of each row's anchor (first line).
    // Rows before scroll_offset are skipped; we lay rows out sequentially.
    let mut anchor: Vec<Option<usize>> = vec![None; rows.len()];
    let mut line = 0usize;
    for (row_idx, _row) in rows.iter().enumerate() {
        if row_idx < scroll_offset {
            continue;
        }
        if line >= inner_height {
            break;
        }
        anchor[row_idx] = Some(line);
        line += row_heights[row_idx];
    }

    // Group rows by the surface they link to (`link_si`) — but ONLY rows with a
    // live agent connection. An association without a live connection draws no
    // line: the connector reflects an actual connection, not a saved link.
    let mut groups: std::collections::HashMap<usize, Vec<usize>> = std::collections::HashMap::new();
    for (row_idx, row) in rows.iter().enumerate() {
        if let (Some(si), true) = (row.link_si, row.connected) {
            groups.entry(si).or_default().push(row_idx);
        }
    }

    let set = |grid: &mut Vec<Vec<char>>, l: usize, c: usize, ch: char| {
        if l < inner_height && c < conn_w {
            grid[l][c] = ch;
        }
    };

    for (_si, members) in groups {
        // Anchor lines of members actually visible in the viewport.
        let mut lines: Vec<(usize, bool)> = members
            .iter()
            .filter_map(|&ri| anchor[ri].map(|l| (l, rows[ri].surface.is_some())))
            .collect();
        if lines.is_empty() {
            continue;
        }
        lines.sort_by_key(|&(l, _)| l);

        // Single visible member → straight horizontal run across the column.
        if lines.len() == 1 {
            let (l, _) = lines[0];
            for c in 0..conn_w {
                set(&mut grid, l, c, '─');
            }
            continue;
        }

        let top = lines.first().unwrap().0;
        let bottom = lines.last().unwrap().0;

        // Vertical bus between top and bottom anchored member lines.
        for l in top..=bottom {
            set(&mut grid, l, bus, '│');
        }

        // Each member: horizontal stub from left edge to the bus, with a corner
        // glyph where it meets the bus.
        for &(l, is_agent_row) in &lines {
            for c in 0..bus {
                set(&mut grid, l, c, '─');
            }
            let corner = if l == top {
                '┐'
            } else if l == bottom {
                '┘'
            } else {
                '┤'
            };
            set(&mut grid, l, bus, corner);
            // The agent (head) row also extends a stub from the bus to the right
            // edge toward the agent, turning the corner into a tee/cross.
            if is_agent_row {
                for c in (bus + 1)..conn_w {
                    set(&mut grid, l, c, '─');
                }
                let tee = match corner {
                    '┐' => '┬',
                    '┘' => '┴',
                    _ => '┼',
                };
                set(&mut grid, l, bus, tee);
            }
        }
    }

    grid.into_iter().map(|r| r.into_iter().collect()).collect()
}

// ── Background refresh ───────────────────────────────────────────────────

type DiscoveryResult = (
    Vec<FlutterApp>,
    Vec<CmuxSurface>,
    Vec<TrmPane>,
    DesktopTarget,
    Vec<AgentSession>,
);

/// Ask every relay we can see what it can do.
///
/// Separate from discovery and much slower-paced: discovery runs every 5s off
/// the process table, while this makes an HTTP call per relay and the answer
/// only changes when somebody restarts one.
fn spawn_relay_check(tx: mpsc::Sender<Vec<RelayCheck>>) {
    tokio::task::spawn_blocking(move || {
        let checks = check_all_relays(&load_peers());
        let _ = tx.blocking_send(checks);
    });
}

fn spawn_discovery(tx: mpsc::Sender<DiscoveryResult>) {
    tokio::task::spawn_blocking(move || {
        let result = (
            {
                // A statically-served release bundle has no Flutter process to
                // find; it is discovered by what it serves.
                let mut apps = discover_flutter_apps();
                merge_remote_apps(&mut apps, discover_static_web_apps());
                // An app on the build host is on no process table here. Its own
                // flan server can see it, so ask. Peers go in before the remote
                // registry merge in `apply_discovery`, so a full peer row wins
                // over the pid-0 stub the same app left when it last flushed.
                merge_peer_apps(&mut apps, discover_peer_apps(&load_peers()));
                apps
            },
            cmux_surface_list(),
            discover_trm_panes(),
            discover_desktop_target(),
            discover_agent_sessions(),
        );
        let _ = tx.blocking_send(result);
    });
}

// ── App State ───────────────────────────────────────────────────────────

#[derive(PartialEq, Clone, Copy)]
enum Column {
    Flutter,
    Claude,
}

#[derive(PartialEq, Clone, Copy)]
enum Focus {
    Main,
    Log,
}

/// Unified handle for anything that can appear in the Claude column.
#[derive(Clone)]
enum ClaudeEntry {
    Cmux(CmuxSurface),
    Trm(TrmPane),
    /// A running agent session with no pane behind it. This is what a headless
    /// host looks like: detached `zmx`/`screen`/ssh sessions expose no trm RPC
    /// surface, so pane discovery finds nothing, while the session registry and
    /// the process table describe every agent on the box.
    Session(AgentSession),
}

impl ClaudeEntry {
    fn id(&self) -> String {
        match self {
            ClaudeEntry::Cmux(s) => s.id.clone(),
            // Key by the stable pane_id, NOT the positional `index`. `index` is
            // the enumeration order in trm's live surface list and shifts when
            // panes are created/removed/reordered, so associations stored by
            // index would silently re-point at a different pane (and several
            // would collapse onto whatever sits at the low indices — "the first
            // agent"). pane_id is assigned per-pane by trm and is stable.
            ClaudeEntry::Trm(p) => format!("trm:{}", p.pane_id),
            // See AgentSession::entry_id — the server resolves links by the
            // same string, so both sides must agree on it.
            ClaudeEntry::Session(a) => a.entry_id(),
        }
    }
    fn is_claude(&self) -> bool {
        match self {
            ClaudeEntry::Cmux(s) => title_has_agent(&s.title),
            ClaudeEntry::Trm(p) => p.has_claude,
            ClaudeEntry::Session(_) => true,
        }
    }
    fn cwd(&self) -> Option<&str> {
        match self {
            ClaudeEntry::Cmux(s) => s.cwd.as_deref(),
            ClaudeEntry::Trm(p) => p.cwd.as_deref(),
            ClaudeEntry::Session(a) => a.cwd.as_deref(),
        }
    }
}

/// Append discovered agent sessions, skipping any whose channel is already
/// shown as a pane's `channel_port` — that is the same agent seen twice, and
/// the pane is the better row (it can be focused and text-injected, a bare
/// session can't).
fn append_session_entries(entries: &mut Vec<ClaudeEntry>, sessions: &[AgentSession]) {
    for session in sessions {
        let claimed = session.channel_port.is_some()
            && entries.iter().any(|e| match e {
                ClaudeEntry::Trm(p) => p.channel_port == session.channel_port,
                _ => false,
            });
        if !claimed {
            entries.push(ClaudeEntry::Session(session.clone()));
        }
    }
}

struct App {
    shared: Arc<SharedState>,
    flutter_apps: Vec<FlutterApp>,
    /// Last reported reachability per peer, so only CHANGES reach the log.
    peer_reachable: std::collections::HashMap<String, bool>,
    cmux_surfaces: Vec<CmuxSurface>,
    trm_panes: Vec<TrmPane>,
    /// Every agent session on the host, pane or no pane.
    agent_sessions: Vec<AgentSession>,
    associations: Vec<Association>,
    desktop_target: Option<DesktopTarget>,
    /// Snapshot of shared log for rendering (avoids async read during draw)
    log_snapshot: Vec<LogEntry>,

    active_column: Column,
    focus: Focus,
    /// Per-column row selection — each column tracks its own cursor independently
    flutter_row: Option<usize>,
    claude_row: Option<usize>,
    flutter_list_state: ListState,
    claude_list_state: ListState,
    log_state: ListState,
    log_visible: bool,
    toast: Option<(String, Instant)>,
    /// Relays that answered with fewer capabilities than this binary has.
    stale_relays: Vec<RelayCheck>,
    port: u16,
}

impl App {
    fn new(shared: Arc<SharedState>, port: u16) -> Self {
        Self {
            shared,
            flutter_apps: Vec::new(),
            peer_reachable: std::collections::HashMap::new(),
            cmux_surfaces: Vec::new(),
            trm_panes: Vec::new(),
            agent_sessions: Vec::new(),
            associations: Vec::new(),
            desktop_target: None,
            log_snapshot: Vec::new(),

            active_column: Column::Flutter,
            focus: Focus::Main,
            flutter_row: None,
            claude_row: None,
            flutter_list_state: ListState::default(),
            claude_list_state: ListState::default(),
            log_state: ListState::default(),
            log_visible: true,
            toast: None,
            stale_relays: Vec::new(),
            port,
        }
    }

    /// Get the active column's row selection
    fn active_row(&self) -> Option<usize> {
        match self.active_column {
            Column::Flutter => self.flutter_row,
            Column::Claude => self.claude_row,
        }
    }

    /// Set the active column's row selection
    fn set_active_row(&mut self, row: Option<usize>) {
        match self.active_column {
            Column::Flutter => self.flutter_row = row,
            Column::Claude => self.claude_row = row,
        }
    }

    /// Sync both column list states from their respective selections
    fn sync_row_state(&mut self) {
        self.flutter_list_state.select(self.flutter_row);
        self.claude_list_state.select(self.claude_row);
    }

    /// Stable identity of the currently-selected Flutter app (its PID), if any.
    ///
    /// Row indices are positions in the derived [`build_rows`] list, which is
    /// re-sorted whenever associations or discovery change. Capture this before
    /// mutating state and feed it to [`reanchor_selection`] afterwards so the
    /// cursor follows the same process instead of pointing at whatever moved
    /// into that index.
    fn selected_flutter_pid(&self) -> Option<u32> {
        self.selected_flutter().map(|f| f.pid)
    }

    /// Stable identity of the currently-selected Claude entry (its `id()`).
    fn selected_claude_id(&self) -> Option<String> {
        self.selected_entry().map(|e| e.id())
    }

    /// Re-point `flutter_row` / `claude_row` at the rows that now hold the
    /// given Flutter PID and Claude entry id after the row list was rebuilt.
    ///
    /// If an identity is no longer present (process gone, surface closed),
    /// that column's selection falls back to the first row that has content
    /// in that column — never a stale index.
    fn reanchor_selection(&mut self, pid: Option<u32>, claude_id: Option<String>) {
        let rows = build_rows(self);
        let entries = self.claude_entries();

        self.flutter_row = pid
            .and_then(|pid| {
                rows.iter().position(|r| {
                    r.flutter
                        .map(|fi| self.flutter_apps[fi].pid == pid)
                        .unwrap_or(false)
                })
            })
            .or_else(|| rows.iter().position(|r| r.flutter.is_some()));

        self.claude_row = claude_id
            .and_then(|id| {
                rows.iter().position(|r| {
                    r.surface
                        .map(|si| entries[si].id() == id)
                        .unwrap_or(false)
                })
            })
            .or_else(|| rows.iter().position(|r| r.surface.is_some()));

        self.sync_row_state();
    }

    async fn log(
        &self,
        direction: &'static str,
        summary: String,
        detail: Option<String>,
        ok: bool,
    ) {
        self.shared.log(direction, summary, detail, ok).await;
    }

    async fn sync_log_snapshot(&mut self) {
        let log = self.shared.activity_log.read().await;
        self.log_snapshot = log.iter().cloned().collect();
    }

    /// All Claude-bearing entries across cmux and trm, in display order.
    /// cmux Claude surfaces first, then trm panes.
    fn claude_entries(&self) -> Vec<ClaudeEntry> {
        let mut entries: Vec<ClaudeEntry> = self
            .cmux_surfaces
            .iter()
            .filter(|s| title_has_agent(&s.title))
            .cloned()
            .map(ClaudeEntry::Cmux)
            .collect();
        for pane in &self.trm_panes {
            if pane.has_claude {
                entries.push(ClaudeEntry::Trm(pane.clone()));
            }
        }
        append_session_entries(&mut entries, &self.agent_sessions);
        entries
    }

    // Keep for legacy callers that only need cmux surface indices (e.g. association lookup).
    fn claude_surfaces_indices(&self) -> Vec<usize> {
        self.cmux_surfaces
            .iter()
            .enumerate()
            .filter(|(_, s)| title_has_agent(&s.title))
            .map(|(i, _)| i)
            .collect()
    }

    fn selected_flutter(&self) -> Option<&FlutterApp> {
        let rows = build_rows(self);
        self.flutter_row
            .and_then(|i| rows.get(i))
            .and_then(|row| row.flutter)
            .and_then(|fi| self.flutter_apps.get(fi))
    }

    fn selected_entry(&self) -> Option<ClaudeEntry> {
        let rows = build_rows(self);
        let entries = self.claude_entries();
        self.claude_row
            .and_then(|i| rows.get(i))
            .and_then(|row| row.surface)
            .and_then(|si| entries.get(si))
            .cloned()
    }

    /// Returns the selected entry only if it is a cmux surface.
    fn selected_surface(&self) -> Option<CmuxSurface> {
        match self.selected_entry() {
            Some(ClaudeEntry::Cmux(s)) => Some(s),
            _ => None,
        }
    }

    fn assoc_for_flutter(&self, pid: u32) -> Option<&Association> {
        self.associations.iter().find(|a| a.flutter_pid == pid)
    }

    fn assoc_for_surface(&self, id: &str) -> Option<&Association> {
        self.associations
            .iter()
            .find(|a| a.claude_surface_id == id)
    }

    /// The flan-channel port that reaches the agent behind `id`, whether it was
    /// discovered as a trm pane or registered itself as a bare channel.
    fn channel_port_for_id(&self, id: &str) -> Option<u16> {
        if let Some(pane_id) = id.strip_prefix("trm:").and_then(|n| n.parse::<usize>().ok()) {
            return self
                .trm_panes
                .iter()
                .find(|p| p.pane_id == pane_id)
                .and_then(|p| p.channel_port);
        }
        // Resolve through the live list rather than trusting the id: a link
        // persisted against a session that has since exited — or whose channel
        // was rebound on a new port — must not look reachable.
        self.agent_sessions
            .iter()
            .find(|a| {
                ClaudeEntry::Session((*a).clone()).id() == id
            })
            .and_then(|a| a.channel_port)
    }

    fn set_toast(&mut self, msg: impl Into<String>) {
        self.toast = Some((msg.into(), Instant::now()));
    }

    /// Say something the first time a peer stops answering, and again when it
    /// comes back.
    ///
    /// An unreachable peer and a peer running nothing both produce an empty
    /// list. Without this the TUI looks identical in both cases, so a peer whose
    /// flan server isn't running reads as "the feature is broken" — which is
    /// exactly how this was first reported.
    async fn report_peer_changes(&mut self) {
        for state in peer_states() {
            let was = self.peer_reachable.insert(state.peer.clone(), state.reachable);
            if was == Some(state.reachable) {
                continue; // nothing changed; don't refill the log every tick
            }
            let host = peer_host(&state.peer).unwrap_or_else(|| state.peer.clone());
            if state.reachable {
                self.log(
                    "peer",
                    format!("{host}: {} app(s)", state.app_count),
                    None,
                    true,
                )
                .await;
            } else {
                let detail = format!(
                    "No flan server answered at {}. Apps running there can't be \
                     discovered until one does.",
                    state.peer
                );
                self.log("peer", format!("{host} unreachable"), Some(detail), false)
                    .await;
                self.set_toast(format!("peer {host} unreachable"));
            }
        }
        // A peer removed from the config stops being tracked.
        let live: std::collections::HashSet<String> =
            peer_states().into_iter().map(|s| s.peer).collect();
        self.peer_reachable.retain(|peer, _| live.contains(peer));
    }

    /// Relays that are behind this binary, newest answer first seen.
    ///
    /// An app posts to exactly one relay and a stale one answers 404 for an
    /// endpoint that shipped days ago; the symptom is always "the feature is
    /// broken". Saying it here, where the link is made, is the whole point.
    async fn apply_relay_checks(&mut self, checks: Vec<RelayCheck>) {
        let stale: Vec<RelayCheck> = checks.into_iter().filter(RelayCheck::is_stale).collect();
        let changed: Vec<&RelayCheck> = stale
            .iter()
            .filter(|check| {
                !self
                    .stale_relays
                    .iter()
                    .any(|known| known.endpoint == check.endpoint)
            })
            .collect();
        for check in changed {
            self.log("in", format!("Stale relay: {}", check.endpoint), Some(check.summary()), false)
                .await;
        }
        self.stale_relays = stale;
        self.sync_log_snapshot().await;
    }

    async fn apply_discovery(&mut self, result: DiscoveryResult) {
        let (flutter, surfaces, trm, desktop, discovered_sessions) = result;

        // Apps this host can't see as processes are known only from the
        // flushes they send. They must join the list here too — the TUI
        // overwrites the shared cache below, so merging only inside the HTTP
        // layer would leave them out of both the column and the API.
        let mut flutter = flutter;
        merge_remote_apps(&mut flutter, self.shared.remote_apps().await);
        self.flutter_apps = flutter.clone();
        self.report_peer_changes().await;
        self.cmux_surfaces = surfaces;
        let mut trm = trm;
        // Attach registered channel ports to trm panes.
        // Priority: 1) surface_id key, 2) login PID, 3) cwd prefix match.
        //
        // The surface_id key is authoritative: it is produced by
        // resolve_trm_pane_for_pid, which anchors a channel to its pane via the
        // PANE's login PID (a 1:1 identifier). The by-login map, by contrast, is
        // keyed on the CHANNEL process's own self-resolved login PID, which can
        // land on the wrong pane when several panes share a cwd (a Claude pane
        // and sibling shell panes in the same repo) — that mis-key was routing
        // app flushes to a Claude-less pane. Trust the surface key first so a
        // stale/bad by-login entry can't override a correct surface resolution.
        {
            let ports = self.shared.channel_ports.read().await;
            let login_ports = self.shared.channel_ports_by_login.read().await;
            let cwd_ports = self.shared.channel_ports_by_cwd.read().await;
            let mut used_cwds: std::collections::HashSet<String> = std::collections::HashSet::new();

            for pane in &mut trm {
                // 1. Direct surface_id key match (keyed by stable pane_id).
                //    Authoritative — see the block comment above.
                let key = format!("trm:{}", pane.pane_id);
                if let Some(&port) = ports.get(&key) {
                    pane.channel_port = Some(port);
                    continue;
                }

                // 2. Login PID match — fallback when the surface key is absent
                //    (e.g. title-less pane the surface resolver couldn't map).
                if let Some(login_pid) = pane.login_pid {
                    if let Some(&port) = login_ports.get(&login_pid) {
                        pane.channel_port = Some(port);
                        continue;
                    }
                }

                // 3. Cwd prefix match (fallback for panes whose login wasn't resolved).
                if pane.channel_port.is_none() && pane.has_claude && !cwd_ports.is_empty() {
                    if let Some(ref pane_cwd) = pane.cwd {
                        let pane_clean = pane_cwd.trim_end_matches('/');
                        for (reg_cwd, &port) in cwd_ports.iter() {
                            if used_cwds.contains(reg_cwd) { continue; }
                            let reg_clean = reg_cwd.trim_end_matches('/');
                            if reg_clean == pane_clean
                                || reg_clean.starts_with(&format!("{}/", pane_clean))
                                || pane_clean.starts_with(&format!("{}/", reg_clean))
                            {
                                pane.channel_port = Some(port);
                                used_cwds.insert(reg_cwd.clone());
                                break;
                            }
                        }
                    }
                }
            }
        }
        self.trm_panes = trm;
        self.agent_sessions = self.shared.agent_sessions(discovered_sessions).await;
        self.desktop_target = if desktop.alive { Some(desktop.clone()) } else { None };
        *self.shared.desktop_cache.write().await = Some((Instant::now(), desktop));

        // Prune stale associations where the Flutter process is gone
        let mut assocs = load_associations(&self.shared.persistence_path);
        let before = assocs.len();
        // Keep a link while its app's process is alive, even when this pass of
        // discovery didn't see it — a probe can time out, and dropping the link
        // on that would quietly unlink a running app.
        assocs.retain(|a| {
            // A link made against an app id is kept unconditionally. Such an
            // app has no process to check and is invisible between flushes, so
            // "not currently listed" says nothing about whether it still
            // exists — dropping it there silently unlinks a working app.
            if a.flutter_app_id.is_some() {
                return true;
            }
            self.flutter_apps.iter().any(|f| f.pid == a.flutter_pid)
                || (a.flutter_pid != 0 && pid_is_alive(a.flutter_pid))
        });
        if assocs.len() < before {
            save_associations(&self.shared.persistence_path, &assocs);
        }
        self.associations = assocs.clone();
        {
            let mut shared_assocs = self.shared.associations.write().await;
            *shared_assocs = assocs;
        }

        // Update shared cache so HTTP handlers (e.g. /api/flush) can find VM URIs
        *self.shared.flutter_cache.write().await = Some((Instant::now(), flutter));
        self.sync_log_snapshot().await;

        // Re-anchor the per-column cursors to the same Flutter PID / Claude
        // entry they pointed at before this refresh. Discovery can reorder the
        // row list (new apps, changed cwd pairing), so clamping indices alone
        // would silently move the cursor onto a different process.
        let prev_pid = self.selected_flutter_pid();
        let prev_claude = self.selected_claude_id();

        if build_rows(self).is_empty() {
            self.flutter_row = None;
            self.claude_row = None;
            self.sync_row_state();
        } else {
            self.reanchor_selection(prev_pid, prev_claude);
        }
    }

    fn move_up(&mut self) {
        if self.focus == Focus::Log {
            let len = self.log_snapshot.len();
            if len == 0 {
                return;
            }
            let i = self.log_state.selected().unwrap_or(0);
            self.log_state.select(Some(i.saturating_sub(1)));
            return;
        }
        let rows = build_rows(self);
        if rows.is_empty() {
            return;
        }
        let i = self.active_row().unwrap_or(0);
        // Skip rows that have nothing in the active column
        let mut target = i.saturating_sub(1);
        while target > 0 && !row_has_column(&rows[target], self.active_column) {
            target = target.saturating_sub(1);
        }
        self.set_active_row(Some(target));
        self.sync_row_state();
    }

    fn move_down(&mut self) {
        if self.focus == Focus::Log {
            let len = self.log_snapshot.len();
            if len == 0 {
                return;
            }
            let i = self.log_state.selected().unwrap_or(0);
            self.log_state
                .select(Some((i + 1).min(len.saturating_sub(1))));
            return;
        }
        let rows = build_rows(self);
        if rows.is_empty() {
            return;
        }
        let last = rows.len() - 1;
        let i = self.active_row().unwrap_or(0);
        // Skip rows that have nothing in the active column
        let mut target = (i + 1).min(last);
        while target < last && !row_has_column(&rows[target], self.active_column) {
            target += 1;
        }
        self.set_active_row(Some(target));
        self.sync_row_state();
    }

    fn toggle_column(&mut self) {
        if self.focus == Focus::Log {
            self.focus = Focus::Main;
            return;
        }
        self.active_column = match self.active_column {
            Column::Flutter => Column::Claude,
            Column::Claude => Column::Flutter,
        };
        // Restore the target column's own row selection
        self.sync_row_state();
    }
}

// ── UI Rendering ────────────────────────────────────────────────────────

fn ui(f: &mut Frame, app: &mut App) {
    let area = f.area();
    f.render_widget(Block::default().style(Style::default().bg(BG)), area);

    let log_height = if app.log_visible { 10u16 } else { 1u16 };

    let outer = Layout::vertical([
        Constraint::Length(1),
        Constraint::Length(1),
        Constraint::Min(6),
        Constraint::Length(log_height),
        Constraint::Length(1),
    ])
    .split(area);

    render_status_bar(f, app, outer[0]);
    render_column_headers(f, app, outer[1]);
    render_rows(f, app, outer[2]);
    render_log_panel(f, app, outer[3]);
    render_help_bar(f, outer[4]);
}

fn render_status_bar(f: &mut Frame, app: &App, area: Rect) {
    let flutter_count = app.flutter_apps.len();
    let entries = app.claude_entries();
    let claude_count = entries.len();
    let link_count = app.associations.iter().filter(|a| {
        app.flutter_apps.iter().any(|f| f.pid == a.flutter_pid)
            && entries.iter().any(|e| e.id() == a.claude_surface_id)
    }).count();

    let mut spans = vec![
        Span::styled(
            " flan",
            Style::default().fg(ACCENT2).add_modifier(Modifier::BOLD),
        ),
        Span::styled(" tui  ", Style::default().fg(TEXT)),
    ];

    if let Some((ref msg, ts)) = app.toast {
        if ts.elapsed() < Duration::from_secs(3) {
            spans.push(Span::styled(
                format!("  {}  ", msg),
                Style::default().fg(GREEN).add_modifier(Modifier::BOLD),
            ));
        }
    }

    // An app talks to exactly one relay, and a relay older than this binary
    // answers 404 for whatever shipped since — which looks like a broken
    // feature and nothing else. Name it where the links are made.
    if !app.stale_relays.is_empty() {
        let ports: Vec<String> = app
            .stale_relays
            .iter()
            .map(|check| {
                check
                    .endpoint
                    .rsplit(':')
                    .next()
                    .map(|port| format!(":{port}"))
                    .unwrap_or_else(|| check.endpoint.clone())
            })
            .collect();
        spans.push(Span::styled(
            format!("  ⚠ stale relay {}  ", ports.join(" ")),
            Style::default().fg(ORANGE).add_modifier(Modifier::BOLD),
        ));
    }

    let desktop_str = if app.desktop_target.is_some() {
        "● desktop"
    } else {
        "○ desktop"
    };

    let status = format!(
        "{} · ● {} flutter · {} agents · {} linked · :{} ",
        desktop_str, flutter_count, claude_count, link_count, app.port
    );

    let status_width = status.len() as u16;
    let left_width = area.width.saturating_sub(status_width);

    let cols = Layout::horizontal([
        Constraint::Length(left_width),
        Constraint::Length(status_width),
    ])
    .split(area);

    f.render_widget(
        Paragraph::new(Line::from(spans)).style(Style::default().bg(SURFACE_BG)),
        cols[0],
    );

    f.render_widget(
        Paragraph::new(Line::from(vec![Span::styled(
            status,
            Style::default().fg(GREEN),
        )]))
        .style(Style::default().bg(SURFACE_BG))
        .alignment(ratatui::layout::Alignment::Right),
        cols[1],
    );
}

fn render_column_headers(f: &mut Frame, app: &App, area: Rect) {
    let flutter_active = app.focus == Focus::Main && app.active_column == Column::Flutter;
    let claude_active = app.focus == Focus::Main && app.active_column == Column::Claude;

    let cols = Layout::horizontal([
        Constraint::Percentage(45),
        Constraint::Percentage(10),
        Constraint::Percentage(45),
    ])
    .split(area);

    let flutter_style = if flutter_active {
        Style::default().fg(ACCENT2).add_modifier(Modifier::BOLD)
    } else {
        Style::default().fg(TEXT2)
    };
    let claude_style = if claude_active {
        Style::default().fg(ACCENT2).add_modifier(Modifier::BOLD)
    } else {
        Style::default().fg(TEXT2)
    };

    let fl_header = if flutter_active {
        " ▸ FLUTTER APPS"
    } else {
        "   FLUTTER APPS"
    };
    let cl_header = if claude_active {
        "CODING AGENTS ◂ "
    } else {
        "CODING AGENTS   "
    };

    f.render_widget(
        Paragraph::new(Line::from(Span::styled(fl_header, flutter_style)))
            .style(Style::default().bg(BG)),
        cols[0],
    );
    f.render_widget(
        Paragraph::new(Line::from(Span::styled("", Style::default().fg(BORDER))))
            .style(Style::default().bg(BG)),
        cols[1],
    );
    f.render_widget(
        Paragraph::new(Line::from(Span::styled(cl_header, claude_style)))
            .style(Style::default().bg(BG))
            .alignment(ratatui::layout::Alignment::Right),
        cols[2],
    );
}

fn render_rows(f: &mut Frame, app: &mut App, area: Rect) {
    let rows = build_rows(app);

    if rows.is_empty() {
        let block = Block::default()
            .borders(Borders::ALL)
            .border_style(Style::default().fg(BORDER))
            .style(Style::default().bg(BG));
        let empty = Paragraph::new(Line::from(Span::styled(
            "No Flutter apps or coding agents found",
            Style::default().fg(TEXT2),
        )))
        .block(block)
        .alignment(ratatui::layout::Alignment::Center);
        f.render_widget(empty, area);
        return;
    }

    let active_col = app.active_column;
    let has_focus = app.focus == Focus::Main;
    let flutter_sel = app.flutter_row;
    let claude_sel = app.claude_row;

    // Active column gets brighter highlight, inactive gets dimmer
    let hl_bg_active = Color::Rgb(28, 24, 50);
    let hl_bg_inactive = Color::Rgb(20, 18, 35);

    // Split the area into three columns: flutter | connector | claude
    let cols = Layout::horizontal([
        Constraint::Percentage(44),
        Constraint::Percentage(12),
        Constraint::Percentage(44),
    ])
    .split(area);

    let left_area = cols[0];
    let conn_area = cols[1];
    let right_area = cols[2];

    // Pre-compute per-row line heights (max of both sides) so the two
    // columns stay vertically aligned even though they scroll independently.
    let row_heights: Vec<usize> = rows
        .iter()
        .map(|row| {
            let fl = row
                .flutter
                .map(|fi| build_flutter_lines(app, fi).len())
                .unwrap_or(0)
                .max(1);
            let cl = row
                .surface
                .map(|si| {
                    let entries = app.claude_entries();
                    build_entry_lines(app, &entries[si]).len()
                })
                .unwrap_or(0)
                .max(1);
            fl.max(cl)
        })
        .collect();

    // ── Flutter column (left) ────────────────────────────────────────
    let left_w = left_area.width.saturating_sub(2) as usize; // account for border
    let flutter_items: Vec<ListItem> = rows
        .iter()
        .enumerate()
        .map(|(row_idx, row)| {
            let hl = has_focus && flutter_sel == Some(row_idx) && row.flutter.is_some();
            let bg = if hl {
                if active_col == Column::Flutter { hl_bg_active } else { hl_bg_inactive }
            } else {
                BG
            };

            let content_lines = row
                .flutter
                .map(|fi| build_flutter_lines(app, fi))
                .unwrap_or_default();

            let max_lines = row_heights[row_idx];
            let mut lines = Vec::new();

            for line_idx in 0..max_lines {
                if let Some((text, style)) = content_lines.get(line_idx) {
                    let truncated = truncate_str(text, left_w);
                    let pad = left_w.saturating_sub(char_width(&truncated));
                    let s = if hl { style.bg(bg) } else { *style };
                    let mut spans = vec![Span::styled(truncated, s)];
                    if pad > 0 {
                        let pad_style = if hl { Style::default().bg(bg) } else { Style::default() };
                        spans.push(Span::styled(" ".repeat(pad), pad_style));
                    }
                    lines.push(Line::from(spans));
                } else {
                    let pad_style = if hl { Style::default().bg(bg) } else { Style::default() };
                    lines.push(Line::from(Span::styled(" ".repeat(left_w), pad_style)));
                }
            }

            ListItem::new(lines)
        })
        .collect();

    let flutter_border = if has_focus && active_col == Column::Flutter {
        ACCENT
    } else {
        BORDER
    };
    let flutter_list = List::new(flutter_items)
        .block(
            Block::default()
                .borders(Borders::LEFT | Borders::TOP | Borders::BOTTOM)
                .border_style(Style::default().fg(flutter_border))
                .style(Style::default().bg(BG)),
        )
        .highlight_style(Style::default());

    f.render_stateful_widget(flutter_list, left_area, &mut app.flutter_list_state);

    // ── Connector column (center) ────────────────────────────────────
    // Rendered as a plain widget (no scrolling) — we need to figure out
    // which rows are actually visible in each column's viewport to draw
    // connectors. For simplicity, render connectors based on absolute row
    // position relative to the area.
    // The connector column doesn't scroll — it just fills the space.
    // We render it as a static Paragraph matching visible row offsets.
    {
        let conn_w = conn_area.width as usize;
        let inner_height = conn_area.height.saturating_sub(2) as usize; // top+bottom border
        let scroll_offset = app.flutter_list_state.offset();

        let glyphs = build_connector_glyphs(&rows, &row_heights, scroll_offset, inner_height, conn_w);
        let visible_lines: Vec<Line> = glyphs
            .into_iter()
            .map(|g| Line::from(Span::styled(g, Style::default().fg(GREEN))))
            .collect();

        let conn_block = Block::default()
            .borders(Borders::TOP | Borders::BOTTOM)
            .border_style(Style::default().fg(BORDER))
            .style(Style::default().bg(BG));

        f.render_widget(
            Paragraph::new(visible_lines).block(conn_block),
            conn_area,
        );
    }

    // ── Claude column (right) ────────────────────────────────────────
    let right_w = right_area.width.saturating_sub(2) as usize; // account for border
    let claude_items: Vec<ListItem> = rows
        .iter()
        .enumerate()
        .map(|(row_idx, row)| {
            let hl = has_focus && claude_sel == Some(row_idx) && row.surface.is_some();
            let bg = if hl {
                if active_col == Column::Claude { hl_bg_active } else { hl_bg_inactive }
            } else {
                BG
            };

            let content_lines = row.surface.map(|si| {
                let entries = app.claude_entries();
                build_entry_lines(app, &entries[si])
            }).unwrap_or_default();

            let max_lines = row_heights[row_idx];
            let mut lines = Vec::new();

            for line_idx in 0..max_lines {
                if let Some((text, style)) = content_lines.get(line_idx) {
                    let truncated = truncate_str(text, right_w);
                    let pad = right_w.saturating_sub(char_width(&truncated));
                    let s = if hl { style.bg(bg) } else { *style };
                    let mut spans = vec![Span::styled(truncated, s)];
                    if pad > 0 {
                        let pad_style = if hl { Style::default().bg(bg) } else { Style::default() };
                        spans.push(Span::styled(" ".repeat(pad), pad_style));
                    }
                    lines.push(Line::from(spans));
                } else {
                    let pad_style = if hl { Style::default().bg(bg) } else { Style::default() };
                    lines.push(Line::from(Span::styled(" ".repeat(right_w), pad_style)));
                }
            }

            ListItem::new(lines)
        })
        .collect();

    let claude_border = if has_focus && active_col == Column::Claude {
        ACCENT
    } else {
        BORDER
    };
    let claude_list = List::new(claude_items)
        .block(
            Block::default()
                .borders(Borders::RIGHT | Borders::TOP | Borders::BOTTOM)
                .border_style(Style::default().fg(claude_border))
                .style(Style::default().bg(BG)),
        )
        .highlight_style(Style::default());

    f.render_stateful_widget(claude_list, right_area, &mut app.claude_list_state);
}

fn build_flutter_lines(app: &App, idx: usize) -> Vec<(String, Style)> {
    let fl = &app.flutter_apps[idx];
    let mut lines = Vec::new();

    let device = fl.device.as_deref().unwrap_or("?");
    // Where it is, then how to open it. The host answers the question a
    // two-machine setup asks first — mini or m1 — and without it two apps on
    // two machines differ only by a port number, which reads as one project
    // built twice. An app found locally reports no host, so it gets this
    // machine's name: "not remote" is a fact about this machine, not a blank.
    let host = fl.host.clone().unwrap_or_else(local_hostname);
    let where_ = match fl.web_port {
        Some(port) => format!("  {host}:{port}"),
        None => format!("  {host}"),
    };
    lines.push((
        format!("{}  ({}){}", fl.folder_name, device, where_),
        Style::default().fg(TEXT).add_modifier(Modifier::BOLD),
    ));

    lines.push((
        if fl.cwd.is_empty() {
            // No local process to read a cwd from — the id it flushes with is
            // the only thing that names it.
            fl.app_id.clone().unwrap_or_else(|| "(remote app)".into())
        } else {
            shorten_path(&fl.cwd)
        },
        Style::default().fg(TEXT2),
    ));

    if fl.queue_count > 0 {
        lines.push((
            format!("{} queued", fl.queue_count),
            Style::default().fg(ORANGE),
        ));
    }

    lines
}

/// A short marker for what the session is doing right now, from Claude Code's
/// own registry. Blank when it reports nothing rather than guessing.
fn status_tag(agent: &AgentSession) -> String {
    match agent.status.as_deref() {
        Some("busy") => "  \u{25cf} busy".into(),
        Some("idle") => "  \u{25cb} idle".into(),
        Some(other) if !other.is_empty() => format!("  \u{b7} {other}"),
        _ => String::new(),
    }
}

/// The artifacts a session has published, as Claude Code's own status line
/// names them. Two sessions on one repo often differ only in what they've
/// produced, so this is frequently the line that tells them apart when
/// choosing which one to link.
fn artifact_tag(agent: &AgentSession) -> Option<String> {
    if agent.artifacts.is_empty() {
        return None;
    }
    // Publication order, oldest first — the same order Claude Code's status
    // line uses, so a name spotted there is in the same place here. Showing the
    // newest first instead hid the oldest artifact behind the overflow count,
    // which is the one a long-running session is most likely known by.
    const SHOWN: usize = 4;
    let total = agent.artifacts.len();
    let shown: Vec<&str> = agent
        .artifacts
        .iter()
        .take(SHOWN)
        .map(|s| s.as_str())
        .collect();
    let mut tag = format!("\u{229e} {}", shown.join(" \u{b7} "));
    if total > SHOWN {
        tag.push_str(&format!(" +{}", total - SHOWN));
    }
    Some(tag)
}

fn build_entry_lines(app: &App, entry: &ClaudeEntry) -> Vec<(String, Style)> {
    match entry {
        ClaudeEntry::Cmux(surface) => {
            let mut lines = Vec::new();
            let mut title = surface.title.clone();
            if surface.focused {
                title.push_str(" [focused]");
            }
            lines.push((title, Style::default().fg(TEXT).add_modifier(Modifier::BOLD)));

            if let Some(ref cwd) = surface.cwd {
                lines.push((shorten_path(cwd), Style::default().fg(TEXT2)));
                return lines;
            }

            // Fall back to a path-like sibling surface title in the same pane.
            let pane_path = app.cmux_surfaces.iter()
                .filter(|s| s.pane_id == surface.pane_id && s.id != surface.id)
                .find(|s| {
                    let t = &s.title;
                    t.starts_with('/') || t.starts_with('~') || t.starts_with('…') || t.contains("/dev/")
                })
                .map(|s| s.title.clone());

            if let Some(path) = pane_path {
                lines.push((path, Style::default().fg(TEXT2)));
            } else {
                let short_pane = &surface.pane_id[..8.min(surface.pane_id.len())];
                lines.push((format!("pane {}…", short_pane), Style::default().fg(TEXT2)));
            }
            lines
        }
        ClaudeEntry::Trm(pane) => {
            let mut lines = Vec::new();
            let status = if pane.has_claude {
                pane.agent_name.as_deref()
                    .unwrap_or("agent")
            } else {
                "(shell)"
            };
            let port_tag = pane.channel_port
                .map(|p| format!("  ch:{}", p))
                .unwrap_or_default();
            lines.push((
                // Show pane_id — this is the stable id used as the routing key.
                format!("trm:{}  {}{}", pane.pane_id, status, port_tag),
                Style::default().fg(TEXT).add_modifier(Modifier::BOLD),
            ));
            if let Some(ref cwd) = pane.cwd {
                lines.push((shorten_path(cwd), Style::default().fg(TEXT2)));
            } else if let Some(ref folder) = pane.folder_name {
                lines.push((folder.clone(), Style::default().fg(TEXT2)));
            } else if let Some(ref t) = pane.title {
                // Only use the title if it looks like a path, not a status string.
                let path_token = t.split_whitespace()
                    .find(|tok| tok.starts_with('/') || tok.starts_with('~'));
                if let Some(p) = path_token {
                    lines.push((shorten_path(p), Style::default().fg(TEXT2)));
                } else {
                    lines.push(("(unknown path)".into(), Style::default().fg(TEXT2)));
                }
            } else {
                lines.push(("(empty pane)".into(), Style::default().fg(TEXT2)));
            }
            lines
        }
        ClaudeEntry::Session(agent) => {
            let mut lines = Vec::new();
            // Several sessions routinely share one repo, so the cwd alone can't
            // tell them apart. Lead with the identifiers that can: the session's
            // own name and its tty.
            let where_ = agent.tty.clone()
                .or_else(|| agent.agent_pid.map(|p| format!("pid {}", p)))
                .unwrap_or_else(|| "headless".into());
            let name = agent.session_name.clone()
                .unwrap_or_else(|| agent.agent_name.clone().unwrap_or_else(|| "agent".into()));
            // An unreachable session (no flan-channel) is worth showing but
            // must not look linkable — say so instead of leaving a blank.
            let reach = match agent.channel_port {
                Some(port) => format!("ch:{port}"),
                None => "no channel".to_string(),
            };
            let head_style = if agent.channel_port.is_some() {
                Style::default().fg(TEXT).add_modifier(Modifier::BOLD)
            } else {
                Style::default().fg(TEXT2).add_modifier(Modifier::BOLD)
            };
            lines.push((
                format!("{}  {}  {}{}", name, where_, reach, status_tag(agent)),
                head_style,
            ));

            // Path plus branch — or the worktree name, which is what actually
            // distinguishes sibling sessions on one repo.
            let mut place = agent.cwd.as_deref().map(shorten_path)
                .unwrap_or_else(|| "(unknown path)".into());
            if let Some(ref worktree) = agent.worktree {
                place.push_str(&format!("  \u{2442} {worktree}"));
            } else if let Some(ref branch) = agent.branch {
                place.push_str(&format!("  \u{2442} {branch}"));
            }
            lines.push((place, Style::default().fg(TEXT2)));

            if let Some(ref summary) = agent.summary {
                lines.push((format!("\u{201c}{summary}\u{201d}"), Style::default().fg(TEXT2)));
            }
            if let Some(artifacts) = artifact_tag(agent) {
                lines.push((artifacts, Style::default().fg(ACCENT2)));
            }
            lines
        }
    }
}

fn shorten_path(path: &str) -> String {
    let path = flan_server::strip_ansi(path);
    let home = std::env::var("HOME").unwrap_or_default();
    if !home.is_empty() && path.starts_with(&home) {
        format!("~{}", &path[home.len()..])
    } else {
        path
    }
}

fn char_width(s: &str) -> usize {
    s.chars().count()
}

fn truncate_str(s: &str, max_width: usize) -> String {
    let cw = char_width(s);
    if cw <= max_width {
        s.to_string()
    } else if max_width > 1 {
        let truncated: String = s.chars().take(max_width - 1).collect();
        format!("{}…", truncated)
    } else {
        "…".to_string()
    }
}

fn center_pad(s: &str, width: usize) -> String {
    let cw = char_width(s);
    if cw >= width {
        return s.chars().take(width).collect();
    }
    let total_pad = width - cw;
    let left = total_pad / 2;
    let right = total_pad - left;
    format!("{}{}{}", " ".repeat(left), s, " ".repeat(right))
}

fn render_log_panel(f: &mut Frame, app: &mut App, area: Rect) {
    let is_active = app.focus == Focus::Log;
    let border_color = if is_active { ACCENT } else { BORDER };

    let title = format!(
        " Activity Log ({}) {} ",
        app.log_snapshot.len(),
        if app.log_visible { "▼" } else { "▶" }
    );

    let block = Block::default()
        .borders(Borders::ALL)
        .border_style(Style::default().fg(border_color))
        .title(Span::styled(
            title,
            Style::default()
                .fg(if is_active { ACCENT2 } else { TEXT2 })
                .add_modifier(Modifier::BOLD),
        ))
        .style(Style::default().bg(BG));

    if !app.log_visible || app.log_snapshot.is_empty() {
        let msg = if !app.log_visible {
            ""
        } else {
            "No activity yet"
        };
        let empty = Paragraph::new(Line::from(Span::styled(msg, Style::default().fg(TEXT2))))
            .block(block);
        f.render_widget(empty, area);
        return;
    }

    let items: Vec<ListItem> = app
        .log_snapshot
        .iter()
        .rev()
        .map(|entry| {
            let dir_style = if !entry.ok {
                Style::default().fg(RED)
            } else if entry.direction == "in" {
                Style::default().fg(ACCENT2)
            } else {
                Style::default().fg(ORANGE)
            };

            let arrow = if entry.direction == "in" { "→" } else { "←" };

            let summary_style = if entry.ok {
                Style::default().fg(TEXT)
            } else {
                Style::default().fg(RED)
            };

            let mut spans = vec![
                Span::styled(&entry.timestamp, Style::default().fg(TEXT2)),
                Span::styled("  ", Style::default()),
                Span::styled(arrow, dir_style),
                Span::styled("  ", Style::default()),
                Span::styled(&entry.summary, summary_style),
            ];

            if let Some(ref detail) = entry.detail {
                spans.push(Span::styled(
                    format!(" — {}", detail),
                    Style::default().fg(TEXT2),
                ));
            }

            ListItem::new(Line::from(spans))
        })
        .collect();

    let list = List::new(items)
        .block(block)
        .highlight_style(Style::default().bg(Color::Rgb(26, 26, 50)));

    f.render_stateful_widget(list, area, &mut app.log_state);
}

fn render_help_bar(f: &mut Frame, area: Rect) {
    let spans = vec![
        Span::styled(" [s]", Style::default().fg(ACCENT2)),
        Span::styled("can ", Style::default().fg(TEXT2)),
        Span::styled("[l]", Style::default().fg(ACCENT2)),
        Span::styled("ink ", Style::default().fg(TEXT2)),
        Span::styled("[u]", Style::default().fg(ACCENT2)),
        Span::styled("nlink ", Style::default().fg(TEXT2)),
        Span::styled("[f]", Style::default().fg(ACCENT2)),
        Span::styled("ocus ", Style::default().fg(TEXT2)),
        Span::styled("[t]", Style::default().fg(ACCENT2)),
        Span::styled("est ", Style::default().fg(TEXT2)),
        Span::styled("[x]", Style::default().fg(ACCENT2)),
        Span::styled("flush ", Style::default().fg(TEXT2)),
        Span::styled("[R]", Style::default().fg(ACCENT2)),
        Span::styled("eload ", Style::default().fg(TEXT2)),
        Span::styled("[g]", Style::default().fg(ACCENT2)),
        Span::styled("log ", Style::default().fg(TEXT2)),
        Span::styled("[←→]", Style::default().fg(ACCENT2)),
        Span::styled("switch ", Style::default().fg(TEXT2)),
        Span::styled("[r]", Style::default().fg(ACCENT2)),
        Span::styled("efresh ", Style::default().fg(TEXT2)),
        Span::styled("[q]", Style::default().fg(ACCENT2)),
        Span::styled("uit", Style::default().fg(TEXT2)),
    ];

    f.render_widget(
        Paragraph::new(Line::from(spans)).style(Style::default().bg(SURFACE_BG)),
        area,
    );
}

// ── Main ────────────────────────────────────────────────────────────────

#[tokio::main]
async fn main() -> io::Result<()> {
    let port: u16 = std::env::var("FLAN_SERVER_PORT")
        .ok()
        .and_then(|p| p.parse().ok())
        .or_else(|| {
            std::env::args()
                .skip_while(|a| a != "--port")
                .nth(1)
                .and_then(|p| p.parse().ok())
        })
        .unwrap_or(4050);

    // `--watch 9689[,3000]` names web dev servers to instrument; see the
    // `watch` module. Persisted, so it only has to be said once.
    {
        let args: Vec<String> = std::env::args().collect();
        for (i, arg) in args.iter().enumerate() {
            let list = match arg.strip_prefix("--watch=") {
                Some(list) => Some(list.to_string()),
                None if arg == "--watch" => args.get(i + 1).cloned(),
                None => None,
            };
            for port in list.as_deref().map(watch::parse_port_list).unwrap_or_default() {
                watch::add_watched_port(port);
            }
        }
    }

    // Send tracing to the same log file the standalone server uses. Without a
    // subscriber every tracing::info! in the request path is discarded, which
    // makes a misrouted flush impossible to diagnose after the fact.
    if let Ok(log_file) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(flan_dir().join("server.log"))
    {
        let _ = tracing_subscriber::fmt()
            .with_env_filter(
                tracing_subscriber::EnvFilter::try_from_default_env()
                    .unwrap_or_else(|_| "flan_server=info".parse().unwrap()),
            )
            .with_writer(std::sync::Mutex::new(log_file))
            .with_ansi(false)
            .try_init();
    }

    // Shared state between TUI and HTTP server
    let shared = Arc::new(SharedState::new());

    // Bind BEFORE taking over the terminal.
    //
    // A busy port is the common failure — a flan-server or a second TUI
    // already owns 4050 — and binding inside the spawned task made it a
    // silent trap: the task panicked, the panic hook below ran
    // `disable_raw_mode()` on the tty, and the TUI carried on drawing over a
    // cooked terminal. Keystrokes echoed instead of being delivered, so `q`
    // printed a `q` and never quit. Fail here, while the terminal is still
    // plainly ours, and say what to do about it.
    let listener = match tokio::net::TcpListener::bind(format!("0.0.0.0:{}", port)).await {
        Ok(listener) => listener,
        Err(err) => {
            eprintln!("flan-tui: cannot listen on port {port}: {err}");
            eprintln!(
                "Another flan-tui or flan-server already has it. Stop that process, \n\
                 or start this one on a free port with FLAN_SERVER_PORT=<port>."
            );
            std::process::exit(1);
        }
    };

    // Serve in the background. The TUI and the HTTP API share one state, so
    // agents register with whichever process holds the port — running both a
    // TUI and a standalone server splits that state in two.
    let server_state = shared.clone();
    tokio::spawn(async move {
        axum::serve(listener, build_router(server_state)).await.ok();
    });
    watch::spawn_watch_proxies(shared.clone(), port).await;

    // Terminal setup — open /dev/tty directly so raw mode works even when
    // launched inside trm or another terminal emulator in debug mode.
    let tty = OpenOptions::new().read(true).write(true).open("/dev/tty")?;
    enable_raw_mode()?;
    let mut tty_out = tty;
    execute!(tty_out, EnterAlternateScreen)?;
    let backend = ratatui::backend::CrosstermBackend::new(tty_out);
    let mut terminal = Terminal::new(backend)?;

    let original_hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        let _ = disable_raw_mode();
        if let Ok(mut t) = OpenOptions::new().write(true).open("/dev/tty") {
            let _ = execute!(t, LeaveAlternateScreen);
        }
        original_hook(info);
    }));

    let mut app = App::new(shared, port);

    // Channel for background discovery results.
    let (discovery_tx, mut discovery_rx) = mpsc::channel::<DiscoveryResult>(1);
    let (relay_tx, mut relay_rx) = mpsc::channel::<Vec<RelayCheck>>(1);

    // Kick off the initial discovery immediately.
    spawn_discovery(discovery_tx.clone());
    // ...and ask the relays who they are, before the first link is made.
    spawn_relay_check(relay_tx.clone());

    let mut event_stream = event::EventStream::new();
    let mut refresh_interval = tokio::time::interval(Duration::from_secs(5));
    refresh_interval.tick().await; // consume the immediate tick
    let mut log_poll = tokio::time::interval(Duration::from_millis(500));
    log_poll.tick().await;
    // Relays only change when somebody restarts one, so this is a slow patrol
    // rather than part of the discovery cycle.
    let mut relay_poll = tokio::time::interval(Duration::from_secs(60));
    relay_poll.tick().await;

    loop {
        if let Some((_, ts)) = &app.toast {
            if ts.elapsed() > Duration::from_secs(3) {
                app.toast = None;
            }
        }

        terminal.draw(|f| ui(f, &mut app))?;

        tokio::select! {
            biased;
            Some(Ok(evt)) = event_stream.next() => {
                match evt {
                    Event::Key(KeyEvent { code, modifiers, .. }) => {
                        if code == KeyCode::Char('c') && modifiers.contains(KeyModifiers::CONTROL) {
                            break;
                        }

                        match code {
                            KeyCode::Char('q') | KeyCode::Esc => break,

                            KeyCode::Up | KeyCode::Char('k') => app.move_up(),
                            KeyCode::Down | KeyCode::Char('j') => app.move_down(),

                            KeyCode::Left | KeyCode::Right | KeyCode::Tab | KeyCode::BackTab => app.toggle_column(),

                            KeyCode::Char('g') => {
                                if app.focus == Focus::Log {
                                    app.focus = Focus::Main;
                                    app.log_visible = false;
                                } else if app.log_visible {
                                    app.focus = Focus::Log;
                                    if !app.log_snapshot.is_empty() {
                                        app.log_state.select(Some(0));
                                    }
                                } else {
                                    app.log_visible = true;
                                    app.focus = Focus::Log;
                                    if !app.log_snapshot.is_empty() {
                                        app.log_state.select(Some(0));
                                    }
                                }
                            }

                            KeyCode::Char('s') | KeyCode::Char('r') => {
                                spawn_discovery(discovery_tx.clone());
                                app.set_toast("Scanning…");
                            }

                            KeyCode::Char('l') => {
                                let flutter_pid = app.selected_flutter_pid();
                                let surface_id = app.selected_claude_id();

                                if let (Some(pid), Some(sid)) = (flutter_pid, surface_id) {
                                    // Capture the app's cwd so the link survives a
                                    // rebuild (new pid, same cwd) — the flush
                                    // handler re-binds by cwd when the pid misses.
                                    let flutter_cwd = app
                                        .selected_flutter()
                                        .map(|f| f.cwd.clone())
                                        .filter(|c| !c.is_empty());
                                    // An app with no local process reports pid
                                    // 0, so its FLAN_APP_ID is the only thing
                                    // that identifies it — and for a local app
                                    // it outlives a rebuild.
                                    let flutter_app_id = app
                                        .selected_flutter()
                                        .and_then(|f| f.app_id.clone())
                                        .filter(|id| !id.is_empty());
                                    let assoc = Association {
                                        id: new_association_id(),
                                        claude_surface_id: sid.clone(),
                                        flutter_pid: pid,
                                        flutter_cwd,
                                        flutter_app_id: flutter_app_id.clone(),
                                    };
                                    // Update shared state
                                    {
                                        let mut assocs = app.shared.associations.write().await;
                                        // Replace this app's link only. Matching
                                        // on pid alone would drop every other
                                        // remote app's link, since they share 0.
                                        assocs.retain(|a| match (&a.flutter_app_id, &flutter_app_id) {
                                            (Some(existing), Some(new)) => existing != new,
                                            _ => a.flutter_pid != pid || pid == 0,
                                        });
                                        assocs.push(assoc);
                                        save_associations(&app.shared.persistence_path, &assocs);
                                    }
                                    app.associations = app.shared.associations.read().await.clone();
                                    // Linking moves this pair to the top of the row list, so the
                                    // old row indices no longer point at the same items. Re-anchor
                                    // the cursor to the PID/surface the user actually selected.
                                    app.reanchor_selection(Some(pid), Some(sid.clone()));
                                    app.log("in", format!("Link created: PID {} → {}", pid, &sid[..8.min(sid.len())]), None, true).await;
                                    app.sync_log_snapshot().await;
                                    app.set_toast("Link created");
                                    // A link is the moment someone starts
                                    // expecting the app's relay to answer, so
                                    // re-check it now rather than up to a
                                    // minute later.
                                    spawn_relay_check(relay_tx.clone());
                                } else {
                                    app.set_toast("Select both a Flutter app and Claude surface first");
                                }
                            }

                            KeyCode::Char('u') => {
                                // Capture the selected identities before the row list
                                // is rebuilt, so the cursor can follow them afterwards.
                                let sel_pid = app.selected_flutter_pid();
                                let sel_claude = app.selected_claude_id();
                                let assoc_id = match app.active_column {
                                    Column::Flutter => app
                                        .selected_flutter()
                                        .and_then(|f| app.assoc_for_flutter(f.pid))
                                        .map(|a| a.id.clone()),
                                    Column::Claude => app
                                        .selected_entry()
                                        .and_then(|e| app.assoc_for_surface(&e.id()))
                                        .map(|a| a.id.clone()),
                                };

                                if let Some(id) = assoc_id {
                                    {
                                        let mut assocs = app.shared.associations.write().await;
                                        assocs.retain(|a| a.id != id);
                                        save_associations(&app.shared.persistence_path, &assocs);
                                    }
                                    app.associations = app.shared.associations.read().await.clone();
                                    // Unlinking moves this pair out of the linked block,
                                    // shifting row indices — re-anchor to the same items.
                                    app.reanchor_selection(sel_pid, sel_claude);
                                    app.log("in", format!("Unlinked: {}", id), None, true).await;
                                    app.sync_log_snapshot().await;
                                    app.set_toast("Unlinked");
                                } else {
                                    app.set_toast("No link on this item");
                                }
                            }

                            KeyCode::Char('f') => {
                                match app.active_column {
                                    Column::Flutter => {
                                        let device = app
                                            .selected_flutter()
                                            .and_then(|f| f.device.clone())
                                            .unwrap_or_else(|| "chrome".to_string());
                                        let d = device.clone();
                                        let ok = tokio::task::spawn_blocking(move || focus_app_by_device(&d))
                                            .await
                                            .unwrap_or(false);
                                        app.log("out", format!("Focus app: {}", device), None, ok).await;
                                        app.sync_log_snapshot().await;
                                        app.set_toast(if ok { format!("Focused {}", device) } else { "Focus failed".into() });
                                    }
                                    Column::Claude => {
                                        match app.selected_entry() {
                                            Some(ClaudeEntry::Cmux(surface)) => {
                                                let id = surface.id.clone();
                                                let id2 = id.clone();
                                                let ok = tokio::task::spawn_blocking(move || cmux_focus_surface(&id2))
                                                    .await
                                                    .unwrap_or(false);
                                                app.log("out", format!("Focus surface {}…", &id[..8.min(id.len())]), None, ok).await;
                                                app.sync_log_snapshot().await;
                                                app.set_toast(if ok { "Focused pane" } else { "Focus failed".into() });
                                            }
                                            Some(ClaudeEntry::Trm(pane)) => {
                                                let idx = pane.index;
                                                let sid = pane.surface_id.clone();
                                                let label = sid.clone().unwrap_or_else(|| format!("trm:{}", pane.pane_id));
                                                let ok = tokio::task::spawn_blocking(move || {
                                                    if let Some(sid) = sid {
                                                        trm_focus_pane_by_surface(&sid)
                                                    } else {
                                                        trm_focus_pane(idx)
                                                    }
                                                })
                                                    .await
                                                    .unwrap_or(false);
                                                app.log("out", format!("Focus trm:{}…", label), None, ok).await;
                                                app.sync_log_snapshot().await;
                                                app.set_toast(if ok { format!("Focused {}", label) } else { format!("Failed {}", label) });
                                            }
                                            Some(ClaudeEntry::Session(agent)) => {
                                                // No pane means nothing to raise —
                                                // the agent lives in a detached
                                                // session on some other display.
                                                app.set_toast(format!(
                                                    "{} has no pane to focus ({})",
                                                    agent.session_name.as_deref().unwrap_or("session"),
                                                    agent.tty.as_deref().unwrap_or("headless"),
                                                ));
                                            }
                                            None => {
                                                app.set_toast("No surface to focus");
                                            }
                                        }
                                    }
                                }
                            }

                            KeyCode::Char('t') => {
                                let selected = app.selected_entry();
                                let target_label = selected.as_ref()
                                    .map(|e| e.id())
                                    .unwrap_or_else(|| format!("none (claude_row={:?})", app.claude_row));

                                // If the pane has a channel port, use channel push.
                                // Otherwise, fall back to text injection via trm socket.
                                let channel_port = selected.as_ref().and_then(|e| match e {
                                    ClaudeEntry::Trm(p) => p.channel_port,
                                    ClaudeEntry::Session(a) => a.channel_port,
                                    ClaudeEntry::Cmux(_) => None,
                                });

                                // Useful routing context so the agent (and the
                                // human watching the TUI) can confirm the test
                                // landed in the right pane, plus an explicit ask
                                // for the agent to reply confirming it can see
                                // the linked Flutter app.
                                let routing_info = match selected.as_ref() {
                                    Some(ClaudeEntry::Trm(p)) => format!(
                                        "Routed to trm pane_id={} (surface {}){}{}{}",
                                        p.pane_id,
                                        p.surface_id.as_deref().unwrap_or("?"),
                                        p.cwd.as_deref()
                                            .map(|c| format!(", cwd={}", c))
                                            .unwrap_or_default(),
                                        p.login_pid
                                            .map(|l| format!(", login_pid={}", l))
                                            .unwrap_or_default(),
                                        channel_port
                                            .map(|port| format!(", channel_port={}", port))
                                            .unwrap_or_default(),
                                    ),
                                    Some(ClaudeEntry::Cmux(s)) => {
                                        format!("Routed to cmux surface {}", s.id)
                                    }
                                    Some(ClaudeEntry::Session(a)) => format!(
                                        "Routed to session {} (no pane){}{}{}{}",
                                        a.session_name.as_deref().unwrap_or("?"),
                                        a.agent_pid.map(|p| format!(", agent_pid={}", p)).unwrap_or_default(),
                                        a.tty.as_deref().map(|t| format!(", tty={}", t)).unwrap_or_default(),
                                        a.cwd.as_deref().map(|c| format!(", cwd={}", c)).unwrap_or_default(),
                                        a.channel_port.map(|p| format!(", channel_port={}", p)).unwrap_or_default(),
                                    ),
                                    None => "Routed to <unknown>".to_string(),
                                };

                                // Resolve the linked Flutter app's VM service URI
                                // up front so the test flush carries it (just like
                                // the `x` flush does). Without it the agent gets
                                // "not connected" with no URI and has to hand-hunt
                                // the DDS auth token — slow and error-prone. We
                                // look up agent → association → flutter app, using
                                // the cached URI or re-probing by pid as a fallback.
                                let test_vm_uri: Option<String> = selected.as_ref()
                                    .map(|e| e.id())
                                    .and_then(|sid| app.assoc_for_surface(&sid).cloned())
                                    .and_then(|assoc| {
                                        let fpid = assoc.flutter_pid;
                                        let cached = app.flutter_apps.iter()
                                            .find(|f| f.pid == fpid)
                                            .and_then(|f| f.vm_service_uri.clone());
                                        cached.or_else(|| {
                                            tokio::task::block_in_place(|| probe_vm_service_uri(fpid))
                                        })
                                    });

                                let app_hint = if test_vm_uri.is_some() {
                                    "A vm_uri for the linked Flutter app is attached — \
                                     use the flan connect tool with it (don't go hunting \
                                     for the VM service URI yourself), then report the \
                                     app's current screen."
                                } else {
                                    "No linked Flutter app was found for this agent, so \
                                     no vm_uri is attached — just confirm you received \
                                     this message."
                                };

                                // A Codex target takes the same road a real flush
                                // does: `codex queue` into its open thread. Its
                                // flan-channel (if any) would only reject the batch.
                                let codex_pid: Option<u32> = match selected.as_ref() {
                                    Some(ClaudeEntry::Session(a))
                                        if a.agent_name.as_deref() == Some("Codex") =>
                                    {
                                        a.agent_pid
                                    }
                                    Some(ClaudeEntry::Trm(p))
                                        if p.agent_name.as_deref() == Some("Codex") =>
                                    {
                                        let target = format!("trm:{}", p.pane_id);
                                        tokio::task::spawn_blocking(move || codex_pid_for_target(&target))
                                            .await
                                            .ok()
                                            .flatten()
                                    }
                                    _ => None,
                                };

                                if let Some(pid) = codex_pid {
                                    let test_text = format!(
                                        "Flan connectivity test from the TUI (relayed with \
                                         `codex queue`).\n{}\n\n\
                                         If you can read this, the Flan → Codex relay is wired \
                                         up correctly. {}",
                                        routing_info, app_hint
                                    );
                                    let (text, images) = format_codex_message(
                                        &[serde_json::json!({"type": "test", "text": test_text})],
                                        test_vm_uri.as_deref(),
                                        None,
                                    );
                                    let result = tokio::task::spawn_blocking(move || {
                                        let thread = codex_threads_for_pid(pid)
                                            .into_iter()
                                            .next()
                                            .ok_or_else(|| format!("Codex pid {pid} has no open thread"))?;
                                        relay_codex_queue(&thread, &text, &images).map(|_| thread)
                                    })
                                    .await
                                    .unwrap_or_else(|e| Err(e.to_string()));
                                    let (ok, detail) = match result {
                                        Ok(thread) => (true, format!("codex queue → thread {}", thread)),
                                        Err(e) => (false, e),
                                    };
                                    app.log("out", format!("Test codex → pid {}", pid), Some(detail.clone()), ok).await;
                                    app.sync_log_snapshot().await;
                                    app.set_toast(if ok { format!("Test → {} (codex queue)", target_label) } else { detail });
                                } else if let Some(port) = channel_port {
                                    let test_text = format!(
                                        "Flan connectivity test from the TUI.\n{}\n\n\
                                         If you can read this, the flan-channel is wired up \
                                         correctly. {}",
                                        routing_info, app_hint
                                    );
                                    // Include vm_service_uri so the channel surfaces
                                    // a vm_uri attribute and the agent can connect in
                                    // one step instead of discovering the URI itself.
                                    let payload = match test_vm_uri.as_ref() {
                                        Some(uri) => serde_json::json!({
                                            "vm_service_uri": uri,
                                            "messages": [{
                                                "type": "test",
                                                "text": test_text,
                                            }]
                                        }),
                                        None => serde_json::json!({
                                            "messages": [{
                                                "type": "test",
                                                "text": test_text,
                                            }]
                                        }),
                                    };
                                    let body_str = payload.to_string();
                                    let req = format!(
                                        "POST /flush HTTP/1.1\r\nHost: 127.0.0.1:{}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                                        port, body_str.len(), body_str
                                    );
                                    let (ok, detail) = match tokio::net::TcpStream::connect(
                                        format!("127.0.0.1:{}", port)
                                    ).await {
                                        Ok(mut stream) => {
                                            match tokio::io::AsyncWriteExt::write_all(&mut stream, req.as_bytes()).await {
                                                Ok(_) => {
                                                    let mut buf = vec![0u8; 4096];
                                                    let resp = match tokio::time::timeout(
                                                        std::time::Duration::from_secs(2),
                                                        tokio::io::AsyncReadExt::read(&mut stream, &mut buf),
                                                    ).await {
                                                        Ok(Ok(n)) => String::from_utf8_lossy(&buf[..n]).to_string(),
                                                        Ok(Err(e)) => format!("read err: {}", e),
                                                        Err(_) => "read timeout".into(),
                                                    };
                                                    (true, format!("sent ok, response: {}", resp))
                                                }
                                                Err(e) => (false, format!("write err: {}", e)),
                                            }
                                        }
                                        Err(e) => (false, format!("connect err: {}", e)),
                                    };
                                    app.log("out", format!("Test channel → :{}", port), Some(detail.clone()), ok).await;
                                    app.sync_log_snapshot().await;
                                    app.set_toast(if ok { format!("Test → {} :{}", target_label, port) } else { detail.clone() });
                                } else if let Some(entry) = selected {
                                    // No channel — inject text directly into the pane.
                                    let text = format!(
                                        "Flan connectivity test from the TUI (no channel — \
                                         injected as text). {} Please reply confirming whether \
                                         you can see the linked Flutter app and its current route.",
                                        routing_info
                                    );
                                    let t = text.clone();
                                    let label = target_label.clone();
                                    let ok = match entry {
                                        ClaudeEntry::Trm(p) => {
                                            let pid = p.pane_id;
                                            tokio::task::spawn_blocking(move || trm_send_to_pane(pid, &t))
                                                .await.unwrap_or(false)
                                        }
                                        ClaudeEntry::Cmux(s) => {
                                            let sid = s.id.clone();
                                            tokio::task::spawn_blocking(move || cmux_send_text(&sid, &t) && cmux_send_text(&sid, "\n"))
                                                .await.unwrap_or(false)
                                        }
                                        // A session with a channel took the
                                        // branch above; one without has no pane
                                        // to type into either, so there is
                                        // nowhere to deliver this.
                                        ClaudeEntry::Session(_) => false,
                                    };
                                    app.log("out", format!("Test text → {}", label), Some(text), ok).await;
                                    app.sync_log_snapshot().await;
                                    app.set_toast(if ok { format!("Test → {} (text)", target_label) } else { "Test failed".to_string() });
                                } else {
                                    app.set_toast("No agent selected");
                                }
                            }

                            // Shift-R: hot reload the selected app. Lower
                            // case `r` is taken by refresh, and a reload is
                            // the more consequential of the two — it should
                            // not be a neighbour of `q` on the home row.
                            KeyCode::Char('R') => {
                                if let Some(flutter) = app.selected_flutter().cloned() {
                                    let label = if flutter.folder_name.is_empty() {
                                        format!("pid {}", flutter.pid)
                                    } else {
                                        flutter.folder_name.clone()
                                    };
                                    // Signalling a local app is a syscall; only
                                    // the VM-service and peer paths actually
                                    // wait, and those are bounded.
                                    let outcome = tokio::task::spawn_blocking(move || {
                                        hot_reload_app(&flutter, false)
                                    })
                                    .await
                                    .unwrap_or_else(|error| HotReloadOutcome {
                                        ok: false,
                                        via: "none".into(),
                                        detail: format!("Hot reload task failed: {}", error),
                                        needs_page_refresh: false,
                                    });
                                    app.log(
                                        "out",
                                        format!("Hot reload {} via {}", label, outcome.via),
                                        Some(outcome.detail.clone()),
                                        outcome.ok,
                                    )
                                    .await;
                                    app.sync_log_snapshot().await;
                                    app.set_toast(&outcome.detail);
                                } else {
                                    app.set_toast("Select a Flutter app first");
                                }
                            }

                            KeyCode::Char('x') => {
                                if let Some(flutter) = app.selected_flutter() {
                                    let pid = flutter.pid;
                                    let vm_uri = flutter.vm_service_uri.clone();

                                    let assoc = app.assoc_for_flutter(pid).cloned();
                                    // The association must still resolve to a live linked
                                    // receiver — a Claude-bearing entry that currently
                                    // exists. claude_entries() only contains entries with
                                    // Claude running, so a match here means the receiver is
                                    // live. Without it a flush would silently fall back to
                                    // text injection into a dead/missing pane and the
                                    // message would be lost — refuse and tell the user.
                                    let receiver_live = assoc.as_ref().is_some_and(|a| {
                                        app.claude_entries()
                                            .iter()
                                            .any(|e| e.id() == a.claude_surface_id)
                                    });
                                    if assoc.is_some() && !receiver_live {
                                        app.set_toast("No linked receiver — message not sent (link it first)");
                                        continue;
                                    }
                                    if let Some(assoc) = assoc {
                                        // Re-probe at flush time if not in cache — the
                                        // discovery cycle may have missed the URI.
                                        let vm_uri = vm_uri.or_else(|| {
                                            tokio::task::block_in_place(|| probe_vm_service_uri(pid))
                                        });
                                        let Some(uri) = vm_uri.clone() else {
                                            app.set_toast("Flush failed: VM service URI not yet resolved");
                                            continue;
                                        };

                                        let sid = assoc.claude_surface_id.clone();
                                        let label = sid[..8.min(sid.len())].to_string();

                                        // Check whether the target agent has a live
                                        // flan-channel (a pane's registered port,
                                        // or a pane-less registration).
                                        let channel_port = app.channel_port_for_id(&sid);

                                        if let Some(port) = channel_port {
                                            // Channel push — the flan-channel MCP server will
                                            // deliver the message directly into the Claude session.
                                            let payload = serde_json::json!({
                                                "vm_service_uri": uri,
                                                "messages": []
                                            });
                                            let body_str = payload.to_string();
                                            let req = format!(
                                                "POST /flush HTTP/1.1\r\nHost: 127.0.0.1:{}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                                                port, body_str.len(), body_str
                                            );
                                            let (ok, detail) = match tokio::net::TcpStream::connect(
                                                format!("127.0.0.1:{}", port)
                                            ).await {
                                                Ok(mut stream) => {
                                                    match tokio::io::AsyncWriteExt::write_all(&mut stream, req.as_bytes()).await {
                                                        Ok(_) => (true, "channel push ok".into()),
                                                        Err(e) => (false, format!("write err: {}", e)),
                                                    }
                                                }
                                                Err(e) => (false, format!("connect err: {}", e)),
                                            };
                                            app.log("out", format!("Flush channel → {} :{}", label, port), Some(detail.clone()), ok).await;
                                            app.sync_log_snapshot().await;
                                            app.set_toast(if ok { "Flushed (channel)" } else { &detail });
                                        } else {
                                            // No channel — inject text directly into the pane.
                                            let text = format!("flan connect to {}", uri);
                                            let t = text.clone();
                                            // Resolve the actual pane_id before entering spawn_blocking.
                                            let trm_pane_id = if sid.starts_with("trm:") {
                                                sid["trm:".len()..].parse::<usize>().ok()
                                                    .and_then(|pane_id| app.trm_panes.iter().find(|p| p.pane_id == pane_id))
                                                    .map(|p| p.pane_id)
                                            } else {
                                                None
                                            };
                                            let ok = tokio::task::spawn_blocking(move || {
                                                if let Some(pid) = trm_pane_id {
                                                    trm_send_to_pane(pid, &t)
                                                } else if cmux_send_text(&sid, &t) {
                                                    cmux_send_text(&sid, "\n")
                                                } else {
                                                    false
                                                }
                                            })
                                            .await
                                            .unwrap_or(false);
                                            app.log("out", format!("Flush text → {}…", label), Some(text), ok).await;
                                            app.sync_log_snapshot().await;
                                            app.set_toast(if ok { "Flushed (text)" } else { "Flush failed" });
                                        }
                                    } else {
                                        app.set_toast("No association for this Flutter app");
                                    }
                                } else {
                                    app.set_toast("Select a Flutter app first");
                                }
                            }

                            _ => {}
                        }
                    }
                    Event::Resize(_, _) => {}
                    _ => {}
                }
            }
            Some(result) = discovery_rx.recv() => {
                app.apply_discovery(result).await;
            }
            _ = refresh_interval.tick() => {
                spawn_discovery(discovery_tx.clone());
            }
            Some(checks) = relay_rx.recv() => {
                app.apply_relay_checks(checks).await;
            }
            _ = relay_poll.tick() => {
                spawn_relay_check(relay_tx.clone());
            }
            _ = log_poll.tick() => {
                let prev_len = app.log_snapshot.len();
                app.sync_log_snapshot().await;
                if app.log_snapshot.len() != prev_len {
                    // New log entries arrived (e.g. from HTTP flush) — redraw
                }
            }
        }
    }

    disable_raw_mode()?;
    execute!(terminal.backend_mut(), LeaveAlternateScreen)?;
    Ok(())
}


#[cfg(test)]
mod tests {
    use super::*;

    fn sess(port: Option<u16>, name: &str, cwd: &str) -> AgentSession {
        AgentSession {
            session_id: Some(format!("id-{name}")),
            agent_pid: Some(port.unwrap_or(1) as u32),
            agent_name: Some("Claude".into()),
            session_name: Some(name.into()),
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

    fn pane(pane_id: usize, cwd: &str, channel_port: Option<u16>) -> TrmPane {
        TrmPane {
            index: pane_id,
            pane_id,
            folder_name: None,
            cwd: Some(cwd.into()),
            has_claude: true,
            agent_name: Some("Claude".into()),
            surface_id: None,
            title: None,
            channel_port,
            login_pid: None,
            has_dev_channels: false,
        }
    }

    /// The headless case this whole entry kind exists for: no panes at all
    /// (trm's RPC is absent), so every agent must come from the session
    /// registry or the column is empty.
    #[test]
    fn sessions_become_entries_when_there_are_no_panes() {
        let mut entries: Vec<ClaudeEntry> = Vec::new();
        let sessions = vec![
            sess(Some(60365), "flan-mcp-8f", "/Users/g/dev/flan_mcp"),
            sess(Some(60604), "fasmac-40", "/Users/g/dev/fasmac"),
        ];

        append_session_entries(&mut entries, &sessions);

        let ids: Vec<String> = entries.iter().map(|e| e.id()).collect();
        assert_eq!(ids, vec!["sess:60365", "sess:60604"]);
        assert!(entries.iter().all(|e| e.is_claude()));
        assert_eq!(entries[1].cwd(), Some("/Users/g/dev/fasmac"));
    }

    /// A session with no flan-channel is listed but not reachable. Filtering
    /// these out is what hid half the running agents.
    #[test]
    fn a_session_without_a_channel_is_listed_but_unreachable() {
        let mut entries: Vec<ClaudeEntry> = Vec::new();
        let sessions = vec![sess(None, "trm-34", "/Users/g/dev/trm")];

        append_session_entries(&mut entries, &sessions);

        assert_eq!(entries.len(), 1);
        let reachable: Vec<bool> = entries
            .iter()
            .map(|e| match e {
                ClaudeEntry::Session(a) => a.channel_port.is_some(),
                _ => true,
            })
            .collect();
        assert_eq!(reachable, vec![false]);
    }

    /// Two live agents CAN report the same Claude session id — resuming one
    /// session twice does it — so identity must not be the session id, or the
    /// two would collapse onto one link.
    #[test]
    fn two_agents_resuming_one_session_keep_separate_identities() {
        let mut a = sess(Some(60365), "pe-2a", "/Users/g/dev/pe");
        let mut b = sess(Some(60391), "pe-49", "/Users/g/dev/pe");
        a.session_id = Some("877cf911".into());
        b.session_id = Some("877cf911".into());
        a.agent_pid = Some(44254);
        b.agent_pid = Some(6947);
        let mut entries: Vec<ClaudeEntry> = Vec::new();

        append_session_entries(&mut entries, &[a, b]);

        assert_ne!(entries[0].id(), entries[1].id());
    }

    /// Two agents in the same repo — routine here, since several sessions run
    /// against one checkout. They must stay separate entries; keying on cwd
    /// would silently merge them and route both apps to one agent.
    #[test]
    fn sessions_sharing_a_cwd_stay_distinct_entries() {
        let mut entries: Vec<ClaudeEntry> = Vec::new();
        let sessions = vec![
            sess(Some(60365), "flan-mcp-8f", "/Users/g/dev/flan_mcp"),
            sess(Some(60391), "flan-mcp-a9", "/Users/g/dev/flan_mcp"),
        ];

        append_session_entries(&mut entries, &sessions);

        assert_eq!(entries.len(), 2);
        assert_ne!(entries[0].id(), entries[1].id());
    }

    /// A pane whose channel port is already known is the SAME agent seen from
    /// both sides. It must render once — as the pane, which can also be
    /// focused and text-injected.
    #[test]
    fn a_session_already_bound_to_a_pane_is_not_listed_twice() {
        let mut entries = vec![
            ClaudeEntry::Trm(pane(19, "/Users/g/dev/flan_mcp", Some(60365))),
            ClaudeEntry::Trm(pane(20, "/Users/g/dev/trm", None)),
        ];
        let sessions = vec![
            sess(Some(60365), "flan-mcp-8f", "/Users/g/dev/flan_mcp"), // same agent as pane 19
            sess(Some(60604), "fasmac-40", "/Users/g/dev/fasmac"),     // pane-less
        ];

        append_session_entries(&mut entries, &sessions);

        let ids: Vec<String> = entries.iter().map(|e| e.id()).collect();
        assert_eq!(ids, vec!["trm:19", "trm:20", "sess:60604"]);
    }

    fn assoc(pid: u32, sid: &str) -> Association {
        Association {
            id: format!("{pid}"),
            claude_surface_id: sid.into(),
            flutter_pid: pid,
            flutter_cwd: None,
            flutter_app_id: None,
        }
    }

    // Reproduces the live state: 3 chrome Flutter apps, 4 trm agents, with two
    // apps linked to the SAME agent (trm:19).
    #[test]
    fn all_flutter_apps_get_a_row_even_when_two_link_to_one_agent() {
        let flutter = vec![
            (31421u32, "/Users/gaurav/dev/fasmac/frontend"),
            (35190, "/Users/gaurav/dev/tow/dispatch/tower"),
            (36213, "/Users/gaurav/dev/tow/dispatch/customer"),
        ];
        let entry_ids = vec![
            "trm:0".to_string(), "trm:19".to_string(),
            "trm:20".to_string(), "trm:25".to_string(),
        ];
        let entry_cwds = vec![
            Some("/Users/gaurav/dev/fasmac"),
            Some("/Users/gaurav/dev/tow"),
            Some("/Users/gaurav/dev/trm"),
            Some("/Users/gaurav/dev/flan_mcp"),
        ];
        let assocs = vec![
            assoc(31421, "trm:0"),
            assoc(35190, "trm:19"),
            assoc(36213, "trm:19"), // duplicate target
        ];
        // entry_reachable is indexed by ENTRY (surface), not flutter app.
        let entry_reachable = vec![true, true, true, true];

        let rows = build_rows_inner(&flutter, &entry_reachable, &entry_ids, &entry_cwds, &assocs);

        // Every Flutter app must be present in exactly one row.
        for (pid, _) in &flutter {
            let count = rows.iter()
                .filter(|r| r.flutter.map(|fi| flutter[fi].0 == *pid).unwrap_or(false))
                .count();
            assert_eq!(count, 1, "pid {pid} should appear in exactly one row, got {count}");
        }

        // The shared agent (trm:19) must be RENDERED exactly once...
        let si_19 = entry_ids.iter().position(|id| id == "trm:19").unwrap();
        let rendered = rows.iter().filter(|r| r.surface == Some(si_19)).count();
        assert_eq!(rendered, 1, "shared agent should render once, got {rendered}");
        // ...but BOTH apps linked to it must reference it via link_si.
        let linked = rows.iter().filter(|r| r.link_si == Some(si_19)).count();
        assert_eq!(linked, 2, "both apps should link to the shared agent, got {linked}");

        // The two members should be contiguous so the connector bus is unbroken.
        let positions: Vec<usize> = rows.iter().enumerate()
            .filter(|(_, r)| r.link_si == Some(si_19))
            .map(|(i, _)| i)
            .collect();
        assert_eq!(positions[1] - positions[0], 1, "shared-agent rows must be adjacent");
    }

    #[test]
    fn cwd_proximity_without_association_draws_no_line() {
        // App and agent share a cwd but there is NO association. They may be
        // placed on the same row for layout, but NO connector line should draw —
        // a line means an explicit link, not a proximity guess.
        let flutter = vec![(111u32, "/Users/gaurav/dev/fasmac/frontend")];
        let entry_ids = vec!["trm:0".to_string()];
        let entry_cwds = vec![Some("/Users/gaurav/dev/fasmac")];
        let entry_reachable = vec![true]; // agent IS reachable, but unlinked
        let assocs: Vec<Association> = vec![]; // <-- no associations

        let rows = build_rows_inner(&flutter, &entry_reachable, &entry_ids, &entry_cwds, &assocs);

        assert_eq!(rows.len(), 1);
        assert!(rows[0].link_si.is_none(), "proximity row must not carry link_si");
        assert!(!rows[0].connected, "proximity row must not be marked connected");
    }

    #[test]
    fn single_link_draws_straight_horizontal_run() {
        let rows = vec![Row { flutter: Some(0), surface: Some(0), link_si: Some(0), connected: true }];
        let heights = vec![2];
        let g = build_connector_glyphs(&rows, &heights, 0, 4, 7);
        // Anchor (line 0) is a full horizontal run; other lines blank.
        assert!(g[0].chars().all(|c| c == '─'), "got {:?}", g[0]);
        assert_eq!(g[0].chars().count(), 7);
        assert!(g[1].trim().is_empty());
    }

    #[test]
    fn no_connection_draws_no_line() {
        // Linked (link_si set) but NOT connected → no connector at all.
        let rows = vec![Row { flutter: Some(0), surface: Some(0), link_si: Some(0), connected: false }];
        let heights = vec![2];
        let g = build_connector_glyphs(&rows, &heights, 0, 4, 7);
        assert!(g.iter().all(|l| l.trim().is_empty()), "no line when disconnected; got {:?}", g);
    }

    #[test]
    fn shared_agent_draws_orthogonal_bus() {
        // Two apps (rows 0 and 1) share agent rendered on row 0.
        let rows = vec![
            Row { flutter: Some(0), surface: Some(5), link_si: Some(5), connected: true }, // head: renders agent
            Row { flutter: Some(1), surface: None,    link_si: Some(5), connected: true }, // member
        ];
        let heights = vec![2, 2];
        let g = build_connector_glyphs(&rows, &heights, 0, 4, 7);
        // Row 0 anchor at line 0, row 1 anchor at line 2. Bus column = 3.
        let chars = |s: &str| s.chars().collect::<Vec<_>>();
        // Line 0 = head row: left stub + tee (agent stub goes right too).
        let l0 = chars(&g[0]);
        assert_eq!(l0[3], '┬', "head corner is a downward tee; got {:?}", g[0]);
        assert_eq!(&l0[0..3], &['─', '─', '─'], "head has left stub");
        assert_eq!(&l0[4..7], &['─', '─', '─'], "head extends right toward agent");
        // Line 1 = vertical bus between the two members.
        assert_eq!(chars(&g[1])[3], '│', "bus runs vertically");
        // Line 2 = bottom member: left stub + bottom corner, no right stub.
        let l2 = chars(&g[2]);
        assert_eq!(l2[3], '┘', "bottom member corner; got {:?}", g[2]);
        assert_eq!(&l2[0..3], &['─', '─', '─'], "bottom member has left stub");
        assert_eq!(&l2[4..7], &[' ', ' ', ' '], "no right stub on a non-agent member");
    }
}
