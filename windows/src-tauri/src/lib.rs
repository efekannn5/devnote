//! DevNote (Windows) yerel katmanı: dosya deposu, gizli anahtar deposu (Windows Kimlik Bilgisi
//! Yöneticisi), iCloud girişinin dönüş bağlantısı (cloudkit-icloud.com.efekan.devnote://) ve MCP köprüsü.
//! Uygulama mantığının tamamı arayüz tarafında (TypeScript); burada yalnızca işletim sistemi işleri var.

mod mcp;

use base64::{engine::general_purpose::STANDARD as B64, Engine};
use std::fs;
use std::io::Write;
use std::path::PathBuf;
use tauri::{AppHandle, Manager};

const KEYRING_SERVICE: &str = "DevNote";

fn data_dir(app: &AppHandle) -> Result<PathBuf, String> {
    let dir = app.path().app_data_dir().map_err(|e| e.to_string())?;
    fs::create_dir_all(dir.join("assets")).map_err(|e| e.to_string())?;
    Ok(dir)
}

/// Yalnızca düz dosya adları (klasör dışına çıkılamasın)
fn safe_name(name: &str) -> Result<&str, String> {
    if name.is_empty() || name.contains(['/', '\\', ':']) || name.contains("..") {
        return Err(format!("geçersiz dosya adı: {name}"));
    }
    Ok(name)
}

/// Yarım yazılmış dosya kalmasın: önce geçici dosyaya yaz, sonra yerine taşı
fn write_atomic(path: &PathBuf, bytes: &[u8]) -> Result<(), String> {
    let tmp = path.with_extension("tmp");
    {
        let mut file = fs::File::create(&tmp).map_err(|e| e.to_string())?;
        file.write_all(bytes).map_err(|e| e.to_string())?;
        file.sync_all().map_err(|e| e.to_string())?;
    }
    fs::rename(&tmp, path).map_err(|e| e.to_string())
}

#[tauri::command]
fn store_read(app: AppHandle, name: String) -> Result<Option<String>, String> {
    let path = data_dir(&app)?.join(safe_name(&name)?);
    match fs::read_to_string(&path) {
        Ok(text) => Ok(Some(text)),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e.to_string()),
    }
}

#[tauri::command]
fn store_write(app: AppHandle, name: String, content: String) -> Result<(), String> {
    let path = data_dir(&app)?.join(safe_name(&name)?);
    write_atomic(&path, content.as_bytes())
}

#[tauri::command]
fn store_delete(app: AppHandle, name: String) -> Result<(), String> {
    let path = data_dir(&app)?.join(safe_name(&name)?);
    match fs::remove_file(path) {
        Err(e) if e.kind() != std::io::ErrorKind::NotFound => Err(e.to_string()),
        _ => Ok(()),
    }
}

/// Görsel gibi ikili veriler: assets klasörüne yazılır, yolu döner (arayüz convertFileSrc ile gösterir)
#[tauri::command]
fn asset_write(app: AppHandle, name: String, base64: String) -> Result<String, String> {
    let bytes = B64.decode(base64).map_err(|e| e.to_string())?;
    let path = data_dir(&app)?.join("assets").join(safe_name(&name)?);
    write_atomic(&path, &bytes)?;
    Ok(path.to_string_lossy().into_owned())
}

#[tauri::command]
fn asset_path(app: AppHandle, name: String) -> Result<Option<String>, String> {
    let path = data_dir(&app)?.join("assets").join(safe_name(&name)?);
    Ok(path.exists().then(|| path.to_string_lossy().into_owned()))
}

#[tauri::command]
fn asset_read(app: AppHandle, name: String) -> Result<Option<String>, String> {
    let path = data_dir(&app)?.join("assets").join(safe_name(&name)?);
    match fs::read(&path) {
        Ok(bytes) => Ok(Some(B64.encode(bytes))),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e.to_string()),
    }
}

#[tauri::command]
fn asset_delete(app: AppHandle, name: String) -> Result<(), String> {
    let path = data_dir(&app)?.join("assets").join(safe_name(&name)?);
    let _ = fs::remove_file(path);
    Ok(())
}

// MARK: - Gizli bilgiler (Windows: Kimlik Bilgisi Yöneticisi, macOS: Anahtar Zinciri)

#[tauri::command]
fn secret_get(key: String) -> Result<Option<String>, String> {
    let entry = keyring::Entry::new(KEYRING_SERVICE, &key).map_err(|e| e.to_string())?;
    match entry.get_password() {
        Ok(value) => Ok(Some(value)),
        Err(keyring::Error::NoEntry) => Ok(None),
        Err(e) => Err(e.to_string()),
    }
}

#[tauri::command]
fn secret_set(key: String, value: String) -> Result<(), String> {
    let entry = keyring::Entry::new(KEYRING_SERVICE, &key).map_err(|e| e.to_string())?;
    entry.set_password(&value).map_err(|e| e.to_string())
}

#[tauri::command]
fn secret_delete(key: String) -> Result<(), String> {
    let entry = keyring::Entry::new(KEYRING_SERVICE, &key).map_err(|e| e.to_string())?;
    match entry.delete_credential() {
        Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
        Err(e) => Err(e.to_string()),
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        // İkinci kez açılırsa yeni süreç yerine var olan pencereyi öne getir (depoya iki yazan olmasın)
        .plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| {
            if let Some(window) = app.get_webview_window("main") {
                let _ = window.unminimize();
                let _ = window.set_focus();
            }
        }))
        // Apple girişi bitince tarayıcı cloudkit-icloud.com.efekan.devnote://callback?ckWebAuthToken=… açar;
        // bağlantı açık pencereye iletilir (single-instance "deep-link" özelliği)
        .plugin(tauri_plugin_deep_link::init())
        .plugin(tauri_plugin_window_state::Builder::default().build())
        .plugin(tauri_plugin_http::init())
        .plugin(tauri_plugin_notification::init())
        .plugin(tauri_plugin_opener::init())
        .setup(|app| {
            // Kurulum bağlantıyı kullanıcı kaydına (HKCU) yazar; geliştirme / taşınabilir çalıştırmada da kayıtlı olsun
            #[cfg(windows)]
            {
                use tauri_plugin_deep_link::DeepLinkExt;
                let _ = app.deep_link().register_all();
            }
            let _ = app;
            Ok(())
        })
        .manage(mcp::McpBridge::default())
        .invoke_handler(tauri::generate_handler![
            store_read,
            store_write,
            store_delete,
            asset_write,
            asset_path,
            asset_read,
            asset_delete,
            secret_get,
            secret_set,
            secret_delete,
            mcp::mcp_start,
            mcp::mcp_stop,
            mcp::mcp_respond,
        ])
        .run(tauri::generate_context!())
        .expect("DevNote başlatılamadı");
}
