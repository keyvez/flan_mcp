use flan_server::*;
use std::sync::Arc;

#[tokio::main]
async fn main() {
    unsafe { libc::signal(libc::SIGPIPE, libc::SIG_IGN); }

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

    let state = Arc::new(SharedState::new());
    let app = build_router(state);

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
