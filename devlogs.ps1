# ============================================================
#  devlogs.ps1  -  Dev Log Viewer v1.0
#  Живые логи всех серверов с подсветкой и фильтрацией
# ============================================================

$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# ── Настройки ──
$configPath   = "$PSScriptRoot\devlogs-config.ps1"
$logSavePath  = "$PSScriptRoot\devlogs-saved"

# Папки где искать .log файлы (добавляй свои)
$searchRoots = @(
    "$env:USERPROFILE\Desktop",
    "$env:USERPROFILE\Documents",
    "$env:USERPROFILE\Projects",
    "$env:USERPROFILE\dev",
    "$env:USERPROFILE\code",
    "C:\Projects",
    "C:\dev",
    "C:\work",
    "C:\Users\$env:USERNAME\AppData\Local\Temp"
)

# Загружаем пользовательский конфиг
$extraRoots = @()
if (Test-Path $configPath) { . $configPath }
$searchRoots = ($searchRoots + $extraRoots) | Where-Object { Test-Path $_ } | Select-Object -Unique

# Системные процессы — игнорируем
$systemProcs = @("svchost","System","lsass","wininit","services","spoolsv","jhi_service",
                 "explorer","RuntimeBroker","SearchApp","TextInputHost","ShellExperienceHost",
                 "StartMenuExperienceHost","ctfmon","sihost","taskhostw","dwm","winlogon",
                 "csrss","smss","MemCompression","Registry","Idle","MsMpEng","NisSrv",
                 "SecurityHealthService","WmiPrvSE","dllhost","conhost","audiodg","fontdrvhost")

$colors = @{
    Header  = "Cyan"
    Success = "Green"
    Warning = "Yellow"
    Danger  = "Red"
    Info    = "White"
    Muted   = "DarkGray"
    Error   = "Red"
    Warn    = "Yellow"
    Debug   = "DarkGray"
    Http2xx = "Green"
    Http4xx = "Yellow"
    Http5xx = "Red"
}

function Write-Header {
    Clear-Host
    Write-Host ""
    Write-Host "  ===========================================" -ForegroundColor $colors.Header
    Write-Host "     DEV LOGS  v1.0  -  Live Log Viewer     " -ForegroundColor $colors.Header
    Write-Host "  ===========================================" -ForegroundColor $colors.Header
    Write-Host ""
}

# ── Подсветка строки лога ──
function Write-ColoredLog {
    param([string]$line, [string]$prefix = "")

    $out = if ($prefix) { "  [" + $prefix + "]  " + $line } else { "  " + $line }

    # HTTP статусы
    if ($line -match "\b5\d{2}\b")         { Write-Host $out -ForegroundColor $colors.Http5xx; return }
    if ($line -match "\b4\d{2}\b")         { Write-Host $out -ForegroundColor $colors.Http4xx; return }
    if ($line -match "\b2\d{2}\b")         { Write-Host $out -ForegroundColor $colors.Http2xx; return }

    # Уровни логов
    if ($line -match "(?i)(error|fatal|exception|panic|critical|ERR)") { Write-Host $out -ForegroundColor $colors.Error; return }
    if ($line -match "(?i)(warn|warning|WARN)")                         { Write-Host $out -ForegroundColor $colors.Warn; return }
    if ($line -match "(?i)(debug|trace|verbose|DEBUG)")                 { Write-Host $out -ForegroundColor $colors.Debug; return }
    if ($line -match "(?i)(info|success|started|listening|ready|INFO)") { Write-Host $out -ForegroundColor $colors.Success; return }

    # Стек трейсы
    if ($line -match "^\s+at ")            { Write-Host $out -ForegroundColor $colors.Muted; return }

    Write-Host $out -ForegroundColor $colors.Info
}

