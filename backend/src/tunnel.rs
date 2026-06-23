// Port-forward manager — KHUNG (chưa hoàn thiện).
//
// Record tunnel được lưu/đọc qua REST trong api.rs. Phần runtime thực tế
// (bind listener TCP rồi nối với russh `channel_open_direct_tcpip` cho local/dynamic,
// hoặc `tcpip_forward` cho remote) chưa được nối — xem roadmap trong README.md.
//
// Giữ module này để `mod tunnel;` trong main.rs hợp lệ và là chỗ cắm khi triển khai.
#![allow(dead_code)]

use crate::AppState;

/// Loại port-forward hỗ trợ.
pub enum Kind {
    Local,
    Remote,
    Dynamic,
}

/// Khởi động một tunnel (chưa triển khai).
///
/// TODO: bind TcpListener trên (listen_host, listen_port) và bridge mỗi kết nối
/// tới SSH channel tương ứng theo `kind`.
pub async fn start(_state: &AppState, _tunnel_id: &str) -> anyhow::Result<()> {
    anyhow::bail!("tunnel runtime chưa được triển khai")
}
