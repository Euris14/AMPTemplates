param(
    [Parameter(Mandatory = $false)]
    [string]$EnableHeadless = "false",

    [Parameter(Mandatory = $false)]
    [string]$HeadlessExecutable = "Fika.Dedicated.exe"
)

$ErrorActionPreference = 'Stop'

function ConvertTo-Bool([object]$value) {
    if ($null -eq $value) { return $false }
    $text = $value.ToString().Trim().ToLowerInvariant()
    return $text -in @('1', 'true', 'yes', 'y', 'on')
}

function Start-ManagedProcess {
    param(
        [Parameter(Mandatory = $true)] [string]$FilePath,
        [Parameter(Mandatory = $false)] [string]$Arguments = "",
        [Parameter(Mandatory = $true)] [string]$WorkingDirectory,
        [Parameter(Mandatory = $true)] [string]$Prefix
    )

    if (!(Test-Path -LiteralPath $FilePath)) {
        Write-Host "${Prefix} Missing executable: $FilePath"
        return $null
    }

    $processStartInfo = New-Object System.Diagnostics.ProcessStartInfo
    $processStartInfo.FileName = $FilePath
    $processStartInfo.Arguments = $Arguments
    $processStartInfo.WorkingDirectory = $WorkingDirectory
    $processStartInfo.UseShellExecute = $false
    $processStartInfo.RedirectStandardInput = $true
    $processStartInfo.RedirectStandardOutput = $true
    $processStartInfo.RedirectStandardError = $true
    $processStartInfo.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $processStartInfo
    $process.EnableRaisingEvents = $true

    $null = $process.Start()

    $process.add_OutputDataReceived({
            if ($null -ne $EventArgs.Data -and $EventArgs.Data.Length -gt 0) {
                if ([string]::IsNullOrEmpty($Prefix)) {
                    Write-Host $EventArgs.Data
                } else {
                    Write-Host ("{0} {1}" -f $Prefix, $EventArgs.Data)
                }
            }
        })

    $process.add_ErrorDataReceived({
            if ($null -ne $EventArgs.Data -and $EventArgs.Data.Length -gt 0) {
                if ([string]::IsNullOrEmpty($Prefix)) {
                    Write-Host $EventArgs.Data
                } else {
                    Write-Host ("{0} {1}" -f $Prefix, $EventArgs.Data)
                }
            }
        })

    $process.BeginOutputReadLine()
    $process.BeginErrorReadLine()

    return $process
}

function Stop-ProcessSafe {
    param(
        [Parameter(Mandatory = $false)] [System.Diagnostics.Process]$Process,
        [Parameter(Mandatory = $true)] [string]$Name
    )

    if ($null -eq $Process) { return }
    if ($Process.HasExited) { return }

    try {
        $Process.StandardInput.WriteLine('exit')
    } catch {
        # ignore
    }

    Start-Sleep -Seconds 2

    if (!$Process.HasExited) {
        try { $Process.Kill() } catch { }
    }
}

$enableHeadlessBool = ConvertTo-Bool $EnableHeadless

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location -Path $root

$serverWorkingDir = Join-Path $root 'server\SPT'
$serverExe = Join-Path $serverWorkingDir 'SPT.Server.exe'

$headlessWorkingDir = Join-Path $root 'headless'
$headlessExe = Join-Path $headlessWorkingDir $HeadlessExecutable

Write-Host "[SUPERVISOR] Starting server..."
$server = Start-ManagedProcess -FilePath $serverExe -WorkingDirectory $serverWorkingDir -Prefix ''
if ($null -eq $server) {
    exit 1
}

$headless = $null
function Start-Headless {
    if (!$enableHeadlessBool) {
        Write-Host "[SUPERVISOR] Headless disabled (EnableHeadless=false)."
        return
    }
    if ($null -ne $headless -and !$headless.HasExited) {
        Write-Host "[SUPERVISOR] Headless already running."
        return
    }

    Write-Host "[SUPERVISOR] Starting headless..."
    $script:headless = Start-ManagedProcess -FilePath $headlessExe -WorkingDirectory $headlessWorkingDir -Prefix '[HEADLESS]'
    if ($null -eq $script:headless) {
        Write-Host "[SUPERVISOR] Headless executable not found. If installed, set HeadlessExecutable to the correct file name."
    }
}

function Stop-Headless {
    if ($null -eq $headless -or $headless.HasExited) {
        Write-Host "[SUPERVISOR] Headless not running."
        return
    }
    Write-Host "[SUPERVISOR] Stopping headless..."
    Stop-ProcessSafe -Process $headless -Name 'headless'
}

function Restart-Headless {
    Stop-Headless
    Start-Headless
}

if ($enableHeadlessBool) {
    Start-Headless
}

Write-Host "[SUPERVISOR] Ready. Commands: headless start|stop|restart (forwarded server commands otherwise)."

try {
    while ($true) {
        if ($server.HasExited) {
            Write-Host "[SUPERVISOR] Server exited. Shutting down."
            break
        }

        $line = [Console]::ReadLine()
        if ($null -eq $line) {
            Start-Sleep -Milliseconds 100
            continue
        }

        $trim = $line.Trim()
        if ($trim.Length -eq 0) {
            continue
        }

        switch -Regex ($trim) {
            '^headless\s+start$' { Start-Headless; continue }
            '^headless\s+stop$' { Stop-Headless; continue }
            '^headless\s+restart$' { Restart-Headless; continue }
            '^exit$' {
                try { $server.StandardInput.WriteLine('exit') } catch { }
                break
            }
            default {
                try { $server.StandardInput.WriteLine($trim) } catch { }
            }
        }
    }
}
finally {
    Stop-Headless
    Stop-ProcessSafe -Process $server -Name 'server'
}
