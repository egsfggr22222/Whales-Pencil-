# Find a file by name through Everything's window-message IPC.
#
# Everything indexes every NTFS filename and answers WM_COPYDATA queries. This
# asks it for one name and prints the full paths it knows, which is how the
# plugin finds its own folder after that folder is renamed or moved: the marker
# file's name is the identity, and its current path is whatever Everything says.
#
# Protocol facts, each taken from voidtools' SDK or the maintained Rust port that
# documents where the SDK is wrong:
#
#   request   EVERYTHING_IPC_QUERY2 = 7 DWORDs (28 bytes) + UTF-16 search + NUL
#   dwData    EVERYTHING_IPC_COPYDATA_QUERY2W (18)
#   reply id  reply_copydata_message is an arbitrary caller-chosen id and comes
#             back as the reply's dwData. The SDK comment calling it a fixed
#             reply constant is wrong; matching on one never recognises a reply.
#   reply     arrives by PostMessage, so the caller must pump messages
#   list      EVERYTHING_IPC_LIST2 = 5 DWORDs (20 bytes)
#   item      EVERYTHING_IPC_ITEM2 = flags(4) + data_offset(4), offset absolute
#   string    u32 character count + UTF-16 + NUL
#
# Needs nothing but Everything running in the background: no administrator, no
# SDK, no es.exe. This file must stay ASCII-only.

