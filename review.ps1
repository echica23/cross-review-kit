# Cross-review Kit.
# Copies only the requested inputs into a temporary workspace, checks that
# Codex's own permission profile (not the copy itself) confines file access,
# then runs a fresh non-interactive read-only review.
# Requires Windows PowerShell 5.1. See README for provider readiness and authentication.
# Do not pass --sandbox: that selects the legacy sandbox, which can read the
# whole disk and disables permission profiles.

[CmdletBinding()]
param(
    [string]$Target,
    [string[]]$Evidence = @(),
    [string]$Criteria,
    [string]$Output = "review-result.json",
    [string]$Model = "",
    [ValidateSet("codex", "copilot")][string]$Provider = "codex",
    [switch]$SelfTest
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Web.Extensions

$script:ProfileName = "cross-review"
$script:InsideMarker = "INSIDE_OK"
$Provider = $Provider.ToLowerInvariant()
if (-not $PSBoundParameters.ContainsKey('Model') -and $Provider -eq 'codex') {
    $Model = 'gpt-6.1-sol'
}
$script:ModelWasSpecified = $PSBoundParameters.ContainsKey('Model')
. (Join-Path $PSScriptRoot ("providers\{0}.ps1" -f $Provider))

function Write-Utf8File {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text
    )
    $encoding = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($Path, $Text, $encoding)
}

function ConvertTo-PlainJson {
    param($Value)
    $json = ConvertTo-Json -InputObject $Value -Depth 8
    return [regex]::Replace($json, '(?<!\\)\\u([0-9a-fA-F]{4})', {
        param($Match)
        [string][char][Convert]::ToInt32($Match.Groups[1].Value, 16)
    })
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value
    )
    Write-Utf8File -Path $Path -Text ((ConvertTo-PlainJson -Value $Value) + [Environment]::NewLine)
}

function Get-ComparablePath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $providerPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $full = [System.IO.Path]::GetFullPath($providerPath)
    return $full.TrimEnd('\', '/')
}

function Test-OutputOverwritesInput {
    param(
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [string[]]$InputPaths
    )
    $outputFull = Get-ComparablePath -Path $OutputPath
    foreach ($inputPath in @($InputPaths)) {
        if ([string]::IsNullOrWhiteSpace($inputPath) -or -not (Test-Path -LiteralPath $inputPath)) {
            continue
        }
        $inputFull = Get-ComparablePath -Path $inputPath
        $item = Get-Item -LiteralPath $inputPath
        $same = $outputFull.Equals($inputFull, [System.StringComparison]::OrdinalIgnoreCase)
        if ($item.PSIsContainer) {
            $prefix = $inputFull + '\'
            $inside = $outputFull.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
            if ($same -or $inside) {
                return "出力先が入力ディレクトリと重なっています: $outputFull"
            }
        } elseif ($same) {
            return "出力先が入力ファイルと同じです: $outputFull"
        }
    }
    return $null
}

function Test-ResultWriteAllowed {
    param(
        [string]$OutputPath,
        [string[]]$InputPaths
    )
    $decision = New-Object System.Collections.Specialized.OrderedDictionary
    $decision["Allowed"] = $false
    $decision["Message"] = "出力先の安全性を確認できないため、結果を書き込みません。"
    if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        return $decision
    }
    try {
        $blocked = Test-OutputOverwritesInput -OutputPath $OutputPath -InputPaths $InputPaths
    } catch {
        $decision["Message"] = "出力先の安全性を確認できないため、結果を書き込みません: $($_.Exception.Message)"
        return $decision
    }
    if ($blocked) {
        $decision["Message"] = [string]$blocked
        return $decision
    }
    $decision["Allowed"] = $true
    $decision["Message"] = $null
    return $decision
}

function Resolve-ExistingPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label
    )
    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "$Label が指定されていません。"
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "$Label が見つかりません: $Path"
    }
    return (Resolve-Path -LiteralPath $Path).Path
}

