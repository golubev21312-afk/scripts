# ============================================================
#  porttimemachine.ps1  -  Port Time Machine v1.0
#  История использования портов — что когда висело и сколько
# ============================================================

$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$historyFile  = "$PSScriptRoot\porttimemachine-history.json"
$configPath   = "$PSScriptRoot\killdevs-config.ps1"
$pollInterval = 5
$maxHistory   = 2000   # максимум записей, старые обрезаются

$activePorts  = @{}   # Port → PSCustomObject
$history      = [System.Collections.Generic.List[object]]::new()
$monitorStart = Get-Date

$systemProcs = @(
    "svchost","System","lsass","wininit","services","spoolsv",
    "explorer","RuntimeBroker","SearchApp","TextInputHost",
    "ShellExperienceHost","StartMenuExperienceHost","ctfmon","sihost",
    "taskhostw","dwm","winlogon","csrss","smss","MemCompression",
    "Registry","Idle","MsMpEng","NisSrv","SecurityHealthService",
    "WmiPrvSE","dllhost","conhost","audiodg","fontdrvhost",
    "LockApp","ApplicationFrameHost","BackgroundTransferHost"
)

# ── История: загрузка / сохранение ───────────────────────────────────────────

function Load-History {
    if (-not (Test-Path $historyFile)) { return }
    try {
        $raw = Get-Content $historyFile -Raw -ErrorAction Stop | ConvertFrom-Json
        foreach ($item in $raw) {
            $history.Add([PSCustomObject]@{
                Port      = [int]$item.Port
                Process   = [string]$item.Process
                PID       = [int]$item.PID
                StartTime = [datetime]$item.StartTime
                EndTime   = [datetime]$item.EndTime
                Duration  = [string]$item.Duration
            })
        }
    } catch {}
}

function Save-History {
    try {
        $toSave = if ($history.Count -gt $maxHistory) {
            $history.GetRange($history.Count - $maxHistory, $maxHistory)
        } else { $history }
        $toSave | ConvertTo-Json -Depth 3 | Out-File -FilePath $historyFile -Encoding utf8
    } catch {}
}

# ── Helpers ───────────────────────────────────────────────────────────────────

function Format-Duration {
    param([datetime]$from, [datetime]$to)
    $s = [int]($to - $from).TotalSeconds
    if ($s -ge 3600) { return ("{0}ч {1}мин" -f [int]($s/3600), [int](($s%3600)/60)) }
    if ($s -ge 60)   { return ("{0}мин {1}с"  -f [int]($s/60), ($s%60)) }
    return ("{0}с" -f $s)
}

function Format-Date {
    param([datetime]$dt)
    $today     = (Get-Date).Date
    $yesterday = $today.AddDays(-1)
    if ($dt.Date -eq $today)     { return "сегодня  " + $dt.ToString("HH:mm") }
    if ($dt.Date -eq $yesterday) { return "вчера    " + $dt.ToString("HH:mm") }
    return $dt.ToString("dd.MM    HH:mm")
}

function Get-HistorySlice {
    param([int]$count)
    if ($history.Count -eq 0) { return @() }
    $take = [math]::Min($count, $history.Count)
    return $history.GetRange($history.Count - $take, $take).ToArray() |
           Sort-Object StartTime -Descending
}

# ── Опрос портов ─────────────────────────────────────────────────────────────

function Poll-Ports {
    $now     = Get-Date
    $current = @{}

    try {
        Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
            Where-Object { $_.LocalPort -ge 1024 -and $_.LocalPort -lt 49000 } |
            ForEach-Object {
                $port = $_.LocalPort
                $pid_ = $_.OwningProcess
                if (-not $current.ContainsKey($port)) {
                    $proc  = Get-Process -Id $pid_ -ErrorAction SilentlyContinue
                    $pname = if ($proc) { $proc.ProcessName } else { "?" }
                    if ($systemProcs -notcontains $pname) {
                        $current[$port] = @{ Process=$pname; PID=$pid_ }
                    }
                }
            }
    } catch {}

    # Новые порты
    foreach ($port in $current.Keys) {
        if (-not $activePorts.ContainsKey($port)) {
            $activePorts[$port] = [PSCustomObject]@{
                Port      = $port
                Process   = $current[$port].Process
                PID       = $current[$port].PID
                StartTime = $now
            }
        }
    }

    # Закрытые порты → пишем в историю
    $changed = $false
    foreach ($port in @($activePorts.Keys)) {
        if (-not $current.ContainsKey($port)) {
            $entry = $activePorts[$port]
            $dur   = Format-Duration $entry.StartTime $now
            $history.Add([PSCustomObject]@{
                Port      = $port
                Process   = $entry.Process
                PID       = $entry.PID
                StartTime = $entry.StartTime
                EndTime   = $now
                Duration  = $dur
            })
            $activePorts.Remove($port)
            $changed = $true
        }
    }

    if ($changed) { Save-History }
}

# ── Вьюхи ────────────────────────────────────────────────────────────────────