# ── Найти все серверные процессы на портах ──
function Get-ServerProcesses {
    $found = @()
    $seen  = @{}
    try {
        Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Sort-Object LocalPort | ForEach-Object {
            $port_  = $_.LocalPort
            $pid_   = $_.OwningProcess
            if ($port_ -lt 49000 -and -not $seen.ContainsKey($pid_)) {
                $proc = Get-Process -Id $pid_ -ErrorAction SilentlyContinue
                if ($proc -and $systemProcs -notcontains $proc.ProcessName) {
                    $seen[$pid_] = $true
                    # Пробуем найти рабочую папку процесса
                    $workDir = $null
                    try {
                        $wmi = Get-CimInstance Win32_Process -Filter "ProcessId=$pid_" -ErrorAction SilentlyContinue
                        if ($wmi) { $workDir = Split-Path $wmi.ExecutablePath -Parent }
                    } catch {}

                    $found += [PSCustomObject]@{
                        Name    = $proc.ProcessName
                        PID     = $pid_
                        Port    = $port_
                        WorkDir = $workDir
                        RAM_MB  = [math]::Round($proc.WorkingSet64 / 1MB, 0)
                    }
                }
            }
        }
    } catch {}
    return $found
}

# ── Найти .log файлы рядом с процессом или в searchRoots ──
function Find-LogFiles {
    param([string]$workDir, [string]$procName)

    $logs = @()

    # 1. Сначала ищем рядом с исполняемым файлом
    if ($workDir -and (Test-Path $workDir)) {
        $nearby = Get-ChildItem -Path $workDir -Filter "*.log" -Recurse -Depth 3 -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime -Descending |
                  Select-Object -First 5
        $logs += $nearby
    }

    # 2. Ищем в searchRoots по имени процесса
    foreach ($root in $searchRoots) {
        $found = Get-ChildItem -Path $root -Filter "*.log" -Recurse -Depth 4 -ErrorAction SilentlyContinue |
                 Where-Object { $_.FullName -match $procName -or $_.Directory.Name -match $procName } |
                 Sort-Object LastWriteTime -Descending |
                 Select-Object -First 3
        $logs += $found
    }

    # 3. Общий поиск свежих .log файлов в searchRoots
    if ($logs.Count -eq 0) {
        foreach ($root in $searchRoots) {
            $found = Get-ChildItem -Path $root -Filter "*.log" -Recurse -Depth 4 -ErrorAction SilentlyContinue |
                     Where-Object { $_.LastWriteTime -gt (Get-Date).AddHours(-24) } |
                     Sort-Object LastWriteTime -Descending |
                     Select-Object -First 3
            $logs += $found
        }
    }

    return $logs | Sort-Object LastWriteTime -Descending | Select-Object -Unique -First 5
}

