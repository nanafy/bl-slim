param([string]$GameDir, [string]$Keep, [switch]$Scan, [switch]$Yes)
$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using Microsoft.Win32.SafeHandles;

public class Bl4Slim
{
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool DeviceIoControl(SafeFileHandle h, uint code, byte[] inBuf, int inSize, byte[] outBuf, int outSize, out int returned, IntPtr overlapped);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern uint GetCompressedFileSizeW(string path, out uint high);

    const uint SetSparse = 0x900C4, SetZeroData = 0x980C8, QueryAllocatedRanges = 0x940CF;
    static readonly string[] Wwise = { "Chinese(Simplified)", "English(US)", "French(France)", "German", "Italian", "Japanese", "Korean", "Spanish(Spain)" };
    static readonly Regex ChunkFile = new Regex(@"^pakchunk(\d+)-Windows_(\d+)_P\.(pak|ucas|utoc)$");

    class Toc { public string[] Ids; public bool[] Header; public long[] SpanOff, SpanLen, BlockOff, BlockSize; public long BlockSz; }
    class Pak { public string Mount; public Dictionary<string, long> Entries = new Dictionary<string, long>(); public long DataEnd; }

    public string Paks;
    public long Unit, Saves;
    public long ForeignBytes { get { return Drop.Values.Sum(); } }
    public SortedDictionary<int, string> Voices = new SortedDictionary<int, string>();
    public SortedDictionary<string, long> Drop = new SortedDictionary<string, long>();
    public List<string> Foreign = new List<string>();
    public Dictionary<string, List<long[]>> Old = new Dictionary<string, List<long[]>>(StringComparer.OrdinalIgnoreCase);
    public Dictionary<string, List<long[]>> Todo = new Dictionary<string, List<long[]>>(StringComparer.OrdinalIgnoreCase);
    Dictionary<int, List<string>> chunks = new Dictionary<int, List<string>>();
    Dictionary<string, int> patch = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);

    public Bl4Slim(string paks)
    {
        Paks = paks;
        foreach (var f in Directory.GetFiles(paks))
        {
            var m = ChunkFile.Match(Path.GetFileName(f));
            if (!m.Success) continue;
            int c = int.Parse(m.Groups[1].Value);
            if (!chunks.ContainsKey(c)) chunks[c] = new List<string>();
            chunks[c].Add(f);
            patch[f] = int.Parse(m.Groups[2].Value);
        }
        foreach (var kv in chunks)
        {
            var lang = ChunkLanguage(kv.Value);
            if (lang != null) Voices[kv.Key] = lang;
        }
    }

    public void Prepare(string keep)
    {
        if (Voices.Count > 0 && !Voices.ContainsValue(keep))
            throw new Exception(string.Format("No {0} voice pack is installed. Found: {1}", keep, string.Join(", ", Voices.Values.Distinct())));
        foreach (var kv in Voices.Where(v => v.Value != keep))
            foreach (var f in chunks[kv.Key].OrderBy(f => f.EndsWith(".pak")).ThenBy(f => f))
            {
                Foreign.Add(f);
                Drop[kv.Value] = (Drop.ContainsKey(kv.Value) ? Drop[kv.Value] : 0) + new FileInfo(f).Length;
            }
        var skip = new HashSet<string>(Foreign, StringComparer.OrdinalIgnoreCase);
        PlanIoStore(skip);
        PlanPak(skip);
        Unit = ProbeUnit(Paks);
        if (Unit == 0) return;
        foreach (var kv in Old)
        {
            var held = Allocated(kv.Key);
            var hs = held.Select(h => h[0]).ToArray();
            var todo = new List<long[]>();
            foreach (var r in kv.Value)
            {
                long g = Overlap(held, hs, (r[0] + Unit - 1) / Unit * Unit, r[1] / Unit * Unit);
                if (g > 0) { todo.Add(r); Saves += g; }
            }
            if (todo.Count > 0) Todo[kv.Key] = todo;
        }
    }

    public void Apply()
    {
        foreach (var f in Foreign) File.Delete(f);
        int i = 0;
        var buf = new byte[16 << 20];
        foreach (var kv in Todo)
        {
            var name = Path.GetFileName(kv.Key);
            Console.WriteLine("  [{0}/{1}] {2}", ++i, Todo.Count, name);
            var kept = Kept(Old[kv.Key], new FileInfo(kv.Key).Length);
            var before = Hash(kv.Key, kept, buf);
            try { Zero(kv.Key, kv.Value); }
            finally { if (Hash(kv.Key, kept, buf) != before) throw new Exception(name + ": data the game reads changed. Run Verify integrity in Steam."); }
        }
    }

    public static long OnDisk(string dir)
    {
        long t = 0;
        foreach (var f in Directory.EnumerateFiles(dir, "*", SearchOption.AllDirectories))
        {
            uint hi, lo = GetCompressedFileSizeW(f, out hi);
            if (lo == 0xFFFFFFFF && Marshal.GetLastWin32Error() != 0) throw new Win32Exception(Marshal.GetLastWin32Error());
            t += ((long)hi << 32) | lo;
        }
        return t;
    }

    static string ChunkLanguage(List<string> files)
    {
        var langs = new HashSet<string>();
        foreach (var f in files)
        {
            if (f.EndsWith(".pak"))
            {
                var pak = ReadPak(f);
                if (pak == null || pak.Entries.Count > 0 && !pak.Mount.TrimEnd('/').EndsWith("WwiseAudio")) return null;
                foreach (var p in pak.Entries.Keys) langs.Add(LanguageOf(p));
            }
            else if (f.EndsWith(".utoc") && ReadToc(f).Header.Any(h => !h)) return null;
        }
        var lang = langs.Count == 1 ? langs.First() : null;
        return lang != null && Wwise.Contains(lang) ? lang : null;
    }

    static string LanguageOf(string path)
    {
        var parts = path.Trim('/').Split('/');
        int i = parts[0] == "Media" ? 1 : 0;
        return parts.Length - i > 1 ? parts[i] : null;
    }

    void PlanIoStore(HashSet<string> skip)
    {
        var tocs = new Dictionary<string, Toc>();
        var newest = new Dictionary<string, int>();
        foreach (var f in patch.Keys.Where(f => f.EndsWith(".utoc") && !skip.Contains(f) && !skip.Contains(Path.ChangeExtension(f, ".ucas"))))
        {
            var t = tocs[f] = ReadToc(f);
            foreach (var id in t.Ids) Bump(newest, id, patch[f]);
        }
        foreach (var kv in tocs)
        {
            var t = kv.Value;
            var used = new HashSet<long>();
            var covered = new HashSet<long>();
            for (int i = 0; i < t.Ids.Length; i++)
            {
                if (t.SpanLen[i] == 0) continue;
                bool replaced = !t.Header[i] && newest[t.Ids[i]] > patch[kv.Key];
                for (long b = t.SpanOff[i] / t.BlockSz; b <= (t.SpanOff[i] + t.SpanLen[i] - 1) / t.BlockSz; b++)
                {
                    covered.Add(b);
                    if (!replaced) used.Add(b);
                }
            }
            var starts = t.BlockOff.OrderBy(x => x).ToArray();
            var old = new List<long[]>();
            foreach (var b in covered.Where(b => !used.Contains(b)))
            {
                int k = Upper(starts, t.BlockOff[b]);
                old.Add(new[] { t.BlockOff[b], k < starts.Length ? starts[k] : t.BlockOff[b] + t.BlockSize[b] });
            }
            Check(Path.ChangeExtension(kv.Key, ".ucas"), Merge(old), Merge(used.Select(b => new[] { t.BlockOff[b], t.BlockOff[b] + t.BlockSize[b] }).ToList()));
        }
    }

    void PlanPak(HashSet<string> skip)
    {
        var paks = new Dictionary<string, Pak>();
        var newest = new Dictionary<string, int>();
        foreach (var f in patch.Keys.Where(f => f.EndsWith(".pak") && !skip.Contains(f)))
        {
            var p = ReadPak(f);
            if (p == null) continue;
            paks[f] = p;
            foreach (var e in p.Entries.Keys) Bump(newest, p.Mount + e, patch[f]);
        }
        foreach (var kv in paks)
        {
            var p = kv.Value;
            var used = new HashSet<long>(p.Entries.Where(e => newest[p.Mount + e.Key] <= patch[kv.Key]).Select(e => e.Value));
            var starts = p.Entries.Values.Distinct().OrderBy(x => x).ToArray();
            var old = new List<long[]>();
            for (int k = 0; k < starts.Length; k++)
                if (!used.Contains(starts[k])) old.Add(new[] { starts[k], k + 1 < starts.Length ? starts[k + 1] : p.DataEnd });
            Check(kv.Key, Merge(old), used.OrderBy(x => x).Select(s => new[] { s, s + 1 }).ToList());
        }
    }

    void Check(string f, List<long[]> old, List<long[]> used)
    {
        if (old.Count == 0) return;
        var os = old.Select(r => r[0]).ToArray();
        foreach (var u in used)
            if (Overlap(old, os, u[0], u[1]) > 0) throw new Exception(Path.GetFileName(f) + ": an old range covers data the game reads at " + u[0]);
        if (old[old.Count - 1][1] > new FileInfo(f).Length) throw new Exception(Path.GetFileName(f) + ": an old range runs past the end of the file");
        Old[f] = old;
    }

    static void Bump(Dictionary<string, int> newest, string key, int patch)
    {
        int v;
        newest[key] = newest.TryGetValue(key, out v) ? Math.Max(v, patch) : patch;
    }

    static List<long[]> Merge(List<long[]> ranges)
    {
        var o = new List<long[]>();
        foreach (var r in ranges.OrderBy(r => r[0]).ThenBy(r => r[1]))
        {
            if (o.Count > 0 && r[0] <= o[o.Count - 1][1]) o[o.Count - 1][1] = Math.Max(o[o.Count - 1][1], r[1]);
            else o.Add(new[] { r[0], r[1] });
        }
        return o;
    }

    static int Upper(long[] a, long v)
    {
        int lo = 0, hi = a.Length;
        while (lo < hi) { int m = (lo + hi) / 2; if (a[m] <= v) lo = m + 1; else hi = m; }
        return lo;
    }

    static long Overlap(List<long[]> held, long[] starts, long lo, long hi)
    {
        long t = 0;
        for (int j = Math.Max(0, Upper(starts, lo) - 1); j < held.Count && held[j][0] < hi; j++)
            t += Math.Max(0, Math.Min(hi, held[j][1]) - Math.Max(lo, held[j][0]));
        return t;
    }

    static List<long[]> Kept(List<long[]> old, long size)
    {
        var o = new List<long[]>();
        long pos = 0;
        foreach (var r in old) { if (pos < r[0]) o.Add(new[] { pos, r[0] }); pos = r[1]; }
        if (pos < size) o.Add(new[] { pos, size });
        return o;
    }

    static Toc ReadToc(string path)
    {
        var d = File.ReadAllBytes(path);
        var name = Path.GetFileName(path);
        if (d.Length < 104 || Encoding.ASCII.GetString(d, 0, 16) != "-==--==--==--==-" || d[16] != 8 || U32(d, 32) != 12)
            throw new Exception(name + ": not a version 8 IoStore TOC");
        if ((d[80] & 6) != 0 || U32(d, 52) != 1)
            throw new Exception(name + ": encrypted, signed or split containers are not supported");
        long n = U32(d, 24), nb = U32(d, 28), p = U32(d, 20);
        var t = new Toc { BlockSz = U32(d, 44), Ids = new string[n], Header = new bool[n], SpanOff = new long[n], SpanLen = new long[n], BlockOff = new long[nb], BlockSize = new long[nb] };
        for (int i = 0; i < n; i++) { t.Ids[i] = Convert.ToBase64String(d, (int)(p + i * 12), 12); t.Header[i] = d[p + i * 12 + 11] == 6; }
        p += n * 12;
        for (int i = 0; i < n; i++) { t.SpanOff[i] = Num(d, p + i * 10, 5, true); t.SpanLen[i] = Num(d, p + i * 10 + 5, 5, true); }
        p += n * 10 + U32(d, 84) * 4L + U32(d, 96) * 4L;
        for (int i = 0; i < nb; i++) { t.BlockOff[i] = Num(d, p + i * 12, 5, false); t.BlockSize[i] = Num(d, p + i * 12 + 5, 3, false); }
        p += nb * 12 + U32(d, 36) * (long)U32(d, 40) + U32(d, 48);
        if (d.Length - p != n * 24) throw new Exception(name + ": TOC sections do not add up to the file size");
        return t;
    }

    static Pak ReadPak(string path)
    {
        var name = Path.GetFileName(path);
        var pak = new Pak();
        using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
        {
            long size = fs.Length;
            if (size < 221) throw new Exception(name + ": too small to be a pak");
            var ft = ReadAt(fs, size - 221, 221);
            if (U32(ft, 17) != 0x5A6F12E1) throw new Exception(name + ": no pak footer");
            if (BitConverter.ToInt32(ft, 21) != 11) throw new Exception(name + ": pak version " + BitConverter.ToInt32(ft, 21) + ", expected 11");
            if (ft[16] != 0) return null;
            long io = BitConverter.ToInt64(ft, 25);
            var idx = ReadAt(fs, io, (int)BitConverter.ToInt64(ft, 33));
            var bounds = new List<long> { io, size - 221 };
            int p = 0;
            pak.Mount = FString(idx, ref p);
            p += 12;
            uint hasHash = U32(idx, p);
            p += 4;
            if (hasHash != 0) { bounds.Add(BitConverter.ToInt64(idx, p)); p += 36; }
            uint hasDirs = U32(idx, p);
            p += 4;
            if (hasDirs == 0) return null;
            long dirOff = BitConverter.ToInt64(idx, p), dirSize = BitConverter.ToInt64(idx, p + 8);
            bounds.Add(dirOff);
            p += 36;
            int enc = p + 4, q = enc + BitConverter.ToInt32(idx, p);
            var plain = new List<long>();
            uint count = U32(idx, q);
            q += 4;
            for (uint i = 0; i < count; i++)
            {
                plain.Add(BitConverter.ToInt64(idx, q));
                uint method = U32(idx, q + 24);
                q += 48;
                if (method != 0) q += 4 + 16 * (int)U32(idx, q);
                q += 5;
            }
            if (q != idx.Length) throw new Exception(name + ": index layout does not add up to its size");
            var dirs = ReadAt(fs, dirOff, (int)dirSize);
            int r = 0, folders = BitConverter.ToInt32(dirs, r);
            r += 4;
            for (int i = 0; i < folders; i++)
            {
                var folder = FString(dirs, ref r);
                int files = BitConverter.ToInt32(dirs, r);
                r += 4;
                for (int j = 0; j < files; j++)
                {
                    var file = FString(dirs, ref r);
                    int loc = BitConverter.ToInt32(dirs, r);
                    r += 4;
                    if (loc == int.MinValue) continue;
                    if (loc < 0) { pak.Entries[folder + file] = plain[-loc - 1]; continue; }
                    uint flags = U32(idx, enc + loc);
                    int at = enc + loc + ((flags & 0x3F) == 0x3F ? 8 : 4);
                    pak.Entries[folder + file] = (flags >> 31) != 0 ? U32(idx, at) : BitConverter.ToInt64(idx, at);
                }
            }
            pak.DataEnd = bounds.Min();
        }
        return pak;
    }

    static uint U32(byte[] d, long o) { return BitConverter.ToUInt32(d, (int)o); }

    static long Num(byte[] d, long o, int n, bool bigEndian)
    {
        long v = 0;
        for (int i = 0; i < n; i++) v = (v << 8) | d[o + (bigEndian ? i : n - 1 - i)];
        return v;
    }

    static string FString(byte[] b, ref int p)
    {
        int n = BitConverter.ToInt32(b, p);
        p += 4;
        int len = n < 0 ? -n * 2 : n;
        var s = n < 0 ? Encoding.Unicode.GetString(b, p, len) : Encoding.GetEncoding(28591).GetString(b, p, len);
        p += len;
        return s.TrimEnd('\0');
    }

    static byte[] ReadAt(FileStream fs, long off, int n)
    {
        var b = new byte[n];
        fs.Position = off;
        for (int got = 0, k; got < n; got += k)
            if ((k = fs.Read(b, got, n - got)) == 0) throw new Exception(Path.GetFileName(fs.Name) + ": file ends early");
        return b;
    }

    static byte[] Pair(long a, long b)
    {
        var o = new byte[16];
        BitConverter.GetBytes(a).CopyTo(o, 0);
        BitConverter.GetBytes(b).CopyTo(o, 8);
        return o;
    }

    static void Ioctl(FileStream fs, uint code, byte[] inBuf)
    {
        int ret;
        if (!DeviceIoControl(fs.SafeFileHandle, code, inBuf, inBuf == null ? 0 : inBuf.Length, null, 0, out ret, IntPtr.Zero))
            throw new Win32Exception(Marshal.GetLastWin32Error());
    }

    static void Zero(string path, List<long[]> ranges)
    {
        using (var fs = new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.Read))
        {
            Ioctl(fs, SetSparse, null);
            foreach (var r in ranges) Ioctl(fs, SetZeroData, Pair(r[0], r[1]));
        }
    }

    static List<long[]> Allocated(string path)
    {
        var o = new List<long[]>();
        using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
        {
            long start = 0, size = fs.Length;
            var buf = new byte[16 * 4096];
            while (start < size)
            {
                int ret;
                bool ok = DeviceIoControl(fs.SafeFileHandle, QueryAllocatedRanges, Pair(start, size - start), 16, buf, buf.Length, out ret, IntPtr.Zero);
                int err = Marshal.GetLastWin32Error();
                if (!ok && err != 234) throw new Win32Exception(err);
                for (int i = 0; i + 16 <= ret; i += 16) o.Add(new[] { BitConverter.ToInt64(buf, i), BitConverter.ToInt64(buf, i) + BitConverter.ToInt64(buf, i + 8) });
                if (ok || ret == 0) break;
                start = o[o.Count - 1][1];
            }
        }
        return o;
    }

    static long ProbeUnit(string dir)
    {
        var f = Path.Combine(dir, "bl4-slim-probe.tmp");
        const int n = 8 << 20;
        try
        {
            File.WriteAllBytes(f, Enumerable.Repeat((byte)1, n).ToArray());
            using (var fs = new FileStream(f, FileMode.Open, FileAccess.ReadWrite, FileShare.Read))
            {
                Ioctl(fs, SetSparse, null);
                Ioctl(fs, SetZeroData, Pair(1, n - 1));
            }
            var a = Allocated(f);
            return a.Count == 2 && a[0][0] == 0 && a[1][1] == n && a[0][1] == n - a[1][0] ? a[0][1] : 0;
        }
        catch (Win32Exception) { return 0; }
        catch (IOException) { return 0; }
        finally { File.Delete(f); }
    }

    static string Hash(string path, List<long[]> ranges, byte[] buf)
    {
        using (var sha = SHA1.Create())
        using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 20))
        {
            foreach (var r in ranges)
            {
                fs.Position = r[0];
                for (long left = r[1] - r[0]; left > 0; )
                {
                    int k = fs.Read(buf, 0, (int)Math.Min(left, buf.Length));
                    if (k == 0) throw new Exception(Path.GetFileName(path) + ": file ends before byte " + r[1]);
                    sha.TransformBlock(buf, 0, k, null, 0);
                    left -= k;
                }
            }
            sha.TransformFinalBlock(new byte[0], 0, 0);
            return Convert.ToBase64String(sha.Hash);
        }
    }
}
'@