function Draw-Live {
    $now = Get-Date
    Clear-Host
    Write-Host ""
    Write-Host "  ===========================================" -ForegroundColor Cyan
    Write-Host "     PORT TIME MACHINE  v1.0               " -ForegroundColor Cyan
    Write-Host "  ===========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host ("  Записей: " + $history.Count + "   [H] История   [F] Поиск   [S] Статистика   [Q] Выход") -ForegroundColor DarkGray
    Write-Host ""

    Write-Host "  СЕЙЧАС ОТКРЫТО" -ForegroundColor Yellow
    Write-Host "  ──────────────────────────────────────────────────────" -ForegroundColor DarkGray

    if ($activePorts.Count -eq 0) {
        Write-Host "  Нет активных портов в диапазоне 1024–49000." -ForegroundColor DarkGray
    } else {
        Write-Host "  Порт      Процесс          PID        Работает" -ForegroundColor DarkGray
        foreach ($port in ($activePorts.Keys | Sort-Object)) {
            $p   = $activePorts[$port]
            $dur = Format-Duration $p.StartTime $now
            Write-Host ("  " + $port.ToString().PadRight(10) + $p.Process.PadRight(18) + $p.PID.ToString().PadRight(11) + $dur) -ForegroundColor White
        }
    }

    Write-Host ""
    Write-Host "  ПОСЛЕДНИЕ СЕССИИ" -ForegroundColor DarkGray
    Write-Host "  ──────────────────────────────────────────────────────" -ForegroundColor DarkGray

    $recent = Get-HistorySlice 8
    if ($recent.Count -eq 0) {
        Write-Host "  История пуста. Записи появятся когда порты начнут закрываться." -ForegroundColor DarkGray
    } else {
        Write-Host "  Когда              Порт      Процесс          Работал" -ForegroundColor DarkGray
        foreach ($h in $recent) {
            Write-Host ("  " + (Format-Date $h.StartTime).PadRight(19) + $h.Port.ToString().PadRight(10) + $h.Process.PadRight(18) + $h.Duration) -ForegroundColor DarkGray
        }
    }

    Write-Host ""
}

