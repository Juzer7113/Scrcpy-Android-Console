param([switch]$NoBrowser)

# STB Console backend - zero dependency (Windows PowerShell 5.1 built-in HttpListener)
$BASE    = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ADB     = Join-Path $BASE 'adb.exe'
$SCRCPY  = Join-Path $BASE 'scrcpy.exe'
$DB      = Join-Path $BASE 'devices.json'
$PORT    = 8000

# allwinner hw encoder has a known bug: emits corrupt streams (ref-frames
# exceeds max, then QP out of range) that crash FFmpeg. The fix is to force
# all-I-frames (i-frame-interval=0) so frames have no cross-frame dependency.
# This applies to SW-618 and any Amlogic box that ships the allwinner encoder.
$VIDEO_ARGS_ALLWINNER = @(
  '--video-codec=h264',
  '--video-encoder=OMX.allwinner.video.encoder.avc',
  '--max-size=1280',
  '--max-fps=25',
  '--video-bit-rate=4M',
  '--video-codec-options=i-frame-interval=0',
  '--no-audio'
)

# Fallback for allwinner boxes whose hw encoder emits unusable streams
# (frames never reach the decoder). Lower spec + software encoder.
$VIDEO_ARGS_SWFALLBACK = @(
  '--video-codec=h264',
  '--video-encoder=c2.android.avc.encoder',
  '--max-size=640',
  '--max-fps=15',
  '--video-bit-rate=1M',
  '--no-audio'
)

$ENCODER_CACHE = @{}

function Video-Args-For($t) {
  $model = ''
  try { $model = (& $ADB -s $t shell getprop ro.product.model 2>$null | Out-String).Trim() } catch {}
  Write-Host ('[launch] device model = ' + $model)

  # $model is diagnostic only - encoder choice comes from the probe below
  # detect allwinner hw encoder (cached per device, ~1s one-time cost)
  $useAllwinner = $false
  if ($ENCODER_CACHE.ContainsKey($t)) {
    $useAllwinner = $ENCODER_CACHE[$t]
  } else {
    try {
      $r = Invoke-Proc $SCRCPY ('-s ' + $t + ' --list-encoders')
      if ($r.out -match 'OMX\.allwinner\.video\.encoder\.avc\s*\(hw\)') {
        $useAllwinner = $true
      }
    } catch {}
    $ENCODER_CACHE[$t] = $useAllwinner
  }

  if ($useAllwinner) {
    Write-Host '[launch] allwinner hw encoder detected - using all-I-frame workaround'
    return $VIDEO_ARGS_ALLWINNER
  }
  Write-Host '[launch] using default encoder (conservative profile for low-end devices)'
  return @('--max-size=1024', '--max-fps=30', '--video-bit-rate=4M', '--no-audio')
}

$utf8 = New-Object System.Text.UTF8Encoding($false)
$APPCACHE = Join-Path $BASE 'cache\apps'

# ---- local aapt (from the Android SDK) for app label + icon parsing ----
function Find-Aapt {
  # 1) explicit override file wins
  $ov = Join-Path $BASE 'aapt_path.txt'
  if (Test-Path $ov) {
    $p = (Get-Content $ov -Raw).Trim()
    if ($p) {
      if (Test-Path $p -PathType Leaf) { return $p }
      foreach ($exe in @('aapt2.exe', 'aapt.exe')) {
        $q = Join-Path $p $exe
        if (Test-Path $q) { return $q }
      }
    }
  }
  # 2) bundled copy inside this folder - keeps the folder portable
  foreach ($exe in @('aapt2.exe', 'aapt.exe')) {
    $q = Join-Path (Join-Path $BASE 'tools') $exe
    if (Test-Path $q) { return $q }
  }
  # 3) Android SDK on this machine
  $dirs = @()
  foreach ($e in @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT)) { if ($e) { $dirs += (Join-Path $e 'build-tools') } }
  $dirs += (Join-Path $env:LOCALAPPDATA 'Android\Sdk\build-tools')
  $best = $null; $bestRank = -1; $bestVer = [version]'0.0.0'
  foreach ($dir in $dirs) {
    if (-not (Test-Path $dir)) { continue }
    foreach ($sub in (Get-ChildItem $dir -Directory -ErrorAction SilentlyContinue)) {
      $ver = [version]'0.0.0'
      if ($sub.Name -match '^(\d+)\.(\d+)\.(\d+)') { $ver = [version]("$($matches[1]).$($matches[2]).$($matches[3])") }
      foreach ($exe in @('aapt2.exe', 'aapt.exe')) {
        $p = Join-Path $sub.FullName $exe
        if (-not (Test-Path $p)) { continue }
        $rank = 0; if ($exe -eq 'aapt2.exe') { $rank = 1 }
        if ($rank -gt $bestRank -or ($rank -eq $bestRank -and $ver -gt $bestVer)) {
          $best = $p; $bestRank = $rank; $bestVer = $ver
        }
      }
    }
  }
  return $best
}