function Size($n) { if ($n -ge 1GB -or $n -eq 0) { '{0,8:N2} GB' -f ($n / 1GB) } else { '{0,8:N2} MB' -f ($n / 1MB) } }

function Find-Game {
    $steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
    if (-not $steam) { return }
    $libs = @($steam)
    $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
    if (Test-Path -LiteralPath $vdf) { $libs += Select-String -LiteralPath $vdf -Pattern '"path"\s+"(.+?)"' | ForEach-Object { $_.Matches[0].Groups[1].Value -replace '\\\\', '\' } }
    foreach ($lib in $libs) {
        $acf = Join-Path $lib 'steamapps\appmanifest_1285190.acf'
        if (-not (Test-Path -LiteralPath $acf)) { continue }
        $m = Select-String -LiteralPath $acf -Pattern '"installdir"\s+"(.+?)"' | Select-Object -First 1
        if ($m) { return Join-Path $lib ('steamapps\common\' + $m.Matches[0].Groups[1].Value) }
    }
}

try {
    if (-not $GameDir) { $GameDir = Find-Game }
    if (-not $GameDir) { $GameDir = Read-Host 'Paste your Borderlands 4 folder' }
    $GameDir = $GameDir.Trim().Trim('"')
    if (-not $GameDir -or -not (Test-Path -LiteralPath (Join-Path $GameDir 'OakGame\Content\Paks'))) { Write-Host "No Borderlands 4 found at $GameDir"; exit 2 }
    $GameDir = (Resolve-Path -LiteralPath $GameDir).ProviderPath.TrimEnd('\')
    Write-Host "Borderlands 4: $GameDir"
    if (-not $Scan) {
        if (Get-Process Borderlands4 -ErrorAction SilentlyContinue) { Write-Host 'Borderlands 4 is running. Close it first.'; exit 1 }
        $acf = Join-Path (Split-Path (Split-Path $GameDir)) 'appmanifest_1285190.acf'
        if ((Test-Path -LiteralPath $acf) -and (Get-Content -LiteralPath $acf -Raw) -notmatch '"StateFlags"\s+"4"') { Write-Host 'Steam is updating or checking the game. Let it finish first.'; exit 1 }
    }

    $s = New-Object Bl4Slim (Join-Path $GameDir 'OakGame\Content\Paks')
    $langs = @($s.Voices.Values | Sort-Object -Unique)
    if (-not $Keep) {
        $Keep = 'English(US)'
        if ($langs.Count -eq 1) { $Keep = $langs[0] }
        elseif ($langs.Count -gt 1) {
            Write-Host 'Voice languages installed:'
            for ($i = 0; $i -lt $langs.Count; $i++) { Write-Host ('  {0}. {1}' -f ($i + 1), $langs[$i]) }
            $a = (Read-Host 'Number of the one to keep (Enter = English(US))').Trim()
            if ($a -match '^\d+$' -and [int]$a -ge 1 -and [int]$a -le $langs.Count) { $Keep = $langs[[int]$a - 1] } elseif ($a) { $Keep = $a }
        }
    }
    $Keep = @($langs | Where-Object { $_ -eq $Keep }) + $Keep | Select-Object -First 1
    Write-Host 'Reading the game files...'
    $s.Prepare($Keep)
    $before = [Bl4Slim]::OnDisk($GameDir)

    Write-Host ''
    Write-Host ('Game on disk now:        {0}' -f (Size $before))
    foreach ($d in $s.Drop.GetEnumerator()) { Write-Host ('  {0,-21} {1}' -f $d.Key, (Size $d.Value)) }
    Write-Host ('Voice languages to drop: {0}   (keeping {1})' -f (Size $s.ForeignBytes), $Keep)
    Write-Host ('Old patch copies:        {0}   in {1} files' -f (Size $s.Saves), $s.Todo.Count)
    if ($s.Unit -eq 0) { Write-Host 'Old patch copies stay: this drive cannot free part of a file. That needs NTFS and a few MB free.' }
    if ($s.Foreign.Count -eq 0 -and $s.Todo.Count -eq 0) { Write-Host 'Nothing to do.'; exit 0 }
    if ($Scan) { exit 0 }
    if (-not $Yes -and (Read-Host 'Go ahead? (y/n)') -notmatch '^\s*y') { Write-Host 'Nothing changed.'; exit 1 }

    $s.Apply()
    $after = [Bl4Slim]::OnDisk($GameDir)
    Write-Host ''
    Write-Host ('Before:  {0}' -f (Size $before))
    Write-Host ('After:   {0}' -f (Size $after))
    Write-Host ('Saved:   {0}' -f (Size ($before - $after)))
    if ($s.Todo.Count) { Write-Host 'In File Explorer, "Size" still counts the freed space. "Size on disk" is the real number.' }
}
catch {
    $e = $_.Exception.GetBaseException()
    if ($e -is [UnauthorizedAccessException]) { Write-Host 'Windows blocked access to a game file. Right-click bl4-slim.cmd and pick "Run as administrator".' }
    else { Write-Host "Stopped: $($e.Message)" }
    exit 1
}
