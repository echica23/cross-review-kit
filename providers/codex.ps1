function Get-CodexConfigArguments {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    Assert-SafeSandboxPath -Path $Workspace
    $workspaceRule = 'permissions.{0}.filesystem."{1}"="read"' -f $script:ProfileName, $Workspace
    return @(
        "-c", 'windows.sandbox="mxc"',
        "-c", "features.prefer_mxc=true",
        "-c", ('default_permissions="{0}"' -f $script:ProfileName),
        "-c", ('permissions.{0}.extends=":read-only"' -f $script:ProfileName),
        "-c", ('permissions.{0}.network.enabled=false' -f $script:ProfileName),
        "-c", ('permissions.{0}.filesystem.":root"="deny"' -f $script:ProfileName),
        "-c", ('permissions.{0}.filesystem.":minimal"="read"' -f $script:ProfileName),
        "-c", ('permissions.{0}.filesystem.":tmpdir"="deny"' -f $script:ProfileName),
        "-c", ('permissions.{0}.filesystem.":slash_tmp"="deny"' -f $script:ProfileName),
        "-c", $workspaceRule,
        "-c", 'web_search="disabled"',
        "-c", 'approval_policy="never"'
    )
}

function Invoke-Codex {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [string]$CodexHome
    )
    $previous = $ErrorActionPreference
    $previousHome = $env:CODEX_HOME
    $changeHome = $PSBoundParameters.ContainsKey("CodexHome")
    $ErrorActionPreference = "Continue"
    try {
        if ($changeHome) {
            $env:CODEX_HOME = $CodexHome
        }
        $output = & codex @Arguments 2>&1 | Out-String -Width 4096
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
        if ($changeHome) {
            if ([string]::IsNullOrEmpty($previousHome)) {
                Remove-Item Env:\CODEX_HOME -ErrorAction SilentlyContinue
            } else {
                $env:CODEX_HOME = $previousHome
            }
        }
    }
    if ($null -eq $code) {
        $code = 1
    }
    return [pscustomobject]@{
        ExitCode = [int]$code
        Output   = [string]$output
    }
}

function Invoke-AccessProbe {
    param(
        [Parameter(Mandatory = $true)][string]$RunRoot,
        [Parameter(Mandatory = $true)][string]$Workspace
    )
    $insidePath = Join-Path $Workspace "access-probe.txt"
    $canaryPath = Join-Path (Join-Path $RunRoot "outside") "canary.txt"
    $writePath = Join-Path $Workspace "access-write-probe.txt"
    $token = "CANARY-" + [guid]::NewGuid().ToString("N")

    Assert-SafeSandboxPath -Path $insidePath
    Assert-SafeSandboxPath -Path $canaryPath
    Assert-SafeSandboxPath -Path $writePath

    Write-Utf8File -Path $insidePath -Text $script:InsideMarker
    Write-Utf8File -Path $canaryPath -Text $token

    $osText = [System.IO.File]::ReadAllText($canaryPath).Trim()
    $osCanRead = ($osText -eq $token)

    $isolatedHome = Join-Path $RunRoot "codex-home"
    New-Item -ItemType Directory -Force -Path $isolatedHome | Out-Null
    $config = Get-CodexConfigArguments -Workspace $Workspace
    $sandboxArgs = $config + @(
        "sandbox",
        "--include-managed-config",
        "--permission-profile", $script:ProfileName,
        "-C", $Workspace,
        "--",
        "cmd.exe", "/d", "/c"
    )
    $inside = Invoke-Codex -CodexHome $isolatedHome -Arguments (
        $sandboxArgs + @(('type "{0}"' -f $insidePath))
    )
    $outside = Invoke-Codex -CodexHome $isolatedHome -Arguments (
        $sandboxArgs + @(('type "{0}"' -f $canaryPath))
    )
    $write = Invoke-Codex -CodexHome $isolatedHome -Arguments (
        $sandboxArgs + @(('echo WRITE_MARKER> "{0}"' -f $writePath))
    )

    $insideText = [string]$inside.Output
    $outsideText = [string]$outside.Output
    $workspaceRead = ($inside.ExitCode -eq 0 -and $insideText.Contains($script:InsideMarker))
    $outsideDenied = (
        $outside.ExitCode -ne 0 -and
        -not $outsideText.Contains($token)
    )
    $writeDenied = (
        $write.ExitCode -ne 0 -and
        -not (Test-Path -LiteralPath $writePath)
    )

    Remove-Item -LiteralPath $insidePath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $writePath -Force -ErrorAction SilentlyContinue

    $probe = New-Object System.Collections.Specialized.OrderedDictionary
    $probe["mechanism"] = "cross-review profile via the same -c flags; sandbox uses an empty CODEX_HOME and --include-managed-config because sandbox has no --ignore-user-config or --ignore-rules; exec uses those flags"
    $probe["workspace_read"] = $workspaceRead
    $probe["outside_read_denied"] = $outsideDenied
    $probe["write_denied"] = $writeDenied
    $probe["os_can_read_outside_file"] = $osCanRead

    $failure = $null
    if (-not $osCanRead) {
        $failure = "アクセス制御の確認用ファイルを、サンドボックス外から読めませんでした。"
    } elseif (-not $workspaceRead) {
        $failure = "権限プロファイルが、レビュー用ワークスペースの読み取りを許可しませんでした。"
    } elseif (-not $outsideDenied) {
        $failure = "権限プロファイルが、ワークスペース外のファイルの読み取りを拒否しませんでした。"
    } elseif (-not $writeDenied) {
        $failure = "権限プロファイルが、ワークスペースへの書き込みを拒否しませんでした。"
    }

    return [pscustomobject]@{
        Probe   = $probe
        Failure = $failure
    }
}

