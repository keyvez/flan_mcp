use crossterm::{
    event::{self, Event, KeyCode, KeyEvent, KeyModifiers},
    execute,
    terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen},
};
use futures::StreamExt;
use ratatui::{
    layout::{Constraint, Layout, Rect},
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, List, ListItem, ListState, Paragraph},
    Frame, Terminal,
};
use serde::Deserialize;
use std::{
    io,
    time::{Duration, Instant},
};

// ── Colors (matching browser CSS variables) ─────────────────────────────

const BG: Color = Color::Rgb(10, 10, 15);
const SURFACE: Color = Color::Rgb(18, 18, 26);
const BORDER: Color = Color::Rgb(42, 42, 58);
const TEXT: Color = Color::Rgb(224, 224, 232);
const TEXT2: Color = Color::Rgb(136, 136, 153);
const ACCENT: Color = Color::Rgb(108, 92, 231);
const ACCENT2: Color = Color::Rgb(162, 155, 254);
const GREEN: Color = Color::Rgb(0, 184, 148);
const ORANGE: Color = Color::Rgb(253, 203, 110);
const RED: Color = Color::Rgb(225, 112, 85);

// ── Data Models (mirrors server JSON) ───────────────────────────────────

#[derive(Debug, Clone, Deserialize)]
struct FlutterApp {
    pid: u32,
    cwd: String,
    folder_name: String,
    vm_service_uri: Option<String>,
    device: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[allow(dead_code)]
struct ClaudeProcess {
    pid: u32,
    cwd: String,
    folder_name: String,
    last_message_preview: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
struct CmuxSurface {
    id: String,
    title: String,
    pane_id: String,
    focused: bool,
}

#[derive(Debug, Clone, Deserialize)]
struct Association {
    id: String,
    claude_surface_id: String,
    flutter_pid: u32,
}

#[derive(Debug, Clone, Deserialize)]
struct LogEntry {
    timestamp: String,
    direction: String,
    summary: String,
    detail: Option<String>,
    ok: bool,
}

// ── API Client ──────────────────────────────────────────────────────────

struct FlanClient {
    client: reqwest::Client,
    base: String,
}

impl FlanClient {
    fn new(port: u16) -> Self {
        Self {
            client: reqwest::Client::builder()
                .timeout(Duration::from_secs(5))
                .build()
                .unwrap(),
            base: format!("http://localhost:{}", port),
        }
    }

    async fn fetch_all(&self) -> Result<DashboardData, reqwest::Error> {
        let (flutter, surfaces, associations, logs) = tokio::join!(
            self.client.get(format!("{}/api/flutter-apps", self.base)).send(),
            self.client.get(format!("{}/api/cmux-surfaces", self.base)).send(),
            self.client.get(format!("{}/api/associations", self.base)).send(),
            self.client.get(format!("{}/api/logs", self.base)).send(),
        );

        Ok(DashboardData {
            flutter_apps: flutter?.json().await.unwrap_or_default(),
            cmux_surfaces: surfaces?.json().await.unwrap_or_default(),
            associations: associations?.json().await.unwrap_or_default(),
            logs: logs?.json().await.unwrap_or_default(),
        })
    }

    async fn rescan(&self) -> bool {
        self.client
            .post(format!("{}/api/rescan", self.base))
            .send()
            .await
            .is_ok_and(|r| r.status().is_success())
    }

    async fn create_association(&self, surface_id: &str, flutter_pid: u32) -> bool {
        self.client
            .post(format!("{}/api/associations", self.base))
            .json(&serde_json::json!({
                "claude_surface_id": surface_id,
                "flutter_pid": flutter_pid,
            }))
            .send()
            .await
            .is_ok_and(|r| r.status().is_success())
    }

    async fn delete_association(&self, id: &str) -> bool {
        self.client
            .delete(format!("{}/api/associations/{}", self.base, id))
            .send()
            .await
            .is_ok_and(|r| r.status().is_success())
    }

    async fn focus_surface(&self, surface_id: &str) -> bool {
        self.client
            .post(format!("{}/api/focus-surface", self.base))
            .json(&serde_json::json!({ "surface_id": surface_id }))
            .send()
            .await
            .is_ok_and(|r| r.status().is_success())
    }

    async fn focus_app(&self, device: &str) -> bool {
        self.client
            .post(format!("{}/api/focus-app", self.base))
            .json(&serde_json::json!({ "device": device }))
            .send()
            .await
            .is_ok_and(|r| r.status().is_success())
    }