function Invoke-Proc($exe, $argLine) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $exe
  $psi.Arguments = $argLine
  $psi.WorkingDirectory = $BASE
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8   # aapt emits UTF-8 (Khmer labels etc.)
  $psi.StandardErrorEncoding  = [System.Text.Encoding]::UTF8
  $p = [System.Diagnostics.Process]::Start($psi)
  # stderr must be drained concurrently - blocking on one pipe while the other
  # fills its ~4KB buffer deadlocks both sides
  $errTask = $p.StandardError.ReadToEndAsync()
  $o = $p.StandardOutput.ReadToEnd()
  if (-not $p.WaitForExit(180000)) {
    try { $p.Kill() } catch {}
    return @{ code = -1; out = $o; err = 'timed out after 180s' }
  }
  return @{ code = $p.ExitCode; out = $o; err = $errTask.Result }
}

# parse "aapt dump badging" output -> label + best icon path
function Parse-Badging($text) {
  $label = ''
  $icons = @{}
  foreach ($line in ($text -split "`r?`n")) {
    if ($line -match "^application-label:'([^']*)'") {
      if (-not $label) { $label = $matches[1].Trim() }
    }
    elseif ($line -match "^application-icon-(\d+):'([^']+)'") {
      $icons[[int]$matches[1]] = $matches[2]
    }
    elseif ($line -match "^application:\s+label='([^']*)'\s+icon='([^']+)'") {
      if (-not $label) { $label = $matches[1].Trim() }
      if (-not $icons.ContainsKey(0)) { $icons[0] = $matches[2] }
    }
  }
  $icon = ''
  foreach ($want in @(320, 240, 480, 160, 120)) {
    if ($icons.ContainsKey($want)) { $icon = $icons[$want]; break }
  }
  if (-not $icon) {
    $best = 0
    foreach ($k in $icons.Keys) {
      if ($k -gt $best -and $k -lt 60000) { $best = $k; $icon = $icons[$k] }
    }
  }
  if (-not $icon -and $icons.ContainsKey(0)) { $icon = $icons[0] }
  return @{ label = $label; icon = $icon }
}

# extract the icon file from the pulled apk (xml/vector icons are skipped)
function Extract-Icon($apk, $iconPath, $destDir) {
  $ext = [System.IO.Path]::GetExtension($iconPath).ToLower()
  if ($ext -eq '.xml') { return $null }
  if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $zip = $null
  try {
    $zip = [System.IO.Compression.ZipFile]::OpenRead($apk)
    $entry = $zip.Entries | Where-Object { $_.FullName -eq $iconPath } | Select-Object -First 1
    if (-not $entry) { return $null }
    $dest = Join-Path $destDir ('icon' + $ext)
    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $dest, $true)
    return $dest
  } catch { return $null }
  finally { if ($zip) { $zip.Dispose() } }
}

