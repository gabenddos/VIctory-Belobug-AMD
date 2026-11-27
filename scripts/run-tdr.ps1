# Diag TDR bisect runner: sets env, tees a log, optional hash accumulate/loop.
#
# Recommended (you still press Enter once per run if you want):
#   .\scripts\run-tdr.ps1 -Kinds compute -Hashes 910b4be059bfb28f,bff8660bf8e29c26
#   .\scripts\run-tdr.ps1 -Kinds compute,mesh            # OK: -Kinds is string[] (comma = array)
#   .\scripts\run-tdr.ps1 -Kinds compute -FromRemoved   # after a crash (also merges into .pool)
#
# Binary-search the hash pool (~50% per step) — prefer this over peeling ~30 FromRemoved:
#   .\scripts\run-tdr.ps1 -Kinds compute -LoadPool      # skip = all of tdr-skip-hashes.txt.pool
#   # stable →  .\scripts\run-tdr.ps1 -Kinds compute -BisectStable
#   # TDR    →  .\scripts\run-tdr.ps1 -Kinds compute -BisectCrash
#
# Unattended loop (auto Enter via VICTORY_KEYS — tweak -Keys if menu timing differs):
#   .\scripts\run-tdr.ps1 -Kinds compute -Loop -Keys "50:Enter,55:Enter,60:Enter,70:Enter,90:Enter"
#
#   .\scripts\run-tdr.ps1 -ClearSkips

param(
    # Accepts -Kinds compute,mesh (PowerShell array) or -Kinds "compute,mesh".
    [string[]]$Kinds = @(),
    # Accepts -Hashes a,b,c (PowerShell array) or -Hashes "a,b,c" (one string).
    [string[]]$Hashes = @(),
    [string]$TextureMax = "128",
    # VICTORY_SHADER_LOOP_LIMIT. Default 1024 for AMD TDRs (4096 still left
    # enough work with mesh EI + dispatch 4096x1x1 — run-20261127-042742).
    # Pass -LoopLimit 1048576 to restore the translator default; -LoopLimit "" to leave unset.
    [string]$LoopLimit = "1024",
    [string]$Console = "series-s",
    [string]$GameExe = "",
    [string]$VictoryExe = "",
    # Seconds after input starts: key name (Enter, Esc, A, ...). Empty = no auto keys.
    [string]$Keys = "",
    [switch]$FromRemoved,
    # Load tdr-skip-hashes.txt.pool into the active skip list (full universe).
    [switch]$LoadPool,
    # After a STABLE run: parent := current skips, then keep first half only.
    [switch]$BisectStable,
    # After a TDR: keep second half of parent (parent unchanged).
    [switch]$BisectCrash,
    [switch]$Loop,
    [switch]$ClearSkips,
    [int]$MaxLoops = 20
)

# Continue: victory logs on stderr; with Stop, Tee-Object turns INFO into NativeCommandError.
$ErrorActionPreference = "Continue"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root

$SkipFile = Join-Path $Root "tdr-skip-hashes.txt"
$PoolFile = Join-Path $Root "tdr-skip-hashes.txt.pool"
$ParentFile = Join-Path $Root "tdr-skip-hashes.txt.bisect-parent"
$RemovedLog = Join-Path $Root "victory-gpu-removed.log"
$DefaultGame = "C:\Users\gabri\Downloads\GTA6.Xbox.v1.0.2.1-CYBERLEEK\game_scarlett_master.exe"
if (-not $GameExe) { $GameExe = $DefaultGame }
if (-not $VictoryExe) { $VictoryExe = Join-Path $Root "target\diag\victory.exe" }

if ($BisectStable -and $BisectCrash) {
    Write-Host "Use only one of -BisectStable or -BisectCrash"
    exit 1
}
if (($LoadPool -or $BisectStable -or $BisectCrash) -and $ClearSkips) {
    Write-Host "Do not combine -ClearSkips with -LoadPool / -BisectStable / -BisectCrash"
    exit 1
}

if (-not (Test-Path $VictoryExe)) {
    Write-Host "Missing $VictoryExe — build first:"
    Write-Host "  cargo build --profile diag -p victory --features diagnostics"
    exit 1
}
if (-not (Test-Path $GameExe)) {
    Write-Host "Missing game exe: $GameExe"
    exit 1
}

function Read-SkipFile {
    if (-not (Test-Path $SkipFile)) { return [System.Collections.Generic.List[string]]::new() }
    $list = [System.Collections.Generic.List[string]]::new()
    Get-Content $SkipFile | ForEach-Object {
        $h = $_.Trim().ToLowerInvariant()
        if ($h -match '^[0-9a-f]{16}$' -and -not $list.Contains($h)) { $list.Add($h) }
    }
    return $list
}

