# ============================================================
#  envguardian.ps1  -  Env Guardian v1.0
#  Следит за .env файлами — находит, проверяет, предупреждает
# ============================================================

$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$configPath  = "$PSScriptRoot\killdevs-config.ps1"
$logsConfig  = "$PSScriptRoot\devlogs-config.ps1"
$pollInterval = 10  # секунды между проверками

$watchedFiles = @{}   # path → PSCustomObject
$alerts       = [System.Collections.Generic.List[object]]::new()
$scanStart    = Get-Date

$searchRoots = @(
    "$env:USERPROFILE\Desktop", "$env:USERPROFILE\Documents",
    "$env:USERPROFILE\Projects", "$env:USERPROFILE\dev",
    "$env:USERPROFILE\code", "C:\Projects", "C:\dev", "C:\work"
)
$extraRoots = @()
if (Test-Path $logsConfig) { . $logsConfig }
$searchRoots = ($searchRoots + $extraRoots) | Where-Object { Test-Path $_ } | Select-Object -Unique

# Паттерны чувствительных данных
# Игнорируем комментарии (#) и пустые значения (KEY=)
$sensitivePatterns = @(
    @{ P = "(?i)^(password|passwd|pwd|pass)\s*=\s*(?!$|changeme|example|test|placeholder|your_|xxx|1234|qwerty|password)(\S.*)"; L = "Пароль" }
    @{ P = "(?i)^(secret|secret_key|app_secret|client_secret|private_key)\s*=\s*(?!\s*$)(.{8,})"; L = "Секретный ключ" }
    @{ P = "(?i)^(api_key|apikey|api_token|access_token|auth_token|bearer)\s*=\s*(?!\s*$)(.{8,})"; L = "API ключ / токен" }
    @{ P = "(?i)(postgres|mysql|mongodb|redis|amqp|jdbc)://[^:\s]+:[^@\s]+@"; L = "URL с паролем в строке" }
    @{ P = "AKIA[0-9A-Z]{16}"; L = "AWS Access Key" }
    @{ P = "eyJ[A-Za-z0-9_\-]{20,}\.[A-Za-z0-9_\-]{10,}"; L = "JWT токен" }
    @{ P = "(?i)^(stripe_secret|stripe_key).*=\s*sk_live_"; L = "Stripe LIVE ключ" }
    @{ P = "(?i)^(twilio_auth|sendgrid_api|mailgun_api|firebase_server).*=\s*(?!\s*$)(.{16,})"; L = "Сервисный API ключ" }
    @{ P = "(?i)^(database_url|db_url)\s*=\s*\S+://[^:\s]+:[^@\s]+@"; L = "БД URL с паролем" }
)

# ── Helpers ───────────────────────────────────────────────────────────────────

function Format-Path {
    param([string]$path)
    $parts = $path -split '\\'
    if ($parts.Count -gt 5) { return "...\" + ($parts[-4..-1] -join "\") }
    return $path
}

function Format-Duration {
    param([datetime]$from, [datetime]$to)
    $s = [int]($to - $from).TotalSeconds
    if ($s -ge 3600) { return ("{0}ч {1}мин" -f [int]($s/3600), [int](($s%3600)/60)) }
    if ($s -ge 60)   { return ("{0}мин" -f [int]($s/60)) }
    return ("{0}с" -f $s)
}

function Show-Notification {
    param([string]$title, [string]$message)
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $n = New-Object System.Windows.Forms.NotifyIcon
        $n.Icon            = [System.Drawing.SystemIcons]::Warning
        $n.BalloonTipTitle = $title
        $n.BalloonTipText  = $message
        $n.BalloonTipIcon  = "Warning"
        $n.Visible         = $true
        $n.ShowBalloonTip(6000)
        Start-Sleep -Milliseconds 200
        $n.Dispose()
    } catch {}
}

function Get-FileHash-MD5 {
    param([string]$path)
    try { return (Get-FileHash $path -Algorithm MD5 -ErrorAction Stop).Hash } catch { return "" }
}

# ── Проверка .gitignore ───────────────────────────────────────────────────────

