# ============================================================
#  killdevs.ps1  -  Smart Dev Process Killer v2.0
#  Новое: уведомления RAM, свои процессы, автозапуск при выключении
# ============================================================

$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# ── Конфиг файл для пользовательских процессов ──
$configPath = "$PSScriptRoot\killdevs-config.ps1"

# Базовые процессы
$defaultProcessNames = @(
    "python", "python3", "pythonw",
    "node",
    "go",
    "php", "php-cgi",
    "ruby", "rails",
    "java",
    "dotnet",
    "cargo", "rustc",
    "deno",
    "bun",
    "Code",
    "webpack", "vite", "esbuild",
    "docker", "docker-compose",
    "nginx", "apache", "httpd",
    "mongod", "mysqld", "postgres", "redis-server",
    "uvicorn", "gunicorn", "flask",
    "air", "reflex",
    "gradle", "mvn"
)

# Загружаем пользовательские процессы из конфига
$customProcessNames = @()
if (Test-Path $configPath) {
    . $configPath
}

$devProcessNames = ($defaultProcessNames + $customProcessNames) | Select-Object -Unique

# Порог RAM для уведомления (%)
$ramAlertThreshold = 80

$colors = @{
    Header  = "Cyan"
    Success = "Green"
    Warning = "Yellow"
    Danger  = "Red"
    Info    = "White"
    Muted   = "DarkGray"
}

# ── Balloon уведомление Windows ──
function Show-Notification {
    param([string]$title, [string]$message, [string]$icon = "Info")
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $notify = New-Object System.Windows.Forms.NotifyIcon
        $notify.Icon = [System.Drawing.SystemIcons]::Warning
        $notify.BalloonTipTitle = $title
        $notify.BalloonTipText  = $message
        $notify.BalloonTipIcon  = $icon
        $notify.Visible = $true
        $notify.ShowBalloonTip(5000)
        Start-Sleep -Milliseconds 200
        $notify.Dispose()
    } catch {}
}

function Write-Header {
    Clear-Host
    Write-Host ""
    Write-Host "  ===========================================" -ForegroundColor $colors.Header
    Write-Host "     DEV KILLER  v2.0  -  Process Manager   " -ForegroundColor $colors.Header
    Write-Host "  ===========================================" -ForegroundColor $colors.Header
    Write-Host ""
}

function Get-RamStats {
    $os = Get-CimInstance Win32_OperatingSystem
    $totalMB = [math]::Round($os.TotalVisibleMemorySize / 1024, 0)
    $freeMB  = [math]::Round($os.FreePhysicalMemory / 1024, 0)
    $usedMB  = $totalMB - $freeMB
    $usedPct = [math]::Round(($usedMB / $totalMB) * 100, 0)
    return @{ Total = $totalMB; Free = $freeMB; Used = $usedMB; Pct = $usedPct }
}

function Get-DevProcesses {
    $found = @()
    $allPorts = @{}

    # Метод 1: Get-NetTCPConnection
    try {
        Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | ForEach-Object {
            $pid_ = $_.OwningProcess
            $port_ = $_.LocalPort
            if ($port_ -lt 49000) {
                if ($allPorts.ContainsKey($pid_)) {
                    $allPorts[$pid_] = $allPorts[$pid_] + "," + $port_
                } else {
                    $allPorts[$pid_] = "$port_"
                }
            }
        }
    } catch {}

    # Метод 2: netstat как запасной
    if ($allPorts.Count -eq 0) {
        try {
            $ns = netstat -ano 2>$null | Select-String "LISTENING"
            foreach ($line in $ns) {
                $parts = $line.ToString().Trim() -split '\s+'
                if ($parts.Count -ge 5) {
                    $pid_ = [int]$parts[4]
                    if ($parts[1] -match ":(\d+)$") {
                        $port_ = [int]$matches[1]
                        if ($port_ -lt 49000) {
                            if ($allPorts.ContainsKey($pid_)) {
                                $allPorts[$pid_] = $allPorts[$pid_] + "," + $port_
                            } else {
                                $allPorts[$pid_] = "$port_"
                            }
                        }
                    }
                }
            }
        } catch {}
    }

    foreach ($name in $devProcessNames) {
        $procs = Get-Process -Name $name -ErrorAction SilentlyContinue
        foreach ($p in $procs) {
            $port = if ($allPorts.ContainsKey($p.Id)) { $allPorts[$p.Id] } else { "-" }
            $found += [PSCustomObject]@{
                Name   = $p.ProcessName
                PID    = $p.Id
                Port   = $port
                CPU    = [math]::Round($p.CPU, 1)
                RAM_MB = [math]::Round($p.WorkingSet64 / 1MB, 0)
            }
        }
    }
    return $found
}