# ── Живой просмотр логов процесса ──
function Start-LogViewer {
    param($server)

    Clear-Host
    Write-Host ""
    Write-Host "  ===========================================" -ForegroundColor $colors.Header
    Write-Host ("  ЛОГИ: " + $server.Name + "  (PID " + $server.PID + ", порт " + $server.Port + ")") -ForegroundColor $colors.Header
    Write-Host "  ===========================================" -ForegroundColor $colors.Header
    Write-Host "  Ctrl+C = выход  |  Цвета: " -NoNewline -ForegroundColor $colors.Muted
    Write-Host "ERROR " -NoNewline -ForegroundColor $colors.Error
    Write-Host "WARN " -NoNewline -ForegroundColor $colors.Warn
    Write-Host "INFO " -NoNewline -ForegroundColor $colors.Success
    Write-Host "DEBUG " -NoNewline -ForegroundColor $colors.Debug
    Write-Host "2xx " -NoNewline -ForegroundColor $colors.Http2xx
    Write-Host "4xx " -NoNewline -ForegroundColor $colors.Http4xx
    Write-Host "5xx" -ForegroundColor $colors.Http5xx
    Write-Host "  ------------------------------------------" -ForegroundColor $colors.Muted
    Write-Host ""

    # Ищем лог-файлы
    $logFiles = Find-LogFiles -workDir $server.WorkDir -procName $server.Name

    if ($logFiles.Count -gt 0) {
        Write-Host ("  Найдено лог-файлов: " + $logFiles.Count) -ForegroundColor $colors.Muted
        foreach ($lf in $logFiles) {
            Write-Host ("    " + $lf.FullName) -ForegroundColor $colors.Muted
        }
        Write-Host ""
        Write-Host "  Режим: ФАЙЛ + STDOUT" -ForegroundColor $colors.Success
        Write-Host ""

        # Читаем последние 30 строк из каждого файла
        foreach ($lf in $logFiles) {
            Write-Host ("  === " + $lf.Name + " (последние строки) ===") -ForegroundColor $colors.Warning
            try {
                $tail = Get-Content $lf.FullName -Tail 30 -ErrorAction SilentlyContinue
                foreach ($line in $tail) {
                    Write-ColoredLog $line $lf.BaseName
                }
            } catch {}
        }

        Write-Host ""
        Write-Host "  === LIVE TAIL ===" -ForegroundColor $colors.Warning
        Write-Host ""

        # Живое слежение за файлами
        $jobs = @()
        foreach ($lf in $logFiles) {
            $lfPath = $lf.FullName
            $lfName = $lf.BaseName
            $job = Start-Job -ScriptBlock {
                param($path, $name)
                Get-Content $path -Wait -Tail 0 | ForEach-Object {
                    Write-Output ("LOG|" + $name + "|" + $_)
                }
            } -ArgumentList $lfPath, $lfName
            $jobs += $job
        }

        try {
            while ($true) {
                foreach ($job in $jobs) {
                    $output = Receive-Job $job -ErrorAction SilentlyContinue
                    foreach ($line in $output) {
                        if ($line -match "^LOG\|([^|]+)\|(.*)$") {
                            Write-ColoredLog $matches[2] $matches[1]
                        }
                    }
                }
                Start-Sleep -Milliseconds 300
            }
        } finally {
            foreach ($job in $jobs) {
                Stop-Job $job -ErrorAction SilentlyContinue
                Remove-Job $job -ErrorAction SilentlyContinue
            }
        }

    } else {
        # Нет файлов — пробуем читать stdout процесса через ETW/трассировку
        Write-Host "  Лог-файлы не найдены." -ForegroundColor $colors.Warning
        Write-Host "  Режим: STDOUT мониторинг" -ForegroundColor $colors.Info
        Write-Host ""
        Write-Host "  Совет: чтобы захватить stdout сервера, запусти его через devlogs:" -ForegroundColor $colors.Muted
        Write-Host "    node server.js 2>&1 | Tee-Object -FilePath server.log" -ForegroundColor $colors.Info
        Write-Host "    python app.py 2>&1 | Tee-Object -FilePath app.log" -ForegroundColor $colors.Info
        Write-Host "    go run main.go 2>&1 | Tee-Object -FilePath app.log" -ForegroundColor $colors.Info
        Write-Host ""
        Write-Host "  Или добавь папку проекта через [S] Настройки поиска." -ForegroundColor $colors.Muted
        Write-Host ""

        # Показываем Event Log ошибки связанные с процессом
        Write-Host "  === Windows Event Log (последние события) ===" -ForegroundColor $colors.Warning
        Write-Host ""
        try {
            $events = Get-EventLog -LogName Application -Newest 20 -ErrorAction SilentlyContinue |
                      Where-Object { $_.Source -match $server.Name -or $_.Message -match $server.Name }
            if ($events) {
                foreach ($ev in $events) {
                    $line = $ev.TimeGenerated.ToString("HH:mm:ss") + "  [" + $ev.EntryType + "]  " + $ev.Message.Split("`n")[0]
                    Write-ColoredLog $line $ev.Source
                }
            } else {
                Write-Host "  Событий не найдено." -ForegroundColor $colors.Muted
            }
        } catch {
            Write-Host "  Event Log недоступен." -ForegroundColor $colors.Muted
        }

        Write-Host ""
        Write-Host "  Нажми любую клавишу для возврата..." -ForegroundColor $colors.Muted
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    }
}