function Test-GitIgnored {
    param([string]$filePath)

    $fileName = Split-Path $filePath -Leaf
    $dir      = Split-Path $filePath -Parent

    # Ищем .git вверх по дереву
    $gitRoot = $null
    $current = $dir
    while ($current) {
        if (Test-Path (Join-Path $current ".git")) { $gitRoot = $current; break }
        $parent = Split-Path $current -Parent
        if ($parent -eq $current) { break }
        $current = $parent
    }

    # Не в git-репозитории — не можем определить
    if (-not $gitRoot) { return "NOGIT" }

    # Проверяем все .gitignore от папки файла до корня репо
    $current = $dir
    while ($current) {
        $gi = Join-Path $current ".gitignore"
        if (Test-Path $gi) {
            $lines = Get-Content $gi -ErrorAction SilentlyContinue |
                     Where-Object { $_ -and -not $_.TrimStart().StartsWith("#") } |
                     ForEach-Object { $_.Trim() }
            foreach ($pat in $lines) {
                if ($pat -eq $fileName)          { return "IGNORED" }
                if ($pat -eq ".env")             { return "IGNORED" }
                if ($pat -eq "*.env" -and $fileName -match "\.env$")   { return "IGNORED" }
                if ($pat -eq ".env*" -and $fileName -match "^\.env")   { return "IGNORED" }
                if ($pat -eq ".env.*" -and $fileName -match "^\.env\."){ return "IGNORED" }
                if ($pat -eq "**/.env*")         { return "IGNORED" }
            }
        }
        if ($current -eq $gitRoot) { break }
        $parent = Split-Path $current -Parent
        if ($parent -eq $current) { break }
        $current = $parent
    }

    return "EXPOSED"   # в репо, но НЕ в .gitignore
}

# ── Сканирование содержимого файла ────────────────────────────────────────────

function Scan-EnvFile {
    param([string]$path)

    $findings = [System.Collections.Generic.List[object]]::new()
    $isExample = (Split-Path $path -Leaf) -match "\.(example|sample|template)$"

    if ($isExample) { return @{ Findings=$findings; IsExample=$true } }

    try {
        $lines = Get-Content $path -ErrorAction Stop
        $lineNum = 0
        foreach ($line in $lines) {
            $lineNum++
            $trimmed = $line.Trim()
            if ($trimmed.StartsWith("#") -or $trimmed -eq "") { continue }

            foreach ($sp in $sensitivePatterns) {
                if ($trimmed -match $sp.P) {
                    # Маскируем значение в отчёте — показываем только первые 4 символа
                    $masked = if ($matches[2] -and $matches[2].Length -gt 4) {
                        $matches[2].Substring(0, 4) + "****"
                    } else { "****" }
                    $findings.Add([PSCustomObject]@{
                        Line    = $lineNum
                        Label   = $sp.L
                        Preview = $masked
                    })
                    break
                }
            }
        }
    } catch {}

    return @{ Findings=$findings; IsExample=$false }
}

# ── Регистрация / обновление файла ───────────────────────────────────────────

function Register-EnvFile {
    param([string]$path, [bool]$isNew = $false)

    $lwt      = (Get-Item $path -ErrorAction SilentlyContinue).LastWriteTime
    $hash     = Get-FileHash-MD5 $path
    $giStatus = Test-GitIgnored $path
    $scan     = Scan-EnvFile $path

    $danger = $giStatus -eq "EXPOSED"
    $warn   = ($giStatus -eq "IGNORED" -or $giStatus -eq "NOGIT") -and $scan.Findings.Count -gt 0

    $status = if ($scan.IsExample)           { "EXAMPLE" }
              elseif ($danger)               { "DANGER"  }
              elseif ($warn)                 { "WARN"    }
              else                           { "SAFE"    }

    $watchedFiles[$path] = [PSCustomObject]@{
        Path      = $path
        Short     = Format-Path $path
        Name      = Split-Path $path -Leaf
        LWT       = $lwt
        Hash      = $hash
        GIStatus  = $giStatus
        Findings  = $scan.Findings
        IsExample = $scan.IsExample
        Status    = $status
    }

    # Алерты
    if ($isNew -and $danger) {
        $msg = (Split-Path $path -Leaf) + " НЕ в .gitignore!"
        $alerts.Add([PSCustomObject]@{ Time=(Get-Date); Msg=$msg; Color="Red" })
        Show-Notification "ENV GUARDIAN — ОПАСНОСТЬ" $msg
    } elseif ($isNew -and $scan.Findings.Count -gt 0 -and $giStatus -eq "IGNORED") {
        $msg = (Split-Path $path -Leaf) + " — найдено " + $scan.Findings.Count + " чувствительных значений"
        $alerts.Add([PSCustomObject]@{ Time=(Get-Date); Msg=$msg; Color="Yellow" })
    }
}