function Assert-SafeSandboxPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ($Path -match '["\r\n&|<>^]') {
        throw "サンドボックスへ渡せない文字がパスに含まれています: $Path"
    }
}

function Get-ContentFingerprint {
    param([Parameter(Mandatory = $true)][string]$Path)
    $item = Get-Item -LiteralPath $Path
    if (-not $item.PSIsContainer) {
        return (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash
    }

    $files = @(Get-ChildItem -LiteralPath $item.FullName -Recurse -File | Sort-Object FullName)
    $builder = New-Object System.Text.StringBuilder
    foreach ($file in $files) {
        $relative = $file.FullName.Substring($item.FullName.Length).TrimStart('\', '/')
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        [void]$builder.Append($relative.Replace('\', '/'))
        [void]$builder.Append('=')
        [void]$builder.AppendLine($hash)
    }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($builder.ToString()))
        return ([System.BitConverter]::ToString($bytes)).Replace("-", "")
    } finally {
        $sha.Dispose()
    }
}

function Copy-ReviewInput {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$DestinationDirectory
    )
    $item = Get-Item -LiteralPath $Source
    $destination = Join-Path $DestinationDirectory $item.Name
    if (Test-Path -LiteralPath $destination) {
        throw "コピー先の名前が重複しています: $($item.Name)"
    }
    Copy-Item -LiteralPath $item.FullName -Destination $destination -Recurse -Force
    return $destination
}

function New-RunDirectory {
    $root = Join-Path $env:TEMP ("cross-review-" + [guid]::NewGuid().ToString("N"))
    $workspace = Join-Path $root "workspace"
    New-Item -ItemType Directory -Path (Join-Path $workspace "target") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $workspace "evidence") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $workspace "criteria") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $root "outside") -Force | Out-Null
    return $root
}

function Remove-RunDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)
    $tempRoot = [System.IO.Path]::GetFullPath($env:TEMP)
    if (-not $tempRoot.EndsWith('\')) {
        $tempRoot = $tempRoot + '\'
    }
    $full = [System.IO.Path]::GetFullPath($Path)
    $prefixOk = $full.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase)
    $nameOk = (Split-Path -Leaf $full) -like "cross-review-*"
    if (-not $prefixOk -or -not $nameOk) {
        throw "一時ディレクトリ以外は削除しません: $full"
    }
    if (Test-Path -LiteralPath $full) {
        Remove-Item -LiteralPath $full -Recurse -Force
    }
}

function Test-MapKey {
    param($Map, $Key)
    if ($null -eq $Map) {
        return $false
    }
    foreach ($existing in @($Map.Keys)) {
        if ([string]$existing -eq [string]$Key) {
            return $true
        }
    }
    return $false
}

function ConvertFrom-JsonStrict {
    param([AllowEmptyString()][string]$Text)
    $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $serializer.MaxJsonLength = 67108864
    $serializer.RecursionLimit = 64
    return $serializer.DeserializeObject($Text)
}

function Test-ReviewDocument {
    param($Document)
    if ($null -eq $Document -or $Document -isnot [System.Collections.IDictionary]) {
        return "レビュー結果がJSONオブジェクトではありません。"
    }

    $allowedRoot = @("status", "findings", "reason")
    foreach ($key in @($Document.Keys)) {
        if ($allowedRoot -notcontains [string]$key) {
            return "レビュー結果に未定義のフィールドがあります: $key"
        }
    }
    $reasonValue = $Document["reason"]
    $hasReason = Test-MapKey -Map $Document -Key "reason"
    if ($hasReason -and ($null -ne $reasonValue) -and ($reasonValue -isnot [string])) {
        return "reason が文字列ではありません。"
    }
    if ([string]$Document["status"] -ne "completed") {
        return "レビュー結果の status が completed ではありません。"
    }
    if (-not (Test-MapKey -Map $Document -Key "findings")) {
        return "レビュー結果に findings がありません。"
    }

    $findings = $Document["findings"]
    if ($null -eq $findings -or $findings -isnot [System.Array]) {
        return "findings が配列ではありません。"
    }

    $allowedSeverity = @("critical", "major", "minor", "info")
    $required = @("severity", "location", "description", "evidence", "suggestion")
    foreach ($item in $findings) {
        if ($null -eq $item -or $item -isnot [System.Collections.IDictionary]) {
            return "findings の要素がオブジェクトではありません。"
        }
        foreach ($key in @($item.Keys)) {
            if ($required -notcontains [string]$key) {
                return "指摘に未定義のフィールドがあります: $key"
            }
        }
        foreach ($key in $required) {
            if (-not (Test-MapKey -Map $item -Key $key) -or $item[$key] -isnot [string]) {
                return "指摘の $key が文字列ではありません。"
            }
        }
        if ($allowedSeverity -notcontains [string]$item["severity"]) {
            return "指摘の severity が不正です。"
        }
    }
    return $null
}

