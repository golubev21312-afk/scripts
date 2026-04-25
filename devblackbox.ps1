# ============================================================
#  devblackbox.ps1  -  Dev Black Box v1.0
#  Бортовой журнал dev-сессии — пишет всё, отчёт при выходе
# ============================================================

$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$savePath     = "$PSScriptRoot\devblackbox-sessions"
$configPath   = "$PSScriptRoot\killdevs-config.ps1"
$logsConfig   = "$PSScriptRoot\devlogs-config.ps1"
$pollInterval = 4   # секунды между опросами

$sessionStart  = Get-Date
$events        = [System.Collections.Generic.List[object]]::new()
$trackedProcs  = @{}   # PID → PSCustomObject
$sessionPorts  = @{}   # Port → ProcessName (всё что видели за сессию)
$ramSamples    = [System.Collections.Generic.List[object]]::new()
$sessionErrors = [System.Collections.Generic.List[object]]::new()
$logPositions  = @{}   # path → byte offset (не читаем старые ошибки, только новые)

# Тот же список что у killdevs + пользовательский конфиг
$devProcessNames = @(
    "python","python3","pythonw","node","go","php","php-cgi",
    "ruby","rails","java","dotnet","cargo","rustc","deno","bun",
    "webpack","vite","esbuild","docker","docker-compose",
    "nginx","apache","httpd","mongod","mysqld","postgres","redis-server",
    "uvicorn","gunicorn","flask","air","reflex","gradle","mvn"
)
$customProcessNames = @()
if (Test-Path $configPath) { . $configPath }
$devProcessNames = ($devProcessNames + $customProcessNames) | Select-Object -Unique

# Папки для сканирования логов — берём из devlogs-config если есть
$searchRoots = @(
    "$env:USERPROFILE\Desktop", "$env:USERPROFILE\Documents",
    "$env:USERPROFILE\Projects", "$env:USERPROFILE\dev",
    "$env:USERPROFILE\code", "C:\Projects", "C:\dev", "C:\work"
)
$extraRoots = @()
if (Test-Path $logsConfig) { . $logsConfig }
$searchRoots = ($searchRoots + $extraRoots) | Where-Object { Test-Path $_ } | Select-Object -Unique

# ── Вспомогательные функции ───────────────────────────────────────────────────

function Format-Duration {
    param([datetime]$from, [datetime]$to)
    $s = [int]($to - $from).TotalSeconds
    if ($s -ge 3600) { return ("{0}ч {1}мин" -f [int]($s/3600), [int](($s % 3600)/60)) }
    if ($s -ge 60)   { return ("{0}мин {1}с"  -f [int]($s/60), ($s % 60)) }
    return ("{0}с" -f $s)
}

function Get-RamStats {
    $os = Get-CimInstance Win32_OperatingSystem
    $t  = [math]::Round($os.TotalVisibleMemorySize / 1024)
    $f  = [math]::Round($os.FreePhysicalMemory / 1024)
    $u  = $t - $f
    return @{ Total=$t; Free=$f; Used=$u; Pct=[math]::Round(($u / $t) * 100) }
}

function Get-PortMap {
    $map = @{}
    try {
        Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
            Where-Object { $_.LocalPort -lt 49000 } |
            ForEach-Object { if (-not $map.ContainsKey($_.OwningProcess)) { $map[$_.OwningProcess] = $_.LocalPort } }
    } catch {}
    return $map
}

function Add-Event {
    param([string]$type, [string]$msg, [string]$color = "White")
    $events.Add([PSCustomObject]@{ Time=(Get-Date); Type=$type; Msg=$msg; Color=$color })
}

# ── Опрос процессов ───────────────────────────────────────────────────────────

