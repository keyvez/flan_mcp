use crossterm::{
    event::{self, Event, KeyCode, KeyEvent, KeyModifiers},
    execute,
    terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen},
};
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
    let claude_surfaces = app.claude_surfaces_indices();
    let mut used_flutter: Vec<bool> = vec![false; app.flutter_apps.len()];
    let mut used_surface: Vec<bool> = vec![false; claude_surfaces.len()];
    let mut rows = Vec::new();

    for assoc in &app.associations {
        let fi = app
            .flutter_apps
            .iter()
            .position(|f| f.pid == assoc.flutter_pid);
        let si = claude_surfaces
            .iter()
            .position(|&ci| app.cmux_surfaces[ci].id == assoc.claude_surface_id);
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

    // Unlinked: zip Flutter-only and Claude-only side by side,
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

    let paired = unlinked_flutter.len().min(unlinked_surface.len());
    for j in 0..paired {
        rows.push(Row {
            flutter: Some(unlinked_flutter[j]),
            surface: Some(unlinked_surface[j]),
        });
    }
    for &fi in &unlinked_flutter[paired..] {
        rows.push(Row {
            flutter: Some(fi),
            surface: None,
        });
    }
    for &si in &unlinked_surface[paired..] {
        rows.push(Row {
            flutter: None,
            surface: Some(si),
        });
    }

    rows
}

