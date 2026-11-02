param(
    [string] $Remote = "origin",
    [string] $Branch = "main",
    [string] $FirstVersion = "0.1.0"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$tagPrefix = "v"

function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)]
        [string[]] $Arguments
    )

    $output = & git @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
    }

    return $output
}

function Format-Version {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Version
    )

    "$($Version.Major).$($Version.Minor).$($Version.Patch)"
}

function Get-ProjectSetting {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ProjectText,
        [Parameter(Mandatory = $true)]
        [string] $Name
    )

    $pattern = [regex]::Escape($Name) + ' = "([^"]+)"'
    $settingMatches = [regex]::Matches($ProjectText, $pattern)
    if ($settingMatches.Count -ne 2) {
        throw "Expected exactly two '$Name' settings in WMac.xcodeproj/project.pbxproj; found $($settingMatches.Count)."
    }

    $values = @($settingMatches | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    if ($values.Count -ne 1) {
        throw "The two '$Name' settings in WMac.xcodeproj/project.pbxproj do not match."
    }

    return [string] $values[0]
}

function Set-ProjectSetting {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ProjectText,
        [Parameter(Mandatory = $true)]
        [string] $Name,
        [Parameter(Mandatory = $true)]
        [string] $Value
    )

    $pattern = [regex]::Escape($Name) + ' = "[^"]+"'
    $replacement = "$Name = `"$Value`""
    [regex]::Replace($ProjectText, $pattern, $replacement)
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw "git was not found in PATH."
}

$firstVersionMatch = [regex]::Match(
    $FirstVersion,
    '^(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)$'
)
if (-not $firstVersionMatch.Success) {
    throw "FirstVersion '$FirstVersion' must use MAJOR.MINOR.PATCH format."
}
$FirstVersion = Format-Version ([pscustomobject]@{
    Major = [int] $firstVersionMatch.Groups["major"].Value
    Minor = [int] $firstVersionMatch.Groups["minor"].Value
    Patch = [int] $firstVersionMatch.Groups["patch"].Value
})

$repoRoot = (Invoke-Git -Arguments @("rev-parse", "--show-toplevel")).Trim()
Set-Location $repoRoot

$status = Invoke-Git -Arguments @("status", "--porcelain")
if ($status) {
    throw "Working tree is not clean. Commit or stash changes before publishing."
}

Write-Host "Fetching '$Remote'..."
Invoke-Git -Arguments @("fetch", "--prune", "--tags", $Remote) | Out-Null

Write-Host "Switching to '$Branch'..."
Invoke-Git -Arguments @("switch", $Branch) | Out-Null

Write-Host "Updating '$Branch' from '$Remote/$Branch'..."
Invoke-Git -Arguments @("pull", "--ff-only", $Remote, $Branch) | Out-Null

$status = Invoke-Git -Arguments @("status", "--porcelain")
if ($status) {
    throw "Working tree became dirty after updating '$Branch'."
}

$escapedPrefix = [regex]::Escape($tagPrefix)
$tagPattern = "^$escapedPrefix(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)$"
$latest = Invoke-Git -Arguments @("tag", "--merged", $Branch, "--list", "$tagPrefix*") |
    ForEach-Object {
        $tag = $_.Trim()
        $match = [regex]::Match($tag, $tagPattern)
        if ($match.Success) {
            [pscustomobject]@{
                Tag   = $tag
                Major = [int] $match.Groups["major"].Value
                Minor = [int] $match.Groups["minor"].Value
                Patch = [int] $match.Groups["patch"].Value
            }
        }
    } |
    Sort-Object Major, Minor, Patch |
    Select-Object -Last 1

if ($latest) {
    $previousVersion = Format-Version $latest
    $next = [pscustomobject]@{
        Major = $latest.Major
        Minor = $latest.Minor
        Patch = $latest.Patch + 1
    }
    $previousTag = $latest.Tag
}
else {
    $previousVersion = $null
    $next = [pscustomobject]@{
        Major = [int] $firstVersionMatch.Groups["major"].Value
        Minor = [int] $firstVersionMatch.Groups["minor"].Value
        Patch = [int] $firstVersionMatch.Groups["patch"].Value
    }
    $previousTag = "<none>"
}

$nextVersion = Format-Version $next
$nextTag = "$tagPrefix$nextVersion"

$existingLocalTag = Invoke-Git -Arguments @("tag", "--list", $nextTag)
if ($existingLocalTag) {
    throw "Tag '$nextTag' already exists locally."
}

$existingRemoteTag = Invoke-Git -Arguments @(
    "ls-remote",
    "--tags",
    "--refs",
    $Remote,
    "refs/tags/$nextTag"
)
if ($existingRemoteTag) {
    throw "Tag '$nextTag' already exists on '$Remote'."
}

$projectRelativePath = "WMac.xcodeproj/project.pbxproj"
$projectPath = Join-Path $repoRoot $projectRelativePath
$projectText = [System.IO.File]::ReadAllText($projectPath)
$currentVersion = Get-ProjectSetting -ProjectText $projectText -Name "MARKETING_VERSION"
$currentBuild = Get-ProjectSetting -ProjectText $projectText -Name "CURRENT_PROJECT_VERSION"

if ($currentVersion -notmatch '^\d+\.\d+\.\d+$') {
    throw "MARKETING_VERSION '$currentVersion' must use MAJOR.MINOR.PATCH format."
}
if ($currentBuild -notmatch '^[1-9]\d*$') {
    throw "CURRENT_PROJECT_VERSION '$currentBuild' must be a positive integer."
}

try {
    $currentBuildNumber = [long]::Parse($currentBuild, [Globalization.CultureInfo]::InvariantCulture)
}
catch {
    throw "CURRENT_PROJECT_VERSION '$currentBuild' is too large to increment safely."
}

$nextBuildNumber = $currentBuildNumber
if ($latest) {
    if ($currentVersion -eq $previousVersion) {
        $tagProjectText = (Invoke-Git -Arguments @("show", "${previousTag}:$projectRelativePath")) -join [Environment]::NewLine
        $tagBuild = Get-ProjectSetting -ProjectText $tagProjectText -Name "CURRENT_PROJECT_VERSION"
        if ($tagBuild -notmatch '^[1-9]\d*$') {
            throw "The previous release has an invalid CURRENT_PROJECT_VERSION '$tagBuild'."
        }
        $tagBuildNumber = [long]::Parse($tagBuild, [Globalization.CultureInfo]::InvariantCulture)
        $buildBase = [Math]::Max($currentBuildNumber, $tagBuildNumber)
        if ($buildBase -eq [long]::MaxValue) {
            throw "CURRENT_PROJECT_VERSION cannot be incremented beyond $([long]::MaxValue)."
        }
        $nextBuildNumber = $buildBase + 1
    }
    elseif ($currentVersion -eq $nextVersion) {
        $tagProjectText = (Invoke-Git -Arguments @("show", "${previousTag}:$projectRelativePath")) -join [Environment]::NewLine
        $tagBuild = Get-ProjectSetting -ProjectText $tagProjectText -Name "CURRENT_PROJECT_VERSION"
        if ($tagBuild -notmatch '^[1-9]\d*$') {
            throw "The previous release has an invalid CURRENT_PROJECT_VERSION '$tagBuild'."
        }
        $tagBuildNumber = [long]::Parse($tagBuild, [Globalization.CultureInfo]::InvariantCulture)
        if ($nextBuildNumber -le $tagBuildNumber) {
            if ($tagBuildNumber -eq [long]::MaxValue) {
                throw "CURRENT_PROJECT_VERSION cannot be incremented beyond $([long]::MaxValue)."
            }
            $nextBuildNumber = $tagBuildNumber + 1
        }
    }
    else {
        throw "MARKETING_VERSION '$currentVersion' does not match the latest release '$previousVersion' or the prepared next version '$nextVersion'."
    }
}
$nextBuild = $nextBuildNumber.ToString([Globalization.CultureInfo]::InvariantCulture)
$updatedProject = Set-ProjectSetting -ProjectText $projectText -Name "MARKETING_VERSION" -Value $nextVersion
$updatedProject = Set-ProjectSetting -ProjectText $updatedProject -Name "CURRENT_PROJECT_VERSION" -Value $nextBuild

Write-Host "Previous version tag: $previousTag"
Write-Host "Next version tag:     $nextTag"

if ($updatedProject -cne $projectText) {
    [System.IO.File]::WriteAllText($projectPath, $updatedProject, [System.Text.UTF8Encoding]::new($false))
    Invoke-Git -Arguments @("add", $projectRelativePath) | Out-Null
    Invoke-Git -Arguments @("commit", "-m", "Prepare release $nextTag") | Out-Null
    Write-Host "Updated MARKETING_VERSION to $nextVersion and CURRENT_PROJECT_VERSION to $nextBuild."
}
else {
    Write-Host "Project version metadata is already prepared for $nextTag."
}

$status = Invoke-Git -Arguments @("status", "--porcelain")
if ($status) {
    throw "Working tree is not clean after preparing release metadata."
}

$createdLocalTag = $false
try {
    Invoke-Git -Arguments @("tag", "-a", $nextTag, "-m", "Release $nextTag") | Out-Null
    $createdLocalTag = $true

    Invoke-Git -Arguments @("push", "--atomic", $Remote, $Branch, $nextTag) | Out-Null
}
catch {
    $originalError = $_

    if ($createdLocalTag) {
        $remoteTag = & git ls-remote --tags --refs $Remote "refs/tags/$nextTag"
        $remoteTagCheckExitCode = $LASTEXITCODE

        if ($remoteTagCheckExitCode -eq 0 -and -not $remoteTag) {
            & git tag -d $nextTag | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "Push failed and local tag '$nextTag' could not be removed."
            }
            else {
                Write-Host "Removed local tag '$nextTag' after failed push."
            }
        }
        elseif ($remoteTagCheckExitCode -eq 0) {
            Write-Host "Remote tag '$nextTag' exists; keeping the local tag for inspection."
        }
        else {
            Write-Warning "Could not verify whether remote tag '$nextTag' exists; keeping the local tag."
        }
    }

    Write-Warning "The script does not reset the branch after a failed push. If it created a version metadata commit, that commit remains local for retry."
    throw $originalError
}

Write-Host "Published release tag: $nextTag (build $nextBuild)"