function Poll-Processes {
    $portMap = Get-PortMap
    $now     = Get-Date
    $live    = @{}

    foreach ($name in $devProcessNames) {
        Get-Process -Name $name -ErrorAction SilentlyContinue |
            ForEach-Object { $live[$_.Id] = $_ }
    }

    foreach ($pid_ in $live.Keys) {
        if (-not $trackedProcs.ContainsKey($pid_)) {
            $p    = $live[$pid_]
            $port = if ($portMap.ContainsKey($pid_)) { $portMap[$pid_] } else { $null }
            $trackedProcs[$pid_] = [PSCustomObject]@{
                Name=$p.ProcessName; PID=$pid_; Port=$port; StartTime=$now; StopTime=$null
            }
            if ($port) { $sessionPorts[$port] = $p.ProcessName }
            $pi = if ($port) { " → порт $port" } else { "" }
            Add-Event "START" ($p.ProcessName + " запущен (PID $pid_" + $pi + ")") "Green"
        } else {
            $proc = $trackedProcs[$pid_]
            if (-not $proc.Port -and $portMap.ContainsKey($pid_)) {
                $proc.Port = $portMap[$pid_]
                $sessionPorts[$proc.Port] = $proc.Name
                Add-Event "PORT" ($proc.Name + " занял порт " + $proc.Port) "Cyan"
            }
        }
    }

    foreach ($pid_ in @($trackedProcs.Keys)) {
        $proc = $trackedProcs[$pid_]
        if ($null -eq $proc.StopTime -and -not $live.ContainsKey($pid_)) {
            $proc.StopTime = $now
            $dur = Format-Duration $proc.StartTime $now
            $pi  = if ($proc.Port) { " (порт " + $proc.Port + ")" } else { "" }
            Add-Event "STOP" ($proc.Name + $pi + " завершён — жил " + $dur) "DarkYellow"
        }
    }
}

# ── Опрос RAM ─────────────────────────────────────────────────────────────────

function Poll-Ram {
    $ram  = Get-RamStats
    $prev = if ($ramSamples.Count -gt 0) { $ramSamples[$ramSamples.Count - 1].Pct } else { 0 }
    $ramSamples.Add([PSCustomObject]@{ Time=(Get-Date); Used=$ram.Used; Pct=$ram.Pct })
    if ($ram.Pct -ge 85 -and $prev -lt 85) {
        Add-Event "RAM" ("Пик RAM: " + $ram.Used + " MB (" + $ram.Pct + "%)") "Magenta"
    }
    return $ram
}

# ── Сканирование логов на ошибки ──────────────────────────────────────────────

function Scan-LogErrors {
    $pattern = "(?i)(error|fatal|exception|panic|critical)"
    $cutoff  = (Get-Date).AddMinutes(-5)

    foreach ($root in $searchRoots) {
        $files = Get-ChildItem -Path $root -Filter "*.log" -Recurse -Depth 4 -ErrorAction SilentlyContinue |
                 Where-Object { $_.LastWriteTime -gt $cutoff }

        foreach ($lf in $files) {
            $path    = $lf.FullName
            # Для новых файлов начинаем с конца — не тащим старые ошибки
            $lastPos = if ($logPositions.ContainsKey($path)) {
                $logPositions[$path]
            } else {
                try { (Get-Item $path -ErrorAction Stop).Length } catch { 0 }
            }

            try {
                $fs  = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
                $fs.Seek($lastPos, 'Begin') | Out-Null
                $rdr = New-Object System.IO.StreamReader($fs)
                while (-not $rdr.EndOfStream) {
                    $line = $rdr.ReadLine()
                    if ($line -match $pattern) {
                        $sessionErrors.Add([PSCustomObject]@{ Time=(Get-Date); Source=$lf.BaseName; Line=$line.Trim() })
                        $short = if ($line.Length -gt 55) { $line.Substring(0, 55) + "..." } else { $line.Trim() }
                        Add-Event "ERROR" ("[" + $lf.BaseName + "] " + $short) "Red"
                    }
                }
                $logPositions[$path] = $fs.Position
                $rdr.Close(); $fs.Close()
            } catch {}
        }
    }
}

# ── Дэшборд ───────────────────────────────────────────────────────────────────

