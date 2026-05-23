#
# update.ps1 - Robust mirror pipeline for catlikecoding.com
#
# Why NOT --mirror:
#   catlikecoding.com responds with 200 OK + homepage content for any
#   unknown URL (catch-all routing). Combined with the homepage's
#   document-relative links (href="unity/tutorials/" with no ../),
#   wget --mirror enters an infinite recursion that creates millions
#   of duplicate "homepage as <page>" files at bogus deep paths.
#
# Strategy:
#   Use git ls-files as the authoritative URL list (every file ever
#   committed). Also pull the 2 sitemap entries and crawl them for
#   any tutorials added since the last commit. Download via chunked
#   wget --input-file with --no-clobber so existing files are
#   preserved. Verify+retry catches anything wget missed. A safety
#   filter on every retried URL rejects those with repeated path
#   segments (the catch-all recursion fingerprint).
#
# Pipeline:
#   1. Build URL list (git + sitemap + crawl 2 index pages)
#   2. Chunked download (--input-file --no-clobber, no --mirror)
#   3. Verify + retry missing references (with segment-repeat guard)
#   4. Convert absolute URLs to relative (fix-absolute-links.ps1)
#   5. Summary
#

$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot

$siteHost        = 'catlikecoding.com'
$hostPrefix      = "https://$siteHost"
$mirrorRoot      = Join-Path $PSScriptRoot $siteHost
$urlListFile     = Join-Path $PSScriptRoot 'urls.txt'
$missingUrlsFile = Join-Path $PSScriptRoot '.missing-urls.txt'
$fixScript       = Join-Path $PSScriptRoot 'fix-absolute-links.ps1'
$chunkSize       = 50
$maxRetries      = 10
# Crawl entry points (catlikecoding sitemap only lists these two)
$crawlIndexes    = @(
    "$hostPrefix/unity/tutorials/",
    "$hostPrefix/godot/"
)

function Write-Phase($title) {
    Write-Host ''
    Write-Host ('=' * 60) -ForegroundColor Cyan
    Write-Host "  $title"  -ForegroundColor Cyan
    Write-Host ('=' * 60) -ForegroundColor Cyan
}

# Reject URLs that look like the catch-all recursion fingerprint:
# path too deep, OR any segment appearing 3+ times. Legitimate
# catlikecoding URLs sometimes repeat a segment once (e.g. a
# parent tutorial sharing a name with one of its sub-tutorials:
# /movement/swimming/swimming/foo.mp4) so 2 occurrences are fine.
# 3+ occurrences of the same segment is the loop fingerprint.
function Test-UrlLooksValid {
    param([string]$url)
    if (-not $url.StartsWith($hostPrefix)) { return $false }
    $path = $url.Substring($hostPrefix.Length).Trim('/')
    if (-not $path) { return $true }
    $segs = $path -split '/'
    if ($segs.Count -gt 10) { return $false }
    $counts = @{}
    foreach ($s in $segs) {
        if ($counts.ContainsKey($s)) {
            $counts[$s]++
            if ($counts[$s] -ge 3) { return $false }
        } else {
            $counts[$s] = 1
        }
    }
    return $true
}

# Convert a local file path (relative to script dir) into the URL it
# was originally fetched from.
function ConvertTo-Url {
    param([string]$relPath)
    if (-not $relPath.StartsWith("$siteHost/") -and $relPath -ne $siteHost) {
        return $null
    }
    $rel = $relPath.Substring($siteHost.Length).TrimStart('/')
    if ($rel.EndsWith('/index.html')) {
        $rel = $rel.Substring(0, $rel.Length - 'index.html'.Length)
    } elseif ($rel -eq 'index.html') {
        $rel = ''
    }
    return "$hostPrefix/$rel"
}

