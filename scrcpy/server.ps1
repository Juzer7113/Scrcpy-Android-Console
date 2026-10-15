param([switch]$NoBrowser)

# STB Console backend - zero dependency (Windows PowerShell 5.1 built-in HttpListener)
$BASE    = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ADB     = Join-Path $BASE 'adb.exe'
$SCRCPY  = Join-Path $BASE 'scrcpy.exe'
$DB      = Join-Path $BASE 'devices.json'
$PORT    = 8000

# SW-618 STB needs a specific hw encoder + all-I-frame workaround.
# Everything else (emulators, normal devices) uses scrcpy defaults.
$VIDEO_ARGS_SW618 = @(
  '--video-codec=h264',
  '--video-encoder=OMX.allwinner.video.encoder.avc',
  '--max-size=1280',
  '--max-fps=25',
  '--video-bit-rate=4M',
  '--video-codec-options=i-frame-interval=0'
)

function Video-Args-For($t) {
  $model = ''
  try { $model = (& $ADB -s $t shell getprop ro.product.model 2>$null | Out-String).Trim() } catch {}
  Write-Host ('[launch] device model = ' + $model)
  if ($model -match 'SW-?618' -or $model -match 'Amlogic\s+SW') {
    Write-Host '[launch] using SW-618 encoder workaround'
    return $VIDEO_ARGS_SW618
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
  $p = [System.Diagnostics.Process]::Start($psi)
  $o = $p.StandardOutput.ReadToEnd()
  $e = $p.StandardError.ReadToEnd()
  $p.WaitForExit(180000) | Out-Null
  return @{ code = $p.ExitCode; out = $o; err = $e }
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
    return $list
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
  $p = [System.Diagnostics.Process]::Start($psi)
  $o = $p.StandardOutput.ReadToEnd()
  $e = $p.StandardError.ReadToEnd()
  $p.WaitForExit(180000) | Out-Null
  return @{ code = $p.ExitCode; out = $o; err = $e }
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
  foreach ($d in $devs) {
    $t = Target $d
    if ($state.ContainsKey($t)) { $d.status = $state[$t] } else { $d.status = 'offline' }
  }
  Save-Devs $devs
  return @($devs)
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
  $arg = '-s ' + $t + ' --window-title="STB ' + $t + '" ' + ($vargs -join ' ')
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $SCRCPY
  $psi.Arguments = $arg
  $psi.WorkingDirectory = $BASE
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardError = $true
  try {
    $p = [System.Diagnostics.Process]::Start($psi)
  } catch {
    return @{ ok = $false; msg = 'cannot start scrcpy: ' + $_.Exception.Message }
  }
  Start-Sleep -Milliseconds 1200
  if ($p.HasExited) {
    $e = $p.StandardError.ReadToEnd()
    if (-not $e) { $e = 'scrcpy exited immediately (code ' + $p.ExitCode + ')' }
    Write-Host ('[launch] FAILED ' + $t + ' :: ' + ($e -replace "\s+", ' '))
    return @{ ok = $false; msg = $e }
  }
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
if (-not $NoBrowser) { Start-Process "http://127.0.0.1:$PORT" }

while ($listener.IsListening) {
  $ctx = $null
  try { $ctx = $listener.GetContext() } catch { continue }
  try {
    $req  = $ctx.Request
    $path = $req.Url.AbsolutePath
    $m    = $req.HttpMethod.ToUpper()

    if ($m -eq 'GET' -and ($path -eq '/' -or $path -eq '/index.html')) {
      $bytes = [System.IO.File]::ReadAllBytes((Join-Path $BASE 'index.html'))
      Resp $ctx 200 $bytes 'text/html; charset=utf-8'

    } elseif ($m -eq 'GET' -and $path -eq '/api/devices') {
      RespRaw $ctx ('{"ver":3,"devices":' + (Json-Array (Get-Devs)) + '}')

    } elseif ($path -eq '/api/status') {
      RespRaw $ctx ('{"ver":3,"devices":' + (Json-Array (Refresh-Status)) + '}')

    } elseif ($m -eq 'POST' -and $path -eq '/api/devices') {
      $sr  = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
      $raw = $sr.ReadToEnd(); $sr.Close()
      $b = @{}
      if ($raw) { try { $b = $raw | ConvertFrom-Json } catch { $b = @{} } }
      $ip   = [string]$b.ip
      $port = [string]$b.port; if (-not $port) { $port = '5555' }
      $name = [string]$b.name
      if (-not $ip) { RespJson $ctx @{ ok = $false; msg = 'IP is empty' }; continue }

      $devs = @(Get-Devs)
      $dup  = $false
      foreach ($d in $devs) {
        if ($d.ip -eq $ip -and [string]$d.port -eq $port) { $d.name = $name; $dup = $true }
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
      $name = [System.IO.Path]::GetFileName([string]$req.QueryString['name'])
      if (-not $name) { $name = 'app.apk' }
      $upDir = Join-Path $BASE 'uploads'
      if (-not (Test-Path $upDir)) { New-Item -ItemType Directory -Path $upDir | Out-Null }
      $dest = Join-Path $upDir $name
      $fs = [System.IO.File]::Create($dest)
      try { $req.InputStream.CopyTo($fs) } finally { $fs.Close() }
      RespJson $ctx @{ ok = $true; file = $name; size = (Get-Item $dest).Length }

    } elseif ($m -eq 'POST' -and $path -eq '/api/install') {
      $b = Read-Body $req
      $d = Find-Dev $b.id
      if (-not $d) { RespJson $ctx @{ ok = $false; msg = 'device not found' }; continue }
      $apk = Join-Path (Join-Path $BASE 'uploads') ([System.IO.Path]::GetFileName([string]$b.file))
      if (-not (Test-Path $apk)) { RespJson $ctx @{ ok = $false; msg = 'apk not uploaded' }; continue }
      $t = Target $d
      & $ADB connect $t 2>$null | Out-Null
      $r = Invoke-Adb ('-s ' + $t + ' install -r "' + $apk + '"')
      $msg = ($r.out + ' ' + $r.err)
      $ok = ($msg -match 'Success')
      if ($ok) { try { Remove-Item $apk -Force -ErrorAction SilentlyContinue } catch {} }
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
        if ($line -match '^package:(\S+)=(\S+)\s*$') { $map[$matches[2]] = $matches[1].Trim() }
      }
      $pkgs = @($map.Keys)

      # app size (apk bytes) - batch 25 per call
      $sizes = @{}
      for ($i = 0; $i -lt $pkgs.Count; $i += 25) {
        $end = [Math]::Min($i + 24, $pkgs.Count - 1)
        $chunk = @($pkgs[$i..$end])
        $paths = @($chunk | ForEach-Object { $map[$_] })
        $r = Invoke-Adb ('-s ' + $t + ' shell wc -c ' + ($paths -join ' '))
        foreach ($line in ($r.out -split "`r?`n")) {
          if ($line -match '^\s*(\d+)\s+(/\S+)\s*$') { $sizes[$matches[2]] = [int64]$matches[1] }
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
            $paths = @($chunk | ForEach-Object { $map[$_] })
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
      if ($pkg -match '^[A-Za-z0-9._]+$') {
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
      $pkg = [string]$b.pkg
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