function Draw-Dashboard {
    param($ram)
    $now      = Get-Date
    $duration = Format-Duration $sessionStart $now
    $alive    = @($trackedProcs.Values | Where-Object { $null -eq $_.StopTime }).Count
    $ramColor = if ($ram.Pct -gt 85) { "Red" } elseif ($ram.Pct -gt 65) { "Yellow" } else { "Green" }
    $bar      = ""
    $filled   = [math]::Round($ram.Pct / 5)
    for ($i = 0; $i -lt 20; $i++) { $bar += if ($i -lt $filled) { "#" } else { "-" } }

    Clear-Host
    Write-Host ""
    Write-Host "  ===========================================" -ForegroundColor Cyan
    Write-Host "     DEV BLACK BOX  v1.0  -  Session Logger " -ForegroundColor Cyan
    Write-Host "  ===========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host ("  " + $sessionStart.ToString("HH:mm:ss") + " → " + $now.ToString("HH:mm:ss") + "   (" + $duration + ")") -ForegroundColor DarkGray
    Write-Host ("  Процессов: " + $alive + " активных / " + $trackedProcs.Count + " за сессию   Ошибок: " + $sessionErrors.Count + "   Портов: " + $sessionPorts.Count) -ForegroundColor DarkGray
    Write-Host ("  RAM [" + $bar + "] " + $ram.Used + "/" + $ram.Total + " MB (" + $ram.Pct + "%)") -ForegroundColor $ramColor
    Write-Host ""
    Write-Host "  [Q] Завершить сессию и сохранить отчёт" -ForegroundColor DarkGray
    Write-Host "  ─────────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host ""

    $count  = $events.Count
    $skip   = if ($count -gt 28) { $count - 28 } else { 0 }
    $recent = if ($count -gt 0) { $events.GetRange($skip, $count - $skip) } else { @() }

    if ($recent.Count -eq 0) {
        Write-Host "  Ожидание событий..." -ForegroundColor DarkGray
    } else {
        foreach ($ev in $recent) {
            $icon = switch ($ev.Type) {
                "START" { "+" }; "STOP" { "-" }; "ERROR" { "!" }
                "RAM"   { "~" }; "PORT" { ":" }; default  { "·" }
            }
            Write-Host ("  " + $ev.Time.ToString("HH:mm:ss") + "  " + $icon + "  " + $ev.Msg) -ForegroundColor $ev.Color
        }
    }
}

# ── Генерация отчёта ──────────────────────────────────────────────────────────

