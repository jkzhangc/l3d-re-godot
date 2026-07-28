<# :
@echo off
chcp 65001 >nul 2>&1
setlocal DisableDelayedExpansion
cd /d "%~dp0"
set "MY_BAT_FILE=%~f0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Command -ScriptBlock ([scriptblock]::Create([IO.File]::ReadAllText($env:MY_BAT_FILE)))"
pause
exit /b
#>

# === 以下为 PowerShell 核心逻辑 ===
try { [System.Text.Encoding]::RegisterProvider([System.Text.CodePagesEncodingProvider]::Instance) } catch {}

$gbk = [System.Text.Encoding]::GetEncoding(936)
$sjis = [System.Text.Encoding]::GetEncoding(932)

# 【关键升级】：开启“严格解码模式”
# 只要字节有哪怕一点点不符合标准的日文格式，直接触发异常，绝不静默替换成 "・" 或 "?"
$strictEncoder = [System.Text.EncoderFallback]::ExceptionFallback
$strictDecoder = [System.Text.DecoderFallback]::ExceptionFallback
$sjisStrict = [System.Text.Encoding]::GetEncoding(932, $strictEncoder, $strictDecoder)

Write-Host "=================================================" -ForegroundColor Cyan
Write-Host " 正在修复乱码文件名 (终极双重护盾 - 绝对防误杀)..." -ForegroundColor Yellow
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host ""

$count = 0
Get-ChildItem -File | ForEach-Object {
    $oldName = $_.Name
    
    # 排除批处理文件自身
    if ($oldName -match '\.(bat|cmd|exe)$') { return }
    
    # ==========================================
    # 🛡️ 护盾一：原生字典字符集检测
    # ==========================================
    # 尝试将名字用标准日文编码处理一次。
    # 如果是正常的 "風10.wav"，它完全合法，正反向转换后依旧是 "風10.wav"。
    # 如果是乱码 "暔傪.wav"，因为 "暔" 根本不存在于日本汉字字典里，转换会失败变成 "?.wav"。
    $testBytes = $sjis.GetBytes($oldName)
    $testString = $sjis.GetString($testBytes)
    if ($oldName -eq $testString) {
        # 完美的合法日文或纯英文，绝对安全，直接跳过！
        # Write-Host "[正常文件保护跳过] $oldName" -ForegroundColor DarkGray
        return
    }
    
    # ==========================================
    # 🛡️ 护盾二：严格还原转换
    # ==========================================
    try {
        $bytes = $gbk.GetBytes($oldName)
        
        # 使用严格模式解码！如果有任何错乱，这里会直接崩溃跳到 catch，不会产生 "・"
        $newName = $sjisStrict.GetString($bytes)
        
        if ($oldName -ne $newName) {
            $newPath = Join-Path $_.DirectoryName $newName
            if (-not (Test-Path -LiteralPath $newPath)) {
                Rename-Item -LiteralPath $_.FullName -NewName $newName
                Write-Host "[成功修复] $oldName -> $newName" -ForegroundColor Green
                $count++
            }
        }
    } catch {
        # 如果捕获到异常，说明它解析出来不是正常的日文，安全丢弃
        # Write-Host "[解码异常保护跳过] $oldName" -ForegroundColor DarkGray
    }
}

Write-Host ""
Write-Host "全部处理完成！共修复了 $count 个文件。" -ForegroundColor Cyan
