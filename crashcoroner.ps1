# ============================================================
#  crashcoroner.ps1  -  Crash Coroner v1.0
#  Ловит падение dev-процессов, пишет дело с уликами
# ============================================================

$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$casesPath    = "$PSScriptRoot\crashcoroner-cases"
$configPath   = "$PSScriptRoot\killdevs-config.ps1"
$logsConfig   = "$PSScriptRoot\devlogs-config.ps1"
$pollInterval = 2   # секунды — быстро, чтобы не упустить момент

$caseCounter  = 0
$cases        = [System.Collections.Generic.List[object]]::new()
$trackedProcs = @{}   # PID → PSCustomObject
$monitorStart = Get-Date

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

$searchRoots = @(
    "$env:USERPROFILE\Desktop", "$env:USERPROFILE\Documents",
    "$env:USERPROFILE\Projects", "$env:USERPROFILE\dev",
    "$env:USERPROFILE\code", "C:\Projects", "C:\dev", "C:\work"
)
$extraRoots = @()
if (Test-Path $logsConfig) { . $logsConfig }
$searchRoots = ($searchRoots + $extraRoots) | Where-Object { Test-Path $_ } | Select-Object -Unique

# ── Helpers ───────────────────────────────────────────────────────────────────

function Format-Duration {
    param([datetime]$from, [datetime]$to)
    $s = [int]($to - $from).TotalSeconds
    if ($s -ge 3600) { return ("{0}ч {1}мин" -f [int]($s/3600), [int](($s%3600)/60)) }
    if ($s -ge 60)   { return ("{0}мин {1}с"  -f [int]($s/60), ($s%60)) }
    return ("{0}с" -f $s)
}

function Get-RamStats {
    $os = Get-CimInstance Win32_OperatingSystem
    $t  = [math]::Round($os.TotalVisibleMemorySize / 1024)
    $f  = [math]::Round($os.FreePhysicalMemory / 1024)
    $u  = $t - $f
    return @{ Total=$t; Free=$f; Used=$u; Pct=[math]::Round(($u/$t)*100) }
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

function Show-Notification {
    param([string]$title, [string]$message)
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $n = New-Object System.Windows.Forms.NotifyIcon
        $n.Icon             = [System.Drawing.SystemIcons]::Warning
        $n.BalloonTipTitle  = $title
        $n.BalloonTipText   = $message
        $n.BalloonTipIcon   = "Warning"
        $n.Visible          = $true
        $n.ShowBalloonTip(6000)
        Start-Sleep -Milliseconds 200
        $n.Dispose()
    } catch {}
}

# ── Поиск лог-файлов процесса ─────────────────────────────────────────────────

function Find-ProcessLogs {
    param([string]$procName, [string]$workDir)
    $found = [System.Collections.Generic.List[string]]::new()

    if ($workDir -and (Test-Path $workDir)) {
        Get-ChildItem -Path $workDir -Filter "*.log" -Recurse -Depth 3 -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 5 |
            ForEach-Object { $found.Add($_.FullName) }
    }

    foreach ($root in $searchRoots) {
        $escaped = [regex]::Escape($procName)
        Get-ChildItem -Path $root -Filter "*.log" -Recurse -Depth 4 -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match $escaped -or $_.Directory.Name -match $escaped } |
            Sort-Object LastWriteTime -Descending | Select-Object -First 3 |
            ForEach-Object { if (-not $found.Contains($_.FullName)) { $found.Add($_.FullName) } }
    }

    return $found
}

function Get-ProcessWorkDir {
    param([int]$pid_)
    try {
        $wmi = Get-CimInstance Win32_Process -Filter "ProcessId=$pid_" -ErrorAction SilentlyContinue
        if ($wmi -and $wmi.ExecutablePath) { return Split-Path $wmi.ExecutablePath -Parent }
    } catch {}
    return $null
}

# ── Сбор улик при падении ─────────────────────────────────────────────────────

