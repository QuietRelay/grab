<#
    Grab - a tiny interactive front end for yt-dlp.

    Load it from your PowerShell profile:
        Import-Module "$HOME\Tools\Grab\Grab.psm1"
    then run:
        grab            # uses the URL on your clipboard, or asks for one
        grab <url>      # start with a specific URL

    Works in Windows PowerShell 5.1 and PowerShell 7+.
#>

$script:SettingsPath = Join-Path $HOME '.grab.json'
$script:VideoFolder  = Join-Path (Join-Path $HOME 'Downloads') 'Videos'
$script:AudioFolder  = Join-Path (Join-Path $HOME 'Downloads') 'Audio'

# %(title).120B caps the title at 120 bytes: X/Twitter "titles" are the whole
# post text, which otherwise blows past Windows path limits.
$script:NameTemplate = '%(uploader,uploader_id|Unknown)s - %(title).120B [%(id)s].%(ext)s'
$script:ClipTemplate = '%(uploader,uploader_id|Unknown)s - %(title).100B - clip %(section_start)d-%(section_end)d [%(id)s].%(ext)s'

$script:Browsers = @('firefox', 'chrome', 'edge', 'brave', 'opera', 'vivaldi', 'chromium')

# ---------------------------------------------------------------- settings

function Get-GrabSettings {
    $settings = [pscustomobject]@{ CookieBrowser = ''; OpenWhenDone = $true }
    try {
        if (Test-Path -LiteralPath $script:SettingsPath) {
            $saved = Get-Content -LiteralPath $script:SettingsPath -Raw | ConvertFrom-Json
            if ($null -ne $saved.CookieBrowser) { $settings.CookieBrowser = [string]$saved.CookieBrowser }
            if ($null -ne $saved.OpenWhenDone)  { $settings.OpenWhenDone  = [bool]$saved.OpenWhenDone }
        }
    } catch {
        Write-Host "  (Ignoring unreadable settings file $script:SettingsPath)" -ForegroundColor DarkGray
    }
    $settings
}

function Save-GrabSettings($Settings) {
    try {
        $Settings | ConvertTo-Json | Set-Content -LiteralPath $script:SettingsPath -Encoding UTF8
    } catch {
        Write-Host "  Could not save settings: $($_.Exception.Message)" -ForegroundColor DarkYellow
    }
}

# ---------------------------------------------------------------- helpers

function ConvertTo-GrabUrl([string]$Text) {
    # Returns a cleaned-up URL, or $null if the text doesn't look like one.
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $candidate = $Text.Trim().Trim('"', "'", '<', '>')
    if ($candidate -match '^https?://\S+$') { return $candidate }
    return $null
}

function Get-ClipboardUrl {
    try {
        $clip = Get-Clipboard -Raw -ErrorAction Stop
    } catch {
        return $null
    }
    ConvertTo-GrabUrl $clip
}

function Read-GrabUrl {
    $clipUrl = Get-ClipboardUrl
    Write-Host ""
    if ($clipUrl) {
        Write-Host "  Clipboard: " -NoNewline -ForegroundColor DarkGray
        Write-Host $clipUrl -ForegroundColor Cyan
        $typed = Read-Host "  Paste URL (Enter = use clipboard)"
        if ([string]::IsNullOrWhiteSpace($typed)) { return $clipUrl }
    } else {
        $typed = Read-Host "  Paste URL"
    }
    $url = ConvertTo-GrabUrl $typed
    if (-not $url -and -not [string]::IsNullOrWhiteSpace($typed)) {
        Write-Host "  That doesn't look like an http(s) URL." -ForegroundColor Red
    }
    $url
}

function Write-GrabItem([string]$Key, [string]$Label, [string]$Note) {
    Write-Host "  [" -NoNewline -ForegroundColor DarkGray
    Write-Host $Key -NoNewline -ForegroundColor Yellow
    Write-Host "] " -NoNewline -ForegroundColor DarkGray
    if ($Note) {
        Write-Host $Label -NoNewline
        Write-Host "  $Note" -ForegroundColor DarkGray
    } else {
        Write-Host $Label
    }
}