function Write-SkipFile([System.Collections.Generic.List[string]]$list) {
    $list | Sort-Object -Unique | Set-Content -Path $SkipFile -Encoding utf8
}

function Parse-HashesFromRemoved([string]$path) {
    $found = [System.Collections.Generic.List[string]]::new()
    if (-not (Test-Path $path)) { return $found }
    $text = Get-Content $path -Raw
    [regex]::Matches($text, '\b([0-9a-f]{16})\b') | ForEach-Object {
        $h = $_.Groups[1].Value
        if (-not $found.Contains($h)) { $found.Add($h) }
    }
    return $found
}

if ($ClearSkips) {
    Remove-Item $SkipFile -ErrorAction SilentlyContinue
    Write-Host "Cleared $SkipFile"
    # Exit only when ClearSkips is the sole action (no run / no other flags).
    if (-not $Kinds -and $Hashes.Count -eq 0 -and -not $FromRemoved -and -not $Loop -and -not $LoadPool -and -not $BisectStable -and -not $BisectCrash -and -not $LoopLimit) { exit 0 }
}

function Merge-Hashes([System.Collections.Generic.List[string]]$into, $extra) {
    $added = 0
    foreach ($h in $extra) {
        $n = "$h".Trim().ToLowerInvariant()
        if ($n -match '^[0-9a-f]{16}$' -and -not $into.Contains($n)) {
            $into.Add($n)
            $added++
        }
    }
    return $added
}

function Flatten-HashArgs([string[]]$items) {
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($item in $items) {
        foreach ($part in ($item -split '[,;\s]+')) {
            $t = $part.Trim()
            if ($t) { $out.Add($t) }
        }
    }
    return $out
}

function Read-HashFile([string]$path) {
    $list = [System.Collections.Generic.List[string]]::new()
    if (-not (Test-Path $path)) { return $list }
    Get-Content $path | ForEach-Object {
        $h = $_.Trim().ToLowerInvariant()
        if ($h -match '^[0-9a-f]{16}$' -and -not $list.Contains($h)) { $list.Add($h) }
    }
    return $list
}

function Write-HashFile([string]$path, $list) {
    @($list) | Sort-Object -Unique | Set-Content -Path $path -Encoding utf8
}

if ($LoadPool) {
    if (-not (Test-Path $PoolFile)) {
        Write-Host "Missing $PoolFile — build a pool first (union of checkpoints / peels)."
        exit 1
    }
    $pool = Read-HashFile $PoolFile
    Write-HashFile $SkipFile $pool
    Write-HashFile $ParentFile $pool
    Write-Host "Loaded pool: $($pool.Count) hashes -> skip + bisect-parent"
}

if ($BisectStable) {
    $cur = Read-HashFile $SkipFile
    if ($cur.Count -lt 2) {
        Write-Host "Need at least 2 hashes in $SkipFile to bisect (have $($cur.Count))"
        exit 1
    }
    Write-HashFile $ParentFile $cur
    $n = [Math]::Max(1, [Math]::Floor($cur.Count / 2))
    $half = $cur | Select-Object -First $n
    Write-HashFile $SkipFile $half
    Write-Host "BisectStable: parent=$($cur.Count) -> keep first $n (of $($cur.Count))"
}

if ($BisectCrash) {
    $parent = Read-HashFile $ParentFile
    if ($parent.Count -lt 2) {
        Write-Host "Missing/short bisect parent ($ParentFile). Run -LoadPool or -BisectStable first."
        exit 1
    }
    $n = [Math]::Max(1, [Math]::Floor($parent.Count / 2))
    $second = $parent | Select-Object -Skip $n
    if ($second.Count -eq 0) {
        Write-Host "BisectCrash: second half empty (parent=$($parent.Count))"
        exit 1
    }
    Write-HashFile $SkipFile $second
    Write-Host "BisectCrash: parent=$($parent.Count) -> keep second $($second.Count) (skipped first $n)"
}

$accumulated = Read-SkipFile

if ($Hashes.Count -gt 0) {
    $flat = Flatten-HashArgs $Hashes
    $n = Merge-Hashes $accumulated $flat
    Write-Host "Merged $n hash(es) from -Hashes (total $($accumulated.Count))"
    if ($n -eq 0) {
        Write-Host "WARNING: no valid 16-hex hashes parsed from -Hashes. Quote the list or check format."
    }
}

