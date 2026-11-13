using System.Diagnostics;
using System.Globalization;
using System.Windows.Automation;
using System.Windows.Controls.Primitives;
using System.Windows.Data;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using DeskBridge.Core;

namespace DeskBridge.Windows;

internal sealed class MainWindow : Window
{
    private readonly AppModel model;
    private readonly TextBlock status = new() { FontSize = 16, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap };
    private readonly TextBlock error = new() { TextWrapping = TextWrapping.Wrap, Foreground = SystemColors.ControlTextBrush, Margin = new Thickness(0, 8, 0, 8) };
    private readonly ScrollViewer errorDetails;
    private readonly TextBlock autoWifiStatus = new() { TextWrapping = TextWrapping.Wrap, Foreground = SystemColors.ControlTextBrush };
    private readonly CheckBox autoWifi = new();
    private readonly StackPanel transportPanel = new() { Margin = new Thickness(0, 8, 0, 0) };
    private readonly TextBlock transportLabel = new() { FontWeight = FontWeights.SemiBold };
    private readonly RadioButton usbTransport = new() { Content = "USB", GroupName = "PhoneTransport", Margin = new Thickness(0, 4, 16, 0) };
    private readonly RadioButton wifiTransport = new() { Content = "Wi-Fi", GroupName = "PhoneTransport", Margin = new Thickness(0, 4, 0, 0) };
    private Button? useDetectedDevice;
    private Button? disconnectWifiButton;
    private Button? retryAutoWifiButton, restartAdbButton, resumeAutoWifiButton;
    private readonly ComboBox device = new() { DisplayMemberPath = "Label", SelectedValuePath = "Serial", MinHeight = 32 };
    private readonly TextBox adb = new(), pointer = new(), scroll = new(), host = new(), port = new() { Text = "5555" };
    private readonly ComboBox edge = new() { MinHeight = 32 };
    private readonly ComboBox language = new() { ItemsSource = new[] { "English", "Tiếng Việt" }, MinHeight = 32 };
    private readonly CheckBox enabled = new(), back = new(), invert = new(), clipboard = new(), composed = new(), startup = new();
    private readonly TabControl tabs = new();
    private readonly StackPanel setupTools = new();
    private readonly TextBlock setupPhone = new() { TextWrapping = TextWrapping.Wrap };
    private readonly TextBlock backgroundWifiStatus = new() { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 4, 0, 4) };
    private readonly List<Action> translate = [];
    private bool missingAdb;
    private bool loading;
    private string devicesKey = "";
    private sealed record DeviceChoice(string Serial, string Label);
    private string T(string en, string vi) => model.Settings.Language == "vi" ? vi : en;

    public MainWindow(AppModel model)
    {
        this.model = model;
        Title = "DeskBridge — Windows (experimental)";
        LoadIcon();
        Width = 680; Height = 620; MinWidth = 520; MinHeight = 540;
        Background = SystemColors.ControlBrush;
        Foreground = SystemColors.ControlTextBrush;
        var root = new DockPanel { Margin = new Thickness(16) };
        var footer = new StackPanel { Margin = new Thickness(0, 8, 0, 0) };
        var footerActions = new WrapPanel();
        footerActions.Children.Add(Button("Apply & reconnect", "Áp dụng và kết nối lại", ApplyAsync));
        footerActions.Children.Add(Button("Return control to PC", "Trả điều khiển về PC", () =>
        {
            model.ReturnLocal();
            return Task.CompletedTask;
        }));
        footer.Children.Add(footerActions);
        footer.Children.Add(Caption("Release shortcut: Ctrl+Alt+Shift+Esc", "Phím trả điều khiển: Ctrl+Alt+Shift+Esc"));
        footer.Children.Add(Caption("Experimental · Windows/device acceptance pending", "Bản thử nghiệm · Chưa nghiệm thu Windows/thiết bị"));
        DockPanel.SetDock(footer, Dock.Bottom); root.Children.Add(footer);
        var header = new StackPanel { Margin = new Thickness(0, 0, 0, 8) };
        header.Children.Add(new TextBlock { Text = "DeskBridge", FontSize = 24, FontWeight = FontWeights.SemiBold });
        header.Children.Add(status);
        header.Children.Add(backgroundWifiStatus);
        errorDetails = new ScrollViewer { Content = error, MaxHeight = 88, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        header.Children.Add(errorDetails);
        DockPanel.SetDock(header, Dock.Top); root.Children.Add(header);
        root.Children.Add(tabs);
        Content = root;
        device.SelectionChanged += async (_, _) =>
        {
            if (!loading) await model.SelectDeviceAsync(device.SelectedValue as string);
        };
        var transportOptions = new StackPanel { Orientation = Orientation.Horizontal };
        transportOptions.Children.Add(usbTransport); transportOptions.Children.Add(wifiTransport);
        transportPanel.Children.Add(transportLabel); transportPanel.Children.Add(transportOptions);
        usbTransport.Checked += async (_, _) => await SelectTransportAsync(false);
        wifiTransport.Checked += async (_, _) => await SelectTransportAsync(true);
        autoWifi.Checked += async (_, _) => await ChangeAutoWifiAsync(true);
        autoWifi.Unchecked += async (_, _) => await ChangeAutoWifiAsync(false);
        Closing += (_, e) => { if (!((App)Application.Current).Exiting) { e.Cancel = true; Hide(); } };
        model.Changed += Render;
        BuildPages();
        tabs.SelectionChanged += (_, args) =>
        {
            if (ReferenceEquals(args.Source, tabs)) UpdateWifiSummary();
        };
        LoadSettings(); Render();
    }
    private async Task ChangeAutoWifiAsync(bool enabled)
    {
        if (loading) return;
        if (enabled && MessageBox.Show(this, T("This may briefly restart Android debugging and enables unencrypted ADB on the local network. The phone can keep that access enabled after this setting is off. Use only on trusted networks.", "Thao tác này có thể tạm khởi động lại gỡ lỗi Android và bật ADB không mã hóa qua mạng cục bộ. Điện thoại có thể vẫn cho phép truy cập sau khi tắt cài đặt này. Chỉ dùng trên mạng tin cậy."), "DeskBridge", MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes)
        {
            loading = true; autoWifi.IsChecked = false; loading = false;
            return;
        }
        try { await model.SetAutoWifiAsync(enabled); }
        catch (Exception e) { model.Report(e); Render(); }
    }
    private async Task SelectTransportAsync(bool wireless)
    {
        if (loading) return;
        var selected = model.SelectedPhoneTransports.FirstOrDefault(d => AdbClient.IsWirelessSerial(d.Serial) == wireless);
        if (selected is not null) await model.SelectTransportAsync(selected.Serial);
    }
    private void Localize(string en, string vi, Action<string> update)
    {
        void Translate() => update(T(en, vi));
        translate.Add(Translate);
        Translate();
    }

    private TextBlock Caption(string en, string vi)
    {
        var text = new TextBlock { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 4, 0, 0) };
        Localize(en, vi, value => text.Text = value);
        return text;
    }

    private GroupBox Group(string en, string vi, UIElement content)
    {
        var box = new GroupBox { Content = content, Padding = new Thickness(12, 4, 12, 8), Margin = new Thickness(0, 0, 0, 12) };
        Localize(en, vi, value => box.Header = value);
        return box;
    }

    private StackPanel Page(string en, string vi)
    {
        var panel = new StackPanel { Margin = new Thickness(12) };
        var tab = new TabItem
        {
            Padding = new Thickness(12, 6, 12, 6),
            Content = new ScrollViewer { Content = panel, VerticalScrollBarVisibility = ScrollBarVisibility.Auto }
        };
        Localize(en, vi, value => tab.Header = value);
        tabs.Items.Add(tab);
        return panel;
    }

    private StackPanel Field(string en, string vi, Control control, bool inline = false)
    {
        var field = new StackPanel { Orientation = inline ? Orientation.Horizontal : Orientation.Vertical };
        var label = new Label { Target = control, Padding = new Thickness(0, 4, 8, 4), VerticalAlignment = VerticalAlignment.Center };
        if (inline) label.Width = 232;
        Localize(en, vi, value =>
        {
            label.Content = value;
            AutomationProperties.SetName(control, value);
        });
        field.Children.Add(label);
        field.Children.Add(control);
        return field;
    }

    private void Check(StackPanel section, CheckBox control, string en, string vi)
    {
        Localize(en, vi, value => control.Content = value);
        section.Children.Add(control);
    }

    private Button Button(string en, string vi, Func<Task> action)
    {
        var button = new Button();
        Localize(en, vi, text => button.Content = text);
        button.Click += async (_, _) =>
        {
            button.IsEnabled = false;
            try { await action(); }
            catch (Exception e) { model.Report(e); }
            finally { button.IsEnabled = true; }
        };
        return button;
    }
    private void BuildPages()
    {
        var connection = Page("Connection", "Kết nối");
        var controls = Page("Controls", "Điều khiển");
        var shortcuts = Page("Shortcuts", "Phím tắt");
        var general = Page("General", "Chung");

        var phone = new StackPanel();
        Check(phone, enabled, "Enable DeskBridge", "Bật DeskBridge");
        phone.Children.Add(Field("Android device", "Thiết bị Android", device));
        phone.Children.Add(transportPanel);
        var connectionActions = new WrapPanel();
        connectionActions.Children.Add(Button("Connect", "Kết nối", model.ConnectAsync));
        connectionActions.Children.Add(Button("Disconnect", "Ngắt kết nối", model.DisconnectAsync));
        useDetectedDevice = Button("Use detected phone…", "Dùng điện thoại vừa phát hiện…", async () =>
        {
            var detected = model.DetectedPhone;
            if (detected is { } phone && MessageBox.Show(this, T("A different phone is using this connection. Switch control to it?", "Một điện thoại khác đang dùng kết nối này. Chuyển quyền điều khiển sang máy đó?"), "DeskBridge", MessageBoxButton.YesNo, MessageBoxImage.Warning) == MessageBoxResult.Yes)
                await model.UseDetectedDeviceAsync(phone.Serial, phone.Identity);
        });
        connectionActions.Children.Add(useDetectedDevice);
        phone.Children.Add(connectionActions);
        connection.Children.Add(Group("Phone", "Điện thoại", phone));

        setupTools.Children.Add(Caption("Android tools are missing. Set them up to connect.", "Thiếu công cụ Android. Hãy thiết lập để kết nối."));
        setupTools.Children.Add(Button("Open Android tools settings", "Mở cài đặt công cụ Android", () =>
        {
            tabs.SelectedIndex = 3;
            Dispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.Loaded, new Action(() => adb.Focus()));
            return Task.CompletedTask;
        }));
        connection.Children.Add(setupTools);
        connection.Children.Add(setupPhone);

        var wifi = new StackPanel();
        Check(wifi, autoWifi, "Automatically prepare Wi-Fi", "Tự chuẩn bị Wi-Fi");
        wifi.Children.Add(autoWifiStatus);
        var wireless = new WrapPanel();
        disconnectWifiButton = Button("Disconnect Wi-Fi", "Ngắt Wi-Fi", model.DisconnectWifiAsync);
        retryAutoWifiButton = Button("Retry Wi-Fi", "Thử lại Wi-Fi", model.RetryAutoWifiAsync);
        resumeAutoWifiButton = Button("Reconnect Wi-Fi", "Kết nối lại Wi-Fi", model.ResumeAutoWifiAsync);
        restartAdbButton = Button("Restart ADB…", "Khởi động lại ADB…", async () =>
        {
            if (MessageBox.Show(this, T("This temporarily disconnects all devices and other apps using ADB. They may need to reconnect.", "Thao tác này tạm thời ngắt tất cả thiết bị và ứng dụng khác đang dùng ADB. Chúng có thể cần kết nối lại."), "DeskBridge", MessageBoxButton.YesNo, MessageBoxImage.Warning) == MessageBoxResult.Yes)
                await model.RestartAdbAsync();
        });
        wireless.Children.Add(disconnectWifiButton);
        wireless.Children.Add(retryAutoWifiButton); wireless.Children.Add(resumeAutoWifiButton); wireless.Children.Add(restartAdbButton);
        wifi.Children.Add(wireless);

        var manual = new StackPanel { Margin = new Thickness(0, 4, 0, 0) };
        var endpoint = new WrapPanel();
        host.Width = 152; port.Width = 100;
        var addressField = Field("IPv4 address", "Địa chỉ IPv4", host);
        var portField = Field("Connection port", "Cổng kết nối", port);
        addressField.Margin = portField.Margin = new Thickness(0, 0, 8, 0);
        endpoint.Children.Add(addressField); endpoint.Children.Add(portField);
        var connectWifi = Button("Connect Wi-Fi", "Kết nối Wi-Fi", () =>
        {
            if (!int.TryParse(port.Text, out int value)) throw new InvalidDataException(T("Invalid port.", "Cổng không hợp lệ."));
            return model.ConnectWifiAsync(host.Text, value);
        });
        connectWifi.VerticalAlignment = VerticalAlignment.Bottom;
        connectWifi.Margin = new Thickness(0, 0, 0, 8);
        endpoint.Children.Add(connectWifi);
        manual.Children.Add(endpoint);
        manual.Children.Add(Caption(
            "Use the same Wi-Fi network. Enable automatic preparation over USB, or pair the phone outside DeskBridge.",
            "Dùng cùng mạng Wi-Fi. Bật tự chuẩn bị khi cắm USB, hoặc ghép đôi điện thoại bên ngoài DeskBridge."));
        var manualWifi = new ToggleButton
        {
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Left,
            MinHeight = 32,
            Padding = new Thickness(8, 4, 8, 4),
            Margin = new Thickness(0, 8, 0, 0)
        };
        void UpdateManualWifiLabel()
        {
            var label = T("Manual Wi-Fi", "Wi-Fi thủ công");
            manualWifi.Content = (manualWifi.IsChecked == true ? "⌄  " : "›  ") + label;
            AutomationProperties.SetName(manualWifi, label);
        }
        translate.Add(UpdateManualWifiLabel);
        UpdateManualWifiLabel();
        manualWifi.Checked += (_, _) => UpdateManualWifiLabel();
        manualWifi.Unchecked += (_, _) => UpdateManualWifiLabel();
        manual.SetBinding(VisibilityProperty, new Binding(nameof(ToggleButton.IsChecked))
        {
            Source = manualWifi,
            Converter = new BooleanToVisibilityConverter()
        });
        wifi.Children.Add(manualWifi);
        wifi.Children.Add(manual);
        connection.Children.Add(Group("Wi-Fi", "Wi-Fi", wifi));

        edge.Width = 120;
        var edges = Enum.GetValues<Edge>().Select(value => new ComboBoxItem { Tag = value }).ToArray();
        edge.ItemsSource = edges;
        edge.SelectedValuePath = nameof(ComboBoxItem.Tag);
        void TranslateEdges()
        {
            foreach (var item in edges)
                item.Content = (Edge)item.Tag switch
                {
                    Edge.Left => T("Left", "Trái"), Edge.Right => T("Right", "Phải"),
                    Edge.Top => T("Top", "Trên"), Edge.Bottom => T("Bottom", "Dưới"),
                    _ => item.Tag.ToString()
                };
        }
        translate.Add(TranslateEdges);
        TranslateEdges();
        controls.Children.Add(Group("Phone position", "Vị trí điện thoại", Field("Screen edge", "Cạnh màn hình", edge, inline: true)));
        var mouse = new StackPanel();
        pointer.Width = scroll.Width = 88;
        mouse.Children.Add(Field("Pointer speed (0.1–10)", "Tốc độ con trỏ (0.1–10)", pointer, inline: true));
        mouse.Children.Add(Field("Scroll speed (0.1–10)", "Tốc độ cuộn (0.1–10)", scroll, inline: true));
        Check(mouse, back, "Right click goes Back", "Chuột phải để quay lại");
        Check(mouse, invert, "Invert scrolling", "Đảo hướng cuộn");
        controls.Children.Add(Group("Mouse & scrolling", "Chuột và cuộn", mouse));
        var keyboard = new StackPanel();
        Check(keyboard, clipboard, "Share text clipboard", "Chia sẻ clipboard văn bản");
        Check(keyboard, composed, "Composed text (Microsoft IME / UniKey)", "Nhập văn bản qua bộ gõ (Microsoft / UniKey)");
        keyboard.Children.Add(Caption("A small text preview receives focus while controlling Android. Commit words with space or punctuation.",
            "Ô xem trước nhận focus khi điều khiển Android. Hoàn tất từ bằng dấu cách hoặc dấu câu."));
        controls.Children.Add(Group("Keyboard & clipboard", "Bàn phím và clipboard", keyboard));

        shortcuts.Children.Add(Group("Android navigation", "Điều hướng Android", ShortcutRows(
            ("Home", "Màn hình chính", "Alt+H"), ("Back", "Quay lại", "Alt+B"),
            ("Recent apps", "Ứng dụng gần đây", "Alt+R"), ("Switch apps", "Chuyển ứng dụng", "Alt+Tab"),
            ("Notifications", "Thông báo", "Alt+N"))));
        shortcuts.Children.Add(Group("Screen", "Màn hình", ShortcutRows(
            ("Sleep screen", "Tắt màn hình", "Alt+L"), ("Brightness", "Độ sáng", "Alt+←/→"))));
        shortcuts.Children.Add(Group("Audio & media", "Âm thanh và media", ShortcutRows(
            ("Volume", "Âm lượng", "Alt+↑/↓"), ("Mute", "Tắt tiếng", "Alt+M"), ("Play/pause", "Phát/tạm dừng", "Alt+P"))));

        var preferences = new StackPanel();
        Check(preferences, startup, "Start with Windows", "Mở cùng Windows");
        language.Width = 120;
        preferences.Children.Add(Field("Language", "Ngôn ngữ", language, inline: true));
        general.Children.Add(Group("Preferences", "Tùy chọn", preferences));

        var tools = new StackPanel();
        tools.Children.Add(Field("ADB executable", "Đường dẫn ADB", adb));
        var chooseAdb = new WrapPanel();
        chooseAdb.Children.Add(Button("Choose adb.exe…", "Chọn adb.exe…", () =>
        {
            var dialog = new Microsoft.Win32.OpenFileDialog { Filter = "ADB|adb.exe", CheckFileExists = true };
            if (dialog.ShowDialog(this) == true) adb.Text = dialog.FileName;
            return Task.CompletedTask;
        }));
        tools.Children.Add(chooseAdb);
        tools.Children.Add(Caption("To install Android tools, download Platform Tools for Windows from Google, accept its terms, then select the ZIP.",
            "Để cài công cụ Android, tải Platform Tools cho Windows từ Google, chấp nhận điều khoản rồi chọn tệp ZIP."));
        var toolsActions = new WrapPanel();
        toolsActions.Children.Add(Button("Download Android tools from Google", "Tải công cụ Android từ Google", () =>
        {
            Process.Start(new ProcessStartInfo("https://developer.android.com/tools/releases/platform-tools") { UseShellExecute = true });
            return Task.CompletedTask;
        }));
        toolsActions.Children.Add(Button("Select Platform Tools ZIP…", "Chọn tệp ZIP Platform Tools…", InstallAdbAsync));
        tools.Children.Add(toolsActions);
        general.Children.Add(Group("Android tools", "Công cụ Android", tools));
        general.Children.Add(Group("Updates", "Cập nhật", new WrapPanel
        {
            Children = { Button("Check for updates", "Kiểm tra bản cập nhật", CheckUpdatesAsync) }
        }));

        Localize(
            "On your phone, tap Build number seven times in About phone, enable USB debugging, connect USB and tap Allow.",
            "Trên điện thoại, chạm Số bản dựng bảy lần trong Giới thiệu điện thoại, bật Gỡ lỗi USB, cắm cáp USB rồi chạm Cho phép.",
            value => setupPhone.Text = value);
        tabs.SelectedIndex = 0;
    }

    private StackPanel ShortcutRows(params (string En, string Vi, string Keys)[] shortcuts)
    {
        var panel = new StackPanel();
        foreach (var (en, vi, keys) in shortcuts)
        {
            var row = new DockPanel { Margin = new Thickness(0, 4, 0, 4) };
            var chord = new TextBlock { Text = keys, Margin = new Thickness(8, 4, 0, 0) };
            DockPanel.SetDock(chord, Dock.Right);
            row.Children.Add(chord);
            row.Children.Add(Caption(en, vi));
            panel.Children.Add(row);
        }
        return panel;
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
            missingAdb = !ManagedAdb.ExistingAdb(model.Settings.AdbPath);
            Render();
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
        missingAdb = !ManagedAdb.ExistingAdb(value.AdbPath);
        adb.Text = value.AdbPath; pointer.Text = value.PointerSpeed.ToString(CultureInfo.InvariantCulture);
        scroll.Text = value.ScrollSpeed.ToString(CultureInfo.InvariantCulture); edge.SelectedValue = value.Edge;
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
            Edge = edge.SelectedValue is Edge selected ? selected : Edge.Right,
            Enabled = enabled.IsChecked == true, RightClickIsBack = back.IsChecked == true,
            InvertScroll = invert.IsChecked == true, ShareClipboard = clipboard.IsChecked == true,
            ComposedText = composed.IsChecked == true, StartWithWindows = startup.IsChecked == true,
            PreferredSerial = model.SelectedSerial, Language = language.SelectedIndex == 1 ? "vi" : "en"
        });
        foreach (var update in translate) update();
        LoadSettings(); Render();
    }
    private void Render()
    {
        string key = model.Settings.Language + "\n" + model.SelectedSerial + "\n" + string.Join('\n', model.Devices.Select(d => d.Serial + d.State + d.Description));
        loading = true;
        if (key != devicesKey || device.ItemsSource is null)
        {
            var choices = model.Devices.Select(d => new DeviceChoice(d.Serial, $"{d.Description} — {(AdbClient.IsWirelessSerial(d.Serial) ? "Wi-Fi" : "USB")} · {d.Serial} ({d.State})")).ToList();
            if (model.SelectedSerial is { } serial && choices.All(d => d.Serial != serial))
                choices.Add(new(serial, $"{serial} — {T("unavailable", "chưa sẵn sàng")}"));
            device.ItemsSource = choices;
            devicesKey = key;
        }
        device.SelectedValue = model.SelectedSerial;
        transportPanel.Visibility = model.SelectedHasBothTransports ? Visibility.Visible : Visibility.Collapsed;
        transportPanel.IsEnabled = model.Settings.Enabled;
        transportLabel.Text = T("Connection", "Kết nối");
        usbTransport.IsChecked = model.SelectedSerial is { } usb && !AdbClient.IsWirelessSerial(usb);
        wifiTransport.IsChecked = model.SelectedSerial is { } wifi && AdbClient.IsWirelessSerial(wifi);
        autoWifi.IsChecked = model.Settings.AutoPrepareWifi;
        loading = false;
        if (useDetectedDevice is not null) useDetectedDevice.Visibility = model.DetectedDifferentDevice ? Visibility.Visible : Visibility.Collapsed;
        bool selectedWifi = model.SelectedSerial is { } selected && AdbClient.IsWirelessSerial(selected);
        if (disconnectWifiButton is not null) disconnectWifiButton.Visibility = selectedWifi ? Visibility.Visible : Visibility.Collapsed;
        if (retryAutoWifiButton is not null) retryAutoWifiButton.Visibility = model.AutoWifiStatus == "Wi-Fi could not be prepared" && !model.AutoWifiInProgress ? Visibility.Visible : Visibility.Collapsed;
        if (resumeAutoWifiButton is not null) resumeAutoWifiButton.Visibility = model.CanResumeAutoWifi ? Visibility.Visible : Visibility.Collapsed;
        if (restartAdbButton is not null) restartAdbButton.Visibility = model.AutoWifiStatus == "Wi-Fi could not be prepared" && !model.AutoWifiInProgress ? Visibility.Visible : Visibility.Collapsed;
        autoWifiStatus.Text = model.AutoWifiStatus switch
        {
            "Preparing Wi-Fi" => T("Preparing Wi-Fi…", "Đang chuẩn bị Wi-Fi…"),
            "Wi-Fi could not be prepared" => T("Wi-Fi could not be prepared. Check the phone and network.", "Không thể chuẩn bị Wi-Fi. Hãy kiểm tra điện thoại và mạng."),
            "Wi-Fi will be prepared after control returns" => T("Wi-Fi will be prepared after control returns to the PC.", "Wi-Fi sẽ được chuẩn bị sau khi trả điều khiển về PC."),
            _ => ""
        };
        status.Text = model.Settings.Language == "vi" ? model.Status switch
        {
            "Starting" => "Đang khởi động", "Disabled" => "Đã tắt", "No authorized device" => "Chưa có thiết bị được cấp quyền",
            "Ready" => "Sẵn sàng", "Selected device unavailable" => "Thiết bị đã chọn chưa sẵn sàng", "Connecting" => "Đang kết nối", "Connected" => "Đã kết nối",
            "Reconnecting" => "Đang kết nối lại",
            "Restarting ADB" => "Đang khởi động lại ADB",
            "Switched to Wi-Fi" => "Đã tự chuyển sang Wi-Fi", "Switched to USB" => "Đã tự chuyển sang USB",
            "Controlling Android" => "Đang điều khiển Android", "Disconnected" => "Đã ngắt kết nối", "Error" => "Có lỗi", _ => model.Status
        } : model.Status;
        if (model.Connected && model.Status == "Connected" && model.SelectedSerial is { } active)
            status.Text += AdbClient.IsWirelessSerial(active) ? " · Wi-Fi" : " · USB";
        error.Text = model.Error ?? "";
        errorDetails.Visibility = string.IsNullOrEmpty(error.Text) ? Visibility.Collapsed : Visibility.Visible;
        setupTools.Visibility = missingAdb ? Visibility.Visible : Visibility.Collapsed;
        setupPhone.Visibility = !missingAdb && (model.Status == "No authorized device"
            || model.Devices.Any(phone => phone.Serial == model.SelectedSerial && phone.State == "unauthorized"))
            ? Visibility.Visible : Visibility.Collapsed;
        autoWifiStatus.Visibility = string.IsNullOrEmpty(autoWifiStatus.Text) ? Visibility.Collapsed : Visibility.Visible;
        UpdateWifiSummary();
    }

    private void UpdateWifiSummary()
    {
        backgroundWifiStatus.Text = autoWifiStatus.Text;
        backgroundWifiStatus.Visibility = tabs.SelectedIndex > 0 && !string.IsNullOrEmpty(backgroundWifiStatus.Text)
            ? Visibility.Visible : Visibility.Collapsed;
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
