using System.Diagnostics;
using System.Globalization;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using DeskBridge.Core;

namespace DeskBridge.Windows;

internal sealed class MainWindow : Window
{
    private readonly AppModel model;
    private readonly TextBlock status = new() { FontSize = 20, FontWeight = FontWeights.SemiBold };
    private readonly TextBlock error = new() { TextWrapping = TextWrapping.Wrap, Foreground = Brushes.Firebrick, Margin = new Thickness(0, 8, 0, 8) };
    private readonly ComboBox device = new() { DisplayMemberPath = "Label", SelectedValuePath = "Serial", MinHeight = 32 };
    private readonly TextBox adb = new(), pointer = new(), scroll = new(), host = new(), port = new() { Text = "5555" };
    private readonly ComboBox edge = new() { ItemsSource = Enum.GetValues<Edge>(), MinHeight = 32 };
    private readonly ComboBox language = new() { ItemsSource = new[] { "English", "Tiếng Việt" }, MinHeight = 32 };
    private readonly CheckBox enabled = new(), back = new(), invert = new(), clipboard = new(), composed = new(), startup = new();
    private readonly StackPanel fields = new(), actions = new();
    private bool loading;
    private string devicesKey = "";
    private sealed record DeviceChoice(string Serial, string Label);
    private string T(string en, string vi) => model.Settings.Language == "vi" ? vi : en;