function Collect-Evidence {
    param($proc)

    $now      = Get-Date
    $lived    = Format-Duration $proc.StartTime $now
    $livedSec = [int]($now - $proc.StartTime).TotalSeconds
    $script:caseCounter++
    $caseNum  = $script:caseCounter

    $severity = if ($livedSec -lt 30)    { "CRITICAL" }
                elseif ($livedSec -lt 300) { "WARNING"  }
                else                      { "INFO"      }

    # Свидетели — другие dev-процессы в момент смерти
    $witnesses = @($trackedProcs.Values | Where-Object { $null -eq $_.StopTime -and $_.PID -ne $proc.PID })

    # Системная RAM
    $ram = Get-RamStats

    # Последние строки лог-файлов
    $logTails = [ordered]@{}
    foreach ($logPath in $proc.LogFiles) {
        if (Test-Path $logPath) {
            try {
                $tail = Get-Content $logPath -Tail 40 -ErrorAction SilentlyContinue
                if ($tail) { $logTails[$logPath] = $tail }
            } catch {}
        }
    }

    # Windows Event Log — события за последние 2 минуты
    $eventEntries = @()
    try {
        $cutoff = $now.AddMinutes(-2)
        $escaped = [regex]::Escape($proc.Name)
        $eventEntries = @(
            Get-EventLog -LogName Application -After $cutoff -ErrorAction SilentlyContinue |
                Where-Object { $_.Source -match $escaped -or $_.Message -match $escaped } |
                Select-Object -First 5
        )
    } catch {}

    # Собираем дело
    if (-not (Test-Path $casesPath)) { New-Item -ItemType Directory -Path $casesPath | Out-Null }
    $caseFile = "$casesPath\crash_" + $proc.Name + "_" + (Get-Date -Format "yyyy-MM-dd_HH-mm-ss") + ".txt"

    $sep  = "═" * 52
    $hr   = "─" * 52
    $L    = [System.Collections.Generic.List[string]]::new()

    $L.Add($sep)
    $L.Add("  CRASH CORONER — Дело #" + $caseNum.ToString("000"))
    $L.Add("  Жертва:      " + $proc.Name + "  (PID " + $proc.PID + ")")
    $L.Add("  Время:       " + $now.ToString("dd.MM.yyyy  HH:mm:ss"))
    $L.Add("  Прожил:      " + $lived + "  (с " + $proc.StartTime.ToString("HH:mm:ss") + ")")
    if ($proc.Port) { $L.Add("  Порт:        " + $proc.Port) }
    $L.Add("  Серьёзность: " + $severity)
    $L.Add($sep); $L.Add("")

    $L.Add("ОБСТОЯТЕЛЬСТВА")
    $L.Add($hr)
    $L.Add("  RAM процесса (последний замер): " + $proc.LastRAM_MB + " MB")
    $L.Add("  RAM системы в момент смерти:    " + $ram.Used + " MB / " + $ram.Total + " MB (" + $ram.Pct + "%)")
    if ($proc.WorkDir) { $L.Add("  Рабочая папка: " + $proc.WorkDir) }
    $L.Add("")

    if ($logTails.Count -gt 0) {
        foreach ($logPath in $logTails.Keys) {
            $logName = Split-Path $logPath -Leaf
            $L.Add("ПОСЛЕДНИЕ СТРОКИ ЛОГА  (" + $logName + ")")
            $L.Add($hr)
            foreach ($line in $logTails[$logPath]) { $L.Add("  " + $line) }
            $L.Add("")
        }
    } else {
        $L.Add("ЛОГИ")
        $L.Add($hr)
        $L.Add("  Лог-файлы не найдены.")
        $L.Add("  Совет: запускай серверы через Tee-Object для захвата вывода:")
        $L.Add("    node server.js 2>&1 | Tee-Object -FilePath app.log")
        $L.Add("")
    }

    $L.Add("СВИДЕТЕЛИ  (активные процессы в момент смерти)")
    $L.Add($hr)
    if ($witnesses.Count -gt 0) {
        foreach ($w in $witnesses) {
            $wPort = if ($w.Port) { "  порт " + $w.Port } else { "" }
            $wDur  = Format-Duration $w.StartTime $now
            $L.Add("  " + $w.Name.PadRight(16) + "PID " + $w.PID.ToString().PadRight(8) + $wPort + "  (работает " + $wDur + ")")
        }
    } else {
        $L.Add("  Других dev-процессов не было")
    }
    $L.Add("")

    if ($eventEntries.Count -gt 0) {
        $L.Add("WINDOWS EVENT LOG")
        $L.Add($hr)
        foreach ($ev in $eventEntries) {
            $msg = $ev.Message.Split("`n")[0].Trim()
            $msg = if ($msg.Length -gt 72) { $msg.Substring(0, 72) + "..." } else { $msg }
            $L.Add("  " + $ev.TimeGenerated.ToString("HH:mm:ss") + "  [" + $ev.EntryType + "]  " + $ev.Source + " — " + $msg)
        }
        $L.Add("")
    }

    $L.Add($sep)
    $L.Add("  Дело закрыто: " + $now.ToString("dd.MM.yyyy HH:mm:ss"))
    $L.Add($sep)

    $L | Out-File -FilePath $caseFile -Encoding utf8

    $cases.Add([PSCustomObject]@{
        Num      = $caseNum
        Time     = $now
        Name     = $proc.Name
        PID      = $proc.PID
        Lived    = $lived
        LivedSec = $livedSec
        Severity = $severity
        File     = $caseFile
    })

    $livedInfo = if ($livedSec -lt 30) { "прожил $lived — не запустился" } else { "прожил $lived" }
    Show-Notification ("CRASH CORONER — Дело #" + $caseNum) ($proc.Name + " упал  (" + $livedInfo + ")")

    return $caseFile
}