function Get-ProviderVersion {
    return Invoke-Codex -Arguments @('--version')
}

function Test-ProviderAccess {
    param([string]$RunRoot, [string]$Workspace)
    return Invoke-AccessProbe -RunRoot $RunRoot -Workspace $Workspace
}

function Invoke-ProviderReview {
    param([string]$RunRoot, [string]$Workspace, [string]$Model)
    $schemaPath = Join-Path $runRoot "schema.json"
    $lastMessagePath = Join-Path $runRoot "last-message.json"
    $stdoutPath = Join-Path $runRoot "stdout.jsonl"
    $stderrPath = Join-Path $runRoot "stderr.txt"
    Write-Utf8File -Path $schemaPath -Text (Get-SchemaText)

    $execArguments = @(
        "exec",
        "--ignore-user-config",
        "--ignore-rules",
        "--ephemeral",
        "--skip-git-repo-check",
        "--color", "never",
        "--json",
        "-m", $Model,
        "-C", $workspace,
        "--output-schema", $schemaPath,
        "-o", $lastMessagePath
    ) + (Get-CodexConfigArguments -Workspace $workspace) + @(Get-ReviewPrompt)

    Write-Host "Codex CLI でレビューを実行しています。"
    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & codex @execArguments > $stdoutPath 2> $stderrPath
        $execCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }
    if ($null -eq $execCode) {
        $execCode = 1
    }

    $messageText = ""
    if (Test-Path -LiteralPath $lastMessagePath) {
        $messageText = [System.IO.File]::ReadAllText($lastMessagePath)
    }
    $stderrText = ""
    if (Test-Path -LiteralPath $stderrPath) {
        $stderrText = [System.IO.File]::ReadAllText($stderrPath)
    }
    $stdoutText = ""
    if (Test-Path -LiteralPath $stdoutPath) {
        $stdoutText = [System.IO.File]::ReadAllText($stdoutPath)
    }
    $cliError = Get-LastNonEmptyLines -Text $stderrText
    if ([string]::IsNullOrWhiteSpace($cliError) -and $execCode -ne 0) {
        $cliError = Get-LastNonEmptyLines -Text $stdoutText
    }

    return [pscustomobject]@{ ExitCode = [int]$execCode; MessageText = $messageText; CliError = $cliError }
}