function Show-ProcessTable {
    param($procs)
    Write-Host "  НАЙДЕННЫЕ DEV-ПРОЦЕССЫ:" -ForegroundColor $colors.Warning
    Write-Host ""
    Write-Host "  #     Процесс         PID       Порт      CPU(s)    RAM(MB)" -ForegroundColor $colors.Muted
    Write-Host "  ----------------------------------------------------------" -ForegroundColor $colors.Muted
    $i = 1
    foreach ($p in $procs) {
        $c = switch -Wildcard ($p.Name) {
            "python*" { "Blue" }
            "node"    { "Green" }
            "go"      { "Cyan" }
            "php*"    { "Magenta" }
            "ruby*"   { "Red" }
            "java"    { "Yellow" }
            "dotnet"  { "DarkCyan" }
            "deno"    { "DarkGreen" }
            "bun"     { "DarkYellow" }
            "Code"    { "Blue" }
            default   { "White" }
        }
        $row = "  " + $i.ToString().PadRight(6) + $p.Name.PadRight(16) + $p.PID.ToString().PadRight(10) + $p.Port.ToString().PadRight(10) + $p.CPU.ToString().PadRight(10) + $p.RAM_MB.ToString()
        Write-Host $row -ForegroundColor $c
        $i++
    }
    Write-Host ""
}

function Show-PortScan {
    Write-Host ""
    Write-Host "  ВСЕ ОТКРЫТЫЕ ПОРТЫ (LISTENING):" -ForegroundColor $colors.Warning
    Write-Host ""
    Write-Host "  Порт      PID       Процесс          Адрес" -ForegroundColor $colors.Muted
    Write-Host "  --------------------------------------------------" -ForegroundColor $colors.Muted
    try {
        Get-NetTCPConnection -State Listen -ErrorAction Stop | Sort-Object LocalPort | ForEach-Object {
            $pname = try { (Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).ProcessName } catch { "?" }
            $row = "  " + $_.LocalPort.ToString().PadRight(10) + $_.OwningProcess.ToString().PadRight(10) + $pname.PadRight(18) + $_.LocalAddress
            Write-Host $row -ForegroundColor $colors.Info
        }
    } catch {
        $lines = netstat -ano 2>$null | Select-String "LISTENING"
        foreach ($line in $lines) {
            $parts = $line.ToString().Trim() -split '\s+'
            if ($parts.Count -ge 5) {
                $addr  = $parts[1]
                $pid2  = $parts[4]
                $pname = try { (Get-Process -Id $pid2 -ErrorAction SilentlyContinue).ProcessName } catch { "?" }
                $row   = "  " + $addr.PadRight(32) + $pid2.PadRight(10) + $pname
                Write-Host $row -ForegroundColor $colors.Info
            }
        }
    }
    Write-Host ""
}

function Invoke-RamCleanup {
    Write-Host ""
    Write-Host "  ОЧИСТКА ОПЕРАТИВНОЙ ПАМЯТИ" -ForegroundColor $colors.Warning
    Write-Host ""

    $before = Get-RamStats
    Write-Host ("  До:  " + $before.Used + " MB / " + $before.Total + " MB  (" + $before.Pct + "%)") -ForegroundColor $colors.Info

    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]"Administrator")

    Write-Host ""
    Write-Host "  Шаг 1/3  Обрезка рабочих наборов процессов..." -ForegroundColor $colors.Muted
    $code = @'