    async fn test_send(&self, surface_id: &str) -> bool {
        self.client
            .post(format!("{}/api/test-send", self.base))
            .json(&serde_json::json!({ "surface_id": surface_id }))
            .send()
            .await
            .is_ok_and(|r| r.status().is_success())
    }

    async fn flush(&self, flutter_pid: u32) -> bool {
        self.client
            .post(format!("{}/api/flush", self.base))
            .json(&serde_json::json!({ "flutter_pid": flutter_pid }))
            .send()
            .await
            .is_ok_and(|r| r.status().is_success())
    }
}

#[derive(Default)]
struct DashboardData {
    flutter_apps: Vec<FlutterApp>,
    cmux_surfaces: Vec<CmuxSurface>,
    associations: Vec<Association>,
    logs: Vec<LogEntry>,
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
    data: DashboardData,
    active_column: Column,
    focus: Focus,
    flutter_state: ListState,
    claude_state: ListState,
    log_state: ListState,
    log_visible: bool,
    toast: Option<(String, Instant)>,
    connected: bool,
}

impl App {
    fn new() -> Self {
        Self {
            data: DashboardData::default(),
            active_column: Column::Flutter,
            focus: Focus::Main,
            flutter_state: ListState::default(),
            claude_state: ListState::default(),
            log_state: ListState::default(),
            log_visible: true,
            toast: None,
            connected: false,
        }
    }

    fn claude_surfaces(&self) -> Vec<&CmuxSurface> {
        self.data
            .cmux_surfaces
            .iter()
            .filter(|s| s.title.contains("Claude"))
            .collect()
    }

    fn selected_flutter(&self) -> Option<&FlutterApp> {
        self.flutter_state
            .selected()
            .and_then(|i| self.data.flutter_apps.get(i))
    }

    fn selected_surface(&self) -> Option<&CmuxSurface> {
        let surfaces = self.claude_surfaces();
        self.claude_state
            .selected()
            .and_then(|i| surfaces.get(i).copied())
    }

    fn assoc_for_flutter(&self, pid: u32) -> Option<&Association> {
        self.data
            .associations
            .iter()
            .find(|a| a.flutter_pid == pid)
    }

    fn assoc_for_surface(&self, id: &str) -> Option<&Association> {
        self.data
            .associations
            .iter()
            .find(|a| a.claude_surface_id == id)
    }

    fn set_toast(&mut self, msg: impl Into<String>) {
        self.toast = Some((msg.into(), Instant::now()));
    }

    fn move_up(&mut self) {
        if self.focus == Focus::Log {
            let len = self.data.logs.len();
            if len == 0 {
                return;
            }
            let i = self.log_state.selected().unwrap_or(0);
            self.log_state.select(Some(i.saturating_sub(1)));
            return;
        }
        match self.active_column {
            Column::Flutter => {
                let len = self.data.flutter_apps.len();
                if len == 0 {
                    return;
                }
                let i = self.flutter_state.selected().unwrap_or(0);
                self.flutter_state.select(Some(i.saturating_sub(1)));
            }
            Column::Claude => {
                let len = self.claude_surfaces().len();
                if len == 0 {
                    return;
                }
                let i = self.claude_state.selected().unwrap_or(0);
                self.claude_state.select(Some(i.saturating_sub(1)));
            }
        }
    }