# Scan local HTML for src=/href= references whose local target file
# is missing. Returns absolute URLs suitable for wget --input-file.
function Get-MissingFiles {
    if (-not (Test-Path -LiteralPath $mirrorRoot)) { return @() }

    $missing  = New-Object 'System.Collections.Generic.HashSet[string]'
    $pattern  = '(?:src|href)="([^"]+)"'
    $rootNorm = (Get-Item -LiteralPath $mirrorRoot).FullName

    $htmlFiles = Get-ChildItem -Path $mirrorRoot -Recurse -Filter *.html -File
    foreach ($file in $htmlFiles) {
        $htmlDir = $file.DirectoryName
        $content = [System.IO.File]::ReadAllText($file.FullName)

        foreach ($m in [regex]::Matches($content, $pattern)) {
            $url = $m.Groups[1].Value
            if ([string]::IsNullOrEmpty($url)) { continue }

            $cleanUrl = ($url -split '[?#]')[0]
            if ($cleanUrl -match '^(data:|javascript:|mailto:|tel:|#|//)') { continue }
            if ([string]::IsNullOrEmpty($cleanUrl)) { continue }

            $localTarget = $null
            $absUrl      = $null

            if ($cleanUrl -match '^https?://') {
                if (-not $cleanUrl.StartsWith($hostPrefix)) { continue }
                $urlPath     = $cleanUrl.Substring($hostPrefix.Length).TrimStart('/')
                $absUrl      = $cleanUrl
                $localTarget = Join-Path $rootNorm ($urlPath -replace '/', '\')
            } elseif ($cleanUrl.StartsWith('/')) {
                $urlPath     = $cleanUrl.TrimStart('/')
                $absUrl      = "$hostPrefix/$urlPath"
                $localTarget = Join-Path $rootNorm ($urlPath -replace '/', '\')
            } else {
                try {
                    $resolved = [System.IO.Path]::GetFullPath(
                        (Join-Path $htmlDir ($cleanUrl -replace '/', '\'))
                    )
                } catch { continue }
                if (-not $resolved.StartsWith($rootNorm)) { continue }
                $localTarget = $resolved
                $relPart = $resolved.Substring($rootNorm.Length).TrimStart('\') -replace '\\', '/'
                $absUrl  = "$hostPrefix/$relPart"
            }

            if ($cleanUrl.EndsWith('/')) {
                $localTarget = Join-Path $localTarget 'index.html'
                if (-not $absUrl.EndsWith('/')) { $absUrl = "$absUrl/" }
            }

            if (-not (Test-Path -LiteralPath $localTarget -PathType Leaf)) {
                # Safety guard: skip catch-all recursion URLs
                if (Test-UrlLooksValid $absUrl) {
                    [void]$missing.Add($absUrl)
                }
            }
        }
    }
    return @($missing) | Sort-Object
}

# Check wget is on PATH
if (-not (Get-Command wget.exe -ErrorAction SilentlyContinue)) {
    Write-Host 'LOI: Khong tim thay wget.exe trong PATH.' -ForegroundColor Red
    exit 1
}

$wgetBaseOpts = @(
    '--force-directories',
    '--page-requisites',
    '--adjust-extension',
    '--restrict-file-names=windows',
    '--no-verbose',
    '--user-agent=Mozilla/5.0',
    '--secure-protocol=auto',
    '--max-redirect=5',
    '--tries=5',
    '--timeout=30',
    '--waitretry=5',
    '--retry-connrefused',
    '--retry-on-http-error=429,500,502,503,504',
    '--no-clobber'
)

# ------------------------------------------------------------
# Phase 1 - Build URL list (git + sitemap + index crawl)
# ------------------------------------------------------------
Write-Phase 'Phase 1/5: Build URL list'

$allUrls = New-Object 'System.Collections.Generic.HashSet[string]'

# (a) URLs from git-tracked files
Write-Host '  (a) git ls-files...'
$gitFiles = git ls-files $siteHost 2>$null
$gitCount = 0
foreach ($f in $gitFiles) {
    $u = ConvertTo-Url $f
    if ($u -and (Test-UrlLooksValid $u)) {
        $null = $allUrls.Add($u)
        $gitCount++
    }
}
Write-Host ("      {0} URLs tu git ({1} unique total)" -f $gitCount, $allUrls.Count)

# (b) Sitemap.xml entries (just the 2 index pages on catlikecoding)
Write-Host '  (b) sitemap.xml...'
try {
    $smResp = Invoke-WebRequest -Uri "$hostPrefix/sitemap.xml" -UseBasicParsing -TimeoutSec 30
    [xml]$smXml = $smResp.Content
    foreach ($urlNode in $smXml.urlset.url) {
        $loc = [string]$urlNode.loc
        if ($loc) { $null = $allUrls.Add($loc) }
    }
    Write-Host ("      OK ({0} unique total)" -f $allUrls.Count)
} catch {
    Write-Host "      WARN: $($_.Exception.Message)" -ForegroundColor Yellow
}

# (c) Crawl index pages to discover tutorials added since last commit
Write-Host '  (c) crawl 2 index pages de phat hien tutorial moi...'
foreach ($indexUrl in $crawlIndexes) {
    try {
        $resp = Invoke-WebRequest -Uri $indexUrl -UseBasicParsing -TimeoutSec 30
        $html = $resp.Content
        # Base path for resolving relative URLs
        $basePath = $indexUrl.Substring($hostPrefix.Length)  # e.g. /unity/tutorials/
        foreach ($m in [regex]::Matches($html, '(?:href|src)="([^"]+)"')) {
            $href = $m.Groups[1].Value
            $clean = ($href -split '[?#]')[0]
            if ($clean -match '^(data:|javascript:|mailto:|tel:|#|//)') { continue }
            if (-not $clean) { continue }

            $newUrl = $null
            if ($clean -match '^https?://') {
                if ($clean.StartsWith($hostPrefix)) { $newUrl = $clean }
            } elseif ($clean.StartsWith('/')) {
                $newUrl = "$hostPrefix$clean"
            } else {
                # Document-relative -> resolve against $indexUrl
                try {
                    $base   = [System.Uri]$indexUrl
                    $merged = New-Object System.Uri($base, $clean)
                    if ($merged.Host -eq $siteHost) {
                        $newUrl = $merged.AbsoluteUri
                    }
                } catch { }
            }
            if ($newUrl -and (Test-UrlLooksValid $newUrl)) {
                $null = $allUrls.Add($newUrl)
            }
        }
    } catch {
        Write-Host "      WARN crawl $indexUrl - $($_.Exception.Message)" -ForegroundColor Yellow
    }
}
Write-Host ("      OK ({0} unique URLs sau khi crawl)" -f $allUrls.Count)

if ($allUrls.Count -eq 0) {
    Write-Host '  LOI: Khong co URL nao.' -ForegroundColor Red
    exit 1
}

@($allUrls) | Sort-Object | Set-Content -LiteralPath $urlListFile -Encoding utf8
Write-Host ("  Tong: {0} URLs (luu tai urls.txt)" -f $allUrls.Count) -ForegroundColor Green

# ------------------------------------------------------------
# Phase 2 - Chunked download (no --mirror, --no-clobber)
# ------------------------------------------------------------
Write-Phase 'Phase 2/5: Tai chunked (no-clobber: chi tai file thieu)'

$urlArray    = @($allUrls) | Sort-Object
$totalChunks = [int][Math]::Ceiling($urlArray.Count / [double]$chunkSize)

for ($i = 0; $i -lt $urlArray.Count; $i += $chunkSize) {
    $chunkIdx = [int]($i / $chunkSize) + 1
    $chunkEnd = [Math]::Min($i + $chunkSize - 1, $urlArray.Count - 1)
    $chunk    = $urlArray[$i..$chunkEnd]

    Write-Host ''
    Write-Host ("  Chunk {0}/{1} - {2} URLs..." -f $chunkIdx, $totalChunks, $chunk.Count) -ForegroundColor White

    $chunkFile = Join-Path $PSScriptRoot (".chunk-{0:D3}.txt" -f $chunkIdx)
    Set-Content -LiteralPath $chunkFile -Value $chunk -Encoding utf8

    $chunkOpts = @('--input-file', $chunkFile) + $wgetBaseOpts
    & wget.exe @chunkOpts | Out-Null
    Write-Host "    wget exit: $LASTEXITCODE" -ForegroundColor DarkGray

    Remove-Item -LiteralPath $chunkFile -ErrorAction SilentlyContinue
}

# ------------------------------------------------------------
# Phase 3 - Verify + retry (with safety guard)
# ------------------------------------------------------------
Write-Phase 'Phase 3/5: Verify + retry missing'

$previousSignature = $null

for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
    Write-Host ''
    Write-Host "  Scan #$attempt - kiem tra file thieu..." -ForegroundColor White

    $missing = @(Get-MissingFiles)

    if ($missing.Count -eq 0) {
        Write-Host '  Tat ca reference da co local.' -ForegroundColor Green
        break
    }

    $signature = ($missing -join '|')
    if ($signature -eq $previousSignature) {
        Write-Host "  $($missing.Count) file van thieu - khong tien trien, dung retry." -ForegroundColor Yellow
        break
    }
    $previousSignature = $signature

    Write-Host "  $($missing.Count) file thieu - tai lai chunked..." -ForegroundColor Yellow

    $missArray  = @($missing)
    $missChunks = [int][Math]::Ceiling($missArray.Count / [double]$chunkSize)

    for ($j = 0; $j -lt $missArray.Count; $j += $chunkSize) {
        $jChunkIdx = [int]($j / $chunkSize) + 1
        $jChunkEnd = [Math]::Min($j + $chunkSize - 1, $missArray.Count - 1)
        $jChunk    = $missArray[$j..$jChunkEnd]

        Write-Host ("    Retry chunk {0}/{1} - {2} URLs..." -f $jChunkIdx, $missChunks, $jChunk.Count) -ForegroundColor DarkYellow

        $rFile = Join-Path $PSScriptRoot (".retry-{0:D3}.txt" -f $jChunkIdx)
        Set-Content -LiteralPath $rFile -Value $jChunk -Encoding utf8

        $rOpts = @('--input-file', $rFile) + $wgetBaseOpts
        & wget.exe @rOpts | Out-Null

        Remove-Item -LiteralPath $rFile -ErrorAction SilentlyContinue
    }
}

# ------------------------------------------------------------
# Phase 4 - Convert URLs to relative paths
# ------------------------------------------------------------
Write-Phase 'Phase 4/5: Convert URLs to relative paths'

if (Test-Path -LiteralPath $fixScript -PathType Leaf) {
    & $fixScript
} else {
    Write-Host "fix-absolute-links.ps1 khong tim thay - bo qua." -ForegroundColor Yellow
}

# ------------------------------------------------------------
# Phase 5 - Summary
# ------------------------------------------------------------
Write-Phase 'Phase 5/5: Summary'

if (Test-Path -LiteralPath $mirrorRoot) {
    $allFiles  = Get-ChildItem -Path $mirrorRoot -Recurse -File -ErrorAction SilentlyContinue
    $htmlCount = @($allFiles | Where-Object { $_.Extension -eq '.html' }).Count
    $imgCount  = @($allFiles | Where-Object { $_.Extension -match '\.(png|jpg|jpeg|gif|svg|webp|ico)$' }).Count
    $mp4Count  = @($allFiles | Where-Object { $_.Extension -eq '.mp4'  }).Count
    $cssCount  = @($allFiles | Where-Object { $_.Extension -eq '.css'  }).Count
    $jsCount   = @($allFiles | Where-Object { $_.Extension -eq '.js'   }).Count
    $totalSize = ($allFiles | Measure-Object -Property Length -Sum).Sum
    $sizeMb    = if ($totalSize) { '{0:N2} MB' -f ($totalSize / 1MB) } else { '0 MB' }

    Write-Host ("  HTML pages:  {0}" -f $htmlCount) -ForegroundColor Cyan
    Write-Host ("  Images:      {0}" -f $imgCount)  -ForegroundColor Cyan
    Write-Host ("  MP4 videos:  {0}" -f $mp4Count)  -ForegroundColor Cyan
    Write-Host ("  CSS:         {0}" -f $cssCount)  -ForegroundColor Cyan
    Write-Host ("  JS:          {0}" -f $jsCount)   -ForegroundColor Cyan
    Write-Host ("  Total size:  {0}" -f $sizeMb)    -ForegroundColor Cyan
} else {
    Write-Host '  Khong co mirror folder.' -ForegroundColor Yellow
    return
}

$finalMissing = @(Get-MissingFiles)
if ($finalMissing.Count -eq 0) {
    Write-Host ''
    Write-Host '  Tat ca reference da resolve. Mirror complete.' -ForegroundColor Green
} else {
    Write-Host ''
    Write-Host ("  Con {0} URL khong co file local (external hoac 404):" -f $finalMissing.Count) -ForegroundColor Yellow
    $finalMissing | Select-Object -First 15 | ForEach-Object {
        Write-Host "    $_" -ForegroundColor DarkGray
    }
    if ($finalMissing.Count -gt 15) {
        Write-Host ("    ... va {0} URL khac." -f ($finalMissing.Count - 15)) -ForegroundColor DarkGray
    }
}