param(
  [Parameter(Mandatory = $true)][string]$Find,
  [int]$MaxResults = 64,
  [int]$TimeoutMs = 5000
)

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class EverythingIpc
{
    const int WM_COPYDATA = 0x004A;
    const uint PM_REMOVE = 0x0001;
    const string IPC_WNDCLASS = "EVERYTHING_TASKBAR_NOTIFICATION";
    const int COPYDATA_QUERY2W = 18;

    const uint REQUEST_FILE_NAME = 0x00000001;
    const uint REQUEST_PATH = 0x00000002;
    const uint REQUEST_FULL_PATH = 0x00000004;
    const uint SORT_NAME_ASCENDING = 1;

    // Any non-zero value round-trips; it only has to identify our own reply.
    const uint REPLY_ID = 0x57500001;

    [StructLayout(LayoutKind.Sequential)]
    struct COPYDATASTRUCT
    {
        public IntPtr dwData;
        public uint cbData;
        public IntPtr lpData;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct MSG
    {
        public IntPtr hwnd;
        public uint message;
        public IntPtr wParam;
        public IntPtr lParam;
        public uint time;
        public int pt_x;
        public int pt_y;
    }

    delegate IntPtr WndProc(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct WNDCLASSW
    {
        public uint style;
        public IntPtr lpfnWndProc;
        public int cbClsExtra;
        public int cbWndExtra;
        public IntPtr hInstance;
        public IntPtr hIcon;
        public IntPtr hCursor;
        public IntPtr hbrBackground;
        [MarshalAs(UnmanagedType.LPWStr)] public string lpszMenuName;
        [MarshalAs(UnmanagedType.LPWStr)] public string lpszClassName;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr FindWindowW(string lpClassName, string lpWindowName);

    [DllImport("user32.dll", SetLastError = true)]
    static extern IntPtr SendMessageW(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    static extern IntPtr DefWindowProcW(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    static extern bool PeekMessageW(out MSG msg, IntPtr hWnd, uint min, uint max, uint remove);

    [DllImport("user32.dll")]
    static extern bool TranslateMessage(ref MSG msg);

    [DllImport("user32.dll")]
    static extern IntPtr DispatchMessageW(ref MSG msg);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr GetModuleHandleW(string name);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern ushort RegisterClassW(ref WNDCLASSW lpWndClass);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateWindowExW(uint exStyle, string className, string windowName, uint style,
        int x, int y, int width, int height, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr param);

    [DllImport("user32.dll", SetLastError = true)]
    static extern bool DestroyWindow(IntPtr hWnd);

    static readonly object Gate = new object();

    /// <summary>Full paths Everything reports for the given name.</summary>
    public static string[] Search(string term, int maxResults, int timeoutMs, out string error)
    {
        error = null;
        lock (Gate)
        {
            IntPtr ipc = FindWindowW(IPC_WNDCLASS, null);
            if (ipc == IntPtr.Zero) { error = "everything-not-running"; return new string[0]; }

            var replies = new List<byte[]>();
            WndProc proc = (msgHwnd, msg, wParam, lParam) =>
            {
                if (msg == WM_COPYDATA)
                {
                    var cds = (COPYDATASTRUCT)Marshal.PtrToStructure(lParam, typeof(COPYDATASTRUCT));
                    if ((uint)cds.dwData == REPLY_ID && cds.cbData > 0)
                    {
                        var buffer = new byte[cds.cbData];
                        Marshal.Copy(cds.lpData, buffer, 0, (int)cds.cbData);
                        replies.Add(buffer);
                        return (IntPtr)1;
                    }
                }
                return DefWindowProcW(msgHwnd, msg, wParam, lParam);
            };

            string className = "WpEverythingIpcReply";
            IntPtr hinst = GetModuleHandleW(null);
            var wc = new WNDCLASSW();
            wc.lpfnWndProc = Marshal.GetFunctionPointerForDelegate(proc);
            wc.hInstance = hinst;
            wc.lpszClassName = className;

            // A second registration of this class in one process fails with
            // 1410; the existing class is fine to reuse.
            if (RegisterClassW(ref wc) == 0 && Marshal.GetLastWin32Error() != 1410)
            {
                error = "register-class-" + Marshal.GetLastWin32Error();
                return new string[0];
            }

            IntPtr hwnd = CreateWindowExW(0, className, null, 0, 0, 0, 0, 0,
                IntPtr.Zero, IntPtr.Zero, hinst, IntPtr.Zero);
            if (hwnd == IntPtr.Zero)
            {
                error = "create-window-" + Marshal.GetLastWin32Error();
                return new string[0];
            }

            IntPtr payload = IntPtr.Zero;
            IntPtr cdsPtr = IntPtr.Zero;
            try
            {
                byte[] encoded = Encoding.Unicode.GetBytes(term);
                int size = 28 + encoded.Length + 2;
                payload = Marshal.AllocHGlobal(size);
                cdsPtr = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(COPYDATASTRUCT)));

                int at = 0;
                uint[] header = new uint[]
                {
                    (uint)hwnd.ToInt32(),
                    REPLY_ID,
                    0,                       // search_flags
                    0,                       // offset
                    (uint)maxResults,
                    REQUEST_FULL_PATH,
                    SORT_NAME_ASCENDING,
                };
                foreach (uint value in header)
                {
                    Marshal.WriteInt32(payload, at, unchecked((int)value));
                    at += 4;
                }
                Marshal.Copy(encoded, 0, payload + at, encoded.Length);
                Marshal.WriteInt16(payload, at + encoded.Length, 0);

                var cds = new COPYDATASTRUCT();
                cds.dwData = (IntPtr)COPYDATA_QUERY2W;
                cds.cbData = (uint)size;
                cds.lpData = payload;
                Marshal.StructureToPtr(cds, cdsPtr, false);

                SendMessageW(ipc, WM_COPYDATA, hwnd, cdsPtr);

                // Everything posts the reply, so pump until it lands.
                int waited = 0;
                MSG msg;
                while (replies.Count == 0 && waited < timeoutMs)
                {
                    if (PeekMessageW(out msg, IntPtr.Zero, 0, 0, PM_REMOVE))
                    {
                        TranslateMessage(ref msg);
                        DispatchMessageW(ref msg);
                    }
                    else
                    {
                        Thread.Sleep(2);
                        waited += 2;
                    }
                }
            }
            finally
            {
                if (payload != IntPtr.Zero) Marshal.FreeHGlobal(payload);
                if (cdsPtr != IntPtr.Zero) Marshal.FreeHGlobal(cdsPtr);
                DestroyWindow(hwnd);
                GC.KeepAlive(proc);
            }

            if (replies.Count == 0)
            {
                error = "no-reply";
                return new string[0];
            }
            return ParseList(replies[0]);
        }
    }

    static string[] ParseList(byte[] raw)
    {
        var paths = new List<string>();
        if (raw.Length < 20) return paths.ToArray();

        uint numitems = BitConverter.ToUInt32(raw, 4);
        uint requestFlags = BitConverter.ToUInt32(raw, 12);

        int count = (int)Math.Min(numitems, 256u);
        for (int index = 0; index < count; index++)
        {
            int baseAt = 20 + index * 8;
            if (baseAt + 8 > raw.Length) break;
            int cursor = BitConverter.ToInt32(raw, baseAt + 4);

            uint[] order = new uint[] { REQUEST_FILE_NAME, REQUEST_PATH, REQUEST_FULL_PATH };
            foreach (uint flag in order)
            {
                if (cursor + 4 > raw.Length) break;
                if ((requestFlags & flag) == 0) continue;

                int length = BitConverter.ToInt32(raw, cursor);
                int start = cursor + 4;
                int end = start + length * 2;
                if (end > raw.Length) break;

                if (flag == REQUEST_FULL_PATH)
                    paths.Add(Encoding.Unicode.GetString(raw, start, length * 2));

                cursor = end + 2;
            }
        }
        return paths.ToArray();
    }
}
'@

$scanError = $null
$paths = [EverythingIpc]::Search($Find, $MaxResults, $TimeoutMs, [ref]$scanError)

if ($scanError -ne $null) {
  Write-Output (([ordered]@{ ok = $false; reason = $scanError }) | ConvertTo-Json -Compress)
  exit 1
}

Write-Output (([ordered]@{ ok = $true; paths = @($paths) }) | ConvertTo-Json -Compress -Depth 4)
exit 0