    fn move_down(&mut self) {
        if self.focus == Focus::Log {
            let len = self.data.logs.len();
            if len == 0 {
                return;
            }
            let i = self.log_state.selected().unwrap_or(0);
            self.log_state
                .select(Some((i + 1).min(len.saturating_sub(1))));
            return;
        }
        match self.active_column {
            Column::Flutter => {
                let len = self.data.flutter_apps.len();
                if len == 0 {
                    return;
                }
                let i = self.flutter_state.selected().unwrap_or(0);
                self.flutter_state
                    .select(Some((i + 1).min(len.saturating_sub(1))));
            }
            Column::Claude => {
                let len = self.claude_surfaces().len();
                if len == 0 {
                    return;
                }
                let i = self.claude_state.selected().unwrap_or(0);
                self.claude_state
                    .select(Some((i + 1).min(len.saturating_sub(1))));
            }
        }
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

    // Determine log panel height
    let log_height = if app.log_visible { 10u16 } else { 1u16 };

    let outer = Layout::vertical([
        Constraint::Length(1),  // status bar
        Constraint::Min(6),    // main area
        Constraint::Length(log_height), // log panel
        Constraint::Length(1), // help bar
    ])
    .split(area);

    render_status_bar(f, app, outer[0]);
    render_main(f, app, outer[1]);
    render_log_panel(f, app, outer[2]);
    render_help_bar(f, app, outer[3]);
}

fn render_status_bar(f: &mut Frame, app: &App, area: Rect) {
    let flutter_count = app.data.flutter_apps.len();
    let claude_count = app.claude_surfaces().len();
    let link_count = app.data.associations.len();

    let mut spans = vec![
        Span::styled(" flan", Style::default().fg(ACCENT2).add_modifier(Modifier::BOLD)),
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

    // Right-aligned status
    let status = if app.connected {
        format!(
            "● {} flutter · {} claude · {} linked  ",
            flutter_count, claude_count, link_count
        )
    } else {
        "○ disconnected  ".to_string()
    };

    let status_width = status.len() as u16;
    let left_width = area.width.saturating_sub(status_width);

    let cols = Layout::horizontal([
        Constraint::Length(left_width),
        Constraint::Length(status_width),
    ])
    .split(area);

    f.render_widget(
        Paragraph::new(Line::from(spans)).style(Style::default().bg(SURFACE)),
        cols[0],
    );

    let status_color = if app.connected { GREEN } else { RED };
    f.render_widget(
        Paragraph::new(Line::from(vec![Span::styled(
            status,
            Style::default().fg(status_color),
        )]))
        .style(Style::default().bg(SURFACE))
        .alignment(ratatui::layout::Alignment::Right),
        cols[1],
    );
}

fn render_main(f: &mut Frame, app: &mut App, area: Rect) {
    let cols = Layout::horizontal([Constraint::Percentage(50), Constraint::Percentage(50)])
        .split(area);

    render_flutter_column(f, app, cols[0]);
    render_claude_column(f, app, cols[1]);
}

fn render_flutter_column(f: &mut Frame, app: &mut App, area: Rect) {
    let is_active = app.focus == Focus::Main && app.active_column == Column::Flutter;
    let border_color = if is_active { ACCENT } else { BORDER };

    let title = format!(" Flutter Apps ({}) ", app.data.flutter_apps.len());
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

    if app.data.flutter_apps.is_empty() {
        let empty = Paragraph::new(Line::from(Span::styled(
            "No Flutter apps running",
            Style::default().fg(TEXT2),
        )))
        .block(block)
        .alignment(ratatui::layout::Alignment::Center);
        f.render_widget(empty, area);
        return;
    }

    let items: Vec<ListItem> = app
        .data
        .flutter_apps
        .iter()
        .enumerate()
        .map(|(_, app_item)| {
            let assoc = app
                .data
                .associations
                .iter()
                .find(|a| a.flutter_pid == app_item.pid);
            let linked_surface = assoc.and_then(|a| {
                app.data
                    .cmux_surfaces
                    .iter()
                    .find(|s| s.id == a.claude_surface_id)
            });

            let mut lines = vec![];

            // Folder name
            let mut name_spans = vec![Span::styled(
                &app_item.folder_name,
                Style::default().fg(TEXT).add_modifier(Modifier::BOLD),
            )];
            if assoc.is_some() {
                name_spans.push(Span::styled(
                    " [linked]",
                    Style::default().fg(GREEN),
                ));
            }
            lines.push(Line::from(name_spans));

            // Meta line
            let device = app_item.device.as_deref().unwrap_or("?");
            lines.push(Line::from(vec![
                Span::styled(format!("PID {}  ", app_item.pid), Style::default().fg(TEXT2)),
                Span::styled(device, Style::default().fg(TEXT2)),
            ]));

            // VM service URI
            if let Some(ref uri) = app_item.vm_service_uri {
                let short: String = uri.chars().take(40).collect();
                lines.push(Line::from(Span::styled(short, Style::default().fg(TEXT2))));
            }

            // Link target
            if let Some(surface) = linked_surface {
                lines.push(Line::from(vec![
                    Span::styled("→ ", Style::default().fg(GREEN)),
                    Span::styled(
                        &surface.title,
                        Style::default().fg(GREEN),
                    ),
                    Span::styled(
                        format!(" ({}…)", &surface.id[..8.min(surface.id.len())]),
                        Style::default().fg(TEXT2),
                    ),
                ]));
            }

            // CWD
            lines.push(Line::from(Span::styled(
                &app_item.cwd,
                Style::default().fg(Color::Rgb(80, 80, 100)),
            )));

            // Blank separator
            lines.push(Line::from(""));

            ListItem::new(lines)
        })
        .collect();

    let list = List::new(items)
        .block(block)
        .highlight_style(
            Style::default()
                .bg(Color::Rgb(26, 26, 50))
                .fg(TEXT)
                .add_modifier(Modifier::BOLD),
        )
        .highlight_symbol("▸ ");

    f.render_stateful_widget(list, area, &mut app.flutter_state);
}

fn render_claude_column(f: &mut Frame, app: &mut App, area: Rect) {
    let is_active = app.focus == Focus::Main && app.active_column == Column::Claude;
    let border_color = if is_active { ACCENT } else { BORDER };

    // Collect into owned Vec to avoid borrow conflict with app.claude_state
    let claude_surfaces: Vec<CmuxSurface> = app
        .data
        .cmux_surfaces
        .iter()
        .filter(|s| s.title.contains("Claude"))
        .cloned()
        .collect();
    let title = format!(" Claude Code ({}) ", claude_surfaces.len());
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

    if claude_surfaces.is_empty() {
        let empty = Paragraph::new(Line::from(Span::styled(
            "No Claude Code surfaces in cmux",
            Style::default().fg(TEXT2),
        )))
        .block(block)
        .alignment(ratatui::layout::Alignment::Center);
        f.render_widget(empty, area);
        return;
    }

    let items: Vec<ListItem> = claude_surfaces
        .iter()
        .map(|surface| {
            let assoc = app
                .data
                .associations
                .iter()
                .find(|a| a.claude_surface_id == surface.id);
            let linked_app = assoc.and_then(|a| {
                app.data
                    .flutter_apps
                    .iter()
                    .find(|f| f.pid == a.flutter_pid)
            });

            let mut lines = vec![];

            // Title
            let mut name_spans = vec![Span::styled(
                &surface.title,
                Style::default().fg(TEXT).add_modifier(Modifier::BOLD),
            )];
            if surface.focused {
                name_spans.push(Span::styled(
                    " [focused]",
                    Style::default().fg(ACCENT2),
                ));
            }
            if assoc.is_some() {
                name_spans.push(Span::styled(
                    " [linked]",
                    Style::default().fg(GREEN),
                ));
            }
            lines.push(Line::from(name_spans));

            // IDs
            let short_id = &surface.id[..8.min(surface.id.len())];
            let short_pane = &surface.pane_id[..8.min(surface.pane_id.len())];
            lines.push(Line::from(vec![
                Span::styled(format!("{}…  ", short_id), Style::default().fg(TEXT2)),
                Span::styled(format!("pane {}…", short_pane), Style::default().fg(TEXT2)),
            ]));

            // Linked flutter app
            if let Some(flutter) = linked_app {
                lines.push(Line::from(vec![
                    Span::styled("← ", Style::default().fg(GREEN)),
                    Span::styled(
                        &flutter.folder_name,
                        Style::default().fg(GREEN),
                    ),
                    Span::styled(
                        format!(" (PID {})", flutter.pid),
                        Style::default().fg(TEXT2),
                    ),
                ]));
            }

            // Blank separator
            lines.push(Line::from(""));

            ListItem::new(lines)
        })
        .collect();

    let list = List::new(items)
        .block(block)
        .highlight_style(
            Style::default()
                .bg(Color::Rgb(26, 26, 50))
                .fg(TEXT)
                .add_modifier(Modifier::BOLD),
        )
        .highlight_symbol("▸ ");

    f.render_stateful_widget(list, area, &mut app.claude_state);
}

fn render_log_panel(f: &mut Frame, app: &mut App, area: Rect) {
    let is_active = app.focus == Focus::Log;
    let border_color = if is_active { ACCENT } else { BORDER };

    let title = format!(
        " Activity Log ({}) {} ",
        app.data.logs.len(),
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

    if !app.log_visible || app.data.logs.is_empty() {
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

    // Show newest first
    let items: Vec<ListItem> = app
        .data
        .logs
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

fn render_help_bar(f: &mut Frame, _app: &App, area: Rect) {
    let spans = vec![
        Span::styled(" [s]", Style::default().fg(ACCENT2)),
        Span::styled("can ", Style::default().fg(TEXT2)),
        Span::styled("[l]", Style::default().fg(ACCENT2)),
        Span::styled("ink ", Style::default().fg(TEXT2)),
        Span::styled("[u]", Style::default().fg(ACCENT2)),
        Span::styled("nlink ", Style::default().fg(TEXT2)),
        Span::styled("[f]", Style::default().fg(ACCENT2)),
        Span::styled("ocus ", Style::default().fg(TEXT2)),
        Span::styled("[a]", Style::default().fg(ACCENT2)),
        Span::styled("pp ", Style::default().fg(TEXT2)),
        Span::styled("[t]", Style::default().fg(ACCENT2)),
        Span::styled("est ", Style::default().fg(TEXT2)),
        Span::styled("[x]", Style::default().fg(ACCENT2)),
        Span::styled("flush ", Style::default().fg(TEXT2)),
        Span::styled("[g]", Style::default().fg(ACCENT2)),
        Span::styled("log ", Style::default().fg(TEXT2)),
        Span::styled("[Tab]", Style::default().fg(ACCENT2)),
        Span::styled("switch ", Style::default().fg(TEXT2)),
        Span::styled("[r]", Style::default().fg(ACCENT2)),
        Span::styled("efresh ", Style::default().fg(TEXT2)),
        Span::styled("[q]", Style::default().fg(ACCENT2)),
        Span::styled("uit", Style::default().fg(TEXT2)),
    ];

    f.render_widget(
        Paragraph::new(Line::from(spans)).style(Style::default().bg(SURFACE)),
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

    let client = FlanClient::new(port);

    // Terminal setup
    enable_raw_mode()?;
    let mut stdout = io::stdout();
    execute!(stdout, EnterAlternateScreen)?;
    let backend = ratatui::backend::CrosstermBackend::new(stdout);
    let mut terminal = Terminal::new(backend)?;

    // Panic hook to restore terminal
    let original_hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        let _ = disable_raw_mode();
        let _ = execute!(io::stdout(), LeaveAlternateScreen);
        original_hook(info);
    }));

    let mut app = App::new();

    // Initial fetch
    match client.fetch_all().await {
        Ok(data) => {
            app.data = data;
            app.connected = true;
            // Auto-select first items
            if !app.data.flutter_apps.is_empty() {
                app.flutter_state.select(Some(0));
            }
            if !app.claude_surfaces().is_empty() {
                app.claude_state.select(Some(0));
            }
        }
        Err(_) => {
            app.connected = false;
        }
    }

    let mut event_stream = event::EventStream::new();
    let mut refresh_interval = tokio::time::interval(Duration::from_secs(5));
    refresh_interval.tick().await; // consume first immediate tick

    loop {
        // Clear stale toast
        if let Some((_, ts)) = &app.toast {
            if ts.elapsed() > Duration::from_secs(3) {
                app.toast = None;
            }
        }

        terminal.draw(|f| ui(f, &mut app))?;

        tokio::select! {
            _ = refresh_interval.tick() => {
                match client.fetch_all().await {
                    Ok(data) => {
                        app.data = data;
                        app.connected = true;
                        // Clamp selections
                        clamp_selection(&mut app.flutter_state, app.data.flutter_apps.len());
                        let cs_len = app.claude_surfaces().len();
                        clamp_selection(&mut app.claude_state, cs_len);
                    }
                    Err(_) => {
                        app.connected = false;
                    }
                }
            }
            Some(Ok(evt)) = event_stream.next() => {
                match evt {
                    Event::Key(KeyEvent { code, modifiers, .. }) => {
                        // Ctrl+C always quits
                        if code == KeyCode::Char('c') && modifiers.contains(KeyModifiers::CONTROL) {
                            break;
                        }

                        match code {
                            KeyCode::Char('q') | KeyCode::Esc => break,

                            KeyCode::Up | KeyCode::Char('k') => app.move_up(),
                            KeyCode::Down | KeyCode::Char('j') => app.move_down(),

                            KeyCode::Tab | KeyCode::BackTab => app.toggle_column(),

                            KeyCode::Char('g') => {
                                if app.focus == Focus::Log {
                                    app.focus = Focus::Main;
                                    app.log_visible = false;
                                } else if app.log_visible {
                                    app.focus = Focus::Log;
                                    if !app.data.logs.is_empty() {
                                        app.log_state.select(Some(0));
                                    }
                                } else {
                                    app.log_visible = true;
                                    app.focus = Focus::Log;
                                    if !app.data.logs.is_empty() {
                                        app.log_state.select(Some(0));
                                    }
                                }
                            }

                            KeyCode::Char('s') => {
                                if client.rescan().await {
                                    app.set_toast("Scan complete");
                                    if let Ok(data) = client.fetch_all().await {
                                        app.data = data;
                                        app.connected = true;
                                        clamp_selection(&mut app.flutter_state, app.data.flutter_apps.len());
                                        let cs_len = app.claude_surfaces().len();
                                        clamp_selection(&mut app.claude_state, cs_len);
                                    }
                                } else {
                                    app.set_toast("Scan failed");
                                }
                            }

                            KeyCode::Char('r') => {
                                match client.fetch_all().await {
                                    Ok(data) => {
                                        app.data = data;
                                        app.connected = true;
                                        clamp_selection(&mut app.flutter_state, app.data.flutter_apps.len());
                                        let cs_len = app.claude_surfaces().len();
                                        clamp_selection(&mut app.claude_state, cs_len);
                                        app.set_toast("Refreshed");
                                    }
                                    Err(_) => {
                                        app.connected = false;
                                        app.set_toast("Refresh failed");
                                    }
                                }
                            }

                            KeyCode::Char('l') => {
                                // Link: need both a flutter app and a claude surface selected
                                let flutter_pid = app.selected_flutter().map(|f| f.pid);
                                let surface_id = app.selected_surface().map(|s| s.id.clone());

                                if let (Some(pid), Some(sid)) = (flutter_pid, surface_id) {
                                    if client.create_association(&sid, pid).await {
                                        app.set_toast("Link created");
                                        if let Ok(data) = client.fetch_all().await {
                                            app.data = data;
                                        }
                                    } else {
                                        app.set_toast("Link failed");
                                    }
                                } else {
                                    app.set_toast("Select both a Flutter app and Claude surface first");
                                }
                            }

                            KeyCode::Char('u') => {
                                // Unlink: find association for current selection
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
                                    if client.delete_association(&id).await {
                                        app.set_toast("Unlinked");
                                        if let Ok(data) = client.fetch_all().await {
                                            app.data = data;
                                        }
                                    } else {
                                        app.set_toast("Unlink failed");
                                    }
                                } else {
                                    app.set_toast("No link on this item");
                                }
                            }

                            KeyCode::Char('f') => {
                                // Focus surface
                                let sid = match app.active_column {
                                    Column::Claude => app.selected_surface().map(|s| s.id.clone()),
                                    Column::Flutter => {
                                        app.selected_flutter()
                                            .and_then(|f| app.assoc_for_flutter(f.pid))
                                            .map(|a| a.claude_surface_id.clone())
                                    }
                                };
                                if let Some(id) = sid {
                                    if client.focus_surface(&id).await {
                                        app.set_toast("Focused surface");
                                    } else {
                                        app.set_toast("Focus failed");
                                    }
                                } else {
                                    app.set_toast("No surface to focus");
                                }
                            }

                            KeyCode::Char('a') => {
                                // Focus app
                                let device = app
                                    .selected_flutter()
                                    .and_then(|f| f.device.clone())
                                    .unwrap_or_else(|| "chrome".to_string());
                                if client.focus_app(&device).await {
                                    app.set_toast(format!("Focused {}", device));
                                } else {
                                    app.set_toast("Focus app failed");
                                }
                            }

                            KeyCode::Char('t') => {
                                // Test send
                                if let Some(surface) = app.selected_surface() {
                                    let sid = surface.id.clone();
                                    if client.test_send(&sid).await {
                                        app.set_toast("Test sent");
                                    } else {
                                        app.set_toast("Test send failed");
                                    }
                                } else {
                                    app.set_toast("Select a Claude surface first");
                                }
                            }

                            KeyCode::Char('x') => {
                                // Flush
                                if let Some(flutter) = app.selected_flutter() {
                                    let pid = flutter.pid;
                                    if client.flush(pid).await {
                                        app.set_toast("Flushed");
                                        if let Ok(data) = client.fetch_all().await {
                                            app.data = data;
                                        }
                                    } else {
                                        app.set_toast("Flush failed");
                                    }
                                } else {
                                    app.set_toast("Select a Flutter app first");
                                }
                            }

                            _ => {}
                        }
                    }
                    Event::Resize(_, _) => {} // terminal.draw handles resize
                    _ => {}
                }
            }
        }
    }

    // Restore terminal
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
