//! Unix socket client to floss (the desktop agent bridge).
//!
//! Connects to `~/.floss/floss.sock` and sends JSON-RPC 2.0 requests.

use serde_json::{json, Value};
use std::{
    io::{BufRead, BufReader, Write as IoWrite},
    os::unix::net::UnixStream,
    path::PathBuf,
    time::Duration,
};

/// Default path to the floss Unix domain socket.
pub fn floss_socket_path() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".into());
    PathBuf::from(home).join(".floss").join("floss.sock")
}

/// Check if floss is running by pinging it.
pub fn floss_is_alive() -> bool {
    floss_rpc("flan.ping", json!({})).is_some()
}

/// Send a JSON-RPC 2.0 request to floss and return the result.
pub fn floss_rpc(method: &str, params: Value) -> Option<Value> {
    let socket_path = std::env::var("FLOSS_SOCKET_PATH")
        .map(PathBuf::from)
        .unwrap_or_else(|_| floss_socket_path());

    let mut stream = UnixStream::connect(&socket_path).ok()?;
    stream.set_read_timeout(Some(Duration::from_secs(10))).ok()?;
    stream.set_write_timeout(Some(Duration::from_secs(5))).ok()?;

    let request = json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": method,
        "params": params,
    });

    let mut msg = serde_json::to_string(&request).ok()?;
    msg.push('\n');
    stream.write_all(msg.as_bytes()).ok()?;
    stream.flush().ok()?;

    let reader = BufReader::new(&stream);
    let line = reader.lines().next()?.ok()?;

    let response: Value = serde_json::from_str(&line).ok()?;

    // Check for JSON-RPC error
    if let Some(err) = response.get("error") {
        eprintln!(
            "[floss-bridge] RPC error: {}",
            err.get("message")
                .and_then(|m| m.as_str())
                .unwrap_or("unknown")
        );
        return None;
    }

    response.get("result").cloned()
}

/// Take a screenshot via floss.
pub fn floss_take_screenshots() -> Option<Value> {
    floss_rpc("flan.takeScreenshots", json!({}))
}

/// Get interactive elements from floss.
pub fn floss_interactive_elements(params: Value) -> Option<Value> {
    floss_rpc("flan.interactiveElements", params)
}

/// Tap via floss.
pub fn floss_tap(params: Value) -> Option<Value> {
    floss_rpc("flan.tap", params)
}

/// Enter text via floss.
pub fn floss_enter_text(params: Value) -> Option<Value> {
    floss_rpc("flan.enterText", params)
}

/// Scroll via floss.
pub fn floss_scroll_to(params: Value) -> Option<Value> {
    floss_rpc("flan.scrollTo", params)
}

/// Inspect element at position via floss.
pub fn floss_inspect_at(params: Value) -> Option<Value> {
    floss_rpc("flan.inspectAt", params)
}

/// Get focused app info.
pub fn floss_get_focused_app() -> Option<Value> {
    floss_rpc("flan.getFocusedApp", json!({}))
}

/// List windows.
pub fn floss_list_windows() -> Option<Value> {
    floss_rpc("flan.listWindows", json!({}))
}

/// Annotation methods.
pub fn floss_annotation_enable() -> Option<Value> {
    floss_rpc("flan.annotationEnable", json!({}))
}
pub fn floss_annotation_disable() -> Option<Value> {
    floss_rpc("flan.annotationDisable", json!({}))
}
pub fn floss_annotation_get() -> Option<Value> {
    floss_rpc("flan.annotationGet", json!({}))
}
pub fn floss_annotation_clear() -> Option<Value> {
    floss_rpc("flan.annotationClear", json!({}))
}
pub fn floss_annotation_add(params: Value) -> Option<Value> {
    floss_rpc("flan.annotationAdd", params)
}

/// Command overlay.
pub fn floss_command_overlay(params: Value) -> Option<Value> {
    floss_rpc("flan.commandOverlay", params)
}

/// User messages.
pub fn floss_consume_user_messages() -> Option<Value> {
    floss_rpc("flan.consumeUserMessages", json!({}))
}
pub fn floss_peek_user_messages() -> Option<Value> {
    floss_rpc("flan.peekUserMessages", json!({}))
}

/// Policy.
pub fn floss_get_policy() -> Option<Value> {
    floss_rpc("flan.getPolicy", json!({}))
}
pub fn floss_set_policy(params: Value) -> Option<Value> {
    floss_rpc("flan.setPolicy", params)
}