using System;
using System.Runtime.InteropServices;
public class MemApi {
    [DllImport("kernel32.dll")]
    public static extern IntPtr OpenProcess(uint a, bool b, uint c);
    [DllImport("kernel32.dll")]
    public static extern bool SetProcessWorkingSetSize(IntPtr h, UIntPtr mn, UIntPtr mx);
    [DllImport("kernel32.dll")]
    public static extern bool CloseHandle(IntPtr h);
}
'@
    try {
        Add-Type -TypeDefinition $code -ErrorAction Stop
        $all = Get-Process | Where-Object { $_.Id -ne $PID }
        $trimmed = 0
        foreach ($p in $all) {
            try {
                $h = [MemApi]::OpenProcess(0x1F0FFF, $false, $p.Id)
                if ($h -ne [IntPtr]::Zero) {
                    [MemApi]::SetProcessWorkingSetSize($h, [UIntPtr]([uint64]0xFFFFFFFF), [UIntPtr]([uint64]0xFFFFFFFF)) | Out-Null
                    [MemApi]::CloseHandle($h) | Out-Null
                    $trimmed++
                }
            } catch {}
        }
        Write-Host ("  OK  Обрезано: " + $trimmed + " процессов") -ForegroundColor $colors.Success
    } catch {
        Write-Host "  FAIL  Не удалось обрезать рабочие наборы" -ForegroundColor $colors.Warning
    }

    Write-Host "  Шаг 2/3  Сборщик мусора .NET..." -ForegroundColor $colors.Muted
    try {
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
        [System.GC]::Collect()
        Write-Host "  OK  GC выполнен" -ForegroundColor $colors.Success
    } catch {
        Write-Host "  FAIL  GC не выполнен" -ForegroundColor $colors.Warning
    }

    Write-Host "  Шаг 3/3  Очистка Standby List..." -ForegroundColor $colors.Muted
    if ($isAdmin) {
        $ntCode = @'
using System;
using System.Runtime.InteropServices;
public class NtApi {
    [DllImport("ntdll.dll")]
    public static extern uint NtSetSystemInformation(int cls, IntPtr buf, int len);
}
'@
        try {
            Add-Type -TypeDefinition $ntCode -ErrorAction Stop
            $buf = [System.Runtime.InteropServices.Marshal]::AllocHGlobal(4)
            [System.Runtime.InteropServices.Marshal]::WriteInt32($buf, 4)
            $result = [NtApi]::NtSetSystemInformation(80, $buf, 4)
            [System.Runtime.InteropServices.Marshal]::FreeHGlobal($buf)
            if ($result -eq 0) {
                Write-Host "  OK  Standby List очищен" -ForegroundColor $colors.Success
            } else {
                Write-Host ("  ~  Standby List код: " + $result) -ForegroundColor $colors.Warning
            }
        } catch {
            Write-Host "  ~  Standby List недоступен" -ForegroundColor $colors.Warning
        }
    } else {
        Write-Host "  ~  Запусти от имени Администратора для полной очистки" -ForegroundColor $colors.Warning
    }

    Start-Sleep -Milliseconds 800
    $after = Get-RamStats
    $freed = $before.Used - $after.Used

    Write-Host ""
    Write-Host "  ------------------------------------------" -ForegroundColor $colors.Muted
    Write-Host ("  После: " + $after.Used + " MB / " + $after.Total + " MB  (" + $after.Pct + "%)") -ForegroundColor $colors.Info
    if ($freed -gt 0) {
        Write-Host ("  Освобождено: " + $freed + " MB") -ForegroundColor $colors.Success
    } else {
        Write-Host "  Значительного освобождения нет" -ForegroundColor $colors.Muted
    }
    Write-Host ""
}

