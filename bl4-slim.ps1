param([string]$GameDir, [string]$Keep, [switch]$Scan, [switch]$Yes)
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System; using System.Collections.Generic; using System.ComponentModel; using System.IO; using System.Linq; using System.Text;
using System.Runtime.InteropServices; using System.Security.Cryptography; using System.Text.RegularExpressions; using Microsoft.Win32.SafeHandles;
public class Bl4Slim {
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool DeviceIoControl(SafeFileHandle h, uint code, byte[] inBuf, int inSize, byte[] outBuf, int outSize, out int got, IntPtr ov);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern uint GetCompressedFileSizeW(string path, out uint high);
    const uint SetSparse = 0x900C4, SetZeroData = 0x980C8, QueryAllocatedRanges = 0x940CF;
    static readonly string[] Wwise = { "Chinese(Simplified)", "English(US)", "French(France)", "German", "Italian", "Japanese", "Korean", "Spanish(Spain)" };
    static readonly Regex ChunkFile = new Regex(@"^pakchunk(\d+)-Windows_(\d+)_P\.(pak|ucas|utoc)$");
    class Toc { public string[] Ids; public bool[] Header; public long[] SpanOff, SpanLen, BlockOff, BlockSize; public long BlockSz; }
    class Pak { public string Mount; public Dictionary<string, long> Entries = new Dictionary<string, long>(); public long DataEnd; }
    public string Paks; public long Unit, Saves; public List<string> Foreign = new List<string>();
    public SortedDictionary<int, string> Voices = new SortedDictionary<int, string>();
    public SortedDictionary<string, long> Drop = new SortedDictionary<string, long>(); public long ForeignBytes { get { return Drop.Values.Sum(); } }
    public Dictionary<string, List<long[]>> Old = new Dictionary<string, List<long[]>>(StringComparer.OrdinalIgnoreCase), Todo = new Dictionary<string, List<long[]>>(StringComparer.OrdinalIgnoreCase);
    Dictionary<string, int> patch = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase); Dictionary<int, List<string>> chunks;
    public Bl4Slim(string paks) {
        var found = Directory.GetFiles(Paks = paks).Select(f => new { f, m = ChunkFile.Match(Path.GetFileName(f)) }).Where(x => x.m.Success).ToList();
        foreach (var x in found) patch[x.f] = int.Parse(x.m.Groups[2].Value);
        chunks = found.GroupBy(x => int.Parse(x.m.Groups[1].Value)).ToDictionary(g => g.Key, g => g.Select(x => x.f).ToList());
        foreach (var kv in chunks) { var lang = ChunkLanguage(kv.Value); if (lang != null) Voices[kv.Key] = lang; }
    }
    public void Prepare(string keep) {
        if (Voices.Count > 0 && !Voices.ContainsValue(keep)) throw new Exception("No " + keep + " voice pack is installed. Found: " + string.Join(", ", Voices.Values.Distinct()));
        foreach (var kv in Voices.Where(v => v.Value != keep))
            foreach (var f in chunks[kv.Key].OrderBy(f => f.EndsWith(".pak")).ThenBy(f => f)) {
                Foreign.Add(f); long n; Drop.TryGetValue(kv.Value, out n); Drop[kv.Value] = n + new FileInfo(f).Length;
            }
        var skip = new HashSet<string>(Foreign, StringComparer.OrdinalIgnoreCase); PlanIoStore(skip); PlanPak(skip);
        if ((Unit = ProbeUnit(Paks)) == 0) return;
        foreach (var kv in Old) {
            var held = Allocated(kv.Key); var hs = held.Select(h => h[0]).ToArray();
            var gain = kv.Value.Select(r => Overlap(held, hs, (r[0] + Unit - 1) / Unit * Unit, r[1] / Unit * Unit)).ToArray();
            Saves += gain.Sum(); if (gain.Any(g => g > 0)) Todo[kv.Key] = kv.Value.Where((r, i) => gain[i] > 0).ToList();
        }
    }
    public void Apply() {
        foreach (var f in Foreign) File.Delete(f);
        int i = 0; var buf = new byte[16 << 20];
        foreach (var kv in Todo) {
            Console.WriteLine("  [{0}/{1}] {2}", ++i, Todo.Count, Path.GetFileName(kv.Key));
            var o = Old[kv.Key]; long size = new FileInfo(kv.Key).Length;
            var kept = Enumerable.Range(0, o.Count + 1).Select(j => new[] { j > 0 ? o[j - 1][1] : 0, j < o.Count ? o[j][0] : size }).Where(r => r[0] < r[1]).ToList();
            var before = Hash(kv.Key, kept, buf);
            try { Zero(kv.Key, kv.Value); }
            finally { if (Hash(kv.Key, kept, buf) != before) throw Bad(kv.Key, "data the game reads changed. Run Verify integrity in Steam."); }
        }
    }
    public static long OnDisk(string dir) {
        long t = 0; uint hi, lo;
        foreach (var f in Directory.EnumerateFiles(dir, "*", SearchOption.AllDirectories)) {
            if ((lo = GetCompressedFileSizeW(f, out hi)) == 0xFFFFFFFF && Marshal.GetLastWin32Error() != 0) throw new Win32Exception(); t += ((long)hi << 32) | lo;
        }
        return t;
    }
    static string ChunkLanguage(List<string> files) {
        var langs = new HashSet<string>();
        foreach (var f in files)
            if (f.EndsWith(".pak")) {
                var pak = ReadPak(f);
                if (pak == null || pak.Entries.Count > 0 && !pak.Mount.TrimEnd('/').EndsWith("WwiseAudio")) return null;
                langs.UnionWith(pak.Entries.Keys.Select(k => k.Trim('/').Split('/')).Select(p => p.Skip(p[0] == "Media" ? 1 : 0).ToArray()).Select(p => p.Length > 1 ? p[0] : null));
            }
            else if (f.EndsWith(".utoc") && ReadToc(f).Header.Any(h => !h)) return null;
        return langs.Count == 1 && Wwise.Contains(langs.First()) ? langs.First() : null;
    }
    void PlanIoStore(HashSet<string> skip) {
        var tocs = new Dictionary<string, Toc>(); var newest = new Dictionary<string, int>();
        foreach (var f in patch.Keys.Where(f => f.EndsWith(".utoc") && !skip.Contains(f) && !skip.Contains(Path.ChangeExtension(f, ".ucas"))))
            foreach (var id in (tocs[f] = ReadToc(f)).Ids) Bump(newest, id, patch[f]);
        foreach (var kv in tocs) {
            var t = kv.Value; var used = new HashSet<long>(); var covered = new HashSet<long>();
            foreach (int i in Enumerable.Range(0, t.Ids.Length).Where(i => t.SpanLen[i] > 0)) {
                bool keep = t.Header[i] || newest[t.Ids[i]] <= patch[kv.Key];
                for (long b = t.SpanOff[i] / t.BlockSz; b <= (t.SpanOff[i] + t.SpanLen[i] - 1) / t.BlockSz; b++) { covered.Add(b); if (keep) used.Add(b); }
            }
            var starts = t.BlockOff.OrderBy(x => x).ToArray();
            Check(Path.ChangeExtension(kv.Key, ".ucas"), covered.Except(used).Select(b => UpToNext(starts, t.BlockOff[b], t.BlockOff[b] + t.BlockSize[b])),
                Merge(used.Select(b => new[] { t.BlockOff[b], t.BlockOff[b] + t.BlockSize[b] })));
        }
    }
    void PlanPak(HashSet<string> skip) {
        var paks = new Dictionary<string, Pak>(); var newest = new Dictionary<string, int>();
        foreach (var x in patch.Keys.Where(f => f.EndsWith(".pak") && !skip.Contains(f)).Select(f => new { f, p = ReadPak(f) }).Where(x => x.p != null))
            foreach (var e in (paks[x.f] = x.p).Entries.Keys) Bump(newest, x.p.Mount + e, patch[x.f]);
        foreach (var kv in paks) {
            var p = kv.Value; var used = new HashSet<long>(p.Entries.Where(e => newest[p.Mount + e.Key] <= patch[kv.Key]).Select(e => e.Value));
            var starts = p.Entries.Values.Distinct().OrderBy(x => x).ToArray();
            Check(kv.Key, starts.Where(s => !used.Contains(s)).Select(s => UpToNext(starts, s, p.DataEnd)), used.OrderBy(x => x).Select(s => new[] { s, s + 1 }));
        }
    }
    void Check(string f, IEnumerable<long[]> raw, IEnumerable<long[]> used) {
        var old = Merge(raw); if (old.Count == 0) return;
        var os = old.Select(r => r[0]).ToArray();
        foreach (var u in used) if (Overlap(old, os, u[0], u[1]) > 0) throw Bad(f, "an old range covers data the game reads at " + u[0]);
        if (old.Last()[1] > new FileInfo(f).Length) throw Bad(f, "an old range runs past the end of the file");
        Old[f] = old;
    }
    static void Bump(Dictionary<string, int> newest, string key, int patch) { int v; newest.TryGetValue(key, out v); newest[key] = Math.Max(v, patch); }
    static List<long[]> Merge(IEnumerable<long[]> ranges) {
        var o = new List<long[]>();
        foreach (var r in ranges.OrderBy(r => r[0]).ThenBy(r => r[1]))
            if (o.Count > 0 && r[0] <= o.Last()[1]) o.Last()[1] = Math.Max(o.Last()[1], r[1]); else o.Add(new[] { r[0], r[1] });
        return o;
    }
    static int Upper(long[] a, long v) { return ~Array.BinarySearch(a, v, Comparer<long>.Create((x, y) => x <= y ? -1 : 1)); }
    static long[] UpToNext(long[] starts, long lo, long end) { int k = Upper(starts, lo); return new[] { lo, k < starts.Length ? starts[k] : end }; }
    static long Overlap(List<long[]> held, long[] starts, long lo, long hi) {
        long t = 0;
        for (int j = Math.Max(0, Upper(starts, lo) - 1); j < held.Count && held[j][0] < hi; j++) t += Math.Max(0, Math.Min(hi, held[j][1]) - Math.Max(lo, held[j][0]));
        return t;
    }
    static Toc ReadToc(string path) {
        var d = File.ReadAllBytes(path);
        if (d.Length < 104 || Encoding.ASCII.GetString(d, 0, 16) != "-==--==--==--==-" || d[16] != 8 || U32(d, 32) != 12) throw Bad(path, "not a version 8 IoStore TOC");
        if ((d[80] & 6) != 0 || U32(d, 52) != 1) throw Bad(path, "encrypted, signed or split containers are not supported");
        long n = U32(d, 24), nb = U32(d, 28), p = U32(d, 20), s = p + n * 12, b = s + n * 10 + U32(d, 84) * 4L + U32(d, 96) * 4L;
        var t = new Toc { BlockSz = U32(d, 44), Ids = new string[n], Header = new bool[n], SpanOff = new long[n], SpanLen = new long[n], BlockOff = new long[nb], BlockSize = new long[nb] };
        for (int i = 0; i < n; i++) { t.Ids[i] = Convert.ToBase64String(d, (int)(p + i * 12), 12); t.Header[i] = d[p + i * 12 + 11] == 6; }
        for (int i = 0; i < n; i++) { t.SpanOff[i] = Num(d, s + i * 10, 5, true); t.SpanLen[i] = Num(d, s + i * 10 + 5, 5, true); }
        for (int i = 0; i < nb; i++) { t.BlockOff[i] = Num(d, b + i * 12, 5, false); t.BlockSize[i] = Num(d, b + i * 12 + 5, 3, false); }
        if (d.Length - (b + nb * 12 + U32(d, 36) * (long)U32(d, 40) + U32(d, 48)) != n * 24) throw Bad(path, "TOC sections do not add up to the file size");
        return t;
    }
    static Pak ReadPak(string path) {
        using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read)) {
            long size = fs.Length; if (size < 221) throw Bad(path, "too small to be a pak");
            var ft = ReadAt(fs, size - 221, 221);
            if (U32(ft, 17) != 0x5A6F12E1) throw Bad(path, "no pak footer");
            if (BitConverter.ToInt32(ft, 21) != 11) throw Bad(path, "pak version " + BitConverter.ToInt32(ft, 21) + ", expected 11");
            if (ft[16] != 0) return null;
            long io = I64(ft, 25); var idx = ReadAt(fs, io, (int)I64(ft, 33));
            int p = 0; var pak = new Pak { Mount = FString(idx, ref p), DataEnd = Math.Min(io, size - 221) };
            if (U32(idx, p + 12) != 0) { pak.DataEnd = Math.Min(pak.DataEnd, I64(idx, p + 16)); p += 36; }
            if (U32(idx, p + 16) == 0) return null;
            long dirOff = I64(idx, p + 20), dirSize = I64(idx, p + 28); pak.DataEnd = Math.Min(pak.DataEnd, dirOff);
            int enc = p + 60, q = enc + BitConverter.ToInt32(idx, p + 56) + 4; var plain = new List<long>();
            for (uint i = 0, n = U32(idx, q - 4); i < n; i++) { plain.Add(I64(idx, q)); q += U32(idx, q + 24) != 0 ? 57 + 16 * (int)U32(idx, q + 48) : 53; }
            if (q != idx.Length) throw Bad(path, "index layout does not add up to its size");
            var dirs = ReadAt(fs, dirOff, (int)dirSize); int r = 0;
            for (int i = 0, folders = Next(dirs, ref r); i < folders; i++) {
                var folder = FString(dirs, ref r);
                for (int j = 0, files = Next(dirs, ref r); j < files; j++) {
                    var name = folder + FString(dirs, ref r); int loc = Next(dirs, ref r);
                    if (loc == int.MinValue) continue;
                    uint fl = loc < 0 ? 0 : U32(idx, enc + loc); int at = enc + loc + ((fl & 0x3F) == 0x3F ? 8 : 4);
                    pak.Entries[name] = loc < 0 ? plain[-loc - 1] : fl >> 31 != 0 ? U32(idx, at) : I64(idx, at);
                }
            }
            return pak;
        }
    }
    static Exception Bad(string path, string msg) { return new Exception(Path.GetFileName(path) + ": " + msg); }
    static uint U32(byte[] d, long o) { return BitConverter.ToUInt32(d, (int)o); }
    static long I64(byte[] d, long o) { return BitConverter.ToInt64(d, (int)o); }
    static int Next(byte[] b, ref int p) { p += 4; return BitConverter.ToInt32(b, p - 4); }
    static long Num(byte[] d, long o, int n, bool bigEndian) { long v = 0; for (int i = 0; i < n; i++) v = (v << 8) | d[o + (bigEndian ? i : n - 1 - i)]; return v; }
    static byte[] Pair(params long[] v) { return v.SelectMany(x => BitConverter.GetBytes(x)).ToArray(); }
    static string FString(byte[] b, ref int p) {
        int n = Next(b, ref p), len = n < 0 ? -n * 2 : n; p += len;
        return (n < 0 ? Encoding.Unicode : Encoding.GetEncoding(28591)).GetString(b, p - len, len).TrimEnd('\0');
    }
    static byte[] ReadAt(FileStream fs, long off, int n) {
        var b = new byte[n]; fs.Position = off;
        for (int got = 0, k; got < n; got += k) if ((k = fs.Read(b, got, n - got)) == 0) throw Bad(fs.Name, "file ends early");
        return b;
    }
    static void Ioctl(FileStream fs, uint code, byte[] a) {
        int ret; if (!DeviceIoControl(fs.SafeFileHandle, code, a, a == null ? 0 : a.Length, null, 0, out ret, IntPtr.Zero)) throw new Win32Exception();
    }
    static void Zero(string path, IEnumerable<long[]> ranges) {
        using (var fs = new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.Read)) {
            Ioctl(fs, SetSparse, null); foreach (var r in ranges) Ioctl(fs, SetZeroData, Pair(r));
        }
    }
    static List<long[]> Allocated(string path) {
        var o = new List<long[]>(); var buf = new byte[16 * 4096];
        using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
            for (long start = 0, size = fs.Length; start < size; start = o.Last()[1]) {
                int ret; bool ok = DeviceIoControl(fs.SafeFileHandle, QueryAllocatedRanges, Pair(start, size - start), 16, buf, buf.Length, out ret, IntPtr.Zero);
                if (!ok && Marshal.GetLastWin32Error() != 234) throw new Win32Exception();
                for (int i = 0; i + 16 <= ret; i += 16) o.Add(new[] { I64(buf, i), I64(buf, i) + I64(buf, i + 8) });
                if (ok || ret == 0) break;
            }
        return o;
    }
    static long ProbeUnit(string dir) {
        var f = Path.Combine(dir, "bl4-slim-probe.tmp"); const int n = 8 << 20;
        try {
            File.WriteAllBytes(f, Enumerable.Repeat((byte)1, n).ToArray()); Zero(f, new[] { new long[] { 1, n - 1 } });
            var a = Allocated(f); return a.Count == 2 && a[0][0] == 0 && a[1][1] == n && a[0][1] == n - a[1][0] ? a[0][1] : 0;
        }
        catch (Exception e) { if (e is Win32Exception || e is IOException) return 0; throw; }
        finally { File.Delete(f); }
    }
    static string Hash(string path, List<long[]> ranges, byte[] buf) {
        using (var sha = SHA1.Create()) using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 20)) {
            foreach (var r in ranges)
                for (fs.Position = r[0]; fs.Position < r[1]; ) {
                    int k = fs.Read(buf, 0, (int)Math.Min(r[1] - fs.Position, buf.Length)); if (k == 0) throw Bad(path, "file ends before byte " + r[1]);
                    sha.TransformBlock(buf, 0, k, null, 0);
                }
            sha.TransformFinalBlock(buf, 0, 0); return Convert.ToBase64String(sha.Hash);
        }
    }
}
'@
function Size($n) { if ($n -ge 1GB -or $n -eq 0) { '{0,8:N2} GB' -f ($n / 1GB) } else { '{0,8:N2} MB' -f ($n / 1MB) } }
function Find-Game {
    if (-not ($steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath)) { return }
    $libs = @($steam); $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
    if (Test-Path -LiteralPath $vdf) { $libs += Select-String -LiteralPath $vdf -Pattern '"path"\s+"(.+?)"' | ForEach-Object { $_.Matches[0].Groups[1].Value -replace '\\\\', '\' } }
    foreach ($lib in $libs) {
        $acf = Join-Path $lib 'steamapps\appmanifest_1285190.acf'
        $m = if (Test-Path -LiteralPath $acf) { Select-String -LiteralPath $acf -Pattern '"installdir"\s+"(.+?)"' | Select-Object -First 1 }
        if ($m) { return Join-Path $lib ('steamapps\common\' + $m.Matches[0].Groups[1].Value) }
    }
}
try {
    if (-not $GameDir -and -not ($GameDir = Find-Game)) { $GameDir = Read-Host 'Paste your Borderlands 4 folder' }
    if (-not ($GameDir = $GameDir.Trim().Trim('"')) -or -not (Test-Path -LiteralPath (Join-Path $GameDir 'OakGame\Content\Paks'))) { Write-Host "No Borderlands 4 found at $GameDir"; exit 2 }
    $GameDir = (Resolve-Path -LiteralPath $GameDir).ProviderPath.TrimEnd('\'); Write-Host "Borderlands 4: $GameDir"
    if (-not $Scan) {
        if (Get-Process Borderlands4 -ErrorAction SilentlyContinue) { Write-Host 'Borderlands 4 is running. Close it first.'; exit 1 }
        $acf = Join-Path (Split-Path (Split-Path $GameDir)) 'appmanifest_1285190.acf'
        if ((Test-Path -LiteralPath $acf) -and (Get-Content -LiteralPath $acf -Raw) -notmatch '"StateFlags"\s+"4"') { Write-Host 'Steam is updating or checking the game. Let it finish first.'; exit 1 }
    }
    $s = New-Object Bl4Slim (Join-Path $GameDir 'OakGame\Content\Paks'); $langs = @($s.Voices.Values | Sort-Object -Unique)
    if (-not $Keep -and $langs.Count -gt 1) {
        Write-Host 'Voice languages installed:'; 1..$langs.Count | ForEach-Object { Write-Host ('  {0}. {1}' -f $_, $langs[$_ - 1]) }
        $a = (Read-Host 'Number of the one to keep (Enter = English(US))').Trim()
        $Keep = if ($a -match '^\d+$' -and [int]$a -ge 1 -and [int]$a -le $langs.Count) { $langs[[int]$a - 1] } elseif ($a) { $a } else { 'English(US)' }
    }
    if (-not $Keep) { $Keep = if ($langs.Count -eq 1) { $langs[0] } else { 'English(US)' } }
    $Keep = @($langs | Where-Object { $_ -eq $Keep }) + $Keep | Select-Object -First 1
    Write-Host 'Reading the game files...'; $s.Prepare($Keep); $before = [Bl4Slim]::OnDisk($GameDir)
    '', ('Game on disk now:        {0}' -f (Size $before)) | Write-Host
    foreach ($d in $s.Drop.GetEnumerator()) { Write-Host ('  {0,-21} {1}' -f $d.Key, (Size $d.Value)) }
    Write-Host ('Voice languages to drop: {0}   (keeping {1})' -f (Size $s.ForeignBytes), $Keep)
    Write-Host ('Old patch copies:        {0}   in {1} files' -f (Size $s.Saves), $s.Todo.Count)
    if ($s.Unit -eq 0) { Write-Host 'Old patch copies stay: this drive cannot free part of a file. That needs NTFS and a few MB free.' }
    if ($s.Foreign.Count -eq 0 -and $s.Todo.Count -eq 0) { Write-Host 'Nothing to do.'; exit 0 }; if ($Scan) { exit 0 }
    if (-not $Yes -and (Read-Host 'Go ahead? (y/n)') -notmatch '^\s*y') { Write-Host 'Nothing changed.'; exit 1 }
    $s.Apply(); $after = [Bl4Slim]::OnDisk($GameDir)
    '', ('Before:  {0}' -f (Size $before)), ('After:   {0}' -f (Size $after)), ('Saved:   {0}' -f (Size ($before - $after))) | Write-Host
    if ($s.Todo.Count) { Write-Host 'In File Explorer, "Size" still counts the freed space. "Size on disk" is the real number.' }
} catch {
    $e = $_.Exception.GetBaseException()
    if ($e -is [UnauthorizedAccessException]) { Write-Host 'Windows blocked access to a game file. Right-click bl4-slim.cmd and pick "Run as administrator".' }
    else { Write-Host "Stopped: $($e.Message)" }
    exit 1
}