function New-FindingArray {
    param([object[]]$Findings)
    $items = New-Object System.Collections.Generic.List[object]
    if ($null -ne $Findings) {
        foreach ($item in $Findings) {
            if ($null -eq $item) {
                continue
            }
            $finding = New-Object System.Collections.Specialized.OrderedDictionary
            $finding["severity"] = [string]$item["severity"]
            $finding["location"] = [string]$item["location"]
            $finding["description"] = [string]$item["description"]
            $finding["evidence"] = [string]$item["evidence"]
            $finding["suggestion"] = [string]$item["suggestion"]
            $items.Add($finding)
        }
    }
    # The unary comma keeps an empty or single-element array from unrolling.
    return ,$items.ToArray()
}

function New-FailedResult {
    param(
        [Parameter(Mandatory = $true)][string]$Type,
        [Parameter(Mandatory = $true)][string]$Message,
        [int]$ExitCode = 0
    )
    $errorInfo = New-Object System.Collections.Specialized.OrderedDictionary
    $errorInfo["type"] = $Type
    $errorInfo["message"] = $Message
    if ($ExitCode -ne 0) {
        $errorInfo["exit_code"] = $ExitCode
    }
    $result = New-Object System.Collections.Specialized.OrderedDictionary
    $result["status"] = "failed"
    $result["findings"] = $null
    $result["error"] = $errorInfo
    return $result
}

function New-NotReviewableResult {
    param([Parameter(Mandatory = $true)][string]$Message)
    $errorInfo = New-Object System.Collections.Specialized.OrderedDictionary
    $errorInfo["type"] = "review_impossible"
    $errorInfo["message"] = $Message
    $result = New-Object System.Collections.Specialized.OrderedDictionary
    $result["status"] = "not_reviewable"
    $result["findings"] = $null
    $result["error"] = $errorInfo
    return $result
}

function Get-ReviewOutcome {
    param(
        [int]$ExitCode,
        [AllowEmptyString()][string]$MessageText,
        [AllowEmptyString()][string]$CliError
    )
    if ($ExitCode -ne 0) {
        $message = $CliError
        if ([string]::IsNullOrWhiteSpace($message)) {
            $message = "レビュー CLI が終了コード $ExitCode で失敗しました。"
        }
        return New-FailedResult -Type "cli_exit" -Message $message -ExitCode $ExitCode
    }

    $text = ""
    if ($null -ne $MessageText) {
        $text = $MessageText.Trim().Trim([char]0xFEFF).Trim()
    }
    if ([string]::IsNullOrWhiteSpace($text)) {
        return New-FailedResult -Type "invalid_json" -Message "レビュー結果のJSONが空です。"
    }

    try {
        $document = ConvertFrom-JsonStrict -Text $text
    } catch {
        return New-FailedResult -Type "invalid_json" -Message "レビュー結果のJSONを解析できません。"
    }

    if ($null -eq $document -or $document -isnot [System.Collections.IDictionary]) {
        return New-FailedResult -Type "invalid_json" -Message "レビュー結果がJSONオブジェクトではありません。"
    }
    if ([string]$document["status"] -eq "not_reviewable") {
        $reason = ""
        if ((Test-MapKey -Map $document -Key "reason") -and $document["reason"] -is [string]) {
            $reason = $document["reason"].Trim()
        }
        if ([string]::IsNullOrWhiteSpace($reason)) {
            $reason = "レビュー不能と判定されましたが、理由がありません。"
        }
        return New-NotReviewableResult -Message $reason
    }

    $shapeError = Test-ReviewDocument -Document $document
    if ($shapeError) {
        return New-FailedResult -Type "invalid_json" -Message $shapeError
    }

    $result = New-Object System.Collections.Specialized.OrderedDictionary
    $result["status"] = "completed"
    $result["findings"] = New-FindingArray -Findings $document["findings"]
    return $result
}

