# Windows 10/11 x64 · PowerShell 5.1+ · no third-party modules required
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

Add-Type -Language CSharp -ReferencedAssemblies @('System.Windows.Forms.dll','System.Drawing.dll','System.IO.Compression.dll','System.IO.Compression.FileSystem.dll') -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Security;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using System.Runtime.InteropServices;

namespace WeChatDocx {
    public class MainForm : Form {
        const int WH_KEYBOARD_LL = 13, WM_KEYDOWN = 0x0100, VK_V = 0x56, VK_CONTROL = 0x11;
        const uint KEYEVENTF_KEYUP = 0x0002;
        IntPtr hook = IntPtr.Zero;
        HookProc hookProc;
        bool processing = false;
        NumericUpDown limit = new NumericUpDown();
        CheckBox enabled = new CheckBox();
        Label state = new Label();
        System.Windows.Forms.Timer pasteTimer = new System.Windows.Forms.Timer();

        [DllImport("user32.dll")] static extern IntPtr SetWindowsHookEx(int idHook, HookProc lpfn, IntPtr hMod, uint threadId);
        [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr hhk);
        [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);
        [DllImport("user32.dll")] static extern short GetAsyncKeyState(int vKey);
        [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
        [DllImport("user32.dll")] static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
        delegate IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam);

