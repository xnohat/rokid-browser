# Zoom — việc dở còn lại (2026-08-12 ~01:00)

## Tình trạng
Zoom đang KHÔNG hoạt động đúng (theo report cuối của anh Fuk: "chữ không nhỏ,
ảnh không nhỏ, element không nhỏ"). Code nhìn đúng logic nhưng chưa verify được
vì kính đang gắn iPhone của anh → Mac BLE client không gửi lệnh tới được (kính
chỉ nhận 1 GATT client tại 1 thời điểm).

## Cần làm (khi anh nhả iPhone ~5 phút)
1. Nhả iPhone (đóng app iPhone) để Mac chiếm BLE.
2. Test qua Mac: `tmp/zoi.py` (zoom_out) + `adb screencap` + đo pixel
   (so md5/lit-pixel before/after) — biết CHÍNH XÁC chữ/ảnh có đổi không.
3. Đọc logcat `chromium.*CONSOLE` xem JS `_applyZoom` có lỗi cú pháp không
   (nghi ngờ interpolation `$z===1` / `zoom:$zStr`).
4. Xác nhận `setTextZoom` MethodChannel có tới native không (log ở handler).

## Các cách zoom đã thử (đừng lặp lại vô ích)
- CSS `body.zoom` → co box, để đen/tràn. BỎ.
- `WebView.zoomBy` pinch → crop khi in, stuck khi out. BỎ.
- meta viewport width=320/z → Facebook override. BỎ.
- CSS `zoom` html + width (100/z)% / px → Chromium 95 clamp width, nửa phải đen.
  Wikipedia có lúc ăn lúc không (đọc innerWidth động → sai lũy tiến, đã cache base
  nhưng vẫn dao động). BỎ.
- `transform:scale + width` wrapper → advisor cảnh báo reparenting làm vỡ SPA;
  thực tế lệch trái/ẩn phải, kết nối rớt. BỎ.
- **HIỆN TẠI:** native textZoom (chữ) + CSS `zoom` trực tiếp lên img/video/svg
  (KHÔNG wrapper). Đây là hướng đúng nhất theo advisor (không reparent DOM) —
  NHƯNG chưa verify. Nếu chữ cũng không nhỏ → nghi JS lỗi làm cả block fail,
  hoặc app chưa nạp bản mới.

## Giới hạn đã xác nhận (WebView 95 cũ trên kính)
- Facebook: dark-force + zoom-fill-width không thể ép qua CSS (nó control DOM).
- Viền xanh olive quanh khung WebView: chưa tắt được (anh Fuk bảo bỏ qua).
- Whole-page uniform zoom + fill width: không ổn định trên WebView 95.

## Đề xuất nếu textZoom+media-zoom vẫn fail
- Tách bạch: chỉ giữ textZoom (chữ) cho CHẮC CHẮN ổn định (đã verify chạy).
  Ảnh không nhỏ theo là hạn chế chấp nhận được — quan trọng là KHÔNG vỡ/lệch.
- Hoặc: cân nhắc nâng Android System WebView trên kính lên bản mới (Chromium
  đời cao hỗ trợ CSS zoom + force-dark tốt hơn) — cần kính cho phép update.

## Vị trí code
- `rokid_browser_glasses/lib/browser_screen.dart` → `_applyZoom()` (~dòng 246)
- zoom_in/out handlers ~dòng 564-567
- native `setTextZoom` → `MainActivity.kt` ~dòng 343