    public MainWindow(AppModel model)
    {
        this.model = model;
        Title = "DeskBridge — Windows (experimental)";
        LoadIcon();
        Width = 640; Height = 840; MinWidth = 520; MinHeight = 640;
        Background = new SolidColorBrush(Color.FromRgb(246, 248, 252));
        var root = new DockPanel { Margin = new Thickness(24) };
        actions.Orientation = Orientation.Vertical;
        DockPanel.SetDock(actions, Dock.Bottom); root.Children.Add(actions);
        var header = new StackPanel();
        header.Children.Add(new TextBlock { Text = "DeskBridge", FontSize = 28, FontWeight = FontWeights.Bold });
        header.Children.Add(status); header.Children.Add(error);
        DockPanel.SetDock(header, Dock.Top); root.Children.Add(header);
        root.Children.Add(new ScrollViewer { Content = fields, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
        Content = root;
        device.SelectionChanged += async (_, _) =>
        {
            if (!loading) await model.SelectDeviceAsync(device.SelectedValue as string);
        };
        Closing += (_, e) => { if (!((App)Application.Current).Exiting) { e.Cancel = true; Hide(); } };
        model.Changed += Render;
        BuildFields(); LoadSettings(); Render();
    }
    private void Field(string en, string vi, UIElement control)
    {
        fields.Children.Add(new TextBlock { Text = T(en, vi), Margin = new Thickness(0, 16, 0, 4), FontWeight = FontWeights.SemiBold });
        fields.Children.Add(control);
    }
    private void Check(CheckBox control, string en, string vi)
    { control.Content = T(en, vi); fields.Children.Add(control); }
    private Button Button(string en, string vi, Func<Task> action)
    {
        var button = new Button { Content = T(en, vi) };
        button.Click += async (_, _) =>
        {
            button.IsEnabled = false;
            try { await action(); }
            catch (Exception e) { model.Report(e); }
            finally { button.IsEnabled = true; }
        };
        return button;
    }
    private void BuildFields()
    {
        fields.Children.Clear(); actions.Children.Clear();
        Field("Android device", "Thiết bị Android", device);
        Check(enabled, "Enable DeskBridge", "Bật DeskBridge");
        Field("ADB executable", "Đường dẫn ADB", adb);
        fields.Children.Add(Button("Choose adb.exe…", "Chọn adb.exe…", () =>
        {
            var dialog = new Microsoft.Win32.OpenFileDialog { Filter = "ADB|adb.exe", CheckFileExists = true };
            if (dialog.ShowDialog(this) == true) adb.Text = dialog.FileName;
            return Task.CompletedTask;
        }));
        fields.Children.Add(new TextBlock
        {
            Text = T("If Android tools are missing, download Platform Tools for Windows from Google, accept its terms, then select the ZIP. On the phone, tap Build number seven times in About phone, enable USB debugging, connect USB and tap Allow.",
                     "Nếu thiếu công cụ Android, tải Platform Tools cho Windows từ Google, chấp nhận điều khoản rồi chọn tệp ZIP. Trên điện thoại, chạm Số bản dựng bảy lần trong Giới thiệu điện thoại, bật Gỡ lỗi USB, cắm cáp USB rồi chạm Cho phép."),
            TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 8, 0, 4)
        });
        fields.Children.Add(Button("Download Android tools from Google", "Tải công cụ Android từ Google", () =>
        {
            Process.Start(new ProcessStartInfo("https://developer.android.com/tools/releases/platform-tools") { UseShellExecute = true });
            return Task.CompletedTask;
        }));
        fields.Children.Add(Button("Select Platform Tools ZIP…", "Chọn tệp ZIP Platform Tools…", InstallAdbAsync));
        Field("Phone position (screen edge)", "Vị trí điện thoại (cạnh màn hình)", edge);
        Field("Pointer speed (0.1–10)", "Tốc độ con trỏ (0.1–10)", pointer);
        Field("Scroll speed (0.1–10)", "Tốc độ cuộn (0.1–10)", scroll);
        Check(back, "Right click goes Back", "Chuột phải để quay lại");
        Check(invert, "Invert scrolling", "Đảo hướng cuộn");
        Check(clipboard, "Share text clipboard", "Chia sẻ clipboard văn bản");
        Check(composed, "Composed text (Microsoft IME / UniKey)", "Nhập văn bản qua bộ gõ (Microsoft / UniKey)");
        fields.Children.Add(new TextBlock { Text = T("A small text preview receives focus while controlling Android. Commit words with space or punctuation.", "Ô xem trước nhận focus khi điều khiển Android. Hoàn tất từ bằng dấu cách hoặc dấu câu."), TextWrapping = TextWrapping.Wrap });
        Field("Android shortcuts", "Phím tắt Android", new TextBlock
        {
            Text = T("Alt+H Home · Alt+B Back · Alt+R Recent apps\nAlt+L Sleep screen · Alt+↑/↓ Volume · Alt+←/→ Brightness\nAlt+N Notifications · Alt+M Mute · Alt+P Play/pause · Alt+Tab Switch apps",
                     "Alt+H Màn hình chính · Alt+B Quay lại · Alt+R Ứng dụng gần đây\nAlt+L Tắt màn hình · Alt+↑/↓ Âm lượng · Alt+←/→ Độ sáng\nAlt+N Thông báo · Alt+M Tắt tiếng · Alt+P Phát/tạm dừng · Alt+Tab Chuyển ứng dụng"),
            TextWrapping = TextWrapping.Wrap
        });
        fields.Children.Add(Button("Check for updates", "Kiểm tra bản cập nhật", CheckUpdatesAsync));
        Check(startup, "Start with Windows", "Mở cùng Windows");
        Field("Language", "Ngôn ngữ", language);
        Field("Wi-Fi IPv4 address", "Địa chỉ IPv4 Wi-Fi", host);
        Field("Connection port", "Cổng kết nối", port);
        fields.Children.Add(new TextBlock
        {
            Text = T("Pair Wireless Debugging outside DeskBridge first. Switch to Wi-Fi enables unencrypted legacy ADB; use a trusted network.", "Ghép đôi Wireless Debugging bên ngoài DeskBridge. Chuyển sang Wi-Fi bật ADB không mã hóa; chỉ dùng mạng tin cậy."),
            TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 8, 0, 16)
        });
        var primary = new WrapPanel();
        primary.Children.Add(Button("Apply & reconnect", "Áp dụng và kết nối lại", ApplyAsync));
        primary.Children.Add(Button("Connect", "Kết nối", model.ConnectAsync));
        primary.Children.Add(Button("Disconnect", "Ngắt kết nối", model.DisconnectAsync));
        actions.Children.Add(primary);
        var wireless = new WrapPanel();
        wireless.Children.Add(Button("Connect Wi-Fi", "Kết nối Wi-Fi", () =>
        {
            if (!int.TryParse(port.Text, out int value)) throw new InvalidDataException(T("Invalid port.", "Cổng không hợp lệ."));
            return model.ConnectWifiAsync(host.Text, value);
        }));
        wireless.Children.Add(Button("Switch to Wi-Fi", "Chuyển sang Wi-Fi", model.SwitchWifiAsync));
        wireless.Children.Add(Button("Disconnect Wi-Fi", "Ngắt Wi-Fi", model.DisconnectWifiAsync));
        actions.Children.Add(wireless);
        actions.Children.Add(Button("Return control to PC · Ctrl+Alt+Shift+Esc", "Trả điều khiển về PC · Ctrl+Alt+Shift+Esc", () => { model.ReturnLocal(); return Task.CompletedTask; }));
        actions.Children.Add(new TextBlock { Text = T("Experimental · Windows/device acceptance pending", "Bản thử nghiệm · Chưa nghiệm thu Windows/thiết bị"), Foreground = Brushes.DimGray, Margin = new Thickness(0, 8, 0, 0) });
    }
    private async Task InstallAdbAsync()
    {
        if (ManagedAdb.ExistingAdb(model.Settings.AdbPath) || ManagedAdb.ExistingAdb(adb.Text.Trim()))
        {
            MessageBox.Show(T("Android tools are already configured. Your existing tools will be kept.",
                              "Công cụ Android đã được thiết lập. Công cụ hiện có sẽ được giữ nguyên."), "DeskBridge");
            return;
        }
        var dialog = new Microsoft.Win32.OpenFileDialog { Filter = "ZIP|*.zip", CheckFileExists = true };
        if (dialog.ShowDialog(this) != true) return;
        try
        {
            string installed = await Task.Run(() => PlatformToolsArchive.InstallAsync(dialog.FileName, ManagedAdb.Root,
                ManagedAdb.VerifyGoogleAsync, ManagedAdb.EnsureCompatibleAsync));
            await model.ApplyAsync(model.Settings with { AdbPath = installed, PreferredSerial = model.SelectedSerial });
            adb.Text = model.Settings.AdbPath;
        }
        catch (InvalidOperationException)
        {
            throw new InvalidOperationException(T("The existing Android tools are incompatible. Close the other tools and try again.",
                                                  "Công cụ Android đang chạy không tương thích. Hãy đóng công cụ khác rồi thử lại."));
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or OperationCanceledException or System.ComponentModel.Win32Exception)
        {
            throw new InvalidOperationException(T("Could not verify the Android tools ZIP. Download it from Google and try again.",
                                                  "Không thể xác minh tệp ZIP công cụ Android. Hãy tải từ Google và thử lại."));
        }
    }
    private async Task CheckUpdatesAsync()
    {
        var assembly = System.Reflection.Assembly.GetExecutingAssembly();
        string version = assembly.GetCustomAttributes(typeof(System.Reflection.AssemblyInformationalVersionAttribute), false)
            .OfType<System.Reflection.AssemblyInformationalVersionAttribute>().FirstOrDefault()?.InformationalVersion
            ?? assembly.GetName().Version?.ToString(3) ?? "";
        Uri? url;
        try { url = await ReleaseChecker.CheckWindowsAsync(version); }
        catch (InvalidOperationException)
        {
            throw new InvalidOperationException(T("GitHub limited or refused the request. Try again later.",
                                                  "GitHub đã giới hạn hoặc từ chối yêu cầu. Hãy thử lại sau."));
        }
        catch (Exception error) when (error is System.Net.Http.HttpRequestException or System.Text.Json.JsonException or IOException or OperationCanceledException)
        {
            throw new InvalidOperationException(T("Could not check for updates. Check your connection and try again.",
                                                  "Không thể kiểm tra cập nhật. Hãy kiểm tra kết nối và thử lại."));
        }
        if (url is null)
        {
            MessageBox.Show(T("No newer stable Windows release found.", "Không tìm thấy bản Windows ổn định mới hơn."), "DeskBridge");
            return;
        }
        if (MessageBox.Show(T("A new Windows version is available. Open the download page?",
                              "Đã có phiên bản Windows mới. Mở trang tải về?"), "DeskBridge", MessageBoxButton.YesNo) == MessageBoxResult.Yes)
            Process.Start(new ProcessStartInfo(url.AbsoluteUri) { UseShellExecute = true });
    }