function Show-History {
    Clear-Host
    Write-Host ""
    Write-Host "  ===========================================" -ForegroundColor Cyan
    Write-Host "     PORT TIME MACHINE — ИСТОРИЯ            " -ForegroundColor Cyan
    Write-Host "  ===========================================" -ForegroundColor Cyan
    Write-Host ""

    $slice = Get-HistorySlice 60

    if ($slice.Count -eq 0) {
        Write-Host "  История пуста." -ForegroundColor DarkGray
    } else {
        Write-Host ("  " + [math]::Min(60, $history.Count) + " из " + $history.Count + " записей:") -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "  Когда              Порт      Процесс          Работал" -ForegroundColor DarkGray
        Write-Host "  ──────────────────────────────────────────────────────" -ForegroundColor DarkGray
        foreach ($h in $slice) {
            $col = if ($h.StartTime.Date -eq (Get-Date).Date) { "White" } else { "DarkGray" }
            Write-Host ("  " + (Format-Date $h.StartTime).PadRight(19) + $h.Port.ToString().PadRight(10) + $h.Process.PadRight(18) + $h.Duration) -ForegroundColor $col
        }
    }

    Write-Host ""
    Write-Host "  Нажми любую клавишу для возврата..." -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

function Show-Find {
    Clear-Host
    Write-Host ""
    Write-Host "  ===========================================" -ForegroundColor Cyan
    Write-Host "     PORT TIME MACHINE — ПОИСК              " -ForegroundColor Cyan
    Write-Host "  ===========================================" -ForegroundColor Cyan
    Write-Host ""

    $query = Read-Host "  Порт или название процесса"
    if (-not $query) { return }
    $query = $query.Trim()

    Write-Host ""

    # Активные
    $activeHits = @($activePorts.Values | Where-Object {
        $_.Port.ToString() -eq $query -or $_.Process -match [regex]::Escape($query)
    })
    if ($activeHits.Count -gt 0) {
        Write-Host "  СЕЙЧАС АКТИВНО:" -ForegroundColor Green
        foreach ($a in $activeHits) {
            $dur = Format-Duration $a.StartTime (Get-Date)
            Write-Host ("  порт " + $a.Port + "   " + $a.Process + "   PID " + $a.PID + "   работает " + $dur) -ForegroundColor Green
        }
        Write-Host ""
    }

    # История
    $hits = @($history.ToArray() | Where-Object {
        $_.Port.ToString() -eq $query -or $_.Process -match [regex]::Escape($query)
    } | Sort-Object StartTime -Descending | Select-Object -First 50)

    if ($hits.Count -eq 0 -and $activeHits.Count -eq 0) {
        Write-Host "  Ничего не найдено." -ForegroundColor DarkGray
    } elseif ($hits.Count -gt 0) {
        Write-Host ("  ИСТОРИЯ (" + $hits.Count + " записей):") -ForegroundColor Yellow
        Write-Host "  Когда              Порт      Процесс          Работал" -ForegroundColor DarkGray
        Write-Host "  ──────────────────────────────────────────────────────" -ForegroundColor DarkGray
        foreach ($h in $hits) {
            Write-Host ("  " + (Format-Date $h.StartTime).PadRight(19) + $h.Port.ToString().PadRight(10) + $h.Process.PadRight(18) + $h.Duration) -ForegroundColor White
        }
    }

    Write-Host ""
    Write-Host "  Нажми любую клавишу для возврата..." -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

function Show-Stats {
    Clear-Host
    Write-Host ""
    Write-Host "  ===========================================" -ForegroundColor Cyan
    Write-Host "     PORT TIME MACHINE — СТАТИСТИКА         " -ForegroundColor Cyan
    Write-Host "  ===========================================" -ForegroundColor Cyan
    Write-Host ""

    $activeAsHistory = @($activePorts.Values | ForEach-Object {
        [PSCustomObject]@{ Port=$_.Port; Process=$_.Process; PID=$_.PID; StartTime=$_.StartTime; EndTime=(Get-Date); Duration="" }
    })
    $all = @($history.ToArray()) + $activeAsHistory

    if ($all.Count -eq 0) {
        Write-Host "  Недостаточно данных." -ForegroundColor DarkGray
    } else {
        # Топ портов
        Write-Host "  ТОП ПОРТОВ" -ForegroundColor Yellow
        Write-Host "  ──────────────────────────────────────────────────────" -ForegroundColor DarkGray
        Write-Host "  Порт      Процесс          Сессий    Последний раз" -ForegroundColor DarkGray
        $all | Group-Object Port | Sort-Object Count -Descending | Select-Object -First 10 | ForEach-Object {
            $last = $_.Group | Sort-Object StartTime -Descending | Select-Object -First 1
            Write-Host ("  " + $_.Name.PadRight(10) + $last.Process.PadRight(18) + $_.Count.ToString().PadRight(10) + (Format-Date $last.StartTime)) -ForegroundColor White
        }

        Write-Host ""

        # Топ процессов
        Write-Host "  ТОП ПРОЦЕССОВ" -ForegroundColor Yellow
        Write-Host "  ──────────────────────────────────────────────────────" -ForegroundColor DarkGray
        Write-Host "  Процесс          Сессий    Последний раз" -ForegroundColor DarkGray
        $all | Group-Object Process | Sort-Object Count -Descending | Select-Object -First 10 | ForEach-Object {
            $last = $_.Group | Sort-Object StartTime -Descending | Select-Object -First 1
            Write-Host ("  " + $_.Name.PadRight(18) + $_.Count.ToString().PadRight(10) + (Format-Date $last.StartTime)) -ForegroundColor White
        }

        Write-Host ""

        # Активность по дням (последние 14)
        Write-Host "  АКТИВНОСТЬ ПО ДНЯМ" -ForegroundColor Yellow
        Write-Host "  ──────────────────────────────────────────────────────" -ForegroundColor DarkGray
        $all | Group-Object { $_.StartTime.ToString("dd.MM.yyyy") } |
            Sort-Object Name -Descending | Select-Object -First 14 | ForEach-Object {
                $bar = "#" * [math]::Min($_.Count, 35)
                Write-Host ("  " + $_.Name.PadRight(14) + $bar + " " + $_.Count) -ForegroundColor DarkGray
            }
    }

    Write-Host ""
    Write-Host "  Нажми любую клавишу для возврата..." -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

# ──────────────── MAIN ────────────────

Load-History
Poll-Ports
Draw-Live

$exit = $false

try {
    while (-not $exit) {
        $waited = 0
        while ($waited -lt ($pollInterval * 1000)) {
            if ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                switch ($key.KeyChar.ToString().ToUpper()) {
                    "Q" { $exit = $true }
                    "H" { Show-History; Draw-Live; $waited = 0 }
                    "F" { Show-Find;    Draw-Live; $waited = 0 }
                    "S" { Show-Stats;   Draw-Live; $waited = 0 }
                }
                if ($exit) { break }
            }
            Start-Sleep -Milliseconds 200
            $waited += 200
        }

        if (-not $exit) {
            Poll-Ports
            Draw-Live
        }
    }
} finally {
    # Сохраняем текущие активные сессии как завершённые
    $now = Get-Date
    foreach ($port in @($activePorts.Keys)) {
        $entry = $activePorts[$port]
        $history.Add([PSCustomObject]@{
            Port      = $port
            Process   = $entry.Process
            PID       = $entry.PID
            StartTime = $entry.StartTime
            EndTime   = $now
            Duration  = Format-Duration $entry.StartTime $now
        })
    }
    Save-History

    Write-Host ""
    Write-Host ("  История сохранена: " + $history.Count + " записей.") -ForegroundColor Yellow
    Write-Host ("  " + $historyFile) -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Нажми любую клавишу..." -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}