# ── Поиск .env файлов ────────────────────────────────────────────────────────

function Find-EnvFiles {
    $found = [System.Collections.Generic.List[string]]::new()
    foreach ($root in $searchRoots) {
        Get-ChildItem -Path $root -Recurse -Depth 6 -Force -ErrorAction SilentlyContinue |
            Where-Object {
                -not $_.PSIsContainer -and
                ($_.Name -match "^\.env" -or $_.Name -match "\.env$") -and
                $_.FullName -notmatch "\\(node_modules|\.git|vendor|__pycache__|\.venv|venv)\\"
            } |
            ForEach-Object { $found.Add($_.FullName) }
    }
    return $found | Select-Object -Unique
}

# ── Цикл мониторинга ─────────────────────────────────────────────────────────

function Poll-EnvFiles {
    $allPaths = Find-EnvFiles

    foreach ($path in $allPaths) {
        if (-not $watchedFiles.ContainsKey($path)) {
            Register-EnvFile -path $path -isNew $true
        } else {
            # Проверяем изменения
            $lwt = (Get-Item $path -ErrorAction SilentlyContinue).LastWriteTime
            if ($lwt -and $lwt -ne $watchedFiles[$path].LWT) {
                $oldStatus = $watchedFiles[$path].Status
                Register-EnvFile -path $path -isNew $false

                $newStatus = $watchedFiles[$path].Status
                $name = Split-Path $path -Leaf
                $msg  = $name + " изменён"
                if ($newStatus -eq "DANGER")  { $msg += " — НЕ в .gitignore!"; $color = "Red"    }
                elseif ($newStatus -eq "WARN") { $msg += " — найдены чувствительные данные";  $color = "Yellow" }
                else                          { $color = "DarkGray" }
                $alerts.Add([PSCustomObject]@{ Time=(Get-Date); Msg=$msg; Color=$color })
                if ($newStatus -in "DANGER","WARN") {
                    Show-Notification "ENV GUARDIAN" $msg
                }
            }
        }
    }
}

# ── Дэшборд ───────────────────────────────────────────────────────────────────

