# Kiểm chứng chuyển thiết bị macOS — 26/10/2026

Lỗi ban đầu được tái hiện trên app macOS 1.1.6: chọn OPPO USB, mất USB rồi cắm lại; dropdown trở về OPPO USB nhưng phiên thực vẫn ở Samsung Wi-Fi. Bản sửa giữ cố định ADB serial đã chọn, dừng input của phiên cũ trước khi teardown và bỏ kết quả bất đồng bộ đã hết hiệu lực.

Mã macOS nằm trên `main`, dựa trên `6340c00`, ở dạng working diff. App local được đóng gói tại `build/DeskBridge.app`, bundle ID `com.deskbridge.app`, ký bằng `DeskBridge Dev`. Phiên bản phát hành vẫn là 1.1.6; đây là bản local có thay đổi chưa phát hành. Manifest và log của lượt kiểm chứng nằm trong `build/verification/`.

## Thay đổi hành vi

- Header và menu bar mô tả phiên điều khiển thực cùng USB/Wi-Fi; dropdown mô tả lựa chọn người dùng, kể cả khi offline.
- Một serial đã chọn sẽ được chờ đến khi sẵn sàng. Máy khác xuất hiện không thay thế lựa chọn đó. Lần đầu chỉ có một máy ready thì chọn và ghi nhớ máy ấy.
- Chọn máy đánh thức discovery ngay, dừng input vào phiên cũ, chờ teardown xong rồi bắt đầu phiên mới. Mã thế hệ chặn callback và kết quả discovery/chuẩn bị Wi-Fi cũ.
- Wi-Fi tiến qua đọc địa chỉ, chuẩn bị, kết nối ADB, xác nhận thiết bị ready và khởi tạo phiên điều khiển. Thành công cần handshake của phiên điều khiển.
- Toàn thao tác Wi-Fi tối đa 30 giây; mỗi lệnh ADB tối đa 10 giây và bị giới hạn thêm bởi thời gian còn lại. Cleanup forward có deadline riêng để vẫn chạy sau khi tác vụ tạo forward bị hủy.
- Mất Wi-Fi tạm thời thử lại đúng IP/port với backoff 2, 4, 8… tối đa 30 giây. Ngắt chủ động, Hủy và tắt Enabled dừng tự nối lại. Dropdown và Enabled vẫn dùng được trong lúc chuẩn bị Wi-Fi.
- Giữ tên model khi ADB báo offline mà bỏ trường model. Các lỗi giữ nguyên dữ liệu IP/port; Hủy hỗ trợ phím Escape.

## Kiểm tra tự động

| Kiểm tra | Kết quả |
| --- | --- |
| `scripts/check.sh`, bản cuối | Pass: shellcheck, SwiftFormat, strings, server tests/build, mac build/tests |
| AppModel | 11 test functions pass, gồm các trường hợp tham số hóa |
| ADBBridge | 27 tests pass: lệnh/serial, ready đúng endpoint, timeout, hủy và stdout kế thừa |
| DeviceSession/cleanup | Pass: hủy startup đang kẹt, cleanup sau cancellation, kết thúc process bỏ qua SIGTERM |
| Review concurrency/cleanup | Finding về cleanup qua context đã hủy đã sửa; lượt review cuối PASS |

Model tests bao phủ USB biến mất khi máy Wi-Fi khác còn online, USB trở lại, chọn ban đầu, chọn khi chưa có phiên, A → B → A, teardown barrier, callback/kết quả discovery đến muộn, placeholder, handshake trước khi xóa input, hủy/disable/đổi lựa chọn, ngắt chủ động, reconnect/backoff/Thử lại, deadline và lỗi khởi tạo phiên.

## Kiểm chứng thiết bị và giao diện