# ── Фильтр/поиск по логам ──
function Search-Logs {
    param($servers)

    Clear-Host
    Write-Host ""
    Write-Host "  ===========================================" -ForegroundColor $colors.Header
    Write-Host "     ПОИСК ПО ЛОГАМ                         " -ForegroundColor $colors.Header
    Write-Host "  ===========================================" -ForegroundColor $colors.Header
    Write-Host ""

    $query = Read-Host "  Поисковый запрос (например: error, 500, login)"
    if (-not $query) { return }

    Write-Host ""
    Write-Host ("  Ищем: '" + $query + "' во всех лог-файлах...") -ForegroundColor $colors.Warning
    Write-Host ""

    $totalFound = 0
    foreach ($server in $servers) {
        $logFiles = Find-LogFiles -workDir $server.WorkDir -procName $server.Name
        foreach ($lf in $logFiles) {
            try {
                $matches_ = Select-String -Path $lf.FullName -Pattern $query -ErrorAction SilentlyContinue
                if ($matches_) {
                    Write-Host ("  === " + $lf.Name + " (" + $matches_.Count + " совпадений) ===") -ForegroundColor $colors.Warning
                    foreach ($m in ($matches_ | Select-Object -Last 10)) {
                        Write-ColoredLog ("[строка " + $m.LineNumber + "]  " + $m.Line.Trim()) $lf.BaseName
                        $totalFound++
                    }
                    Write-Host ""
                }
            } catch {}
        }
    }

    if ($totalFound -eq 0) {
        Write-Host "  Ничего не найдено." -ForegroundColor $colors.Muted
    } else {
        Write-Host ("  Всего найдено: " + $totalFound + " совпадений") -ForegroundColor $colors.Success
    }

    Write-Host ""
    Write-Host "  Нажми любую клавишу для возврата..." -ForegroundColor $colors.Muted
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

# ── Настройки папок поиска ──
function Manage-SearchRoots {
    while ($true) {
        Clear-Host
        Write-Host ""
        Write-Host "  ===========================================" -ForegroundColor $colors.Header
        Write-Host "     ПАПКИ ПОИСКА ЛОГОВ                     " -ForegroundColor $colors.Header
        Write-Host "  ===========================================" -ForegroundColor $colors.Header
        Write-Host ""
        Write-Host "  Текущие папки:" -ForegroundColor $colors.Warning
        $j = 1
        foreach ($r in $searchRoots) {
            $exists = if (Test-Path $r) { "OK" } else { "не найдена" }
            $col    = if (Test-Path $r) { $colors.Success } else { $colors.Muted }
            Write-Host ("    " + $j + ".  " + $r + "  [" + $exists + "]") -ForegroundColor $col
            $j++
        }
        Write-Host ""
        Write-Host "  [D] Добавить папку" -ForegroundColor $colors.Success
        Write-Host "  [X] Удалить папку" -ForegroundColor $colors.Danger
        Write-Host "  [B] Назад" -ForegroundColor $colors.Muted
        Write-Host ""

        $c = Read-Host "  Выбор"
        switch ($c.ToUpper()) {
            "D" {
                $newPath = Read-Host "  Путь к папке (например: C:\MyProjects)"
                $newPath = $newPath.Trim().Trim('"')
                if ($newPath -and $searchRoots -notcontains $newPath) {
                    $script:extraRoots += $newPath
                    $script:searchRoots = ($searchRoots + $newPath) | Select-Object -Unique
                    Save-LogConfig
                    Write-Host ("  OK  Добавлено: " + $newPath) -ForegroundColor $colors.Success
                    Start-Sleep -Milliseconds 700
                }
            }
            "X" {
                $num = Read-Host "  Номер для удаления"
                $idx = [int]$num - 1
                if ($idx -ge 0 -and $idx -lt $searchRoots.Count) {
                    $removed = $searchRoots[$idx]
                    $script:searchRoots = $searchRoots | Where-Object { $_ -ne $removed }
                    $script:extraRoots  = $extraRoots  | Where-Object { $_ -ne $removed }
                    Save-LogConfig
                    Write-Host ("  OK  Удалено: " + $removed) -ForegroundColor $colors.Success
                    Start-Sleep -Milliseconds 700
                }
            }
            "B" { return }
        }
    }
}

function Save-LogConfig {
    $lines = @('# devlogs custom search roots')
    $lines += '$extraRoots = @('
    foreach ($r in $extraRoots) {
        $lines += ('    "' + $r + '"')
    }
    $lines += ')'
    $lines | Out-File -FilePath $configPath -Encoding utf8
}

# ── Сохранить все логи в файл ──
function Save-AllLogs {
    param($servers)
    if (-not (Test-Path $logSavePath)) {
        New-Item -ItemType Directory -Path $logSavePath | Out-Null
    }
    $timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm"
    $outFile   = "$logSavePath\logs_$timestamp.txt"
    $written   = 0
    foreach ($server in $servers) {
        $logFiles = Find-LogFiles -workDir $server.WorkDir -procName $server.Name
        foreach ($lf in $logFiles) {
            try {
                Add-Content $outFile ("=== " + $lf.FullName + " ===")
                Get-Content $lf.FullName -ErrorAction SilentlyContinue | Add-Content $outFile
                Add-Content $outFile ""
                $written++
            } catch {}
        }
    }
    if ($written -gt 0) {
        Write-Host ("  OK  Сохранено в: " + $outFile) -ForegroundColor $colors.Success
    } else {
        Write-Host "  Нечего сохранять — лог-файлы не найдены." -ForegroundColor $colors.Warning
    }
    Start-Sleep -Milliseconds 1200
}

# ──────────────── MAIN LOOP ────────────────

while ($true) {
    Write-Header

    Write-Host "  Сканирую порты..." -ForegroundColor $colors.Muted
    $servers = Get-ServerProcesses

    if ($servers.Count -eq 0) {
        Write-Host "  Активных серверов не найдено." -ForegroundColor $colors.Warning
        Write-Host ""
        Write-Host "  [S] Настройки папок поиска" -ForegroundColor $colors.Info
        Write-Host "  [Q] Выйти" -ForegroundColor $colors.Muted
        Write-Host ""
        $c = Read-Host "  Выбор"
        if ($c.ToUpper() -eq "S") { Manage-SearchRoots }
        elseif ($c.ToUpper() -eq "Q") { exit }
        continue
    }

    Write-Host ("  Найдено серверов: " + $servers.Count) -ForegroundColor $colors.Success
    Write-Host ""
    Write-Host "  #     Процесс         Порт      PID       RAM(MB)" -ForegroundColor $colors.Muted
    Write-Host "  --------------------------------------------------" -ForegroundColor $colors.Muted

    $i = 1
    foreach ($s in $servers) {
        $logFiles = Find-LogFiles -workDir $s.WorkDir -procName $s.Name
        $logMark  = if ($logFiles.Count -gt 0) { " [" + $logFiles.Count + " лог]" } else { "" }
        $row = "  " + $i.ToString().PadRight(6) + $s.Name.PadRight(16) + $s.Port.ToString().PadRight(10) + $s.PID.ToString().PadRight(10) + $s.RAM_MB.ToString() + $logMark
        $col = if ($logFiles.Count -gt 0) { $colors.Success } else { $colors.Warning }
        Write-Host $row -ForegroundColor $col
        $i++
    }

    Write-Host ""
    Write-Host "  --------------------------------------------------" -ForegroundColor $colors.Muted
    Write-Host ""
    Write-Host "  Введи номер сервера для просмотра логов" -ForegroundColor $colors.Info
    Write-Host "  [F] Поиск по всем логам" -ForegroundColor $colors.Info
    Write-Host "  [V] Сохранить все логи в файл" -ForegroundColor $colors.Info
    Write-Host "  [S] Настройки папок поиска" -ForegroundColor $colors.Info
    Write-Host "  [R] Обновить список" -ForegroundColor $colors.Muted
    Write-Host "  [Q] Выйти" -ForegroundColor $colors.Muted
    Write-Host ""

    $choice = Read-Host "  Выбор"

    if ($choice -match "^\d+$") {
        $idx = [int]$choice - 1
        if ($idx -ge 0 -and $idx -lt $servers.Count) {
            Start-LogViewer $servers[$idx]
        } else {
            Write-Host "  Номер не найден" -ForegroundColor $colors.Warning
            Start-Sleep -Milliseconds 700
        }
    } else {
        switch ($choice.ToUpper()) {
            "F" { Search-Logs $servers }
            "V" { Save-AllLogs $servers }
            "S" { Manage-SearchRoots }
            "R" { continue }
            "Q" { exit }
            default {
                Write-Host "  Неизвестная команда." -ForegroundColor $colors.Warning
                Start-Sleep -Milliseconds 700
            }
        }
    }
}