function Export-Report {
    $now = Get-Date
    $dur = Format-Duration $sessionStart $now
    if (-not (Test-Path $savePath)) { New-Item -ItemType Directory -Path $savePath | Out-Null }

    $outFile = "$savePath\session_$(Get-Date -Format 'yyyy-MM-dd_HH-mm').txt"
    $sep     = "═" * 52
    $line    = "─" * 52
    $L       = [System.Collections.Generic.List[string]]::new()

    $L.Add($sep)
    $L.Add("  DEV BLACK BOX — " + $sessionStart.ToString("dd.MM.yyyy"))
    $L.Add("  Начало:            " + $sessionStart.ToString("HH:mm:ss"))
    $L.Add("  Конец:             " + $now.ToString("HH:mm:ss"))
    $L.Add("  Продолжительность: " + $dur)
    $L.Add($sep); $L.Add("")

    $L.Add("ПРОЦЕССЫ")
    $L.Add($line)
    $procs = @($trackedProcs.Values) | Sort-Object StartTime
    if ($procs.Count -gt 0) {
        foreach ($p in $procs) {
            $end    = if ($p.StopTime) { $p.StopTime } else { $now }
            $d      = Format-Duration $p.StartTime $end
            $ps     = if ($p.Port) { "  порт " + $p.Port } else { "" }
            $status = if ($p.StopTime) { "завершён" } else { "активен " }
            $L.Add("  " + $p.Name.PadRight(14) + $p.StartTime.ToString("HH:mm") + " → " + $end.ToString("HH:mm") + "  (" + $d + ")  [" + $status + "]" + $ps)
        }
    } else { $L.Add("  —") }
    $L.Add("")

    $L.Add("ПОРТЫ")
    $L.Add($line)
    if ($sessionPorts.Count -gt 0) {
        foreach ($port in ($sessionPorts.Keys | Sort-Object)) {
            $L.Add("  " + "$port".PadRight(8) + $sessionPorts[$port])
        }
    } else { $L.Add("  —") }
    $L.Add("")

    $L.Add("RAM")
    $L.Add($line)
    if ($ramSamples.Count -gt 0) {
        $peak    = ($ramSamples | Measure-Object -Property Used -Maximum).Maximum
        $avg     = [math]::Round(($ramSamples | Measure-Object -Property Used -Average).Average)
        $peakPct = ($ramSamples | Sort-Object Used -Descending | Select-Object -First 1).Pct
        $avgPct  = [math]::Round(($ramSamples | Measure-Object -Property Pct -Average).Average)
        $L.Add("  Пик:     $peak MB ($peakPct%)")
        $L.Add("  Среднее: $avg MB ($avgPct%)")
        $L.Add("  Замеров: " + $ramSamples.Count)
    } else { $L.Add("  —") }
    $L.Add("")

    $L.Add("ОШИБКИ В ЛОГАХ (" + $sessionErrors.Count + ")")
    $L.Add($line)
    if ($sessionErrors.Count -gt 0) {
        foreach ($e in $sessionErrors) {
            $s = if ($e.Line.Length -gt 75) { $e.Line.Substring(0, 75) + "..." } else { $e.Line }
            $L.Add("  " + $e.Time.ToString("HH:mm:ss") + "  [" + $e.Source + "]  " + $s)
        }
    } else { $L.Add("  Ошибок не обнаружено") }
    $L.Add("")

    $L.Add("ХРОНОЛОГИЯ (" + $events.Count + " событий)")
    $L.Add($line)
    foreach ($ev in $events) {
        $icon = switch ($ev.Type) {
            "START"{"+"}; "STOP"{"-"}; "ERROR"{"!"}; "RAM"{"~"}; "PORT"{":"}; default{"·"}
        }
        $L.Add("  " + $ev.Time.ToString("HH:mm:ss") + "  " + $icon + "  " + $ev.Msg)
    }
    $L.Add("")
    $L.Add($sep)
    $L.Add("  Отчёт создан: " + $now.ToString("dd.MM.yyyy HH:mm:ss"))
    $L.Add($sep)

    $L | Out-File -FilePath $outFile -Encoding utf8
    return $outFile
}

# ──────────────── MAIN ────────────────

if (-not (Test-Path $savePath)) { New-Item -ItemType Directory -Path $savePath | Out-Null }

Poll-Processes
$ram = Poll-Ram
Add-Event "INFO" "Сессия начата. Нажми Q для завершения и сохранения отчёта." "Green"
Draw-Dashboard $ram

$pollCount = 0
$exit      = $false

try {
    while (-not $exit) {
        $waited = 0
        while ($waited -lt ($pollInterval * 1000)) {
            if ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                if ($key.KeyChar -eq 'q' -or $key.KeyChar -eq 'Q') { $exit = $true; break }
            }
            Start-Sleep -Milliseconds 200
            $waited += 200
        }
        if ($exit) { break }

        Poll-Processes
        $pollCount++
        if ($pollCount % 3 -eq 0) { Scan-LogErrors }
        $ram = Poll-Ram
        Draw-Dashboard $ram
    }
} finally {
    Clear-Host
    Write-Host ""
    Write-Host "  ===========================================" -ForegroundColor Cyan
    Write-Host "     DEV BLACK BOX — ЗАВЕРШЕНИЕ СЕССИИ      " -ForegroundColor Cyan
    Write-Host "  ===========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Генерирую отчёт..." -ForegroundColor Yellow
    $reportFile = Export-Report
    Write-Host ""
    Write-Host ("  OK  Отчёт сохранён:") -ForegroundColor Green
    Write-Host ("      " + $reportFile) -ForegroundColor White
    Write-Host ""
    $dur = Format-Duration $sessionStart (Get-Date)
    Write-Host ("  Длительность: " + $dur + "   Событий: " + $events.Count + "   Процессов: " + $trackedProcs.Count + "   Ошибок: " + $sessionErrors.Count) -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Нажми любую клавишу..." -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}
