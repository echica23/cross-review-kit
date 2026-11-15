# Offline tests: no authentication, network or model calls.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$kit = Join-Path $root 'review.ps1'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($kit, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
foreach ($statement in $ast.EndBlock.Statements) {
    if ($statement -is [Management.Automation.Language.FunctionDefinitionAst]) {
        . ([scriptblock]::Create($statement.Extent.Text))
    }
}
Add-Type -AssemblyName System.Web.Extensions
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
. (Join-Path $root 'providers\copilot.ps1')
$arguments = @(Get-CopilotReviewArguments -Workspace 'C:\review workspace' -Model '' -Prompt 'test')
Assert ($arguments -notcontains '--model') 'Unspecified model must use provider default'
Assert ($arguments -contains '--sandbox') 'Sandbox request missing'
Assert ($arguments -notcontains '--allow-all-tools') 'Blanket permission is forbidden'
$arguments = @(Get-CopilotReviewArguments -Workspace 'C:\review workspace' -Model 'example-model' -Prompt 'test')
Assert ($arguments -contains 'example-model') 'Explicit model missing'
$zero = ConvertFrom-CopilotResponse 0 '{"status":"completed","reason":"","findings":[]}' ''
Assert ($zero.status -eq 'completed' -and @($zero.findings).Count -eq 0) 'Zero findings failed'
$one = ConvertFrom-CopilotResponse 0 '{"status":"completed","reason":"","findings":[{"severity":"major","location":"a","description":"b","evidence":"c","suggestion":"d"}]}' ''
Assert (@($one.findings).Count -eq 1) 'One finding failed'
$impossible = ConvertFrom-CopilotResponse 0 '{"status":"not_reviewable","reason":"missing requirements","findings":[]}' ''
Assert ($impossible.status -eq 'not_reviewable' -and $null -eq $impossible.findings) 'Impossible review failed'
$bad = ConvertFrom-CopilotResponse 0 'not json' ''
Assert ($bad.error.type -eq 'invalid_json') 'Invalid response accepted'
$failed = ConvertFrom-CopilotResponse 9 '{"status":"completed","findings":[]}' 'auth failed'
Assert ($failed.error.type -eq 'cli_exit') 'CLI failure accepted'
$probe = Test-ProviderAccess -RunRoot 'unused' -Workspace 'unused'
Assert ($probe.Failure -and -not $probe.Probe.verified) 'Unverified access accepted'
$threw = $false
try { Invoke-ProviderReview -RunRoot 'unused' -Workspace 'unused' } catch { $threw = $true }
Assert $threw 'Direct Copilot launch must also be blocked'

# Run the actual entry point with a fake CLI that supports ONLY --version.
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('cross-review-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null
try {
    $runner = Join-Path $scratch 'runner.ps1'
    $output = Join-Path $scratch 'result.json'
    $text = @'
param($KitRoot, $ResultPath)
function global:copilot {
    if ($args[0] -ne '--version') { throw 'Unexpected model invocation' }
    $global:LASTEXITCODE = 0
    'copilot test-double'
}
& (Join-Path $KitRoot 'review.ps1') -Provider copilot -Target (Join-Path $KitRoot 'fixtures\test-items.md') -Criteria (Join-Path $KitRoot 'fixtures\criteria.md') -Output $ResultPath
exit $LASTEXITCODE
'@
    [IO.File]::WriteAllText($runner, $text)
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner $root $output
    Assert ($LASTEXITCODE -eq 1) 'Unverified provider must exit 1'
    $result = Get-Content -Raw -LiteralPath $output | ConvertFrom-Json
    Assert ($result.provider -eq 'copilot' -and $result.error.type -eq 'access_control') 'Wrong provider failure'
    Assert ($result.workspace_deleted -and $null -eq $result.findings) 'Cleanup or failure shape incorrect'
    Assert ($result.model_selection -eq 'provider_default') 'Default model falsely reported'
} finally {
    $resolved = [IO.Path]::GetFullPath($scratch)
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolved -Leaf) -notlike 'cross-review-tests-*') { throw 'Unsafe cleanup path' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-Host 'PROVIDER TESTS PASS (mocked; Copilot live execution remains disabled)'