# ── НОВОЕ: Управление своими процессами ──
function Manage-CustomProcesses {
    while ($true) {
        Clear-Host
        Write-Host ""
        Write-Host "  ===========================================" -ForegroundColor $colors.Header
        Write-Host "     СВОИ ПРОЦЕССЫ                          " -ForegroundColor $colors.Header
        Write-Host "  ===========================================" -ForegroundColor $colors.Header
        Write-Host ""
        Write-Host "  Базовых процессов в списке: " + $defaultProcessNames.Count -ForegroundColor $colors.Muted

        if ($customProcessNames.Count -gt 0) {
            Write-Host "  Твои процессы:" -ForegroundColor $colors.Warning
            $j = 1
            foreach ($cp in $customProcessNames) {
                Write-Host ("    " + $j + ".  " + $cp) -ForegroundColor $colors.Info
                $j++
            }
        } else {
            Write-Host "  Твои процессы: (пусто)" -ForegroundColor $colors.Muted
        }

        Write-Host ""
        Write-Host "  [D] Добавить процесс" -ForegroundColor $colors.Success
        Write-Host "  [X] Удалить процесс" -ForegroundColor $colors.Danger
        Write-Host "  [B] Назад" -ForegroundColor $colors.Muted
        Write-Host ""

        $c = Read-Host "  Выбор"
        switch ($c.ToUpper()) {
            "D" {
                Write-Host ""
                $newProc = Read-Host "  Имя процесса (без .exe, например: nginx)"
                $newProc = $newProc.Trim()
                if ($newProc -ne "") {
                    if ($customProcessNames -notcontains $newProc) {
                        $customProcessNames += $newProc
                        Save-Config
                        Write-Host ("  OK  Добавлен: " + $newProc) -ForegroundColor $colors.Success
                    } else {
                        Write-Host "  Уже есть в списке" -ForegroundColor $colors.Warning
                    }
                    Start-Sleep -Milliseconds 800
                }
            }
            "X" {
                if ($customProcessNames.Count -eq 0) {
                    Write-Host "  Список пуст" -ForegroundColor $colors.Warning
                    Start-Sleep -Milliseconds 800
                } else {
                    $num = Read-Host "  Номер для удаления"
                    $idx = [int]$num - 1
                    if ($idx -ge 0 -and $idx -lt $customProcessNames.Count) {
                        $removed = $customProcessNames[$idx]
                        $customProcessNames = $customProcessNames | Where-Object { $_ -ne $removed }
                        Save-Config
                        Write-Host ("  OK  Удалён: " + $removed) -ForegroundColor $colors.Success
                        Start-Sleep -Milliseconds 800
                    }
                }
            }
            "B" { return }
        }
    }
}

function Save-Config {
    $lines = @('# killdevs custom processes config')
    $lines += '$customProcessNames = @('
    foreach ($p in $customProcessNames) {
        $lines += ('    "' + $p + '"')
    }
    $lines += ')'
    $lines | Out-File -FilePath $configPath -Encoding utf8
}