function Get-SchemaText {
    return @'
{
  "type": "object",
  "additionalProperties": false,
  "required": ["status", "reason", "findings"],
  "properties": {
    "status": {
      "type": "string",
      "enum": ["completed", "not_reviewable"]
    },
    "reason": { "type": "string" },
    "findings": {
      "type": "array",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["severity", "location", "description", "evidence", "suggestion"],
        "properties": {
          "severity": {
            "type": "string",
            "enum": ["critical", "major", "minor", "info"]
          },
          "location": { "type": "string" },
          "description": { "type": "string" },
          "evidence": { "type": "string" },
          "suggestion": { "type": "string" }
        }
      }
    }
  }
}
'@
}

function Get-ReviewPrompt {
    return @'
あなたは独立したレビュアーです。この実行より前の会話や、対象を作成した側の作業履歴は持っていません。判断材料は、このワークスペース内の次のディレクトリだけです。

- レビュー対象: target/
- 根拠資料: evidence/
- レビュー基準: criteria/

レビュー基準に従い、レビュー対象を根拠資料と照合してください。ファイルの作成、変更、削除はしないでください。ワークスペース外のファイルは読まないでください。

応答は出力スキーマに合う一つのJSONオブジェクトだけにしてください。

- 照合でき、指摘が無い: status は completed、findings は空配列、reason は空文字。null は使わない。
- 照合でき、指摘がある: status は completed、findings に指摘、reason は空文字。null は使わない。
- 資料を読めない、または判断に必要な要求や対象の記載が無く照合できない: status は not_reviewable、findings は空配列、reason に読めないものまたは不足しているものを書く。

要求があるのに対象の確認が無い、という通常の指摘は completed と findings で表してください。指摘が無い完了を、レビュー不能の代わりに使わないでください。
'@
}

function Get-LastNonEmptyLines {
    param(
        [AllowEmptyString()][string]$Text,
        [int]$Limit = 20
    )
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ""
    }
    $lines = @(
        $Text -split "\r?\n" |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -ne "" }
    )
    if ($lines.Count -eq 0) {
        return ""
    }
    $start = [Math]::Max(0, $lines.Count - $Limit)
    $tail = $lines[$start..($lines.Count - 1)] -join " "
    if ($tail.Length -gt 2000) {
        return $tail.Substring($tail.Length - 2000)
    }
    return $tail
}

function Add-CommonFields {
    param(
        $Result,
        [string]$ModelName,
        [string]$CodexVersion,
        $Inputs,
        $AccessControl,
        [nullable[bool]]$SourcesUnchanged
    )
    $wrapped = New-Object System.Collections.Specialized.OrderedDictionary
    $wrapped["status"] = $Result["status"]
    $wrapped["provider"] = $Provider
    $wrapped["model"] = $ModelName
    $wrapped["model_selection"] = $(if ([string]::IsNullOrWhiteSpace($ModelName)) { 'provider_default' } else { 'requested' })
    $wrapped["actual_model"] = $null
    $wrapped["cli_version"] = $CodexVersion
    if ($Provider -eq "codex") { $wrapped["codex_version"] = $CodexVersion }
    $wrapped["inputs"] = $Inputs
    $wrapped["findings"] = $Result["findings"]
    if (Test-MapKey -Map $Result -Key "error") {
        $wrapped["error"] = $Result["error"]
    }
    if ($null -ne $AccessControl) {
        $wrapped["access_control"] = $AccessControl
    }
    if ($null -ne $SourcesUnchanged) {
        $wrapped["sources_unchanged"] = [bool]$SourcesUnchanged
    }
    return $wrapped
}

