# Copilot transport prototype. The entry point is fail-closed until a deterministic
# pre-model access probe is implemented and verified on the target CLI/Windows host.
# Do not replace the probe with a model's assertion or a manually set boolean.

function Invoke-CopilotCommand {
    param([string[]]$Arguments)
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $text = & copilot @Arguments 2>&1 | Out-String -Width 4096
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }
    if ($null -eq $code) { $code = 1 }
    return [pscustomobject]@{ ExitCode = [int]$code; Output = [string]$text }
}

function Get-ProviderVersion {
    return Invoke-CopilotCommand -Arguments @('--version', '--no-auto-update')
}

function Test-ProviderAccess {
    param([string]$RunRoot, [string]$Workspace)
    return [pscustomobject]@{
        Probe = [ordered]@{
            mechanism = 'copilot pre-model probe not implemented'
            verified = $false
            workspace_read = $null
            outside_read_denied = $null
            write_denied = $null
        }
        Failure = 'Copilot access verification is not implemented. Installing the CLI alone does not enable review. No review/model call was made. See docs/copilot-validation.md.'
    }
}

function Get-CopilotReviewArguments {
    param([string]$Workspace, [string]$Model, [string]$Prompt)
    # Text mode deliberately avoids confusing JSONL events with the final review JSON.
    $arguments = @(
        '-C', $Workspace, '-p', $Prompt, '-s', '--stream=off',
        '--no-ask-user', '--no-auto-update', '--no-color',
        '--no-custom-instructions', '--disable-builtin-mcps',
        '--disable-mcp-server', 'computer-use', '--sync-session=off',
        '--disallow-temp-dir', '--sandbox',
        '--available-tools=view,grep,glob', '--allow-tool=read',
        '--deny-tool=write,shell,url,memory', '--output-format=text'
    )
    if (-not [string]::IsNullOrWhiteSpace($Model)) {
        $arguments += @('--model', $Model)
    }
    return $arguments
}

function ConvertFrom-CopilotResponse {
    param([int]$ExitCode, [string]$Stdout, [string]$Stderr)
    # Common validation rejects prose, fenced JSON and truncated responses.
    # Do not salvage fragments from a failed command or invent an empty review.
    return Get-ReviewOutcome -ExitCode $ExitCode -MessageText $Stdout -CliError $Stderr
}

function Invoke-ProviderReview {
    param([string]$RunRoot, [string]$Workspace, [string]$Model)
    # Intentionally guarded even when called directly. Add the real launch only
    # alongside a verified access probe, isolated settings/auth and capability checks.
    throw 'Copilot review is disabled: a verified pre-model access probe is required.'
}