        public MainForm() {
            Text = "WeChat Long Text to DOCX"; ClientSize = new Size(600, 342); FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false; BackColor = Color.FromArgb(246,248,250); Font = new Font("Microsoft YaHei UI", 9F);
            var accent = Color.FromArgb(20, 89, 184);
            var title = new Label { Text="Long text, still a chat message.", Font=new Font("Microsoft YaHei UI",18F,FontStyle.Bold), ForeColor=Color.FromArgb(21,31,48), Location=new Point(28,25), AutoSize=true };
            var intro = new Label { Text="When WeChat is active, Ctrl+V converts text above your limit to a local DOCX and pastes that file into the chat.", ForeColor=Color.FromArgb(84,96,113), Location=new Point(30,64), Size=new Size(540,42) };
            var line = new Panel { BackColor=Color.FromArgb(218,225,233), Location=new Point(28,116), Size=new Size(544,1) };
            var label = new Label { Text="Conversion threshold", Font=new Font("Microsoft YaHei UI",10F,FontStyle.Bold), Location=new Point(30,139), AutoSize=true };
            limit.Minimum=1; limit.Maximum=1000000; limit.Value=10000; limit.ThousandsSeparator=true; limit.Location=new Point(30,169); limit.Size=new Size(132,28); limit.Font=new Font("Segoe UI",11F);
            var chars = new Label { Text="characters (adjust as needed)", ForeColor=Color.FromArgb(84,96,113), Location=new Point(174,175), AutoSize=true };
            enabled.Text="Enable automatic conversion in WeChat"; enabled.Font=new Font("Microsoft YaHei UI",10F,FontStyle.Bold); enabled.ForeColor=accent; enabled.Location=new Point(28,221); enabled.AutoSize=true; enabled.CheckedChanged += Toggle;
            state.Text="Off. DOCX files are saved to Documents\\WeChat Long Messages."; state.ForeColor=Color.FromArgb(84,96,113); state.Location=new Point(30,255); state.Size=new Size(540,42);
            var note = new Label { Text="This only replaces pasted content. It never clicks WeChat's Send button.", ForeColor=Color.FromArgb(120,130,143), Location=new Point(30,305), AutoSize=true };
            Controls.AddRange(new Control[]{title,intro,line,label,limit,chars,enabled,state,note});
            hookProc = KeyboardHook;
            pasteTimer.Interval = 120; pasteTimer.Tick += PasteFile;
            FormClosed += delegate { StopHook(); };
        }
        void Toggle(object sender, EventArgs e) {
            if (enabled.Checked) { StartHook(); state.Text="On: Ctrl+V in WeChat converts text longer than " + limit.Value + " characters."; }
            else { StopHook(); state.Text="Off."; }
        }
        void StartHook() {
            if (hook != IntPtr.Zero) return;
            using (Process p = Process.GetCurrentProcess()) using (ProcessModule m = p.MainModule) hook = SetWindowsHookEx(WH_KEYBOARD_LL, hookProc, GetModuleHandle(m.ModuleName), 0);
            if (hook == IntPtr.Zero) { enabled.Checked=false; state.Text="Keyboard monitoring could not start. Reopen the tool normally."; }
        }
        void StopHook() { if (hook != IntPtr.Zero) { UnhookWindowsHookEx(hook); hook=IntPtr.Zero; } }
        [DllImport("kernel32.dll", CharSet=CharSet.Auto)] static extern IntPtr GetModuleHandle(string name);
        IntPtr KeyboardHook(int code, IntPtr wParam, IntPtr lParam) {
            if (code >= 0 && wParam.ToInt32() == WM_KEYDOWN && !processing && Marshal.ReadInt32(lParam) == VK_V && (GetAsyncKeyState(VK_CONTROL) & 0x8000) != 0 && IsWeChatForeground()) {
                string text = Clipboard.ContainsText() ? Clipboard.GetText(TextDataFormat.UnicodeText) : "";
                if (text.Length >= (int)limit.Value) {
                    try {
                        processing=true; state.Text="Detected " + text.Length + " characters. Creating DOCX...";
                        string docx = CreateDocx(text);
                        var files = new System.Collections.Specialized.StringCollection(); files.Add(docx); Clipboard.SetFileDropList(files);
                        pasteTimer.Tag=docx; pasteTimer.Start();
                        return (IntPtr)1;
                    } catch (Exception ex) { processing=false; state.Text="Conversion failed: " + ex.Message; }
                }
            }
            return CallNextHookEx(hook, code, wParam, lParam);
        }
        void PasteFile(object sender, EventArgs e) {
            pasteTimer.Stop();
            keybd_event(VK_CONTROL,0,0,UIntPtr.Zero); keybd_event(VK_V,0,0,UIntPtr.Zero); keybd_event(VK_V,0,KEYEVENTF_KEYUP,UIntPtr.Zero); keybd_event(VK_CONTROL,0,KEYEVENTF_KEYUP,UIntPtr.Zero);
            state.Text="DOCX pasted into the WeChat chat: " + Path.GetFileName((string)pasteTimer.Tag);
            var reset = new System.Windows.Forms.Timer(); reset.Interval=650; reset.Tick += delegate { reset.Stop(); reset.Dispose(); processing=false; }; reset.Start();
        }
        bool IsWeChatForeground() {
            uint id; GetWindowThreadProcessId(GetForegroundWindow(), out id);
            try { string n=Process.GetProcessById((int)id).ProcessName.ToLowerInvariant(); return n.Contains("wechat") || n.Contains("weixin"); } catch { return false; }
        }
        string CreateDocx(string text) {
            string folder=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments),"WeChat Long Messages"); Directory.CreateDirectory(folder);
            string path=Path.Combine(folder,"WeChat-Long-Message-"+DateTime.Now.ToString("yyyyMMdd-HHmmss")+".docx");
            using (ZipArchive zip=ZipFile.Open(path,ZipArchiveMode.Create)) {
                Put(zip,"[Content_Types].xml","<?xml version=\"1.0\" encoding=\"UTF-8\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/></Types>");
                Put(zip,"_rels/.rels","<?xml version=\"1.0\" encoding=\"UTF-8\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/></Relationships>");
                var body=new StringBuilder(); foreach(string line in text.Replace("\r\n","\n").Split('\n')) body.Append(line.Length==0?"<w:p/>":"<w:p><w:r><w:t xml:space=\"preserve\">"+SecurityElement.Escape(line)+"</w:t></w:r></w:p>");
                Put(zip,"word/document.xml","<?xml version=\"1.0\" encoding=\"UTF-8\"?><w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body>"+body+"<w:sectPr><w:pgSz w:w=\"11906\" w:h=\"16838\"/><w:pgMar w:top=\"1440\" w:right=\"1440\" w:bottom=\"1440\" w:left=\"1440\"/></w:sectPr></w:body></w:document>");
            } return path;
        }
        static void Put(ZipArchive zip,string name,string value) { using (var w=new StreamWriter(zip.CreateEntry(name).Open(),new UTF8Encoding(false))) w.Write(value); }
    }
    public static class App { [STAThread] public static void Run() { Application.EnableVisualStyles(); Application.SetCompatibleTextRenderingDefault(false); Application.Run(new MainForm()); } }
}
'@
[WeChatDocx.App]::Run()
