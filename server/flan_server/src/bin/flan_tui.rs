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
    surface: Option<usize>,
}

fn build_rows(app: &App) -> Vec<Row> {
    let entries = app.claude_entries();
    let mut used_flutter: Vec<bool> = vec![false; app.flutter_apps.len()];
    let mut used_surface: Vec<bool> = vec![false; entries.len()];
    let mut rows = Vec::new();

    for assoc in &app.associations {
        let fi = app
            .flutter_apps
            .iter()
            .position(|f| f.pid == assoc.flutter_pid);
        let si = entries
            .iter()
            .position(|e| e.id() == assoc.claude_surface_id);
        if let (Some(fi), Some(si)) = (fi, si) {
            if !used_flutter[fi] && !used_surface[si] {
                used_flutter[fi] = true;
                used_surface[si] = true;
                rows.push(Row {
                    flutter: Some(fi),
                    surface: Some(si),
                });
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
        let flutter_cwd = app.flutter_apps[fi].cwd.as_str();
        let best = unlinked_surface
            .iter()
            .enumerate()
            .filter(|(j, _)| !used_surface2[*j])
            .filter_map(|(j, &si)| {
                let claude_cwd = entries[si].cwd().unwrap_or("");
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
            rows.push(Row { flutter: Some(fi), surface: Some(si) });
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

    // Zip any leftover Flutter and Claude entries side-by-side (no path match).
    let paired = leftover_flutter.len().min(leftover_surface.len());
    for j in 0..paired {
        rows.push(Row {
            flutter: Some(leftover_flutter[j]),
            surface: Some(leftover_surface[j]),
        });
    }
    for &fi in &leftover_flutter[paired..] {
        rows.push(Row { flutter: Some(fi), surface: None });
    }
    for &si in &leftover_surface[paired..] {
        rows.push(Row { flutter: None, surface: Some(si) });
    }

    rows
}

fn row_has_column(row: &Row, col: Column) -> bool {
    match col {
        Column::Flutter => row.flutter.is_some(),
        Column::Claude => row.surface.is_some(),
    }
}

// ── Background refresh ───────────────────────────────────────────────────

type DiscoveryResult = (Vec<FlutterApp>, Vec<CmuxSurface>, Vec<TrmPane>, DesktopTarget);

fn spawn_discovery(tx: mpsc::Sender<DiscoveryResult>) {
    tokio::task::spawn_blocking(move || {
        let result = (
            discover_flutter_apps(),
            cmux_surface_list(),
            discover_trm_panes(),
            discover_desktop_target(),
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
}

impl ClaudeEntry {
    fn id(&self) -> String {
        match self {
            ClaudeEntry::Cmux(s) => s.id.clone(),
            ClaudeEntry::Trm(p) => format!("trm:{}", p.index),
        }
    }
    fn is_claude(&self) -> bool {
        match self {
            ClaudeEntry::Cmux(s) => title_has_agent(&s.title),
            ClaudeEntry::Trm(p) => p.has_claude,
        }
    }
    fn cwd(&self) -> Option<&str> {
        match self {
            ClaudeEntry::Cmux(s) => s.cwd.as_deref(),
            ClaudeEntry::Trm(p) => p.cwd.as_deref(),
        }
    }
}

struct App {
    shared: Arc<SharedState>,
    flutter_apps: Vec<FlutterApp>,
    cmux_surfaces: Vec<CmuxSurface>,
    trm_panes: Vec<TrmPane>,
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
    port: u16,
}

impl App {
    fn new(shared: Arc<SharedState>, port: u16) -> Self {
        Self {
            shared,
            flutter_apps: Vec::new(),
            cmux_surfaces: Vec::new(),
            trm_panes: Vec::new(),
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

    fn set_toast(&mut self, msg: impl Into<String>) {
        self.toast = Some((msg.into(), Instant::now()));
    }

    async fn apply_discovery(&mut self, result: DiscoveryResult) {
        let (flutter, surfaces, trm, desktop) = result;

        self.flutter_apps = flutter.clone();
        self.cmux_surfaces = surfaces;
        let mut trm = trm;
        // Attach registered channel ports to trm panes.
        // Priority: 1) login PID (most reliable), 2) surface_id key, 3) cwd prefix match.
        {
            let ports = self.shared.channel_ports.read().await;
            let login_ports = self.shared.channel_ports_by_login.read().await;
            let cwd_ports = self.shared.channel_ports_by_cwd.read().await;
            let mut used_cwds: std::collections::HashSet<String> = std::collections::HashSet::new();

            for pane in &mut trm {
                // 1. Login PID match — most reliable, survives title changes.
                if let Some(login_pid) = pane.login_pid {
                    if let Some(&port) = login_ports.get(&login_pid) {
                        pane.channel_port = Some(port);
                        continue;
                    }
                }

                // 2. Direct surface_id key match.
                let key = format!("trm:{}", pane.index);
                pane.channel_port = ports.get(&key).copied();

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
        self.desktop_target = if desktop.alive { Some(desktop.clone()) } else { None };
        *self.shared.desktop_cache.write().await = Some((Instant::now(), desktop));

        // Prune stale associations where the Flutter process is gone
        let mut assocs = load_associations(&self.shared.persistence_path);
        let before = assocs.len();
        assocs.retain(|a| self.flutter_apps.iter().any(|f| f.pid == a.flutter_pid));
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

        let rows = build_rows(self);
        let row_count = rows.len();

        // Clamp per-column selections
        if row_count == 0 {
            self.flutter_row = None;
            self.claude_row = None;
        } else {
            if let Some(i) = self.flutter_row {
                if i >= row_count {
                    self.flutter_row = Some(row_count - 1);
                }
            }
            if let Some(i) = self.claude_row {
                if i >= row_count {
                    self.claude_row = Some(row_count - 1);
                }
            }

            if self.flutter_row.is_none() {
                self.flutter_row = rows.iter().position(|r| r.flutter.is_some());
            }
            if self.claude_row.is_none() {
                self.claude_row = rows.iter().position(|r| r.surface.is_some());
            }
        }

        self.sync_row_state();
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

            // Blank separator line between rows
            lines.push(Line::from(Span::raw(" ".repeat(left_w))));

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

        // Use the flutter column's scroll offset as reference for connectors
        let scroll_offset = app.flutter_list_state.offset();
        let mut visible_lines: Vec<Line> = Vec::new();

        for (row_idx, row) in rows.iter().enumerate() {
            let h = row_heights[row_idx] + 1; // +1 for separator line
            if row_idx < scroll_offset {
                continue;
            }
            if visible_lines.len() >= inner_height {
                break;
            }

            let is_linked = row.flutter.is_some() && row.surface.is_some();
            for line_idx in 0..h {
                if visible_lines.len() >= inner_height {
                    break;
                }
                if line_idx == 0 && is_linked {
                    let connector = center_pad(CONNECTOR, conn_w);
                    visible_lines.push(Line::from(Span::styled(
                        connector,
                        Style::default().fg(GREEN),
                    )));
                } else {
                    visible_lines.push(Line::from(Span::raw(" ".repeat(conn_w))));
                }
            }
        }

        // Pad remaining space
        while visible_lines.len() < inner_height {
            visible_lines.push(Line::from(Span::raw(" ".repeat(conn_w))));
        }

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

            // Blank separator line between rows
            lines.push(Line::from(Span::raw(" ".repeat(right_w))));

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
    lines.push((
        format!("{}  ({})", fl.folder_name, device),
        Style::default().fg(TEXT).add_modifier(Modifier::BOLD),
    ));

    lines.push((
        shorten_path(&fl.cwd),
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
                format!("trm:{}  {}{}", pane.index, status, port_tag),
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

    // Shared state between TUI and HTTP server
    let shared = Arc::new(SharedState::new());

    // Spawn the HTTP server in the background
    let server_state = shared.clone();
    tokio::spawn(async move {
        let router = build_router(server_state);
        let listener = tokio::net::TcpListener::bind(format!("0.0.0.0:{}", port))
            .await
            .expect("failed to bind HTTP server");
        axum::serve(listener, router).await.ok();
    });

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

    // Kick off the initial discovery immediately.
    spawn_discovery(discovery_tx.clone());

    let mut event_stream = event::EventStream::new();
    let mut refresh_interval = tokio::time::interval(Duration::from_secs(5));
    refresh_interval.tick().await; // consume the immediate tick
    let mut log_poll = tokio::time::interval(Duration::from_millis(500));
    log_poll.tick().await;

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
                                let flutter_pid = app.selected_flutter().map(|f| f.pid);
                                let surface_id = app.selected_entry().map(|e| e.id());

                                if let (Some(pid), Some(sid)) = (flutter_pid, surface_id) {
                                    let assoc = Association {
                                        id: new_association_id(),
                                        claude_surface_id: sid.clone(),
                                        flutter_pid: pid,
                                    };
                                    // Update shared state
                                    {
                                        let mut assocs = app.shared.associations.write().await;
                                        assocs.retain(|a| a.flutter_pid != pid);
                                        assocs.push(assoc);
                                        save_associations(&app.shared.persistence_path, &assocs);
                                    }
                                    app.associations = app.shared.associations.read().await.clone();
                                    app.log("in", format!("Link created: PID {} → {}", pid, &sid[..8.min(sid.len())]), None, true).await;
                                    app.sync_log_snapshot().await;
                                    app.set_toast("Link created");
                                } else {
                                    app.set_toast("Select both a Flutter app and Claude surface first");
                                }
                            }

                            KeyCode::Char('u') => {
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
                                                let label = sid.clone().unwrap_or_else(|| format!("trm:{}", pane.index));
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
                                    _ => None,
                                });

                                if let Some(port) = channel_port {
                                    let payload = serde_json::json!({
                                        "messages": [{
                                            "type": "test",
                                            "text": "TEST MESSAGE FROM FLAN",
                                        }]
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
                                    let text = "flan test message from TUI".to_string();
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
                                    };
                                    app.log("out", format!("Test text → {}", label), Some(text), ok).await;
                                    app.sync_log_snapshot().await;
                                    app.set_toast(if ok { format!("Test → {} (text)", target_label) } else { "Test failed".to_string() });
                                } else {
                                    app.set_toast("No agent selected");
                                }
                            }

                            KeyCode::Char('x') => {
                                if let Some(flutter) = app.selected_flutter() {
                                    let pid = flutter.pid;
                                    let vm_uri = flutter.vm_service_uri.clone();

                                    let assoc = app.assoc_for_flutter(pid).cloned();
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

                                        // Check if the target pane has a channel port (Claude w/ flan-channel).
                                        let channel_port = if sid.starts_with("trm:") {
                                            sid["trm:".len()..].parse::<usize>().ok()
                                                .and_then(|idx| app.trm_panes.iter().find(|p| p.index == idx))
                                                .and_then(|p| p.channel_port)
                                        } else {
                                            None
                                        };

                                        if let Some(port) = channel_port {
                                            // Channel push — the flan-channel MCP server will
                                            // deliver the message directly into the Claude session.
                                            let payload = serde_json::json!({
                                                "vm_service_uri": uri,
                                                "messages": [{
                                                    "type": "flush",
                                                    "text": format!("flan connect to {} and process queue once connected", uri),
                                                }]
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
                                            let text = format!("flan connect to {} and process queue once connected", uri);
                                            let t = text.clone();
                                            // Resolve the actual pane_id before entering spawn_blocking.
                                            let trm_pane_id = if sid.starts_with("trm:") {
                                                sid["trm:".len()..].parse::<usize>().ok()
                                                    .and_then(|idx| app.trm_panes.iter().find(|p| p.index == idx))
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