# ── НОВОЕ: Автозапуск при выключении через Task Scheduler ──
function Manage-AutoShutdown {
    $taskName = "DevKiller-OnShutdown"
    $isAdmin  = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]"Administrator")

    Clear-Host
    Write-Host ""
    Write-Host "  ===========================================" -ForegroundColor $colors.Header
    Write-Host "     АВТОЗАПУСК ПРИ ВЫКЛЮЧЕНИИ              " -ForegroundColor $colors.Header
    Write-Host "  ===========================================" -ForegroundColor $colors.Header
    Write-Host ""

    if (-not $isAdmin) {
        Write-Host "  ВНИМАНИЕ: нужны права администратора!" -ForegroundColor $colors.Danger
        Write-Host "  Перезапусти скрипт от имени Администратора." -ForegroundColor $colors.Warning
        Write-Host ""
        Write-Host "  Нажми любую клавишу..." -ForegroundColor $colors.Muted
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        return
    }

    $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "  Статус: ВКЛЮЧЕН" -ForegroundColor $colors.Success
        Write-Host "  При каждом выключении/перезагрузке ПК все dev-процессы" -ForegroundColor $colors.Muted
        Write-Host "  будут автоматически завершены." -ForegroundColor $colors.Muted
        Write-Host ""
        Write-Host "  [R] Удалить автозапуск" -ForegroundColor $colors.Danger
        Write-Host "  [B] Назад" -ForegroundColor $colors.Muted
        Write-Host ""
        $c = Read-Host "  Выбор"
        if ($c.ToUpper() -eq "R") {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
            Write-Host "  OK  Автозапуск удалён" -ForegroundColor $colors.Success
            Start-Sleep -Milliseconds 1000
        }
    } else {
        Write-Host "  Статус: ВЫКЛЮЧЕН" -ForegroundColor $colors.Muted
        Write-Host ""
        Write-Host "  При включении: скрипт будет автоматически убивать" -ForegroundColor $colors.Info
        Write-Host "  все dev-процессы при каждом выключении/перезагрузке." -ForegroundColor $colors.Info
        Write-Host ""
        Write-Host "  [E] Включить автозапуск" -ForegroundColor $colors.Success
        Write-Host "  [B] Назад" -ForegroundColor $colors.Muted
        Write-Host ""
        $c = Read-Host "  Выбор"
        if ($c.ToUpper() -eq "E") {
            $scriptPath = $PSCommandPath
            # Создаём bat-обёртку для тихого запуска
            $batPath = "$PSScriptRoot\killdevs-silent.bat"
            $batContent = '@echo off' + "`r`n" + 'powershell -WindowStyle Hidden -ExecutionPolicy Bypass -Command "' + "& { . '" + $scriptPath + "'; foreach (`$n in `$devProcessNames) { Stop-Process -Name `$n -Force -ErrorAction SilentlyContinue } }" + '"'
            $batContent | Out-File -FilePath $batPath -Encoding ascii

            $action  = New-ScheduledTaskAction -Execute $batPath
            $trigger = New-ScheduledTaskTrigger -AtLogOff
            $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
            $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

            Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
            Write-Host "  OK  Автозапуск включён!" -ForegroundColor $colors.Success
            Write-Host "  Теперь при каждом выключении ПК dev-процессы будут убиты." -ForegroundColor $colors.Muted
            Start-Sleep -Milliseconds 1500
        }
    }
}

# ── НОВОЕ: Мониторинг RAM с уведомлениями ──
function Start-RamMonitor {
    Clear-Host
    Write-Host ""
    Write-Host "  ===========================================" -ForegroundColor $colors.Header
    Write-Host "     МОНИТОРИНГ RAM                         " -ForegroundColor $colors.Header
    Write-Host "  ===========================================" -ForegroundColor $colors.Header
    Write-Host ""
    Write-Host ("  Порог уведомления: " + $ramAlertThreshold + "%") -ForegroundColor $colors.Info
    Write-Host "  Обновление каждые 5 секунд." -ForegroundColor $colors.Muted
    Write-Host "  Нажми Ctrl+C для выхода." -ForegroundColor $colors.Muted
    Write-Host ""

    $alerted = $false
    while ($true) {
        $ram = Get-RamStats
        $ramColor = if ($ram.Pct -gt 85) { $colors.Danger } elseif ($ram.Pct -gt 65) { $colors.Warning } else { $colors.Success }
        $bar = ""
        $filled = [math]::Round($ram.Pct / 5)
        for ($i = 0; $i -lt 20; $i++) {
            if ($i -lt $filled) { $bar += "#" } else { $bar += "-" }
        }
        $timestamp = Get-Date -Format "HH:mm:ss"
        Write-Host ("  [" + $timestamp + "]  [" + $bar + "]  " + $ram.Used + " / " + $ram.Total + " MB  (" + $ram.Pct + "%)") -ForegroundColor $ramColor

        if ($ram.Pct -ge $ramAlertThreshold -and -not $alerted) {
            Show-Notification "DEV KILLER - RAM Alert!" ("Использовано " + $ram.Pct + "% памяти (" + $ram.Used + " MB / " + $ram.Total + " MB)")
            $alerted = $true
        } elseif ($ram.Pct -lt ($ramAlertThreshold - 5)) {
            $alerted = $false
        }

        Start-Sleep -Seconds 5
    }
}