# ── Опрос процессов ───────────────────────────────────────────────────────────

function Poll-Processes {
    $portMap  = Get-PortMap
    $now      = Get-Date
    $live     = @{}
    $newCases = @()

    foreach ($name in $devProcessNames) {
        Get-Process -Name $name -ErrorAction SilentlyContinue |
            ForEach-Object { $live[$_.Id] = $_ }
    }

    # Новые процессы — регистрируем, сразу ищем логи
    foreach ($pid_ in $live.Keys) {
        if (-not $trackedProcs.ContainsKey($pid_)) {
            $p       = $live[$pid_]
            $port    = if ($portMap.ContainsKey($pid_)) { $portMap[$pid_] } else { $null }
            $workDir = Get-ProcessWorkDir $pid_
            $logs    = Find-ProcessLogs -procName $p.ProcessName -workDir $workDir

            $trackedProcs[$pid_] = [PSCustomObject]@{
                Name       = $p.ProcessName
                PID        = $pid_
                Port       = $port
                StartTime  = $now
                StopTime   = $null
                LastRAM_MB = [math]::Round($p.WorkingSet64 / 1MB)
                WorkDir    = $workDir
                LogFiles   = $logs
            }
        } else {
            $proc = $trackedProcs[$pid_]
            try { $proc.LastRAM_MB = [math]::Round($live[$pid_].WorkingSet64 / 1MB) } catch {}
            if (-not $proc.Port -and $portMap.ContainsKey($pid_)) { $proc.Port = $portMap[$pid_] }
        }
    }

    # Упавшие — немедленно собираем улики
    foreach ($pid_ in @($trackedProcs.Keys)) {
        $proc = $trackedProcs[$pid_]
        if ($null -eq $proc.StopTime -and -not $live.ContainsKey($pid_)) {
            $proc.StopTime = $now
            $newCases += Collect-Evidence $proc
        }
    }

    return $newCases
}

# ── Дэшборд ───────────────────────────────────────────────────────────────────