$iteration = 0
$lastLog = ""
$lastHadRemoved = $false
do {
    $iteration++
    if ($FromRemoved -or ($Loop -and $iteration -gt 1)) {
        $fromFile = Parse-HashesFromRemoved $RemovedLog
        $n = Merge-Hashes $accumulated $fromFile
        Write-Host "Merged $n hash(es) from victory-gpu-removed.log (total $($accumulated.Count))"
        # Grow the binary-search universe too.
        $pool = Read-HashFile $PoolFile
        $pn = Merge-Hashes $pool $fromFile
        if ($pn -gt 0) {
            Write-HashFile $PoolFile $pool
            Write-Host "Pool += $pn -> $($pool.Count) in $PoolFile"
        }
    }

    Write-SkipFile $accumulated

    if ($Loop -and -not $Keys) {
        # Default spam Enter across typical logo/menu window so -Loop can reach world.
        $Keys = "45:Enter,50:Enter,55:Enter,60:Enter,70:Enter,80:Enter,90:Enter,100:Enter,120:Enter"
        Write-Host "Loop: using default -Keys '$Keys' (override if menu timing differs)"
    }

    $env:VICTORY_D3D12_DRED = "1"
    $env:VICTORY_TEXTURE_MAX = $TextureMax
    if ($LoopLimit) {
        $env:VICTORY_SHADER_LOOP_LIMIT = $LoopLimit
    } else {
        Remove-Item Env:VICTORY_SHADER_LOOP_LIMIT -ErrorAction SilentlyContinue
    }
    # PowerShell turns -Kinds compute,mesh into a 2-element array; join for the env var.
    $kindsEnv = (@($Kinds) | ForEach-Object { "$_" -split '[,;\s]+' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join ","
    if ($kindsEnv) {
        $env:VICTORY_SKIP_KINDS = $kindsEnv
    } else {
        Remove-Item Env:VICTORY_SKIP_KINDS -ErrorAction SilentlyContinue
    }
    if ($accumulated.Count -gt 0) {
        $env:VICTORY_SKIP_PIPELINES = ($accumulated -join ",")
    } else {
        Remove-Item Env:VICTORY_SKIP_PIPELINES -ErrorAction SilentlyContinue
    }
    if ($Keys) {
        $env:VICTORY_KEYS = $Keys
    } else {
        Remove-Item Env:VICTORY_KEYS -ErrorAction SilentlyContinue
    }

    Remove-Item Env:VICTORY_D3D12_DEBUG, Env:VICTORY_D3D12_GBV, Env:VICTORY_D3D12_WARP -ErrorAction SilentlyContinue
    Remove-Item $RemovedLog -ErrorAction SilentlyContinue

    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $log = Join-Path $Root "run-$stamp.log"
    $lastLog = $log

    Write-Host ""
    Write-Host "=== TDR run #$iteration ==="
    Write-Host "Kinds:  $(if ($kindsEnv) { $kindsEnv } else { '(none)' })"
    Write-Host "Hashes: $($accumulated.Count)  -> $SkipFile"
    Write-Host "Keys:   $(if ($Keys) { $Keys } else { '(none — press Enter yourself)' })"
    Write-Host "Log:    $log"
    Write-Host "Exe:    $VictoryExe"
    Write-Host ""

    # Native stderr must not become terminating errors under the pipeline.
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & $VictoryExe run --execute $GameExe --console $Console 2>&1 |
        ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.ToString() } else { $_ }
        } |
        Tee-Object -FilePath $log
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prevEap
    $lastHadRemoved = Test-Path $RemovedLog

    Write-Host ""
    Write-Host "Exit code: $code"
    Write-Host "Log: $log"
    if ($lastHadRemoved) {
        Write-Host "GPU report: $RemovedLog"
        $preview = (Get-Content $RemovedLog -Raw)
        if ($preview.Length -gt 400) { $preview = $preview.Substring(0, 400) + "..." }
        Write-Host $preview
    } else {
        Write-Host "No victory-gpu-removed.log (no device-removed dump, or you quit cleanly)."
    }

    if (-not $Loop) { break }
    if (-not $lastHadRemoved) {
        Write-Host "Loop stop: no GPU removal report (stable or manual close)."
        break
    }
    if ($iteration -ge $MaxLoops) {
        Write-Host "Loop stop: hit -MaxLoops $MaxLoops"
        break
    }
    Write-Host "Loop: merging new hashes and restarting in 5s (Ctrl+C to stop)..."
    Start-Sleep -Seconds 5
} while ($true)

Write-Host ""
if ($lastLog) {
    Write-Host "Last log: $lastLog"
}