# ── Автообнаружение незнакомых процессов на портах ──
function Invoke-AutoDiscover {
    # Системные процессы которые игнорируем
    $systemProcs = @("svchost","System","lsass","wininit","services","spoolsv","jhi_service",
                     "explorer","RuntimeBroker","SearchApp","TextInputHost","ShellExperienceHost",
                     "StartMenuExperienceHost","ctfmon","sihost","taskhostw","dwm","winlogon",
                     "csrss","smss","MemCompression","Registry","Idle","MsMpEng","NisSrv",
                     "SecurityHealthService","WmiPrvSE","dllhost","conhost","cmd","powershell",
                     "WindowsTerminal","wt","audiodg","fontdrvhost","igfxEM","igfxHK","igfxTray")

    $unknown = @()
    try {
        Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | ForEach-Object {
            $port_ = $_.LocalPort
            if ($port_ -lt 49000) {
                $pid_   = $_.OwningProcess
                $pname  = try { (Get-Process -Id $pid_ -ErrorAction SilentlyContinue).ProcessName } catch { $null }
                if ($pname -and
                    $devProcessNames -notcontains $pname -and
                    $systemProcs -notcontains $pname -and
                    ($unknown | Where-Object { $_.Name -eq $pname }).Count -eq 0) {
                    $unknown += [PSCustomObject]@{ Name = $pname; Port = $port_; PID = $pid_ }
                }
            }
        }
    } catch {}

    if ($unknown.Count -gt 0) {
        Write-Host ""
        Write-Host "  ОБНАРУЖЕНЫ НОВЫЕ ПРОЦЕССЫ НА ПОРТАХ:" -ForegroundColor $colors.Warning
        foreach ($u in $unknown) {
            Write-Host ("    " + $u.Name + "  (порт " + $u.Port + ", PID " + $u.PID + ")") -ForegroundColor $colors.Info
        }
        Write-Host ""
        Write-Host "  Добавить их в список для слежки? [Y/N]" -ForegroundColor $colors.Warning
        $ans = Read-Host "  Выбор"
        if ($ans.ToUpper() -eq "Y") {
            foreach ($u in $unknown) {
                if ($customProcessNames -notcontains $u.Name) {
                    $script:customProcessNames += $u.Name
                }
            }
            Save-Config
            $script:devProcessNames = ($defaultProcessNames + $script:customProcessNames) | Select-Object -Unique
            Write-Host ("  OK  Добавлено процессов: " + $unknown.Count) -ForegroundColor $colors.Success
            Write-Host ""
        }
    }
}

# ──────────────── MAIN ────────────────

Write-Header

$ram = Get-RamStats
$ramColor = if ($ram.Pct -gt 85) { $colors.Danger } elseif ($ram.Pct -gt 65) { $colors.Warning } else { $colors.Success }
Write-Host ("  RAM: " + $ram.Used + " MB / " + $ram.Total + " MB  (" + $ram.Pct + "%)") -ForegroundColor $ramColor

# Проверяем RAM при запуске и сразу уведомляем если высокая
if ($ram.Pct -ge $ramAlertThreshold) {
    Write-Host ("  ВНИМАНИЕ: RAM выше " + $ramAlertThreshold + "%!") -ForegroundColor $colors.Danger
    Show-Notification "DEV KILLER" ("RAM загружена на " + $ram.Pct + "%!")
}

Write-Host ""

# Автообнаружение незнакомых процессов
Invoke-AutoDiscover

$processes = Get-DevProcesses