    private void LoadSettings()
    {
        var value = model.Settings;
        adb.Text = value.AdbPath; pointer.Text = value.PointerSpeed.ToString(CultureInfo.InvariantCulture);
        scroll.Text = value.ScrollSpeed.ToString(CultureInfo.InvariantCulture); edge.SelectedItem = value.Edge;
        enabled.IsChecked = value.Enabled; back.IsChecked = value.RightClickIsBack; invert.IsChecked = value.InvertScroll;
        clipboard.IsChecked = value.ShareClipboard; composed.IsChecked = value.ComposedText;
        startup.IsChecked = value.StartWithWindows; language.SelectedIndex = value.Language == "vi" ? 1 : 0;
    }
    private async Task ApplyAsync()
    {
        if (!double.TryParse(pointer.Text, NumberStyles.Float, CultureInfo.InvariantCulture, out double pointerSpeed)
            || !double.TryParse(scroll.Text, NumberStyles.Float, CultureInfo.InvariantCulture, out double scrollSpeed))
            throw new InvalidDataException(T("Enter a numeric speed.", "Nhập tốc độ bằng số."));
        await model.ApplyAsync(model.Settings with
        {
            AdbPath = adb.Text.Trim(), PointerSpeed = pointerSpeed, ScrollSpeed = scrollSpeed,
            Edge = edge.SelectedItem is Edge selected ? selected : Edge.Right,
            Enabled = enabled.IsChecked == true, RightClickIsBack = back.IsChecked == true,
            InvertScroll = invert.IsChecked == true, ShareClipboard = clipboard.IsChecked == true,
            ComposedText = composed.IsChecked == true, StartWithWindows = startup.IsChecked == true,
            PreferredSerial = model.SelectedSerial, Language = language.SelectedIndex == 1 ? "vi" : "en"
        });
        // Controls must be detached from their old parents before rebuilding the translated fields.
        fields.Children.Clear();
        BuildFields(); LoadSettings(); Render();
    }
    private void Render()
    {
        string key = model.SelectedSerial + "\n" + string.Join('\n', model.Devices.Select(d => d.Serial + d.State + d.Description));
        loading = true;
        if (key != devicesKey || device.ItemsSource is null)
        {
            var choices = model.Devices.Select(d => new DeviceChoice(d.Serial, $"{d.Description} — {d.Serial} ({d.State})")).ToList();
            if (model.SelectedSerial is { } serial && choices.All(d => d.Serial != serial))
                choices.Add(new(serial, $"{serial} — {T("unavailable", "chưa sẵn sàng")}"));
            device.ItemsSource = choices;
            devicesKey = key;
        }
        device.SelectedValue = model.SelectedSerial;
        loading = false;
        status.Text = model.Settings.Language == "vi" ? model.Status switch
        {
            "Starting" => "Đang khởi động", "Disabled" => "Đã tắt", "No authorized device" => "Chưa có thiết bị được cấp quyền",
            "Ready" => "Sẵn sàng", "Selected device unavailable" => "Thiết bị đã chọn chưa sẵn sàng", "Connecting" => "Đang kết nối", "Connected" => "Đã kết nối",
            "Controlling Android" => "Đang điều khiển Android", "Disconnected" => "Đã ngắt kết nối", "Error" => "Có lỗi", _ => model.Status
        } : model.Status;
        error.Text = model.Error ?? "";
    }
    private void LoadIcon()
    {
        try
        {
            string? exe = Environment.ProcessPath;
            if (!string.IsNullOrEmpty(exe))
            {
                using var ico = System.Drawing.Icon.ExtractAssociatedIcon(exe);
                if (ico != null)
                {
                    Icon = Imaging.CreateBitmapSourceFromHIcon(
                        ico.Handle,
                        Int32Rect.Empty,
                        BitmapSizeOptions.FromEmptyOptions());
                }
            }
        }
        catch { }
    }
}
