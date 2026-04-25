# ============================================================
#  setup.ps1  -  Создание ярлыков на рабочем столе
#  Запусти один раз после установки
# ============================================================

$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$scriptsPath = $PSScriptRoot
$desktop     = [Environment]::GetFolderPath("Desktop")
$shell       = New-Object -ComObject WScript.Shell

Write-Host ""
Write-Host "  ===========================================" -ForegroundColor Cyan
Write-Host "     DEVTOOLS SETUP  -  Создание ярлыков    " -ForegroundColor Cyan
Write-Host "  ===========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host ("  Папка скриптов: " + $scriptsPath) -ForegroundColor DarkGray
Write-Host ("  Рабочий стол:   " + $desktop) -ForegroundColor DarkGray
Write-Host ""

# ── Ярлык DEV KILLER ──
$killerPath = Join-Path $scriptsPath "killdevs.ps1"
if (Test-Path $killerPath) {
    $shortcut = $shell.CreateShortcut("$desktop\DEV KILLER.lnk")
    $shortcut.TargetPath       = "powershell.exe"
    $shortcut.Arguments        = "-NoExit -ExecutionPolicy Bypass -File `"$killerPath`""
    $shortcut.WorkingDirectory = $scriptsPath
    $shortcut.Description      = "Dev Process Killer - убивает зависшие серверы и чистит RAM"
    $shortcut.IconLocation     = "powershell.exe,0"
    $shortcut.Save()

    # Включаем запуск от администратора
    $bytes = [System.IO.File]::ReadAllBytes("$desktop\DEV KILLER.lnk")
    $bytes[0x15] = $bytes[0x15] -bor 0x20
    [System.IO.File]::WriteAllBytes("$desktop\DEV KILLER.lnk", $bytes)

    Write-Host "  OK  Ярлык создан: DEV KILLER.lnk" -ForegroundColor Green
} else {
    Write-Host ("  SKIP  killdevs.ps1 не найден в " + $scriptsPath) -ForegroundColor Yellow
}

# ── Ярлык DEV LOGS ──
$logsPath = Join-Path $scriptsPath "devlogs.ps1"
if (Test-Path $logsPath) {
    $shortcut2 = $shell.CreateShortcut("$desktop\DEV LOGS.lnk")
    $shortcut2.TargetPath       = "powershell.exe"
    $shortcut2.Arguments        = "-NoExit -ExecutionPolicy Bypass -File `"$logsPath`""
    $shortcut2.WorkingDirectory = $scriptsPath
    $shortcut2.Description      = "Dev Log Viewer - живые логи всех серверов"
    $shortcut2.IconLocation     = "powershell.exe,0"
    $shortcut2.Save()

    # Включаем запуск от администратора
    $bytes2 = [System.IO.File]::ReadAllBytes("$desktop\DEV LOGS.lnk")
    $bytes2[0x15] = $bytes2[0x15] -bor 0x20
    [System.IO.File]::WriteAllBytes("$desktop\DEV LOGS.lnk", $bytes2)

    Write-Host "  OK  Ярлык создан: DEV LOGS.lnk" -ForegroundColor Green
} else {
    Write-Host ("  SKIP  devlogs.ps1 не найден в " + $scriptsPath) -ForegroundColor Yellow
}

# ── Ярлык DEV BLACK BOX ──
$blackboxPath = Join-Path $scriptsPath "devblackbox.ps1"
if (Test-Path $blackboxPath) {
    $shortcut3 = $shell.CreateShortcut("$desktop\DEV BLACK BOX.lnk")
    $shortcut3.TargetPath       = "powershell.exe"
    $shortcut3.Arguments        = "-NoExit -ExecutionPolicy Bypass -File `"$blackboxPath`""
    $shortcut3.WorkingDirectory = $scriptsPath
    $shortcut3.Description      = "Dev Black Box - бортовой журнал dev-сессии"
    $shortcut3.IconLocation     = "powershell.exe,0"
    $shortcut3.Save()

    $bytes3 = [System.IO.File]::ReadAllBytes("$desktop\DEV BLACK BOX.lnk")
    $bytes3[0x15] = $bytes3[0x15] -bor 0x20
    [System.IO.File]::WriteAllBytes("$desktop\DEV BLACK BOX.lnk", $bytes3)

    Write-Host "  OK  Ярлык создан: DEV BLACK BOX.lnk" -ForegroundColor Green
} else {
    Write-Host ("  SKIP  devblackbox.ps1 не найден в " + $scriptsPath) -ForegroundColor Yellow
}

Write-Host ""
Write-Host "  Готово! Ярлыки на рабочем столе автоматически" -ForegroundColor Green
Write-Host "  запускаются от имени администратора." -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Нажми любую клавишу для выхода..." -ForegroundColor DarkGray
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