function New-InputRecord {
    param(
        [string]$TargetPath,
        [string[]]$EvidencePaths,
        [string]$CriteriaPath
    )
    $record = New-Object System.Collections.Specialized.OrderedDictionary
    $record["target"] = $TargetPath
    $record["evidence"] = @($EvidencePaths)
    $record["criteria"] = $CriteriaPath
    return $record
}

function Invoke-SelfTest {
    $failures = New-Object System.Collections.Generic.List[string]

    $empty = Get-ReviewOutcome -ExitCode 0 -MessageText '{"status":"completed","reason":null,"findings":[]}'
    if ($empty["status"] -ne "completed" -or @($empty["findings"]).Count -ne 0) {
        $failures.Add("zero findings were not accepted")
    }

    $oneText = '{"status":"completed","findings":[{"severity":"major","location":"target/item","description":"欠落","evidence":"R1","suggestion":"追加する"}]}'
    $one = Get-ReviewOutcome -ExitCode 0 -MessageText $oneText
    if ($one["status"] -ne "completed" -or @($one["findings"]).Count -ne 1) {
        $failures.Add("one finding was not accepted")
    }
    $oneJson = ConvertTo-Json -InputObject $one -Depth 8
    if ($oneJson -notmatch '(?s)"findings":\s*\[') {
        $failures.Add("one finding was not serialized as an array: $oneJson")
    }

    $bad = Get-ReviewOutcome -ExitCode 0 -MessageText "not-json"
    if ($bad["status"] -ne "failed" -or $bad["findings"] -ne $null -or $bad["error"]["type"] -ne "invalid_json") {
        $failures.Add("invalid json was not rejected")
    }

    $shape = Get-ReviewOutcome -ExitCode 0 -MessageText '{"status":"completed","findings":[{"severity":"major"}]}'
    if ($shape["status"] -ne "failed" -or $shape["error"]["type"] -ne "invalid_json") {
        $failures.Add("incomplete finding was not rejected")
    }

    $cli = Get-ReviewOutcome -ExitCode 7 -MessageText '{"status":"completed","findings":[]}' -CliError "boom"
    if ($cli["status"] -ne "failed" -or $cli["findings"] -ne $null -or $cli["error"]["type"] -ne "cli_exit" -or $cli["error"]["exit_code"] -ne 7) {
        $failures.Add("cli failure was not distinguished from an empty review")
    }

    $blankReason = Get-ReviewOutcome -ExitCode 0 -MessageText '{"status":"not_reviewable","reason":null,"findings":[]}'
    if ($blankReason["status"] -ne "not_reviewable" -or $null -ne $blankReason["findings"] -or $blankReason["error"]["message"] -eq "") {
        $failures.Add("null reason on not_reviewable was not recorded")
    }

    $impossible = Get-ReviewOutcome -ExitCode 0 -MessageText '{"status":"not_reviewable","reason":"要求が無い","findings":[]}'
    if ($impossible["status"] -ne "not_reviewable" -or $null -ne $impossible["findings"] -or $impossible["error"]["type"] -ne "review_impossible" -or $impossible["error"]["message"] -ne "要求が無い") {
        $failures.Add("not_reviewable was not distinguished from completion: $(ConvertTo-Json -InputObject $impossible -Depth 6 -Compress)")
    }
    $impossibleJson = ConvertTo-Json -InputObject $impossible -Depth 8
    if ($impossibleJson -notmatch '"findings":\s*null') {
        $failures.Add("not_reviewable findings were not null")
    }

    $cliImpossible = Get-ReviewOutcome -ExitCode 3 -MessageText '{"status":"not_reviewable","reason":"要求が無い","findings":[]}'
    if ($cliImpossible["status"] -ne "failed" -or $cliImpossible["error"]["type"] -ne "cli_exit") {
        $failures.Add("cli failure was treated as not_reviewable")
    }

    $pathRoot = Join-Path $env:TEMP ("cross-review-selftest-" + [guid]::NewGuid().ToString("N"))
    try {
        $inputDir = Join-Path $pathRoot "inputs"
        $otherDir = Join-Path $pathRoot "inputs-extra"
        New-Item -ItemType Directory -Force -Path $inputDir, $otherDir | Out-Null
        $inputFile = Join-Path $inputDir "same.txt"
        Set-Content -LiteralPath $inputFile -Value "keep" -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $otherDir "other.txt") -Value "other" -Encoding ASCII
        Push-Location $inputDir
        try {
            $sameFile = Test-OutputOverwritesInput -OutputPath ".\same.txt" -InputPaths @((Join-Path $inputDir "SAME.TXT"))
            if (-not $sameFile) { $failures.Add("normalized file collision was allowed") }
            $insideDir = Test-OutputOverwritesInput -OutputPath (Join-Path $inputDir "nested\out.json") -InputPaths @($inputDir)
            if (-not $insideDir) { $failures.Add("output inside an input directory was allowed") }
            $dirItself = Test-OutputOverwritesInput -OutputPath ($inputDir + "\") -InputPaths @($inputDir)
            if (-not $dirItself) { $failures.Add("output equal to an input directory was allowed") }
            $sibling = Test-OutputOverwritesInput -OutputPath (Join-Path $otherDir "other.txt") -InputPaths @($inputFile)
            if ($sibling) { $failures.Add("sibling output was rejected: $sibling") }
            $prefix = Test-OutputOverwritesInput -OutputPath (Join-Path $otherDir "out.json") -InputPaths @($inputDir)
            if ($prefix) { $failures.Add("directory prefix was treated as containment: $prefix") }
            $unknown = Test-ResultWriteAllowed -OutputPath $null -InputPaths @($inputFile)
            if ($unknown["Allowed"]) { $failures.Add("unconfirmed output path was allowed") }
            $sameDecision = Test-ResultWriteAllowed -OutputPath $inputFile -InputPaths @($inputFile)
            if ($sameDecision["Allowed"]) { $failures.Add("write onto an input file was allowed") }
            $separate = Test-ResultWriteAllowed -OutputPath (Join-Path $otherDir "out.json") -InputPaths @()
            if (-not $separate["Allowed"]) { $failures.Add("output with no inputs was rejected") }
        } finally {
            Pop-Location
        }

        $guardRoot = Join-Path $pathRoot "guard"
        New-Item -ItemType Directory -Force -Path $guardRoot | Out-Null
        $guardTarget = Join-Path $guardRoot "target.md"
        $guardMissing = Join-Path $guardRoot "missing-criteria.md"
        $guardOutput = Join-Path $guardRoot "safe-result.json"
        $utf8 = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($guardTarget, "ORIGINAL_TARGET", $utf8)
        $guardHash = (Get-FileHash -LiteralPath $guardTarget -Algorithm SHA256).Hash
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Target $guardTarget -Criteria $guardMissing -Output $guardTarget
        if ($LASTEXITCODE -ne 2) {
            $failures.Add("missing criteria with output on the target exited $LASTEXITCODE")
        }
        $guardText = [System.IO.File]::ReadAllText($guardTarget)
        $guardHashAfter = (Get-FileHash -LiteralPath $guardTarget -Algorithm SHA256).Hash
        if ($guardText -ne "ORIGINAL_TARGET" -or $guardHashAfter -ne $guardHash) {
            $failures.Add("missing criteria overwrote the target with failure json")
        }
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Target $guardTarget -Criteria $guardMissing -Output $guardOutput
        if ($LASTEXITCODE -ne 2) {
            $failures.Add("missing criteria with a separate output exited $LASTEXITCODE")
        }
        if (-not (Test-Path -LiteralPath $guardOutput)) {
            $failures.Add("setup failure was not written to a separate output")
        } else {
            $setupText = [System.IO.File]::ReadAllText($guardOutput)
            if ($setupText -notmatch '"type"\s*:\s*"setup"') {
                $failures.Add("separate output was not a setup failure: $setupText")
            }
        }
        if ([System.IO.File]::ReadAllText($guardTarget) -ne "ORIGINAL_TARGET") {
            $failures.Add("separate setup output changed the target")
        }
    } finally {
        if (Test-Path -LiteralPath $pathRoot) {
            Remove-Item -LiteralPath $pathRoot -Recurse -Force
        }
    }

    $emptyJson = ConvertTo-Json -InputObject $empty -Depth 8
    $badJson = ConvertTo-Json -InputObject $bad -Depth 8
    if ($emptyJson -notmatch '(?s)"findings":\s*\[\s*\]') {
        $kind = "null"
        if ($null -ne $empty["findings"]) {
            $kind = $empty["findings"].GetType().FullName
        }
        $failures.Add("empty findings were not serialized as an array ($kind): $emptyJson")
    }
    if ($badJson -notmatch '"findings":\s*null') {
        $failures.Add("failed findings were not serialized as null")
    }

    if ($failures.Count -gt 0) {
        foreach ($failure in $failures) {
            Write-Host "SELFTEST FAIL: $failure"
        }
        return 1
    }

    Write-Host "SELFTEST PASS"
    return 0
}