if ($processes.Count -eq 0) {
    Write-Host "  Чисто! Нет активных dev-процессов." -ForegroundColor $colors.Success
    Write-Host ""
} else {
    Show-ProcessTable $processes
}

Write-Host "  ----------------------------------------------------------" -ForegroundColor $colors.Muted
Write-Host ""
Write-Host "  Что сделать?" -ForegroundColor $colors.Info
Write-Host ""
Write-Host "  [A] Убить ВСЕ процессы" -ForegroundColor $colors.Danger
Write-Host "  [N] Убить по номеру (например: 1,3,5)" -ForegroundColor $colors.Warning
Write-Host "  [M] Очистить оперативную память" -ForegroundColor $colors.Info
Write-Host "  [W] Мониторинг RAM (уведомления)" -ForegroundColor $colors.Info
Write-Host "  [P] Показать все открытые порты" -ForegroundColor $colors.Info
Write-Host "  [C] Свои процессы" -ForegroundColor $colors.Info
Write-Host "  [T] Автозапуск при выключении ПК" -ForegroundColor $colors.Info
Write-Host "  [R] Обновить список" -ForegroundColor $colors.Muted
Write-Host "  [Q] Выйти" -ForegroundColor $colors.Muted
Write-Host ""

$choice = Read-Host "  Выбор"

switch ($choice.ToUpper()) {

    "A" {
        Write-Host ""
        Write-Host ("  Убиваем " + $processes.Count + " процессов...") -ForegroundColor $colors.Danger
        $killed = 0
        foreach ($p in $processes) {
            try {
                Stop-Process -Id $p.PID -Force -ErrorAction Stop
                Write-Host ("  OK  " + $p.Name + "  PID " + $p.PID) -ForegroundColor $colors.Success
                $killed++
            } catch {
                Write-Host ("  FAIL  " + $p.Name + "  " + $_.Exception.Message) -ForegroundColor $colors.Danger
            }
        }
        Write-Host ""
        Write-Host ("  Готово! Убито: " + $killed) -ForegroundColor $colors.Success
    }

    "N" {
        Write-Host ""
        $nums = Read-Host "  Номера через запятую (например: 1,3)"
        $indices = $nums -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ -match "^\d+$" } | ForEach-Object { [int]$_ - 1 }
        $killed = 0
        foreach ($idx in $indices) {
            if ($idx -ge 0 -and $idx -lt $processes.Count) {
                $p = $processes[$idx]
                try {
                    Stop-Process -Id $p.PID -Force -ErrorAction Stop
                    Write-Host ("  OK  " + $p.Name + "  PID " + $p.PID) -ForegroundColor $colors.Success
                    $killed++
                } catch {
                    Write-Host ("  FAIL  " + $p.Name + "  " + $_.Exception.Message) -ForegroundColor $colors.Danger
                }
            } else {
                Write-Host ("  Номер " + ($idx+1) + " не найден") -ForegroundColor $colors.Warning
            }
        }
        Write-Host ""
        Write-Host ("  Готово! Убито: " + $killed) -ForegroundColor $colors.Success
    }

    "M" { Invoke-RamCleanup }

    "W" { Start-RamMonitor }

    "P" { Show-PortScan }

    "C" {
        Manage-CustomProcesses
        # Перезагружаем конфиг после изменений
        $customProcessNames = @()
        if (Test-Path $configPath) { . $configPath }
        $devProcessNames = ($defaultProcessNames + $customProcessNames) | Select-Object -Unique
        & $PSCommandPath
        exit
    }

    "T" { Manage-AutoShutdown }

    "R" {
        & $PSCommandPath
        exit
    }

    "Q" {
        Write-Host ""
        Write-Host "  Пока!" -ForegroundColor $colors.Muted
        exit
    }

    default {
        Write-Host ""
        Write-Host "  Неизвестная команда." -ForegroundColor $colors.Warning
    }
}

Write-Host ""
Write-Host "  Нажми любую клавишу для выхода..." -ForegroundColor $colors.Muted
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