function Draw-Dashboard {
    $now      = Get-Date
    $uptime   = Format-Duration $scanStart $now
    $total    = $watchedFiles.Count
    $dangers  = @($watchedFiles.Values | Where-Object { $_.Status -eq "DANGER"  }).Count
    $warns    = @($watchedFiles.Values | Where-Object { $_.Status -eq "WARN"    }).Count
    $safe     = @($watchedFiles.Values | Where-Object { $_.Status -in "SAFE","EXAMPLE" }).Count

    $headerColor = if ($dangers -gt 0) { "Red" } elseif ($warns -gt 0) { "Yellow" } else { "Cyan" }

    Clear-Host
    Write-Host ""
    Write-Host "  ===========================================" -ForegroundColor $headerColor
    Write-Host "     ENV GUARDIAN  v1.0  -  .env Watchdog   " -ForegroundColor $headerColor
    Write-Host "  ===========================================" -ForegroundColor $headerColor
    Write-Host ""
    Write-Host ("  Мониторинг: " + $uptime + "   Файлов: " + $total + "   [Q] Выход   [R] Пересканировать") -ForegroundColor DarkGray
    Write-Host ""

    # Сводка
    $dangerStr = if ($dangers -gt 0) { "  DANGER: $dangers" } else { "" }
    $warnStr   = if ($warns   -gt 0) { "  WARN: $warns"    } else { "" }
    Write-Host ("  SAFE: $safe" + $warnStr + $dangerStr) -ForegroundColor $(
        if ($dangers -gt 0) { "Red" } elseif ($warns -gt 0) { "Yellow" } else { "Green" }
    )
    Write-Host ""

    Write-Host "  .ENV ФАЙЛЫ" -ForegroundColor Yellow
    Write-Host "  ─────────────────────────────────────────────────────────────────" -ForegroundColor DarkGray

    if ($watchedFiles.Count -eq 0) {
        Write-Host "  Файлов не найдено. Добавь папки проектов в devlogs-config.ps1" -ForegroundColor DarkGray
    } else {
        $sorted = $watchedFiles.Values | Sort-Object { switch ($_.Status) { "DANGER"{0}; "WARN"{1}; "SAFE"{2}; default{3} } }, Path

        foreach ($f in $sorted) {
            $statusStr   = ("[" + $f.Status.PadRight(7) + "]").PadRight(11)
            $statusColor = switch ($f.Status) {
                "DANGER"  { "Red"     }
                "WARN"    { "Yellow"  }
                "SAFE"    { "Green"   }
                "EXAMPLE" { "DarkGray"}
                default   { "White"   }
            }
            $giStr = switch ($f.GIStatus) {
                "IGNORED" { "gitignore:OK " }
                "EXPOSED" { "gitignore:NO!" }
                "NOGIT"   { "не в репо    " }
                default   { "             " }
            }
            $giColor = switch ($f.GIStatus) {
                "EXPOSED" { "Red" }; "IGNORED" { "DarkGray" }; default { "DarkGray" }
            }
            $findStr = if ($f.Findings.Count -gt 0) {
                "  секретов:" + $f.Findings.Count
            } else { "" }

            Write-Host -NoNewline ("  " + $statusStr + " ") -ForegroundColor $statusColor
            Write-Host -NoNewline ($giStr) -ForegroundColor $giColor
            Write-Host -NoNewline ("  " + $f.Short) -ForegroundColor White
            if ($findStr) { Write-Host $findStr -ForegroundColor Yellow } else { Write-Host "" }

            # Детали находок для DANGER/WARN
            if ($f.Status -in "DANGER","WARN" -and $f.Findings.Count -gt 0) {
                foreach ($fd in $f.Findings) {
                    Write-Host ("             строка " + $fd.Line.ToString().PadRight(5) + $fd.Label.PadRight(24) + $fd.Preview) -ForegroundColor DarkGray
                }
            }
        }
    }

    # Последние алерты
    if ($alerts.Count -gt 0) {
        Write-Host ""
        Write-Host "  СОБЫТИЯ" -ForegroundColor DarkGray
        Write-Host "  ─────────────────────────────────────────────────────────────────" -ForegroundColor DarkGray
        $recent = if ($alerts.Count -gt 6) { $alerts.GetRange($alerts.Count - 6, 6) } else { $alerts }
        foreach ($a in $recent) {
            Write-Host ("  [" + $a.Time.ToString("HH:mm:ss") + "]  " + $a.Msg) -ForegroundColor $a.Color
        }
    }

    Write-Host ""
}

# ──────────────── MAIN ────────────────

Write-Host "  Сканирую .env файлы..." -ForegroundColor Cyan
Poll-EnvFiles
Draw-Dashboard

$exit = $false

try {
    while (-not $exit) {
        $waited = 0
        while ($waited -lt ($pollInterval * 1000)) {
            if ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                if ($key.KeyChar -eq 'q' -or $key.KeyChar -eq 'Q') { $exit = $true; break }
                if ($key.KeyChar -eq 'r' -or $key.KeyChar -eq 'R') {
                    Write-Host "  Пересканирую..." -ForegroundColor DarkGray
                    Poll-EnvFiles
                    Draw-Dashboard
                    $waited = 0
                }
            }
            Start-Sleep -Milliseconds 200
            $waited += 200
        }

        if (-not $exit) {
            Poll-EnvFiles
            Draw-Dashboard
        }
    }
} finally {
    Write-Host ""
    Write-Host "  Мониторинг остановлен." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Нажми любую клавишу..." -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}