function Get-AppCache($pkg) {
  $meta = Join-Path (Join-Path $APPCACHE $pkg) 'meta.json'
  if (-not (Test-Path $meta)) { return $null }
  try { return (Get-Content $meta -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Set-AppCache($pkg, $metaObj) {
  $dir = Join-Path $APPCACHE $pkg
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  [System.IO.File]::WriteAllText((Join-Path $dir 'meta.json'), ($metaObj | ConvertTo-Json -Compress), $utf8)
}

# ---- input validation ----
# every one of these values ends up inside an adb/scrcpy command line built by
# string concatenation, and "adb shell" hands its arguments to a shell on the
# device - so anything with a space, quote or ';' in it must never get that far.
function Valid-Host($s) {
  $s = [string]$s
  if ($s.Length -lt 1 -or $s.Length -gt 253) { return $false }
  if ($s -match '\.\.') { return $false }
  return ($s -match '^[A-Za-z0-9]([A-Za-z0-9.\-]*[A-Za-z0-9])?$')
}

function Valid-Port($s) {
  $s = [string]$s
  if ($s -notmatch '^[0-9]{1,5}$') { return $false }
  $n = [int]$s
  return ($n -ge 1 -and $n -le 65535)
}

# android package name: dot-separated [A-Za-z0-9_] segments, nothing else
function Valid-Pkg($s) {
  $s = [string]$s
  if ($s.Length -lt 1 -or $s.Length -gt 255) { return $false }
  return ($s -match '^[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)*$')
}

# set a property that may not exist yet (ConvertFrom-Json objects throw on plain assignment)
function Set-Prop($o, $name, $val) {
  $o | Add-Member -NotePropertyName $name -NotePropertyValue $val -Force
}

function Get-Devs {
  if (-not (Test-Path $DB)) { return @() }
  try {
    $txt = [System.IO.File]::ReadAllText($DB, $utf8)
    if ([string]::IsNullOrWhiteSpace($txt)) { return @() }
    $j = $txt | ConvertFrom-Json
    if ($null -eq $j) { return @() }
    if ($j -is [array]) {
      # array file: either a bare device list, or the old {"devices":[...]} shape
      $list = @($j | Where-Object { $null -ne $_ -and $_.PSObject.Properties.Name -contains 'ip' })
    } else {
      $props = @($j.PSObject.Properties.Name)
      if ($props -contains 'devices') {
        $list = @($j.devices)
      } elseif ($props -contains 'ip') {
        $list = @($j)          # legacy: single device object
      } else {
        return @()
      }
    }
    if ($list.Count -eq 1 -and $null -eq $list[0]) { return @() }
    # normalize + sanitize: downstream code pastes ip/port into command lines and
    # assigns to .status/.name, which throws on a json object that lacks them
    $out = New-Object System.Collections.ArrayList
    foreach ($d in $list) {
      if ($null -eq $d) { continue }
      if (-not (Valid-Host $d.ip)) { continue }
      if (-not [string]$d.port) { Set-Prop $d 'port' '5555' }
      if (-not (Valid-Port $d.port)) { continue }
      if (-not ($d.PSObject.Properties.Name -contains 'id'))     { Set-Prop $d 'id' ([guid]::NewGuid().ToString().Substring(0, 8)) }
      if (-not ($d.PSObject.Properties.Name -contains 'name'))   { Set-Prop $d 'name' '' }
      if (-not ($d.PSObject.Properties.Name -contains 'status')) { Set-Prop $d 'status' 'unknown' }
      $null = $out.Add($d)
    }
    return @($out)
  } catch { return @() }
}

# PS 5.1 flattens single-element arrays in ConvertTo-Json - build arrays by hand
function Json-Array($arr) {
  $items = New-Object System.Collections.ArrayList
  foreach ($x in @($arr)) {
    if ($null -eq $x) { continue }
    $null = $items.Add(($x | ConvertTo-Json -Depth 6 -Compress))
  }
  return '[' + ($items -join ',') + ']'
}

function Save-Devs($devs) {
  if ($null -eq $devs -or @($devs).Count -eq 0) {
    $json = '[]'
  } else {
    $json = Json-Array $devs
  }
  [System.IO.File]::WriteAllText($DB, $json, $utf8)
}

function Target($d) { return "$($d.ip):$($d.port)" }

function Find-Dev($id) {
  foreach ($d in (Get-Devs)) { if ($d.id -eq [string]$id) { return $d } }
  return $null
}

function Read-Body($req) {
  $sr = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
  $raw = $sr.ReadToEnd(); $sr.Close()
  if (-not $raw) { return @{} }
  try { return ($raw | ConvertFrom-Json) } catch { return @{} }
}

# run adb with output captured (no extra console window)
function Invoke-Adb($argLine) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $ADB
  $psi.Arguments = $argLine
  $psi.WorkingDirectory = $BASE
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
  $psi.StandardErrorEncoding  = [System.Text.Encoding]::UTF8
  $p = [System.Diagnostics.Process]::Start($psi)
  $errTask = $p.StandardError.ReadToEndAsync()
  $o = $p.StandardOutput.ReadToEnd()
  if (-not $p.WaitForExit(180000)) {
    try { $p.Kill() } catch {}
    return @{ code = -1; out = $o; err = 'timed out after 180s' }
  }
  return @{ code = $p.ExitCode; out = $o; err = $errTask.Result }
}

function Resp($ctx, $code, $bytes, $ctype) {
  $ctx.Response.StatusCode = $code
  $ctx.Response.ContentType = $ctype
  $ctx.Response.ContentLength64 = $bytes.Length
  $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
  $ctx.Response.OutputStream.Close()
}

function RespJson($ctx, $obj) {
  $s = $obj | ConvertTo-Json -Depth 6
  Resp $ctx 200 ([System.Text.Encoding]::UTF8.GetBytes($s)) 'application/json; charset=utf-8'
}

function RespRaw($ctx, $json) {
  Resp $ctx 200 ([System.Text.Encoding]::UTF8.GetBytes($json)) 'application/json; charset=utf-8'
}

function Refresh-Status {
  $devs = Get-Devs
  if ($devs.Count -eq 0) { return @() }

  # fast TCP probe (concurrent), then adb connect only for reachable boxes
  $clients = New-Object System.Collections.ArrayList
  foreach ($d in $devs) {
    $c = New-Object System.Net.Sockets.TcpClient
    try { $null = $c.ConnectAsync([string]$d.ip, [int]$d.port) } catch {}
    $null = $clients.Add(@{ d = $d; c = $c })
  }
  Start-Sleep -Milliseconds 600
  foreach ($x in $clients) {
    try {
      if ($x.c.Connected) { & $ADB connect (Target $x.d) 2>$null | Out-Null }
    } catch {}
    try { $x.c.Close() } catch {}
  }

  $out = & $ADB devices 2>$null | Out-String
  $state = @{}
  foreach ($line in ($out -split "`r?`n")) {
    if ($line -match '^\s*(\S+)\s+(\S+)\s*$') {
      if ($matches[1] -like '*:*') { $state[$matches[1]] = $matches[2] }
    }
  }
  $changed = $false
  foreach ($d in $devs) {
    $t = Target $d
    $new = 'offline'
    if ($state.ContainsKey($t)) { $new = $state[$t] }
    if ([string]$d.status -ne $new) { Set-Prop $d 'status' $new; $changed = $true }
  }
  if ($changed) { Save-Devs $devs }   # don't rewrite the file on every 30s poll
  return @($devs)
}

# Start a long-lived process with BOTH pipes drained for its whole lifetime.
# A redirected pipe nobody reads fills at ~4KB and blocks the writer for good,
# which freezes the mirroring window mid-session.
# BeginOutput/ErrorReadLine keeps draining even after the handlers are removed.
function Start-Drained($exe, $argLine) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $exe
  $psi.Arguments = $argLine
  $psi.WorkingDirectory = $BASE
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
  $psi.StandardErrorEncoding  = [System.Text.Encoding]::UTF8
  $p = [System.Diagnostics.Process]::Start($psi)
  # synchronized: the event handlers run on another thread while we enumerate
  $outBuf = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
  $errBuf = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
  $so = Register-ObjectEvent -InputObject $p -EventName OutputDataReceived -MessageData $outBuf -Action {
    if ($EventArgs.Data) { $null = $MessageData.Add($EventArgs.Data) }
  }
  $se = Register-ObjectEvent -InputObject $p -EventName ErrorDataReceived -MessageData $errBuf -Action {
    if ($EventArgs.Data) { $null = $MessageData.Add($EventArgs.Data) }
  }
  $p.BeginOutputReadLine()
  $p.BeginErrorReadLine()
  return @{ p = $p; out = $outBuf; err = $errBuf; subs = @($so.Name, $se.Name) }
}

# drop the line collectors once the probe window is over (the pipes keep draining)
function Stop-Collect($h) {
  foreach ($s in $h.subs) { Unregister-Event -SourceIdentifier $s -ErrorAction SilentlyContinue }
}

function Lines-Of($buf) {
  try { return @($buf.ToArray()) } catch { return @() }
}

function Start-Scrcpy($t, $vargs) {
  $arg = '-s ' + $t + ' --window-title="STB ' + $t + '" ' + ($vargs -join ' ')
  return Start-Drained $SCRCPY $arg
}

# scrcpy creates its window only once it has decoded a frame, so a window is
# proof that frames are actually arriving. Watching the log instead does not
# work: a redirected stdout is block-buffered inside scrcpy and stays empty
# for minutes, which made the old --print-fps probe always report failure.
function Wait-Window($p, $ms) {
  $deadline = (Get-Date).AddMilliseconds($ms)
  while ((Get-Date) -lt $deadline) {
    if ($p.HasExited) { return $false }
    try {
      $p.Refresh()
      if ($p.MainWindowHandle -ne [System.IntPtr]::Zero) { return $true }
    } catch {}
    Start-Sleep -Milliseconds 250
  }
  return $false
}

function Launch($d) {
  $t = Target $d
  & $ADB connect $t 2>$null | Out-Null

  # pre-flight: make sure the device is actually reachable
  $dv = & $ADB devices 2>$null | Out-String
  $online = $false
  foreach ($line in ($dv -split "`r?`n")) {
    $cols = ($line -split '\s+') | Where-Object { $_ -ne '' }
    if ($cols.Count -ge 2 -and $cols[0] -eq $t -and $cols[1] -eq 'device') { $online = $true }
  }
  if (-not $online) {
    return @{ ok = $false; msg = 'device not reachable (' + $t + ') - check IP / network ADB' }
  }

  $vargs = Video-Args-For $t
  $isAllwinner = ($vargs -join ' ') -match 'allwinner'
  try {
    $h = Start-Scrcpy $t $vargs
  } catch {
    return @{ ok = $false; msg = 'cannot start scrcpy: ' + $_.Exception.Message }
  }
  $p = $h.p

  Start-Sleep -Milliseconds 1500
  if ($p.HasExited) {
    Stop-Collect $h
    $e = (((Lines-Of $h.err) + (Lines-Of $h.out)) -join ' ').Trim()
    if (-not $e) { $e = 'scrcpy exited immediately (code ' + $p.ExitCode + ')' }
    Write-Host ('[launch] FAILED ' + $t + ' :: ' + ($e -replace "\s+", ' '))
    return @{ ok = $false; msg = $e }
  }

  # allwinner hw encoder: give it 5s to put a window up. no window means no
  # decoded frame, i.e. the stream is unusable -> retry with software fallback.
  if ($isAllwinner) {
    $gotFrame = Wait-Window $p 5000
    Stop-Collect $h
    if (-not $gotFrame) {
      Write-Host ('[launch] allwinner hw encoder produced no frames for ' + $t + ' - falling back to software encoder')
      try { $p.Kill() } catch {}
      try { $p.WaitForExit(2000) | Out-Null } catch {}
      try {
        $h2 = Start-Scrcpy $t $VIDEO_ARGS_SWFALLBACK
      } catch {
        return @{ ok = $false; msg = 'cannot start scrcpy (sw fallback): ' + $_.Exception.Message }
      }
      Start-Sleep -Milliseconds 1500
      if ($h2.p.HasExited) {
        Stop-Collect $h2
        $e2 = (((Lines-Of $h2.err) + (Lines-Of $h2.out)) -join ' ').Trim()
        if (-not $e2) { $e2 = 'sw fallback exited immediately (code ' + $h2.p.ExitCode + ')' }
        Write-Host ('[launch] SW-FALLBACK FAILED ' + $t + ' :: ' + ($e2 -replace "\s+", ' '))
        return @{ ok = $false; msg = $e2 }
      }
      Stop-Collect $h2
      Write-Host ('[launch] OK (sw fallback) ' + $t)
      return @{ ok = $true; target = $t; mode = 'sw' }
    }
    Write-Host ('[launch] OK (hw allwinner) ' + $t)
    return @{ ok = $true; target = $t; mode = 'hw' }
  }

  Stop-Collect $h
  Write-Host ('[launch] OK ' + $t)
  return @{ ok = $true; target = $t }
}

# ---------------- http server ----------------
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$PORT/")
try { $listener.Start() } catch {
  Write-Host "Port $PORT is busy. Close the other STB console window first."
  Read-Host "Press Enter to exit"
  exit
}

Write-Host "STB console running: http://127.0.0.1:$PORT"
Write-Host "adb=$ADB"

# uploads/ is a temp dir: clear whatever a previous run left behind
$UPDIR = Join-Path $BASE 'uploads'
if (Test-Path $UPDIR) {
  try { Get-ChildItem $UPDIR -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue } catch {}
}

$OKHOSTS = @("127.0.0.1:$PORT", "localhost:$PORT")
$OKORIGINS = @("http://127.0.0.1:$PORT", "http://localhost:$PORT")

if (-not $NoBrowser) { Start-Process "http://127.0.0.1:$PORT" }

while ($listener.IsListening) {
  $ctx = $null
  try { $ctx = $listener.GetContext() } catch { continue }
  try {
    $req  = $ctx.Request
    $path = $req.Url.AbsolutePath
    $m    = $req.HttpMethod.ToUpper()

    # Listening on loopback is not access control: any page the user happens to
    # have open can POST here, and with DNS rebinding it can read the replies
    # too. Requests must carry our own Host and must not be cross-origin.
    $hostHdr = [string]$req.UserHostName
    $origin  = [string]$req.Headers['Origin']
    if (($OKHOSTS -notcontains $hostHdr) -or ($origin -and ($OKORIGINS -notcontains $origin))) {
      Write-Host ('[block] ' + $m + ' ' + $path + ' host=' + $hostHdr + ' origin=' + $origin)
      Resp $ctx 403 ([System.Text.Encoding]::UTF8.GetBytes('forbidden')) 'text/plain'
      continue
    }

    if ($m -eq 'GET' -and ($path -eq '/' -or $path -eq '/index.html')) {
      $bytes = [System.IO.File]::ReadAllBytes((Join-Path $BASE 'index.html'))
      Resp $ctx 200 $bytes 'text/html; charset=utf-8'

    } elseif ($m -eq 'GET' -and $path -eq '/api/devices') {
      RespRaw $ctx ('{"ver":3,"devices":' + (Json-Array (Get-Devs)) + '}')

    } elseif ($m -eq 'POST' -and $path -eq '/api/status') {
      RespRaw $ctx ('{"ver":3,"devices":' + (Json-Array (Refresh-Status)) + '}')

    } elseif ($m -eq 'POST' -and $path -eq '/api/devices') {
      $sr  = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
      $raw = $sr.ReadToEnd(); $sr.Close()
      $b = @{}
      if ($raw) { try { $b = $raw | ConvertFrom-Json } catch { $b = @{} } }
      $ip   = ([string]$b.ip).Trim()
      $port = ([string]$b.port).Trim(); if (-not $port) { $port = '5555' }
      $name = [string]$b.name
      if (-not $ip) { RespJson $ctx @{ ok = $false; msg = 'IP is empty' }; continue }
      if (-not (Valid-Host $ip)) { RespJson $ctx @{ ok = $false; msg = 'invalid IP / host: ' + $ip }; continue }
      if (-not (Valid-Port $port)) { RespJson $ctx @{ ok = $false; msg = 'invalid port: ' + $port }; continue }
      if ($name.Length -gt 60) { $name = $name.Substring(0, 60) }

      $devs = @(Get-Devs)
      $dup  = $false
      foreach ($d in $devs) {
        if ($d.ip -eq $ip -and [string]$d.port -eq $port) { Set-Prop $d 'name' $name; $dup = $true }
      }
      if (-not $dup) {
        $id = [guid]::NewGuid().ToString().Substring(0, 8)
        $devs += [pscustomobject]@{ id = $id; ip = $ip; port = $port; name = $name; status = 'unknown' }
      }
      Save-Devs $devs
      $devs = @(Refresh-Status)
      RespRaw $ctx ('{"ok":true,"devices":' + (Json-Array $devs) + '}')

    } elseif ($m -eq 'POST' -and $path -eq '/api/connect') {
      $b = Read-Body $req
      $d = Find-Dev $b.id
      if (-not $d) { RespJson $ctx @{ ok = $false; msg = 'device not found' }; continue }
      $r = Launch $d
      RespJson $ctx @{ ok = $r.ok; msg = [string]$r.msg; target = [string]$r.target }

    } elseif ($m -eq 'POST' -and $path -eq '/api/upload') {
      # this name lands on disk and then inside an adb command line: keep it boring
      $name = [System.IO.Path]::GetFileName([string]$req.QueryString['name'])
      $name = ($name -replace '[^A-Za-z0-9._\-]', '_')
      if ($name.Length -gt 100) { $name = $name.Substring(0, 100) }
      if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9._\-]*\.apk$') { $name = 'app.apk' }
      $MAXUP = 1073741824   # 1 GB
      if ($req.ContentLength64 -gt $MAXUP) { RespJson $ctx @{ ok = $false; msg = 'apk too large (max 1 GB)' }; continue }
      $upDir = Join-Path $BASE 'uploads'
      if (-not (Test-Path $upDir)) { New-Item -ItemType Directory -Path $upDir -Force | Out-Null }
      $dest = Join-Path $upDir $name
      $total = 0
      $fs = [System.IO.File]::Create($dest)
      try {
        $buf = New-Object byte[] 65536
        while (($n = $req.InputStream.Read($buf, 0, $buf.Length)) -gt 0) {
          $total += $n
          if ($total -gt $MAXUP) { break }
          $fs.Write($buf, 0, $n)
        }
      } finally { $fs.Close() }
      if ($total -gt $MAXUP) {
        try { Remove-Item $dest -Force -ErrorAction SilentlyContinue } catch {}
        RespJson $ctx @{ ok = $false; msg = 'apk too large (max 1 GB)' }
        continue
      }
      RespJson $ctx @{ ok = $true; file = $name; size = $total }

    } elseif ($m -eq 'POST' -and $path -eq '/api/install') {
      $b = Read-Body $req
      $d = Find-Dev $b.id
      if (-not $d) { RespJson $ctx @{ ok = $false; msg = 'device not found' }; continue }
      $fname = [System.IO.Path]::GetFileName([string]$b.file)
      if ($fname -notmatch '^[A-Za-z0-9][A-Za-z0-9._\-]*\.apk$') { RespJson $ctx @{ ok = $false; msg = 'bad file name' }; continue }
      $apk = Join-Path (Join-Path $BASE 'uploads') $fname
      if (-not (Test-Path $apk -PathType Leaf)) { RespJson $ctx @{ ok = $false; msg = 'apk not uploaded' }; continue }
      $t = Target $d
      & $ADB connect $t 2>$null | Out-Null
      $r = Invoke-Adb ('-s ' + $t + ' install -r "' + $apk + '"')
      $msg = ($r.out + ' ' + $r.err)
      $ok = ($msg -match 'Success')
      # uploads/ is a temp dir: drop the file either way, a failed install used to leak it
      try { Remove-Item $apk -Force -ErrorAction SilentlyContinue } catch {}
      if ($msg.Length -gt 400) { $msg = $msg.Substring(0, 400) }
      RespJson $ctx @{ ok = $ok; msg = $msg.Trim() }

    } elseif ($m -eq 'POST' -and $path -eq '/api/apps') {
      $b = Read-Body $req
      $d = Find-Dev $b.id
      if (-not $d) { RespJson $ctx @{ ok = $false; msg = 'device not found'; apps = @() }; continue }
      $t = Target $d
      & $ADB connect $t 2>$null | Out-Null

      $raw = Invoke-Adb ('-s ' + $t + ' shell pm list packages -f -3')
      $map = @{}
      foreach ($line in ($raw.out -split "`r?`n")) {
        # format: package:<apk-path>=<pkg>  -- the path contains '==', so split on the LAST '='
        if ($line -match '^package:(\S+)=(\S+)\s*$') {
          # the name becomes a cache dir and a temp file name: reject anything odd
          if (Valid-Pkg $matches[2]) { $map[$matches[2]] = $matches[1].Trim() }
        }
      }
      $pkgs = @($map.Keys)

      # app size (apk bytes) - batch 25 per call
      $sizes = @{}
      for ($i = 0; $i -lt $pkgs.Count; $i += 25) {
        $end = [Math]::Min($i + 24, $pkgs.Count - 1)
        $chunk = @($pkgs[$i..$end])
        $paths = @($chunk | ForEach-Object { '"' + $map[$_] + '"' })
        $r = Invoke-Adb ('-s ' + $t + ' shell wc -c ' + ($paths -join ' '))
        foreach ($line in ($r.out -split "`r?`n")) {
          if ($line -match '^\s*(\d+)\s+(/.*?)\s*$') { $sizes[$matches[2]] = [int64]$matches[1] }
        }
      }

      # labels + icons: pull each apk once, parse with local aapt, then cache.
      # (devices rarely ship aapt, so the local SDK tool is the reliable path)
      $labels = @{}
      $icons  = @{}
      $src    = 'pkg'
      $aapt   = Find-Aapt
      if ($aapt) {
        $src = 'local'
        $tmpDir = Join-Path $APPCACHE 'tmp'
        if (-not (Test-Path $tmpDir)) { New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null }
        $todo = @()
        foreach ($p in $pkgs) {
          $c = Get-AppCache $p
          if ($c -and $c.apkPath -eq $map[$p]) {
            if ($c.label) { $labels[$p] = [string]$c.label }
            if ($c.icon)  { $icons[$p]  = [string]$c.icon }
          } else { $todo += $p }
        }
        foreach ($p in $todo) {
          $apkPath = $map[$p]
          $tmpApk = Join-Path $tmpDir ($p + '.apk')
          try { Remove-Item $tmpApk -Force -ErrorAction SilentlyContinue } catch {}
          $null = Invoke-Adb ('-s ' + $t + ' pull "' + $apkPath + '" "' + $tmpApk + '"')
          if (-not (Test-Path $tmpApk)) { continue }
          $bg = Invoke-Proc $aapt ('dump badging "' + $tmpApk + '"')
          $pb = Parse-Badging $bg.out
          $iconFile = ''
          if ($pb.icon) {
            $dest = Extract-Icon $tmpApk $pb.icon (Join-Path $APPCACHE $p)
            if ($dest) { $iconFile = [System.IO.Path]::GetFileName($dest) }
          }
          if ($pb.label) { $labels[$p] = $pb.label }
          if ($iconFile)  { $icons[$p]  = $iconFile }
          $sz = 0
          if ($sizes.ContainsKey($apkPath)) { $sz = $sizes[$apkPath] }
          Set-AppCache $p @{ apkPath = $apkPath; label = $pb.label; icon = $iconFile; size = $sz }
          try { Remove-Item $tmpApk -Force -ErrorAction SilentlyContinue } catch {}
        }
      } else {
        # no local aapt: try the device's own aapt (labels only, no icons)
        $devAapt = (Invoke-Adb ('-s ' + $t + ' shell command -v aapt')).out.Trim()
        if ($devAapt -and $devAapt -notmatch 'not found' -and $devAapt -match 'aapt') {
          $src = 'aapt'
          for ($i = 0; $i -lt $pkgs.Count; $i += 10) {
            $end = [Math]::Min($i + 9, $pkgs.Count - 1)
            $chunk = @($pkgs[$i..$end])
            $paths = @($chunk | ForEach-Object { '"' + $map[$_] + '"' })
            $r = Invoke-Adb ('-s ' + $t + ' shell aapt dump badging ' + ($paths -join ' '))
            $cur = ''
            foreach ($line in ($r.out -split "`r?`n")) {
              if ($line -match "package:\s+name='([^']+)'") { $cur = $matches[1] }
              elseif ($line -match "application-label:'([^']*)'" -and $cur) { $labels[$cur] = $matches[1] }
            }
          }
        }
      }

      $apps = @()
      foreach ($p in $pkgs) {
        $path = $map[$p]
        $sz = 0
        if ($sizes.ContainsKey($path)) { $sz = $sizes[$path] }
        $nm = ''
        if ($labels.ContainsKey($p)) { $nm = [string]$labels[$p] }
        $ic = 0
        if ($icons.ContainsKey($p)) { $ic = 1 }
        $apps += [pscustomobject]@{ pkg = $p; name = $nm; size = $sz; icon = $ic }
      }
      $apps = @($apps | Sort-Object { if ($_.name) { $_.name } else { $_.pkg } })
      RespRaw $ctx ('{"ok":true,"src":"' + $src + '","apps":' + (Json-Array $apps) + '}')

    } elseif ($m -eq 'GET' -and $path -eq '/api/icon') {
      $pkg = [string]$req.QueryString['pkg']
      $sent = $false
      if (Valid-Pkg $pkg) {
        $c = Get-AppCache $pkg
        if ($c -and $c.icon) {
          $f = Join-Path (Join-Path $APPCACHE $pkg) ([string]$c.icon)
          if (Test-Path $f) {
            $ext = [System.IO.Path]::GetExtension($f).ToLower()
            $ct = 'application/octet-stream'
            if ($ext -eq '.png') { $ct = 'image/png' }
            elseif ($ext -eq '.webp') { $ct = 'image/webp' }
            elseif ($ext -eq '.jpg' -or $ext -eq '.jpeg') { $ct = 'image/jpeg' }
            elseif ($ext -eq '.gif') { $ct = 'image/gif' }
            Resp $ctx 200 ([System.IO.File]::ReadAllBytes($f)) $ct
            $sent = $true
          }
        }
      }
      if (-not $sent) { Resp $ctx 404 ([System.Text.Encoding]::UTF8.GetBytes('no icon')) 'text/plain' }

    } elseif ($m -eq 'POST' -and $path -eq '/api/uninstall') {
      $b = Read-Body $req
      $d = Find-Dev $b.id
      if (-not $d) { RespJson $ctx @{ ok = $false; msg = 'device not found' }; continue }
      $t = Target $d
      $pkg = ([string]$b.pkg).Trim()
      # goes into "adb shell pm uninstall ...", i.e. straight to a shell on the device
      if (-not (Valid-Pkg $pkg)) { RespJson $ctx @{ ok = $false; msg = 'invalid package name' }; continue }
      $r = Invoke-Adb ('-s ' + $t + ' uninstall ' + $pkg)
      $msg = ($r.out + ' ' + $r.err).Trim()
      if ($msg -notmatch 'Success') {
        # preinstalled/system apps cannot be removed outright - uninstall for user 0
        $r2 = Invoke-Adb ('-s ' + $t + ' shell pm uninstall -k --user 0 ' + $pkg)
        $msg2 = ($r2.out + ' ' + $r2.err).Trim()
        if ($msg2 -match 'Success' -or $r2.code -eq 0) { $msg = $msg2 }
      }
      RespJson $ctx @{ ok = ($msg -match 'Success'); msg = $msg }

    } elseif ($m -eq 'DELETE' -and $path -eq '/api/devices') {
      $qid = $req.QueryString['id']
      $devs = @(@(Get-Devs) | Where-Object { $_.id -ne $qid })
      if ($devs.Count -eq 1 -and $null -eq $devs[0]) { $devs = @() }
      Save-Devs $devs
      RespRaw $ctx ('{"ok":true,"devices":' + (Json-Array $devs) + '}')

    } else {
      Resp $ctx 404 ([System.Text.Encoding]::UTF8.GetBytes('not found')) 'text/plain'
    }
  } catch {
    try {
      $msg = 'server error: ' + $_.Exception.Message
      Resp $ctx 500 ([System.Text.Encoding]::UTF8.GetBytes($msg)) 'text/plain'
    } catch {}
  }
}
