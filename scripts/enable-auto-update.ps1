[CmdletBinding()]
param(
    [ValidatePattern('^([01][0-9]|2[0-3]):[0-5][0-9]$')]
    [string]$At = '08:00',
    [switch]$Disable,
    [switch]$Update,
    [string]$DockerPath,
    [string]$DockerContext
)

$ErrorActionPreference = 'Stop'
$taskName = 'CVAT VF Auto Update'
$stateDir = Join-Path $env:LOCALAPPDATA $taskName
$stableImage = 'ghcr.io/thomasminh1995/cvat-vf-overlay:v2.83.1-vf-stable'
$overlay = Join-Path $PSScriptRoot 'docker-compose.vf-ego.yml'
if (-not (Test-Path -LiteralPath $overlay -PathType Leaf)) {
    $overlay = Join-Path (Split-Path -Parent $PSScriptRoot) 'docker-compose.vf-ego.yml'
}

function Invoke-Docker {
    param([string[]]$Arguments)
    $output = & $DockerPath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Docker exited with code $LASTEXITCODE."
    }
    $output
}

function Update-CvatUI {
    param([switch]$Check)
    $env:CVAT_VF_IMAGE = $stableImage
    $dockerArgs = @('--context', $DockerContext)
    $metadata = & $DockerPath @dockerArgs inspect --type container --format '{{.State.Running}}|{{json .Config.Labels}}' cvat_ui 2>$null
    if ($LASTEXITCODE -ne 0 -or $metadata -notlike 'true|*') {
        if ($Check) { throw 'Start CVAT before enabling auto-update.' }
        Write-Output 'CVAT UI is stopped or Docker Desktop is unavailable. Skipping.'
        return
    }
    $labels = ($metadata -split '\|', 2)[1] | ConvertFrom-Json
    $project = $labels.'com.docker.compose.project'
    $workingDir = $labels.'com.docker.compose.project.working_dir'
    $files = $labels.'com.docker.compose.project.config_files'
    if (-not $project -or -not $workingDir -or -not $files -or -not (Test-Path -LiteralPath $workingDir -PathType Container)) {
        throw 'CVAT Compose configuration could not be found on Windows. This installer requires a stack started with Windows paths, not WSL paths.'
    }

    Push-Location -LiteralPath $workingDir
    try {
        $compose = $dockerArgs + @('compose', '--project-name', $project, '--project-directory', $workingDir)
        foreach ($path in ($labels.'com.docker.compose.project.environment_file' -split ',')) {
            if (-not $path) { continue }
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing Compose environment file: $path" }
            $compose += @('--env-file', $path)
        }
        foreach ($path in ($files -split ',')) {
            if ($path -eq $overlay) { continue }
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing Compose file: $path" }
            $compose += @('-f', $path)
        }
        $compose += @('-f', $overlay)

        $server = Invoke-Docker ($compose + @('ps', '-q', '--status', 'running', 'cvat_server'))
        if (-not $server) { throw 'CVAT server is not running.' }
        $version = Invoke-Docker ($dockerArgs + @('exec', $server, 'python', '-c', "from cvat import VERSION; print('.'.join(map(str, VERSION[:3])))"))
        if ($version -ne '2.83.1') { throw "CVAT server $version needs a different overlay channel." }
        if (-not $Check) {
            Invoke-Docker ($compose + @('up', '-d', '--no-deps', '--no-build', '--pull', 'always', 'cvat_ui'))
        }
    } finally {
        Pop-Location
    }
}

if ($Disable) {
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    }
    Write-Output 'CVAT VF auto-update disabled.'
    return
}

if ($Update) {
    Start-Transcript -Path (Join-Path $stateDir 'update.log') -Append | Out-Null
    try {
        Update-CvatUI
    } finally {
        Stop-Transcript | Out-Null
    }
    return
}

$DockerPath = (Get-Command docker.exe -CommandType Application).Source
$DockerContext = Invoke-Docker @('context', 'show')
$endpoint = Invoke-Docker @('context', 'inspect', $DockerContext, '--format', '{{.Endpoints.docker.Host}}')
if ($endpoint -notlike 'npipe://*') { throw 'Select a local Docker Desktop context first.' }
Update-CvatUI -Check

New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
$runner = Join-Path $stateDir 'enable-auto-update.ps1'
Copy-Item -LiteralPath $PSCommandPath -Destination $runner -Force
Copy-Item -LiteralPath $overlay -Destination $stateDir -Force

$commandLine = '-NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File "{0}" -Update -DockerPath "{1}" -DockerContext "{2}"' -f $runner, $DockerPath, $DockerContext
$action = New-ScheduledTaskAction -Execute (Join-Path $PSHOME 'powershell.exe') -Argument $commandLine
$trigger = New-ScheduledTaskTrigger -Daily -At ([datetime]::Today.Add([timespan]::ParseExact($At, 'hh\:mm', $null)))
$principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
Write-Output "CVAT VF auto-update enabled daily at $At. Log: $stateDir\update.log"
