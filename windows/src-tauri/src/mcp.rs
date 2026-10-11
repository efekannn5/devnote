//! Yerel MCP sunucusu (Mac sürümüyle aynı: yalnızca 127.0.0.1, POST /mcp → JSON yanıt).
//! JSON-RPC isteği arayüze olay olarak iletilir; araçları arayüzdeki veri deposu çalıştırır ve
//! `mcp_respond` ile yanıtı geri verir. Böylece yapay zekanın değişiklikleri ekranda anında görünür.

use std::collections::HashMap;
use std::io::Read;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tauri::{AppHandle, Emitter, State};

#[derive(Default)]
pub struct McpBridge {
    inner: Arc<Inner>,
}

#[derive(Default)]
struct Inner {
    server: Mutex<Option<Arc<tiny_http::Server>>>,
    pending: Mutex<HashMap<u64, mpsc::Sender<Option<String>>>>,
    next_id: AtomicU64,
}

#[derive(Clone, serde::Serialize)]
struct McpRequest {
    id: u64,
    body: String,
}

#[tauri::command]
pub fn mcp_start(app: AppHandle, bridge: State<McpBridge>, port: u16) -> Result<(), String> {
    stop(&bridge.inner);
    let server = Arc::new(
        tiny_http::Server::http(("127.0.0.1", port)).map_err(|e| format!("MCP sunucusu başlatılamadı: {e}"))?,
    );
    *bridge.inner.server.lock().unwrap() = Some(server.clone());
    let inner = bridge.inner.clone();
    std::thread::spawn(move || {
        for request in server.incoming_requests() {
            let inner = inner.clone();
            let app = app.clone();
            std::thread::spawn(move || handle(app, inner, request));
        }
    });
    Ok(())
}

#[tauri::command]
pub fn mcp_stop(bridge: State<McpBridge>) {
    stop(&bridge.inner);
}

#[tauri::command]
pub fn mcp_respond(bridge: State<McpBridge>, id: u64, reply: Option<String>) {
    if let Some(sender) = bridge.inner.pending.lock().unwrap().remove(&id) {
        let _ = sender.send(reply);
    }
}

fn stop(inner: &Inner) {
    if let Some(server) = inner.server.lock().unwrap().take() {
        server.unblock();
    }
}

fn handle(app: AppHandle, inner: Arc<Inner>, mut request: tiny_http::Request) {
    // DNS rebinding koruması: tarayıcıdan gelen yabancı Origin'leri reddet
    let origin = request
        .headers()
        .iter()
        .find(|h| h.field.equiv("Origin"))
        .map(|h| h.value.as_str().to_string());
    if let Some(origin) = origin {
        if !(origin.starts_with("http://localhost") || origin.starts_with("http://127.0.0.1")) {
            let _ = request.respond(tiny_http::Response::from_string("Forbidden origin").with_status_code(403));
            return;
        }
    }
    let path = request.url().split('?').next().unwrap_or("/").to_string();
    let method = request.method().clone();
    match (method, path.as_str()) {
        (tiny_http::Method::Get, "/health") => {
            let _ = request.respond(tiny_http::Response::from_string("ok"));
        }
        (tiny_http::Method::Post, "/mcp") | (tiny_http::Method::Post, "/") => {
            let mut body = String::new();
            if request.as_reader().take(8 << 20).read_to_string(&mut body).is_err() {
                let _ = request.respond(tiny_http::Response::from_string("Bad Request").with_status_code(400));
                return;
            }
            let id = inner.next_id.fetch_add(1, Ordering::SeqCst);
            let (tx, rx) = mpsc::channel();
            inner.pending.lock().unwrap().insert(id, tx);
            if app.emit("mcp-request", McpRequest { id, body }).is_err() {
                inner.pending.lock().unwrap().remove(&id);
                let _ = request.respond(tiny_http::Response::from_string("Unavailable").with_status_code(503));
                return;
            }
            match rx.recv_timeout(Duration::from_secs(30)) {
                Ok(Some(reply)) => {
                    let header = tiny_http::Header::from_bytes(&b"Content-Type"[..], &b"application/json"[..]).unwrap();
                    let _ = request.respond(tiny_http::Response::from_string(reply).with_header(header));
                }
                // Bildirim (yanıtsız JSON-RPC): 202
                Ok(None) => {
                    let _ = request.respond(tiny_http::Response::empty(202));
                }
                Err(_) => {
                    inner.pending.lock().unwrap().remove(&id);
                    let _ = request.respond(tiny_http::Response::from_string("Timeout").with_status_code(504));
                }
            }
        }
        (_, "/mcp") => {
            let header = tiny_http::Header::from_bytes(&b"Allow"[..], &b"POST"[..]).unwrap();
            let _ = request.respond(
                tiny_http::Response::from_string("Method Not Allowed").with_status_code(405).with_header(header),
            );
        }
        _ => {
            let _ = request.respond(tiny_http::Response::from_string("Not found").with_status_code(404));
        }
    }
}
