<#
  beast-touchpad.ps1
  Lets the Home Assistant Games page work as a touchpad and keyboard for this PC.
  Listens on the home network only (WebSocket), needs the shared key below, and moves the
  mouse / types with Windows SendInput. Started automatically by steam-games-to-ha.ps1;
  only one copy runs at a time.
#>
param([int]$Port = 9876)

$Key = 'TOUCHPAD_KEY_HERE'   # must match touchpad_key in the Games card config

$created = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\BeastTouchpad', [ref]$created)
if (-not $created) { exit }

Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

public static class BeastPad {
    [StructLayout(LayoutKind.Sequential)]
    struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)]
    struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Explicit)]
    struct INPUTUNION { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
    [StructLayout(LayoutKind.Sequential)]
    struct INPUT { public uint type; public INPUTUNION u; }

    [DllImport("user32.dll", SetLastError = true)]
    static extern uint SendInput(uint n, INPUT[] inputs, int size);

    const uint MOVE = 0x0001, LDOWN = 0x0002, LUP = 0x0004, RDOWN = 0x0008, RUP = 0x0010, MDOWN = 0x0020, MUP = 0x0040, WHEEL = 0x0800, HWHEEL = 0x1000;
    const uint KEYUP = 0x0002, UNICODE = 0x0004;

    static string key;
    static readonly object sendLock = new object();

    static void Send(INPUT[] inputs) {
        lock (sendLock) { SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT))); }
    }
    static INPUT Mouse(uint flags, int dx, int dy, int data) {
        INPUT i = new INPUT(); i.type = 0;
        i.u.mi.dx = dx; i.u.mi.dy = dy; i.u.mi.mouseData = unchecked((uint)data); i.u.mi.dwFlags = flags;
        return i;
    }
    static INPUT Key(ushort vk, ushort scan, uint flags) {
        INPUT i = new INPUT(); i.type = 1;
        i.u.ki.wVk = vk; i.u.ki.wScan = scan; i.u.ki.dwFlags = flags;
        return i;
    }

    static void Button(string which, bool down, bool up) {
        uint d = LDOWN, u = LUP;
        if (which == "r") { d = RDOWN; u = RUP; } else if (which == "m") { d = MDOWN; u = MUP; }
        if (down) Send(new INPUT[] { Mouse(d, 0, 0, 0) });
        if (up) Send(new INPUT[] { Mouse(u, 0, 0, 0) });
    }

    static void Text(string s) {
        foreach (char ch in s) {
            Send(new INPUT[] { Key(0, ch, UNICODE), Key(0, ch, UNICODE | KEYUP) });
        }
    }

    static ushort Vk(string name) {
        switch (name) {
            case "enter": return 0x0D; case "esc": return 0x1B; case "back": return 0x08; case "tab": return 0x09;
            case "space": return 0x20; case "left": return 0x25; case "up": return 0x26; case "right": return 0x27; case "down": return 0x28;
            case "del": return 0x2E; case "home": return 0x24; case "end": return 0x23; case "pgup": return 0x21; case "pgdn": return 0x22;
            case "win": return 0x5B; case "ctrl": return 0x11; case "shift": return 0x10; case "alt": return 0x12;
            case "volup": return 0xAF; case "voldown": return 0xAE; case "mute": return 0xAD; case "play": return 0xB3;
        }
        if (name.Length >= 2 && name[0] == 'f') { int n; if (int.TryParse(name.Substring(1), out n) && n >= 1 && n <= 12) return (ushort)(0x70 + n - 1); }
        if (name.Length == 1) { char c = char.ToUpperInvariant(name[0]); if ((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) return (ushort)c; }
        return 0;
    }

    // "enter", "alt+tab", "ctrl+shift+esc" ...
    static void Combo(string combo) {
        string[] parts = combo.ToLowerInvariant().Split('+');
        ushort[] vks = new ushort[parts.Length];
        for (int i = 0; i < parts.Length; i++) { vks[i] = Vk(parts[i].Trim()); if (vks[i] == 0) return; }
        for (int i = 0; i < vks.Length; i++) Send(new INPUT[] { Key(vks[i], 0, 0) });
        for (int i = vks.Length - 1; i >= 0; i--) Send(new INPUT[] { Key(vks[i], 0, KEYUP) });
    }

    static void Command(string line) {
        line = line.Trim('\r');
        if (line.Length == 0) return;
        string[] p = line.Split(new char[] { ' ' }, 2);
        string op = p[0], arg = p.Length > 1 ? p[1] : "";
        int a, b;
        switch (op) {
            case "m": {
                string[] xy = arg.Split(' ');
                if (xy.Length == 2 && int.TryParse(xy[0], out a) && int.TryParse(xy[1], out b))
                    Send(new INPUT[] { Mouse(MOVE, Math.Max(-500, Math.Min(500, a)), Math.Max(-500, Math.Min(500, b)), 0) });
                break;
            }
            case "c": Button(arg, true, true); break;
            case "dc": Button("l", true, true); Button("l", true, true); break;
            case "bd": Button(arg, true, false); break;
            case "bu": Button(arg, false, true); break;
            case "w": if (int.TryParse(arg, out a)) Send(new INPUT[] { Mouse(WHEEL, 0, 0, Math.Max(-1200, Math.Min(1200, a))) }); break;
            case "h": if (int.TryParse(arg, out a)) Send(new INPUT[] { Mouse(HWHEEL, 0, 0, Math.Max(-1200, Math.Min(1200, a))) }); break;
            case "t": if (arg.Length <= 500) Text(arg); break;
            case "k": Combo(arg); break;
        }
    }

    static bool IsHomeNetwork(IPAddress ip) {
        if (ip.IsIPv4MappedToIPv6) ip = ip.MapToIPv4();
        if (IPAddress.IsLoopback(ip)) return true;
        if (ip.AddressFamily != AddressFamily.InterNetwork) return false;
        byte[] b = ip.GetAddressBytes();
        return b[0] == 10 || (b[0] == 172 && b[1] >= 16 && b[1] <= 31) || (b[0] == 192 && b[1] == 168) || (b[0] == 100 && b[1] >= 64 && b[1] <= 127);
    }

    static string ReadHeaders(Stream s) {
        StringBuilder sb = new StringBuilder();
        int last4 = 0;
        while (sb.Length < 8192) {
            int c = s.ReadByte();
            if (c < 0) return null;
            sb.Append((char)c);
            last4 = (last4 << 8) | c;
            if (last4 == 0x0D0A0D0A) return sb.ToString();
        }
        return null;
    }

    static byte[] ReadExactly(Stream s, int n) {
        byte[] buf = new byte[n]; int got = 0;
        while (got < n) { int r = s.Read(buf, got, n - got); if (r <= 0) throw new IOException("closed"); got += r; }
        return buf;
    }

    static void SendFrame(Stream s, int opcode, byte[] payload) {
        byte[] head = payload.Length < 126 ? new byte[] { (byte)(0x80 | opcode), (byte)payload.Length }
                                           : new byte[] { (byte)(0x80 | opcode), 126, (byte)(payload.Length >> 8), (byte)payload.Length };
        lock (s) { s.Write(head, 0, head.Length); s.Write(payload, 0, payload.Length); }
    }

    static void Handle(object o) {
        TcpClient client = (TcpClient)o;
        try {
            client.NoDelay = true;
            IPEndPoint ep = (IPEndPoint)client.Client.RemoteEndPoint;
            if (!IsHomeNetwork(ep.Address)) return;
            NetworkStream s = client.GetStream();
            s.ReadTimeout = 10000;
            string req = ReadHeaders(s);
            if (req == null) return;
            Match wsKey = Regex.Match(req, @"^Sec-WebSocket-Key:\s*(\S+)", RegexOptions.Multiline | RegexOptions.IgnoreCase);
            Match reqKey = Regex.Match(req, @"^GET [^ ]*[?&]k=([A-Za-z0-9]+)(?:[& ])");
            if (!wsKey.Success || !reqKey.Success || reqKey.Groups[1].Value != key) {
                byte[] r = Encoding.ASCII.GetBytes("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
                s.Write(r, 0, r.Length);
                return;
            }
            string accept;
            using (SHA1 sha = SHA1.Create())
                accept = Convert.ToBase64String(sha.ComputeHash(Encoding.ASCII.GetBytes(wsKey.Groups[1].Value + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")));
            byte[] ok = Encoding.ASCII.GetBytes("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + accept + "\r\n\r\n");
            s.Write(ok, 0, ok.Length);
            s.ReadTimeout = 120000;   // the page pings every 20 s
            SendFrame(s, 1, Encoding.UTF8.GetBytes("hello " + Environment.MachineName));

            while (true) {
                byte[] h = ReadExactly(s, 2);
                int opcode = h[0] & 0x0F;
                bool masked = (h[1] & 0x80) != 0;
                long len = h[1] & 0x7F;
                if (len == 126) { byte[] e = ReadExactly(s, 2); len = (e[0] << 8) | e[1]; }
                else if (len == 127) { byte[] e = ReadExactly(s, 8); len = 0; for (int i = 0; i < 8; i++) len = (len << 8) | e[i]; }
                if (len > 65536) return;
                byte[] mask = masked ? ReadExactly(s, 4) : null;
                byte[] data = ReadExactly(s, (int)len);
                if (masked) for (int i = 0; i < data.Length; i++) data[i] ^= mask[i % 4];
                if (opcode == 8) { SendFrame(s, 8, new byte[0]); return; }
                if (opcode == 9) { SendFrame(s, 10, data); continue; }
                if (opcode != 1) continue;
                foreach (string line in Encoding.UTF8.GetString(data).Split('\n')) {
                    try { Command(line); } catch { }
                }
            }
        } catch { }
        finally { try { client.Close(); } catch { } }
    }

    public static void Run(int port, string sharedKey) {
        key = sharedKey;
        TcpListener listener = new TcpListener(IPAddress.Any, port);
        listener.Start();
        while (true) {
            TcpClient c = listener.AcceptTcpClient();
            Thread t = new Thread(Handle);
            t.IsBackground = true;
            t.Start(c);
        }
    }
}
'@

[BeastPad]::Run($Port, $Key)