fn row_has_column(row: &Row, col: Column) -> bool {
    match col {
        Column::Flutter => row.flutter.is_some(),
        Column::Claude => row.surface.is_some(),
    }
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

struct App {
    shared: Arc<SharedState>,
    flutter_apps: Vec<FlutterApp>,
    cmux_surfaces: Vec<CmuxSurface>,
    associations: Vec<Association>,
    desktop_target: Option<DesktopTarget>,
    /// Snapshot of shared log for rendering (avoids async read during draw)
    log_snapshot: Vec<LogEntry>,

    active_column: Column,
    focus: Focus,
    row_state: ListState,
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
            associations: Vec::new(),
            desktop_target: None,
            log_snapshot: Vec::new(),

            active_column: Column::Flutter,
            focus: Focus::Main,
            row_state: ListState::default(),
            log_state: ListState::default(),
            log_visible: true,
            toast: None,
            port,
        }
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

    fn claude_surfaces_indices(&self) -> Vec<usize> {
        self.cmux_surfaces
            .iter()
            .enumerate()
            .filter(|(_, s)| s.title.contains("Claude"))
            .map(|(i, _)| i)
            .collect()
    }

    fn claude_surfaces(&self) -> Vec<&CmuxSurface> {
        self.cmux_surfaces
            .iter()
            .filter(|s| s.title.contains("Claude"))
            .collect()
    }

    fn selected_flutter(&self) -> Option<&FlutterApp> {
        let rows = build_rows(self);
        self.row_state
            .selected()
            .and_then(|i| rows.get(i))
            .and_then(|row| row.flutter)
            .and_then(|fi| self.flutter_apps.get(fi))
    }

    fn selected_surface(&self) -> Option<&CmuxSurface> {
        let rows = build_rows(self);
        let cs = self.claude_surfaces_indices();
        self.row_state
            .selected()
            .and_then(|i| rows.get(i))
            .and_then(|row| row.surface)
            .and_then(|si| cs.get(si))
            .and_then(|&ci| self.cmux_surfaces.get(ci))
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

    async fn refresh(&mut self) {
        let (flutter, surfaces, desktop) = tokio::task::spawn_blocking(|| {
            (discover_flutter_apps(), cmux_surface_list(), discover_desktop_target())
        })
        .await
        .unwrap_or_else(|_| (Vec::new(), Vec::new(), DesktopTarget {
            alive: false,
            socket_path: desktop_bridge::floss_socket_path().to_string_lossy().to_string(),
            version: None,
        }));

        self.flutter_apps = flutter.clone();
        self.cmux_surfaces = surfaces;
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

        let row_count = build_rows(self).len();
        clamp_selection(&mut self.row_state, row_count);

        if self.row_state.selected().is_none() && row_count > 0 {
            self.row_state.select(Some(0));
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
        let i = self.row_state.selected().unwrap_or(0);
        // Skip rows that have nothing in the active column
        let mut target = i.saturating_sub(1);
        while target > 0 && !row_has_column(&rows[target], self.active_column) {
            target = target.saturating_sub(1);
        }
        self.row_state.select(Some(target));
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
        let i = self.row_state.selected().unwrap_or(0);
        // Skip rows that have nothing in the active column
        let mut target = (i + 1).min(last);
        while target < last && !row_has_column(&rows[target], self.active_column) {
            target += 1;
        }
        self.row_state.select(Some(target));
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
    let claude_count = app.claude_surfaces().len();
    let cs_indices = app.claude_surfaces_indices();
    let link_count = app.associations.iter().filter(|a| {
        app.flutter_apps.iter().any(|f| f.pid == a.flutter_pid)
            && cs_indices.iter().any(|&ci| app.cmux_surfaces[ci].id == a.claude_surface_id)
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
        "{} · ● {} flutter · {} claude · {} linked · :{} ",
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
        "CLAUDE CODE ◂ "
    } else {
        "CLAUDE CODE   "
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
            "No Flutter apps or Claude surfaces found",
            Style::default().fg(TEXT2),
        )))
        .block(block)
        .alignment(ratatui::layout::Alignment::Center);
        f.render_widget(empty, area);
        return;
    }

    let selected_row = app.row_state.selected();
    let active_col = app.active_column;
    let has_focus = app.focus == Focus::Main;

    let items: Vec<ListItem> = rows
        .iter()
        .enumerate()
        .map(|(row_idx, row)| {
            let is_selected = has_focus && selected_row == Some(row_idx);
            let is_linked = row.flutter.is_some() && row.surface.is_some();

            let hl_left = is_selected && active_col == Column::Flutter && row.flutter.is_some();
            let hl_right = is_selected && active_col == Column::Claude && row.surface.is_some();

            let mut lines = Vec::new();

            let flutter_lines = row
                .flutter
                .map(|fi| build_flutter_lines(app, fi))
                .unwrap_or_default();
            let surface_lines = row.surface.map(|si| {
                let cs = app.claude_surfaces_indices();
                build_surface_lines(app, cs[si])
            }).unwrap_or_default();

            let max_lines = flutter_lines.len().max(surface_lines.len());

            let left_w = (area.width as usize * 44 / 100).max(10);
            let conn_w = (area.width as usize * 12 / 100).max(4);
            let right_w = (area.width as usize * 44 / 100).max(10);

            let hl_bg = Color::Rgb(28, 24, 50);

            for line_idx in 0..max_lines {
                let left = flutter_lines.get(line_idx);
                let right = surface_lines.get(line_idx);

                let mut spans = Vec::new();

                // Left column (Flutter)
                if let Some((text, style)) = left {
                    let truncated = truncate_str(text, left_w);
                    let pad = left_w.saturating_sub(char_width(&truncated));
                    let s = if hl_left { style.bg(hl_bg) } else { *style };
                    spans.push(Span::styled(truncated, s));
                    if pad > 0 {
                        let pad_style = if hl_left { Style::default().bg(hl_bg) } else { Style::default() };
                        spans.push(Span::styled(" ".repeat(pad), pad_style));
                    }
                } else {
                    spans.push(Span::raw(" ".repeat(left_w)));
                }

                // Connector
                if line_idx == 0 && is_linked {
                    let connector = center_pad(CONNECTOR, conn_w);
                    spans.push(Span::styled(connector, Style::default().fg(GREEN)));
                } else {
                    spans.push(Span::raw(" ".repeat(conn_w)));
                }

                // Right column (Claude)
                if let Some((text, style)) = right {
                    let truncated = truncate_str(text, right_w);
                    let pad = right_w.saturating_sub(char_width(&truncated));
                    let s = if hl_right { style.bg(hl_bg) } else { *style };
                    spans.push(Span::styled(truncated, s));
                    if pad > 0 {
                        let pad_style = if hl_right { Style::default().bg(hl_bg) } else { Style::default() };
                        spans.push(Span::styled(" ".repeat(pad), pad_style));
                    }
                } else if hl_right {
                    spans.push(Span::styled(" ".repeat(right_w), Style::default().bg(hl_bg)));
                } else {
                    spans.push(Span::raw(" ".repeat(right_w)));
                }

                lines.push(Line::from(spans));
            }

            // Blank separator line between rows
            lines.push(Line::from(Span::raw(" ".repeat(left_w + conn_w + right_w))));

            ListItem::new(lines)
        })
        .collect();

    let block = Block::default()
        .borders(Borders::ALL)
        .border_style(Style::default().fg(BORDER))
        .style(Style::default().bg(BG));

    let list = List::new(items)
        .block(block)
        .highlight_symbol("▸");

    f.render_stateful_widget(list, area, &mut app.row_state);
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

    lines
}

fn build_surface_lines(app: &App, cmux_idx: usize) -> Vec<(String, Style)> {
    let surface = &app.cmux_surfaces[cmux_idx];
    let mut lines = Vec::new();

    let mut title = surface.title.clone();
    if surface.focused {
        title.push_str(" [focused]");
    }
    lines.push((
        title,
        Style::default().fg(TEXT).add_modifier(Modifier::BOLD),
    ));

    // Find a sibling surface in the same pane whose title looks like a path
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
        lines.push((
            format!("pane {}…", short_pane),
            Style::default().fg(TEXT2),
        ));
    }

    lines
}