function Invoke-CrossReview {
    $runRoot = $null
    $result = $null
    $exitCode = 1
    $suppressResultWrite = $false
    $outputPath = $null
    $guardPaths = New-Object System.Collections.Generic.List[string]
    foreach ($path in @($Target) + @($Evidence) + @($Criteria)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$path)) {
            $guardPaths.Add([string]$path)
        }
    }

    try {
        $outputPath = Get-ComparablePath -Path $Output
        if (($Provider -eq "codex" -or $script:ModelWasSpecified) -and [string]::IsNullOrWhiteSpace($Model)) {
            throw "モデルが指定されていません。"
        }
        if (-not (Get-Command $Provider -ErrorAction SilentlyContinue)) {
            throw "$Provider コマンドが見つかりません。"
        }

        $targetPath = Resolve-ExistingPath -Path $Target -Label "レビュー対象"
        $criteriaPath = Resolve-ExistingPath -Path $Criteria -Label "レビュー基準"
        $evidencePaths = @()
        foreach ($item in @($Evidence)) {
            if ([string]::IsNullOrWhiteSpace($item)) {
                continue
            }
            $evidencePaths += Resolve-ExistingPath -Path $item -Label "根拠資料"
        }

        $versionResult = Get-ProviderVersion
        if ($versionResult.ExitCode -ne 0) {
            throw "$Provider --version に失敗しました。"
        }
        $codexVersion = ($versionResult.Output -replace "\s+", " ").Trim()
        $inputs = New-InputRecord -TargetPath $targetPath -EvidencePaths $evidencePaths -CriteriaPath $criteriaPath
        $collision = Test-OutputOverwritesInput -OutputPath $outputPath -InputPaths $guardPaths.ToArray()
        if ($collision) {
            $suppressResultWrite = $true
            Write-Host $collision
            $exitCode = 2
            return
        }

        $before = New-Object System.Collections.Specialized.OrderedDictionary
        $before[$targetPath] = Get-ContentFingerprint -Path $targetPath
        $before[$criteriaPath] = Get-ContentFingerprint -Path $criteriaPath
        foreach ($evidencePath in $evidencePaths) {
            $before[$evidencePath] = Get-ContentFingerprint -Path $evidencePath
        }

        $runRoot = New-RunDirectory
        $workspace = Join-Path $runRoot "workspace"
        [void](Copy-ReviewInput -Source $targetPath -DestinationDirectory (Join-Path $workspace "target"))
        [void](Copy-ReviewInput -Source $criteriaPath -DestinationDirectory (Join-Path $workspace "criteria"))
        foreach ($evidencePath in $evidencePaths) {
            [void](Copy-ReviewInput -Source $evidencePath -DestinationDirectory (Join-Path $workspace "evidence"))
        }

        Write-Host "$Provider のファイルアクセス制御を検証しています。"
        $probeResult = Test-ProviderAccess -RunRoot $runRoot -Workspace $workspace
        if ($probeResult.Failure) {
            $result = Add-CommonFields -Result (New-FailedResult -Type "access_control" -Message $probeResult.Failure) `
                -ModelName $Model -CodexVersion $codexVersion -Inputs $inputs -AccessControl $probeResult.Probe -SourcesUnchanged $true
            $exitCode = 1
        } else {
            $execution = Invoke-ProviderReview -RunRoot $runRoot -Workspace $workspace -Model $Model
            $execCode = $execution.ExitCode
            $messageText = $execution.MessageText
            $cliError = $execution.CliError

            $sourcesUnchanged = $true
            foreach ($path in @($before.Keys)) {
                $after = Get-ContentFingerprint -Path $path
                if ($after -ne $before[$path]) {
                    $sourcesUnchanged = $false
                }
            }

            $outcome = Get-ReviewOutcome -ExitCode ([int]$execCode) -MessageText $messageText -CliError $cliError
            if (-not $sourcesUnchanged -and $outcome["status"] -eq "completed") {
                $outcome = New-FailedResult -Type "source_modified" -Message "レビュー対象の元ファイルが変更されました。"
            }
            $result = Add-CommonFields -Result $outcome -ModelName $Model -CodexVersion $codexVersion `
                -Inputs $inputs -AccessControl $probeResult.Probe -SourcesUnchanged $sourcesUnchanged
            if ($result["status"] -eq "completed") {
                $exitCode = 0
            } else {
                $exitCode = 1
            }
        }
    } catch {
        Write-Host $_.Exception.Message
        if (-not $suppressResultWrite) {
            $failure = New-FailedResult -Type "setup" -Message $_.Exception.Message
            $inputs = New-InputRecord -TargetPath $Target -EvidencePaths @($Evidence) -CriteriaPath $Criteria
            $result = Add-CommonFields -Result $failure -ModelName $Model -CodexVersion "" -Inputs $inputs -AccessControl $null -SourcesUnchanged $null
        }
        $exitCode = 2
    } finally {
        $deleted = $false
        if ($runRoot) {
            try {
                Remove-RunDirectory -Path $runRoot
                $deleted = -not (Test-Path -LiteralPath $runRoot)
            } catch {
                Write-Host "一時ワークスペースの削除に失敗しました: $($_.Exception.Message)"
            }
        }
        $writeAllowed = $false
        if ($result -and -not $suppressResultWrite) {
            $decision = Test-ResultWriteAllowed -OutputPath $outputPath -InputPaths $guardPaths.ToArray()
            if ($decision["Allowed"]) {
                $writeAllowed = $true
            } else {
                Write-Host $decision["Message"]
                if ($exitCode -eq 0) {
                    $exitCode = 2
                }
            }
        }
        if ($writeAllowed) {
            $result["workspace_deleted"] = $deleted
            $outputParent = Split-Path -Parent $outputPath
            if ($outputParent -and -not (Test-Path -LiteralPath $outputParent)) {
                New-Item -ItemType Directory -Path $outputParent -Force | Out-Null
            }
            Write-JsonFile -Path $outputPath -Value $result
            Write-Host "レビュー結果を保存しました: $outputPath"
        }
        if ($runRoot -and -not $deleted -and $exitCode -eq 0) {
            $exitCode = 1
        }
        exit $exitCode
    }
}

if ($SelfTest) {
    exit (Invoke-SelfTest)
}

Invoke-CrossReview