| Kịch bản | Bằng chứng/kết quả |
| --- | --- |
| Samsung USB → Wi-Fi | Pass trên app thật; chỉ Connected sau khi phiên điều khiển sẵn sàng |
| Một Samsung có hai endpoint USB/Wi-Fi | Chọn được từng đường; đã chuyển qua lại trước khi chuyển cáp sang OPPO |
| OPPO USB ↔ Samsung Wi-Fi | 20 lượt chọn trong dropdown, gồm đổi nhanh khi phiên trước còn khởi tạo; cuối lượt UI và forward/process cùng trỏ Samsung Wi-Fi |
| Samsung mất Wi-Fi rồi phục hồi | Sau thao tác tắt/bật Wi-Fi của người dùng, phiên cũ kết thúc do im lặng lúc 11:20:56; phiên Wi-Fi mới ready lúc 11:20:59. Lựa chọn giữ nguyên Samsung, không chuyển sang OPPO USB |
| Ngắt Wi-Fi chủ động | App giữ lựa chọn offline, không còn forward và không tự nối lại; bấm Thử lại tạo lại đúng phiên Wi-Fi |
| USB mất và trở lại trên bản cuối | Pass trên bản cuối: 11:40:49 USB biến mất, lựa chọn vẫn OPPO và forward rỗng trong khi Samsung Wi-Fi ready; 11:41:14 USB trở lại, 11:41:16 forward mới trỏ đúng OPPO. Log `usb-return.jsonl` ghi thêm một lượt mất/trở lại 11:42:20–11:42:22 |
| Wi-Fi liên tục | Pass 3 phút (15:29:44–15:32:44), 13 mẫu cách nhau 15 giây: 0 mẫu bất thường; giữ đúng Samsung Wi-Fi, một forward và một server PID 50233 xuyên suốt. Rút từ 15 xuống 3 phút theo yêu cầu người dùng; chưa nghiệm thu độ ổn định 15 phút |
| Visual | 48 offscreen fixtures: connected/waiting/connecting/error × 400/440/700 × sáng/tối × Anh/Việt; đã xem hai contact sheets. Giao diện dark 440 và các trạng thái hoạt động được kiểm tra thêm trên app thật |

Trong lượt test đầu, `adb connect` của daemon cũ báo `No route to host` dù Mac ping và mở TCP 5555 được. Người dùng cho phép restart ADB server một lần; sau restart, kết nối thành công. Đây là thao tác chẩn đoán thủ công, không được đưa vào luồng tự phục hồi của app.

## Độ trễ transport

Đo 300 PING/PONG samples bằng `DeviceSmokeTests.pingRoundTripLatency`, giữ nguyên gate p95 < 25 ms. App được tạm dừng để smoke test sở hữu phiên riêng.

| Đường kết nối | p50 | p95 | max | Gate |
| --- | ---: | ---: | ---: | --- |
| OPPO USB | 0,71 ms | 1,24 ms | 47,94 ms | Pass |
| Samsung Wi-Fi | 30,90 ms | 70,23 ms | 116,39 ms | Fail |

Handshake, PING và enter/move/exit đều pass trên cả hai đường. Số đo này là RTT qua ADB forward, không phải độ trễ toàn bộ từ thao tác chuột đến hình ảnh. Lượt triển khai này chưa chứng minh cải thiện độ trễ Wi-Fi.

## Windows đã bàn giao trước khi làm macOS

Commit `2b19d05` được push lên `windows`: installer, icon và packaging. Local có 43 core tests, 32 server tests pass và cross-build không warning/error. [CI Windows](https://github.com/ThanhNg224/DeskBridge/actions/runs/40265346941) thành công, tạo artifact gồm ZIP và installer. Kiểm chứng installer/runtime trên Windows vật lý nằm ngoài kết quả macOS này.

## Bàn giao local

`build/verification/macos-connection.patch` chứa toàn bộ working diff macOS, gồm các file mới. Bản macOS chưa commit/push hoặc phát hành. App local đang chạy đúng Samsung Wi-Fi; chữ ký và hash binary được kiểm tra lại sau bài theo dõi.