function Write-GrabStatus([string]$Label, [string]$Value, [string]$Color = 'White') {
    Write-Host ("  {0,-9}: " -f $Label) -NoNewline -ForegroundColor DarkGray
    Write-Host $Value -ForegroundColor $Color
}

function Show-GrabHeader {
    Clear-Host
    Write-Host "========================================" -ForegroundColor DarkCyan
    Write-Host "             MEDIA GRABBER" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor DarkCyan
    Write-Host ""
}

function Wait-GrabKey {
    Write-Host ""
    [void](Read-Host "  Press Enter to return to the menu")
}

function Test-GrabTime([string]$Value) {
    # Accepts 90, 1:30, 01:30, 00:01:30, 00:01:30.5
    $Value -match '^\d+(:\d{1,2}){0,2}(\.\d+)?$'
}

function Open-GrabResult([string]$Folder, [string[]]$Files) {
    $file = $Files | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Last 1
    try {
        if ($env:OS -eq 'Windows_NT' -and $file) {
            # Opens Explorer with the new file highlighted.
            Start-Process explorer.exe -ArgumentList "/select,`"$file`""
        } else {
            Invoke-Item -LiteralPath $Folder
        }
    } catch {
        Write-Host "  Could not open $Folder" -ForegroundColor DarkYellow
    }
}

# Runs yt-dlp with the shared options (download folder, cookies, file tracking)
# and reports success/failure.
#
# Deliberately returns nothing: callers must invoke it as a plain statement.
# Capturing its output ($x = ..., [void](...)) would also redirect yt-dlp's
# stdout away from the console and kill the live progress bar.
function Invoke-GrabDownload {
    param(
        [string]$Url,
        [string]$Folder,
        [string[]]$Arguments,
        $Settings
    )

    New-Item -ItemType Directory -Force -Path $Folder | Out-Null

    # yt-dlp appends each finished file's final path here, so we can
    # highlight it in Explorer afterwards without parsing its output.
    $printFile = [IO.Path]::GetTempFileName()

    $ytArgs = @('-P', $Folder, '--print-to-file', 'after_move:filepath', $printFile)
    if ($Settings.CookieBrowser) {
        $ytArgs += @('--cookies-from-browser', $Settings.CookieBrowser)
    }
    $ytArgs += $Arguments
    $ytArgs += @('--', $Url)

    Write-Host ""
    & yt-dlp @ytArgs
    $ok = ($LASTEXITCODE -eq 0)

    $files = @()
    try {
        $files = @(Get-Content -LiteralPath $printFile -Encoding UTF8 -ErrorAction Stop |
                   Where-Object { $_ })
    } catch { }
    Remove-Item -LiteralPath $printFile -ErrorAction SilentlyContinue

    Write-Host ""
    if ($ok) {
        Write-Host "  Done." -ForegroundColor Green
        foreach ($f in $files) {
            Write-Host "  -> $f" -ForegroundColor DarkGreen
        }
        if ($Settings.OpenWhenDone) { Open-GrabResult $Folder $files }
    } else {
        Write-Host "  yt-dlp exited with code $LASTEXITCODE." -ForegroundColor Red
        if (-not $Settings.CookieBrowser) {
            Write-Host "  If this needs a login (age-gated, private, NSFW on X), try [C] to use browser cookies." -ForegroundColor DarkYellow
        }
        Write-Host "  Sites change often; [Y] updates yt-dlp." -ForegroundColor DarkYellow
    }
}

# ---------------------------------------------------------------- sub-menus

function Read-GrabQuality {
    Write-Host ""
    Write-GrabItem '1' '2160p / 4K'
    Write-GrabItem '2' '1440p'
    Write-GrabItem '3' '1080p'
    Write-GrabItem '4' '720p'
    Write-GrabItem '5' '480p'
    Write-GrabItem 'B' 'Back'
    Write-Host ""
    $heights = @{ '1' = 2160; '2' = 1440; '3' = 1080; '4' = 720; '5' = 480 }
    $pick = (Read-Host "  Choose quality").Trim()
    if ($heights.ContainsKey($pick)) { return $heights[$pick] }
    return $null
}

function Read-GrabCookieBrowser($Settings) {
    Write-Host ""
    Write-Host "  Borrow your login from a browser, for private, age-gated or" -ForegroundColor DarkGray
    Write-Host "  members-only videos. Firefox is the most reliable; Chromium-based" -ForegroundColor DarkGray
    Write-Host "  browsers usually need to be fully closed first." -ForegroundColor DarkGray
    Write-Host ""
    Write-GrabItem '0' 'Off'
    for ($i = 0; $i -lt $script:Browsers.Count; $i++) {
        Write-GrabItem ([string]($i + 1)) $script:Browsers[$i]
    }
    Write-Host ""
    $pick = (Read-Host "  Choose").Trim()
    if ($pick -eq '0') {
        $Settings.CookieBrowser = ''
    } elseif ($pick -match '^\d+$' -and [int]$pick -ge 1 -and [int]$pick -le $script:Browsers.Count) {
        $Settings.CookieBrowser = $script:Browsers[[int]$pick - 1]
    } else {
        return
    }
    Save-GrabSettings $Settings
}

# ---------------------------------------------------------------- main

function grab {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Url
    )

    if (-not (Get-Command yt-dlp -ErrorAction SilentlyContinue)) {
        Write-Host "yt-dlp not found on PATH. Install it with:" -ForegroundColor Red
        Write-Host "    winget install yt-dlp.yt-dlp" -ForegroundColor Yellow
        return
    }
    $hasFfmpeg = [bool](Get-Command ffmpeg -ErrorAction SilentlyContinue)

    $settings = Get-GrabSettings

    Show-GrabHeader
    if ($Url) {
        $Url = ConvertTo-GrabUrl $Url
        if (-not $Url) { Write-Host "  That doesn't look like an http(s) URL." -ForegroundColor Red }
    }
    if (-not $Url) { $Url = Read-GrabUrl }
    if (-not $Url) {
        Write-Host "  No URL provided." -ForegroundColor DarkYellow
        return
    }

    $baseVideo = @('-o', $script:NameTemplate)

    while ($true) {
        Show-GrabHeader

        Write-GrabStatus 'URL' $Url 'Cyan'
        if ($settings.CookieBrowser) {
            Write-GrabStatus 'Cookies' $settings.CookieBrowser 'Green'
        } else {
            Write-GrabStatus 'Cookies' 'off' 'DarkGray'
        }
        if ($settings.OpenWhenDone) {
            Write-GrabStatus 'Open' 'folder opens when finished' 'Green'
        } else {
            Write-GrabStatus 'Open' 'off' 'DarkGray'
        }
        if (-not $hasFfmpeg) {
            Write-GrabStatus 'ffmpeg' 'NOT FOUND - merging, MP3/M4A and clips will fail (winget install Gyan.FFmpeg)' 'Red'
        }

        # Offer a newly copied link without making you go through [U].
        $clipUrl = Get-ClipboardUrl
        $clipIsNew = $clipUrl -and ($clipUrl -ne $Url)

        Write-Host ""
        Write-GrabItem '1' 'Best Video'
        Write-GrabItem '2' 'Best Video - MP4'
        Write-GrabItem '3' 'Audio Only - MP3'
        Write-GrabItem '4' 'Audio Only - M4A'
        Write-GrabItem '5' 'Choose Video Quality'
        Write-GrabItem '6' 'Download Clip / Time Range'
        Write-GrabItem '7' 'Download Subtitles'
        Write-GrabItem '8' 'Download Thumbnail'
        Write-GrabItem '9' 'Show Available Formats'
        Write-Host ""
        if ($clipIsNew) {
            Write-GrabItem 'N' 'Use new clipboard URL' $clipUrl
        }
        Write-GrabItem 'U' 'Enter a different URL'
        Write-GrabItem 'C' 'Browser cookies'
        Write-GrabItem 'O' 'Toggle open folder when finished'
        Write-GrabItem 'Y' 'Update yt-dlp'
        Write-GrabItem '0' 'Exit'
        Write-Host ""

        $choice = (Read-Host "  Choose").Trim().ToUpperInvariant()

        switch ($choice) {

            '1' {
                Invoke-GrabDownload $Url $script:VideoFolder ($baseVideo + @('-f', 'bv*+ba/b')) $settings
                Wait-GrabKey
            }

            '2' {
                # Prefer H.264/AAC so the MP4 plays everywhere (phones, Premiere,
                # Windows' built-in player) instead of VP9/AV1 stuffed in MP4.
                $mp4Args = $baseVideo + @(
                    '-f', 'bv*+ba/b',
                    '-S', 'vcodec:h264,acodec:aac',
                    '--merge-output-format', 'mp4'
                )
                Invoke-GrabDownload $Url $script:VideoFolder $mp4Args $settings
                Wait-GrabKey
            }

            '3' {
                $mp3Args = $baseVideo + @('-x', '--audio-format', 'mp3', '--audio-quality', '0')
                Invoke-GrabDownload $Url $script:AudioFolder $mp3Args $settings
                Wait-GrabKey
            }

            '4' {
                $m4aArgs = $baseVideo + @('-x', '--audio-format', 'm4a')
                Invoke-GrabDownload $Url $script:AudioFolder $m4aArgs $settings
                Wait-GrabKey
            }

            '5' {
                $height = Read-GrabQuality
                if ($height) {
                    $qualityArgs = $baseVideo + @(
                        '-f', "bv*[height<=$height]+ba/b[height<=$height]/b",
                        '--merge-output-format', 'mp4'
                    )
                    Invoke-GrabDownload $Url $script:VideoFolder $qualityArgs $settings
                    Wait-GrabKey
                }
            }

            '6' {
                Write-Host ""
                $start = (Read-Host "  Start time (e.g. 1:30 or 00:01:30)").Trim()
                $end   = (Read-Host "  End time   (e.g. 2:15, blank = to the end)").Trim()
                if (-not $end) { $end = 'inf' }

                if (-not (Test-GrabTime $start) -or ($end -ne 'inf' -and -not (Test-GrabTime $end))) {
                    Write-Host "  Times should look like 90, 1:30 or 00:01:30." -ForegroundColor Red
                    Wait-GrabKey
                    break
                }

                $clipArgs = @(
                    '-o', $script:ClipTemplate,
                    '--download-sections', "*$start-$end",
                    '--force-keyframes-at-cuts',
                    '-f', 'bv*+ba/b',
                    '--merge-output-format', 'mp4'
                )
                Invoke-GrabDownload $Url $script:VideoFolder $clipArgs $settings
                Wait-GrabKey
            }

            '7' {
                $subArgs = $baseVideo + @(
                    '--write-subs', '--write-auto-subs',
                    '--sub-langs', 'en.*',
                    '--convert-subs', 'srt',
                    '--skip-download'
                )
                Invoke-GrabDownload $Url $script:VideoFolder $subArgs $settings
                Wait-GrabKey
            }

            '8' {
                $thumbArgs = $baseVideo + @('--write-thumbnail', '--convert-thumbnails', 'jpg', '--skip-download')
                Invoke-GrabDownload $Url $script:VideoFolder $thumbArgs $settings
                Wait-GrabKey
            }

            '9' {
                Write-Host ""
                $listArgs = @('-F')
                if ($settings.CookieBrowser) { $listArgs += @('--cookies-from-browser', $settings.CookieBrowser) }
                & yt-dlp @listArgs -- $Url
                Wait-GrabKey
            }

            'N' {
                if ($clipIsNew) { $Url = $clipUrl }
            }

            'U' {
                $newUrl = Read-GrabUrl
                if ($newUrl) { $Url = $newUrl }
            }

            'C' {
                Read-GrabCookieBrowser $settings
            }

            'O' {
                $settings.OpenWhenDone = -not $settings.OpenWhenDone
                Save-GrabSettings $settings
            }

            'Y' {
                Write-Host ""
                & yt-dlp -U
                if ($LASTEXITCODE -ne 0) {
                    Write-Host ""
                    Write-Host "  If yt-dlp came from winget, update with: winget upgrade yt-dlp.yt-dlp" -ForegroundColor DarkYellow
                    Write-Host "  If it came from pip, update with:        python -m pip install -U yt-dlp" -ForegroundColor DarkYellow
                }
                Wait-GrabKey
            }

            { $_ -in @('0', 'Q', 'EXIT') } {
                Write-Host ""
                return
            }

            default {
                # Unknown key: just redraw the menu.
            }
        }
    }
}

Export-ModuleMember -Function grab