function Draw-Dashboard {
    $now   = Get-Date
    $alive = @($trackedProcs.Values | Where-Object { $null -eq $_.StopTime })

    Clear-Host
    Write-Host ""
    Write-Host "  ===========================================" -ForegroundColor Cyan
    Write-Host "     CRASH CORONER  v1.0  -  Process Watcher" -ForegroundColor Cyan
    Write-Host "  ===========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host ("  Мониторинг: " + (Format-Duration $monitorStart $now) + "   Дел: " + $caseCounter + "   [Q] Выход") -ForegroundColor DarkGray
    Write-Host ""

    Write-Host "  НАБЛЮДАЮ" -ForegroundColor Yellow
    Write-Host "  ─────────────────────────────────────────────" -ForegroundColor DarkGray

    if ($alive.Count -eq 0) {
        Write-Host "  Активных dev-процессов нет. Жду..." -ForegroundColor DarkGray
    } else {
        Write-Host "  #     Процесс         PID       Порт      RAM(MB)   Время" -ForegroundColor DarkGray
        $i = 1
        foreach ($p in ($alive | Sort-Object StartTime)) {
            $dur  = Format-Duration $p.StartTime $now
            $port = if ($p.Port) { $p.Port.ToString() } else { "-" }
            $row  = "  " + $i.ToString().PadRight(6) + $p.Name.PadRight(16) +
                    $p.PID.ToString().PadRight(10) + $port.PadRight(10) +
                    $p.LastRAM_MB.ToString().PadRight(10) + $dur
            Write-Host $row -ForegroundColor White
            $i++
        }
    }
    Write-Host ""

    $caseLabel = if ($cases.Count -gt 0) { "ДЕЛА (" + $cases.Count + ")" } else { "ДЕЛА" }
    $caseColor = if ($cases.Count -gt 0) { "Red" } else { "DarkGray" }
    Write-Host ("  " + $caseLabel) -ForegroundColor $caseColor
    Write-Host "  ─────────────────────────────────────────────" -ForegroundColor DarkGray

    if ($cases.Count -eq 0) {
        Write-Host "  Пока чисто. Дай бог не будет." -ForegroundColor DarkGray
    } else {
        $recent = if ($cases.Count -gt 8) { $cases.GetRange($cases.Count - 8, 8) } else { $cases }
        foreach ($c in $recent) {
            $sevColor = switch ($c.Severity) { "CRITICAL"{"Red"}; "WARNING"{"Yellow"}; default{"DarkGray"} }
            Write-Host ("  [" + $c.Time.ToString("HH:mm:ss") + "]  #" + $c.Num.ToString("000") +
                        "  " + $c.Name.PadRight(14) + "прожил " + $c.Lived.PadRight(12) + "[" + $c.Severity + "]") -ForegroundColor $sevColor
        }
    }
    Write-Host ""
}

# ──────────────── MAIN ────────────────

if (-not (Test-Path $casesPath)) { New-Item -ItemType Directory -Path $casesPath | Out-Null }

Draw-Dashboard

$exit = $false

try {
    while (-not $exit) {
        $newCases = Poll-Processes
        Draw-Dashboard

        foreach ($cf in $newCases) {
            Write-Host ("  >> " + $cf) -ForegroundColor Red
        }
        if ($newCases.Count -gt 0) { Write-Host "" }

        $waited = 0
        while ($waited -lt ($pollInterval * 1000)) {
            if ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                if ($key.KeyChar -eq 'q' -or $key.KeyChar -eq 'Q') { $exit = $true; break }
            }
            Start-Sleep -Milliseconds 200
            $waited += 200
        }
    }
} finally {
    Write-Host ""
    Write-Host ("  Мониторинг остановлен. Дел за сессию: " + $caseCounter) -ForegroundColor Yellow
    if ($caseCounter -gt 0) {
        Write-Host ("  Дела сохранены в: " + $casesPath) -ForegroundColor White
    }
    Write-Host ""
    Write-Host "  Нажми любую клавишу..." -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}