fn shorten_path(path: &str) -> String {
    let home = std::env::var("HOME").unwrap_or_default();
    if !home.is_empty() && path.starts_with(&home) {
        format!("~{}", &path[home.len()..])
    } else {
        path.to_string()
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

    // Terminal setup
    enable_raw_mode()?;
    let mut stdout = io::stdout();
    execute!(stdout, EnterAlternateScreen)?;
    let backend = ratatui::backend::CrosstermBackend::new(stdout);
    let mut terminal = Terminal::new(backend)?;

    let original_hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        let _ = disable_raw_mode();
        let _ = execute!(io::stdout(), LeaveAlternateScreen);
        original_hook(info);
    }));

    let mut app = App::new(shared, port);
    app.refresh().await;

    let mut event_stream = event::EventStream::new();
    let mut refresh_interval = tokio::time::interval(Duration::from_secs(5));
    refresh_interval.tick().await;
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
            _ = refresh_interval.tick() => {
                app.refresh().await;
            }
            _ = log_poll.tick() => {
                let prev_len = app.log_snapshot.len();
                app.sync_log_snapshot().await;
                if app.log_snapshot.len() != prev_len {
                    // New log entries arrived (e.g. from HTTP flush) — redraw
                }
            }
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
                                app.refresh().await;
                                app.log("in", "Scan complete".into(), None, true).await;
                                app.sync_log_snapshot().await;
                                app.set_toast("Scan complete");
                            }

                            KeyCode::Char('l') => {
                                let flutter_pid = app.selected_flutter().map(|f| f.pid);
                                let surface_id = app.selected_surface().map(|s| s.id.clone());

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
                                        .selected_surface()
                                        .and_then(|s| app.assoc_for_surface(&s.id))
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
                                        let sid = app.selected_surface().map(|s| s.id.clone());
                                        if let Some(id) = sid {
                                            let id2 = id.clone();
                                            let ok = tokio::task::spawn_blocking(move || cmux_focus_surface(&id2))
                                                .await
                                                .unwrap_or(false);
                                            app.log("out", format!("Focus surface {}…", &id[..8.min(id.len())]), None, ok).await;
                                            app.sync_log_snapshot().await;
                                            app.set_toast(if ok { "Focused pane" } else { "Focus failed".into() });
                                        } else {
                                            app.set_toast("No surface to focus");
                                        }
                                    }
                                }
                            }

                            KeyCode::Char('t') => {
                                if let Some(surface) = app.selected_surface() {
                                    let sid = surface.id.clone();
                                    let ok = tokio::task::spawn_blocking(move || {
                                        cmux_send_text(&sid, "[flan test] hello from flan tui")
                                    })
                                    .await
                                    .unwrap_or(false);
                                    app.log("out", "Test send".into(), None, ok).await;
                                    app.sync_log_snapshot().await;
                                    app.set_toast(if ok { "Test sent" } else { "Test send failed" });
                                } else {
                                    app.set_toast("Select a Claude surface first");
                                }
                            }

                            KeyCode::Char('x') => {
                                if let Some(flutter) = app.selected_flutter() {
                                    let pid = flutter.pid;
                                    let vm_uri = flutter.vm_service_uri.clone();

                                    let assoc = app.assoc_for_flutter(pid).cloned();
                                    if let Some(assoc) = assoc {
                                        let text = match &vm_uri {
                                            Some(uri) => format!("flan connect to {} and process queue once connected", uri),
                                            None => "process queue".to_string(),
                                        };
                                        let sid = assoc.claude_surface_id.clone();
                                        let t = text.clone();
                                        let ok = tokio::task::spawn_blocking(move || {
                                            if cmux_send_text(&sid, &t) {
                                                cmux_send_text(&sid, "\n")
                                            } else {
                                                false
                                            }
                                        })
                                        .await
                                        .unwrap_or(false);
                                        app.log("out", format!("Flush → {}…", &assoc.claude_surface_id[..8]), Some(text), ok).await;
                                        app.sync_log_snapshot().await;
                                        app.set_toast(if ok { "Flushed" } else { "Flush failed" });
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
        }
    }

    disable_raw_mode()?;
    execute!(terminal.backend_mut(), LeaveAlternateScreen)?;
    Ok(())
}

fn clamp_selection(state: &mut ListState, len: usize) {
    if len == 0 {
        state.select(None);
    } else if let Some(i) = state.selected() {
        if i >= len {
            state.select(Some(len - 1));
        }
    }
}
