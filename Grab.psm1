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

function ConvertTo-GrabFilename([string]$Text) {
    $name = $Text.Trim()
    # Drop an extension typed out of habit; yt-dlp adds the real one.
    $name = $name -replace '\.(mp4|mkv|webm|mov|mp3|m4a|opus|ogg|wav|flac|srt|vtt|jpe?g|png|webp)$', ''
    # Characters Windows doesn't allow in filenames.
    $name = $name -replace '[<>:"/\\|?*\x00-\x1F]', '_'
    # Windows also rejects trailing dots/spaces and reserved device names.
    $name = $name -replace '[. ]+$', ''
    if ($name.Length -gt 200) { $name = $name.Substring(0, 200) -replace '[. ]+$', '' }
    if ($name -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\..*)?$') { $name = "_$name" }
    $name
}

function Format-GrabSuggestion([string]$Text, [int]$Max = 60) {
    # Display only: long X/Twitter post text would otherwise flood the prompt.
    $flat = ($Text -replace '\s+', ' ').Trim()
    if ($flat.Length -le $Max) { return $flat }
    $cut = $Max - 3
    if ([char]::IsHighSurrogate($flat[$cut - 1])) { $cut-- }   # don't split an emoji
    $flat.Substring(0, $cut) + '...'
}

# Asks for a filename before downloading. Pressing Enter returns $Arguments
# untouched, so the default name is exactly what it would have been anyway;
# a typed name replaces the -o template with "<name>.%(ext)s".
function Read-GrabFilename([string]$Url, [string[]]$Arguments, [string[]]$CookieArgs) {
    $outIndex = [array]::IndexOf($Arguments, '-o')
    if ($outIndex -lt 0) { return $Arguments }

    # Ask yt-dlp what it would name the file, using the same options.
    # Written to a file rather than captured, so non-ASCII titles survive.
    Write-Host ""
    Write-Host "  Looking up title..." -ForegroundColor DarkGray
    $nameFile = [IO.Path]::GetTempFileName()
    $lookupArgs = @('--simulate', '--quiet', '--no-warnings', '-I', '1:2',
                    '--print-to-file', 'filename', $nameFile) + $CookieArgs + $Arguments + @('--', $Url)
    & yt-dlp @lookupArgs 2>$null | Out-Null
    $names = @(Get-Content -LiteralPath $nameFile -Encoding UTF8 -ErrorAction SilentlyContinue |
               Where-Object { $_ })
    Remove-Item -LiteralPath $nameFile -ErrorAction SilentlyContinue

    if ($names.Count -gt 1) {
        # A playlist or multi-video post: one custom name can't fit them all.
        Write-Host "  Several videos at this URL; keeping the default filenames." -ForegroundColor DarkGray
        return $Arguments
    }

    $suggestion = 'default name'
    if ($names.Count -eq 1) {
        $suggestion = Format-GrabSuggestion ([IO.Path]::GetFileNameWithoutExtension($names[0]))
    }

    $typed = Read-Host "  Filename [$suggestion]"
    if ([string]::IsNullOrWhiteSpace($typed)) { return $Arguments }

    $name = ConvertTo-GrabFilename $typed
    if (-not $name) {
        Write-Host "  That name has no usable characters; keeping the default." -ForegroundColor DarkYellow
        return $Arguments
    }

    [string[]]$custom = $Arguments.Clone()
    # % starts a yt-dlp template field; %% is a literal percent sign.
    $custom[$outIndex + 1] = ($name -replace '%', '%%') + '.%(ext)s'
    $custom
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
        $Settings,
        $Source      # set when the URL came from `grab inspect`; see New-GrabSource
    )

    New-Item -ItemType Directory -Force -Path $Folder | Out-Null

    $cookieArgs = @()
    if ($Settings.CookieBrowser) {
        $cookieArgs = @('--cookies-from-browser', $Settings.CookieBrowser)
    }
    if ($Source -and $Source.ExtraArgs) { $cookieArgs += $Source.ExtraArgs }

    $Arguments = Read-GrabFilename $Url $Arguments $cookieArgs

    # yt-dlp appends each finished file's final path here, so we can
    # highlight it in Explorer afterwards without parsing its output.
    $printFile = [IO.Path]::GetTempFileName()

    $ytArgs = @('-P', $Folder, '--print-to-file', 'after_move:filepath', $printFile)
    $ytArgs += $cookieArgs
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
        if ($Source -and $Source.FailureHint) {
            Write-Host "  $($Source.FailureHint)" -ForegroundColor DarkYellow
        }
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

# ================================================================ inspect
#
# `grab inspect <url>` and [I] in the menu: find video files and streaming
# manifests on an ordinary web page, then hand the one you pick to the normal
# grab menu (so yt-dlp, the filename prompt and the usual folders all apply).
#
# Two discovery methods, both plain PowerShell + .NET, identical on Windows
# and macOS:
#   1. HTML: fetch the page once and read <video>/<source> tags, og:video and
#      twitter:player:stream meta tags, JSON-LD contentUrl, known player
#      embeds, and media URLs inside inline player config.
#   2. Browser (optional, always asked first): start an installed
#      Chromium-based browser with a throwaway profile and watch its network
#      traffic over the Chrome DevTools Protocol while the page plays.
#
# Nothing is downloaded until you pick a source. Cookies and request headers
# are never printed; debug output shows URLs with query values removed.

$script:InspectDebug       = $false
$script:InspectSeconds     = 120   # hard cap on a browser session
$script:InspectIdleSeconds = 20    # finish early once media was found and nothing new shows up
$script:InspectMaxChecks   = 15    # sources probed for size/resolution
$script:UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36'

$script:KindLabels = @{
    MP4 = 'MP4 Video'; WebM = 'WebM Video'; M4V = 'M4V Video'
    HLS = 'HLS Stream'; DASH = 'DASH Stream'
    Embed = 'Embedded player'; Unknown = 'Video (type unknown)'
}

# Player iframes yt-dlp already knows how to download.
$script:EmbedPattern = '(?i)(youtube\.com/embed/|youtube-nocookie\.com/embed/|player\.vimeo\.com/video/|dailymotion\.com/embed/|geo\.dailymotion\.com/player|player\.twitch\.tv/|streamable\.com/[eo]/|fast\.wistia\.(net|com)/embed/|players\.brightcove\.net/|cdn\.jwplayer\.com/players/|content\.jwplatform\.com/players/|play\.vidyard\.com/|loom\.com/embed/|rumble\.com/embed/|archive\.org/embed/|facebook\.com/plugins/video|bitchute\.com/embed/|odysee\.com/\$/embed/)'

# ---------------------------------------------------------------- inspect: helpers

function Write-GrabDebug([string]$Text) {
    if ($script:InspectDebug) { Write-Host "  [debug] $Text" -ForegroundColor DarkGray }
}

function Format-GrabSafeUrl([string]$Url) {
    # Query values are often signed tokens: show parameter names only.
    try { $u = [Uri]$Url } catch { return '(unparseable URL)' }
    if (-not $u.IsAbsoluteUri) { return '(relative URL)' }
    $text = "$($u.Scheme)://$($u.Authority)$($u.AbsolutePath)"
    if ($u.Query.Length -gt 1) {
        $names = $u.Query.TrimStart('?').Split('&') | ForEach-Object { ($_ -split '=', 2)[0] } | Where-Object { $_ }
        $text += '?' + (($names | ForEach-Object { "$_=..." }) -join '&')
    }
    $text
}

function Format-GrabShortUrl([string]$Url, [int]$Max = 70) {
    # host/path for display: no query string (tokens), long paths shortened.
    try { $u = [Uri]$Url } catch { return '(unparseable URL)' }
    $text = $u.Host + $u.AbsolutePath
    if ($text.Length -gt $Max) {
        $tail = $u.AbsolutePath.Substring([Math]::Max(0, $u.AbsolutePath.Length - ($Max - $u.Host.Length - 4)))
        $text = "$($u.Host)/...$tail"
    }
    $text
}

function Format-GrabSize([long]$Bytes) {
    if ($Bytes -le 0) { return 'Unknown size' }
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    '{0:N0} KB' -f [Math]::Max(1, $Bytes / 1KB)
}

function Get-GrabUrlKey([string]$Url) {
    # Same host + path = same resource, even if the signed query differs.
    try { $u = [Uri]$Url; return "$($u.Host)$($u.AbsolutePath)".ToLowerInvariant() } catch { return $Url }
}

function Resolve-GrabUrl([Uri]$Base, [string]$Raw) {
    if ([string]::IsNullOrWhiteSpace($Raw)) { return $null }
    $text = [Net.WebUtility]::HtmlDecode($Raw.Trim())
    try { $u = New-Object Uri -ArgumentList $Base, $text } catch { return $null }
    if ($u.Scheme -ne 'http' -and $u.Scheme -ne 'https') { return $null }
    $u.AbsoluteUri
}

function Get-GrabAttr([string]$Tag, [string]$Name) {
    $m = [regex]::Match($Tag, "(?i)\s$Name\s*=\s*(?:""([^""]*)""|'([^']*)'|([^\s>]+))")
    if (-not $m.Success) { return $null }
    foreach ($g in 1..3) { if ($m.Groups[$g].Success) { return $m.Groups[$g].Value } }
    $null
}

# Returns MP4, WebM, M4V, HLS, DASH, Segment (a piece of a stream: ignore),
# or $null (not video).
function Get-GrabMediaKind([string]$Url, [string]$Mime) {
    $path = ''; $query = ''
    try { $u = [Uri]$Url; $path = $u.AbsolutePath.ToLowerInvariant(); $query = $u.Query.ToLowerInvariant() } catch { }
    $m = "$Mime".Split(';')[0].Trim().ToLowerInvariant()

    if ($m -in @('application/vnd.apple.mpegurl', 'application/x-mpegurl', 'audio/mpegurl', 'audio/x-mpegurl') -or
        $path.EndsWith('.m3u8')) { return 'HLS' }
    if ($m -eq 'application/dash+xml' -or $path.EndsWith('.mpd')) { return 'DASH' }
    if ($m -in @('video/mp2t', 'video/iso.segment', 'audio/mp4', 'audio/aac', 'audio/mpeg', 'audio/webm') -or
        $path -match '\.(ts|m4s|m4a|m4f|cmfv|cmfa|aac|vtt|webvtt)$') { return 'Segment' }

    $kind = $null
    if ($m -eq 'video/mp4' -or $path.EndsWith('.mp4')) { $kind = 'MP4' }
    elseif ($m -eq 'video/webm' -or $path.EndsWith('.webm')) { $kind = 'WebM' }
    elseif ($m -eq 'video/x-m4v' -or $path.EndsWith('.m4v')) { $kind = 'M4V' }
    if (-not $kind) { return $null }

    # Adaptive players fetch a stream as many small files; any one of them on
    # its own is a fragment, not a video.
    if ($path -match '(^|[/_-])(seg|segment|chunk|frag|fragment|init)[-_]?\d*\.(mp4|webm|m4v)$' -or
        $path -match '/videoplayback$' -or
        $query -match '[?&](range|bytestart|byteend)=') { return 'Segment' }
    $kind
}

# ---------------------------------------------------------------- inspect: findings

function New-GrabFindings {
    [pscustomobject]@{
        Items   = New-Object System.Collections.ArrayList
        Index   = @{}
        Ignored = 0
        Samples = New-Object System.Collections.ArrayList   # ignored fragments, for --debug
    }
}

function Add-GrabFinding {
    param($Findings, [string]$Url, [string]$Kind, [string]$Method, [string]$Mime, [int]$Status = 0, [long]$Size = -1)
    $key = Get-GrabUrlKey $Url
    $item = $Findings.Index[$key]
    if ($item) {
        # Seen before. Keep one entry; a URL the browser fetched just now
        # carries the freshest signed query, so prefer it.
        if ($Method -like 'browser*' -and $Url -ne $item.Url) { $item.Url = $Url; $item.Checked = $false }
        if (-not $item.Mime -and $Mime) { $item.Mime = $Mime }
        if ($Status) { $item.SeenStatus = $Status }
        if ($Size -gt 0 -and $item.Size -le 0) { $item.Size = $Size }
        return $false
    }
    $item = [pscustomobject]@{
        Url = $Url; Key = $key; Kind = $Kind; Method = $Method; Mime = $Mime
        SeenStatus = $Status; Status = 0; Size = $Size; Resolution = ''; Note = ''
        Blocked = $false; Drm = $false; Checked = $false; Variants = @()
    }
    [void]$Findings.Items.Add($item)
    $Findings.Index[$key] = $item
    Write-GrabDebug "found $Kind via ${Method}: $(Format-GrabSafeUrl $Url)"
    $true
}

function Add-GrabIgnored($Findings, [string]$Url) {
    $Findings.Ignored++
    if ($Findings.Samples.Count -lt 5) { [void]$Findings.Samples.Add((Format-GrabSafeUrl $Url)) }
}

# ---------------------------------------------------------------- inspect: HTTP

function Get-GrabHttpClient {
    if (-not $script:HttpClient) {
        if ($PSVersionTable.PSEdition -ne 'Core') {
            # Windows PowerShell 5.1
            Add-Type -AssemblyName System.Net.Http
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        }
        $handler = New-Object System.Net.Http.HttpClientHandler
        $handler.AllowAutoRedirect = $true
        $handler.UseCookies = $false
        $handler.AutomaticDecompression = [System.Net.DecompressionMethods]'GZip, Deflate'
        $client = New-Object System.Net.Http.HttpClient -ArgumentList $handler
        $client.Timeout = [TimeSpan]::FromSeconds(60)
        $script:HttpClient = $client
    }
    $script:HttpClient
}

# One request; never throws. With -FirstByte asks for byte 0 only, so probing
# a large video doesn't download it. The body is read only up to -MaxBytes.
function Invoke-GrabHttp {
    param(
        [string]$Url,
        [string]$Method = 'GET',
        [string]$Referer,
        [switch]$FirstByte,
        [int]$MaxBytes = 0,
        [int]$TimeoutSec = 10
    )
    $result = [pscustomobject]@{ Status = 0; ContentType = ''; Length = [long]-1; FinalUrl = $Url; Body = ''; Error = '' }
    $client = Get-GrabHttpClient
    $cts = New-Object System.Threading.CancellationTokenSource -ArgumentList ([TimeSpan]::FromSeconds($TimeoutSec))
    $resp = $null
    try {
        $req = New-Object System.Net.Http.HttpRequestMessage -ArgumentList (New-Object System.Net.Http.HttpMethod -ArgumentList $Method), $Url
        [void]$req.Headers.TryAddWithoutValidation('User-Agent', $script:UserAgent)
        if ($Referer)   { [void]$req.Headers.TryAddWithoutValidation('Referer', $Referer) }
        if ($FirstByte) { [void]$req.Headers.TryAddWithoutValidation('Range', 'bytes=0-0') }

        $resp = $client.SendAsync($req, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead, $cts.Token).GetAwaiter().GetResult()
        $result.Status = [int]$resp.StatusCode
        $result.FinalUrl = $resp.RequestMessage.RequestUri.AbsoluteUri
        $h = $resp.Content.Headers
        if ($h.ContentType) { $result.ContentType = $h.ContentType.MediaType }
        if ($h.ContentRange -and $h.ContentRange.HasLength) { $result.Length = [long]$h.ContentRange.Length }
        elseif ($h.ContentLength -and $result.Status -eq 200) { $result.Length = [long]$h.ContentLength }

        if ($MaxBytes -gt 0 -and $Method -eq 'GET') {
            $stream = $resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
            $buf = New-Object byte[] 65536
            $ms = New-Object IO.MemoryStream
            while ($ms.Length -lt $MaxBytes) {
                $n = $stream.ReadAsync($buf, 0, $buf.Length, $cts.Token).GetAwaiter().GetResult()
                if ($n -le 0) { break }
                $ms.Write($buf, 0, $n)
            }
            $result.Body = [Text.Encoding]::UTF8.GetString($ms.ToArray())
        }
    } catch {
        $e = $_.Exception
        while ($e.InnerException) { $e = $e.InnerException }
        if ($cts.IsCancellationRequested) { $result.Error = "timed out after ${TimeoutSec}s" } else { $result.Error = $e.Message }
    } finally {
        if ($resp) { $resp.Dispose() }
        $cts.Dispose()
    }
    $result
}

# ---------------------------------------------------------------- inspect: HTML discovery

function Get-GrabPageTitle([string]$Html) {
    foreach ($tag in [regex]::Matches($Html, '(?i)<meta\b[^>]*>')) {
        if ((Get-GrabAttr $tag.Value 'property') -eq 'og:title') {
            $t = Get-GrabAttr $tag.Value 'content'
            if ($t) { return ([Net.WebUtility]::HtmlDecode($t) -replace '\s+', ' ').Trim() }
        }
    }
    $m = [regex]::Match($Html, '(?is)<title[^>]*>(.*?)</title>')
    if ($m.Success) { return ([Net.WebUtility]::HtmlDecode($m.Groups[1].Value) -replace '\s+', ' ').Trim() }
    ''
}

function Find-GrabHtmlMedia([string]$PageUrl, [string]$Html, $Findings) {
    # Undo the escaping inline JSON/JS player configs use for URLs.
    $text = $Html -replace '\\/', '/' -replace '\\u002[fF]', '/' -replace '\\u0026', '&' -replace '&amp;', '&'

    $base = [Uri]$PageUrl
    $m = [regex]::Match($text, '(?i)<base\b[^>]*>')
    if ($m.Success) {
        $href = Get-GrabAttr $m.Value 'href'
        if ($href) { try { $base = New-Object Uri -ArgumentList $base, $href } catch { } }
    }

    $consider = {
        param([string]$Raw, [string]$Method, [string]$Mime)
        $abs = Resolve-GrabUrl $base $Raw
        if (-not $abs) { return }
        $kind = Get-GrabMediaKind $abs $Mime
        if ($kind -eq 'Segment') { Add-GrabIgnored $Findings $abs; return }
        if (-not $kind) {
            if ("$Mime" -like 'video/*') { $kind = 'Unknown' } else { return }
        }
        [void](Add-GrabFinding $Findings $abs $kind $Method $Mime)
    }

    # <video src>, <source src type>
    foreach ($tag in [regex]::Matches($text, '(?i)<(video|source)\b[^>]*>')) {
        $src = Get-GrabAttr $tag.Value 'src'
        if (-not $src) { $src = Get-GrabAttr $tag.Value 'data-src' }
        if ($src) { & $consider $src "<$($tag.Groups[1].Value.ToLowerInvariant())> tag" (Get-GrabAttr $tag.Value 'type') }
    }

    # og:video / twitter:player:stream (+ og:video:type when given)
    $metas = [regex]::Matches($text, '(?i)<meta\b[^>]*>')
    $ogType = $null
    foreach ($tag in $metas) {
        if ((Get-GrabAttr $tag.Value 'property') -eq 'og:video:type') { $ogType = Get-GrabAttr $tag.Value 'content' }
    }
    foreach ($tag in $metas) {
        $prop = Get-GrabAttr $tag.Value 'property'
        if (-not $prop) { $prop = Get-GrabAttr $tag.Value 'name' }
        if ($prop -match '^(og:video(:url|:secure_url)?|twitter:player:stream)$') {
            $mime = $null
            if ($prop -like 'og:video*') { $mime = $ogType }
            & $consider (Get-GrabAttr $tag.Value 'content') "$prop meta tag" $mime
        }
    }

    # JSON-LD VideoObject
    foreach ($mm in [regex]::Matches($text, '"contentUrl"\s*:\s*"([^"]+)"')) {
        & $consider $mm.Groups[1].Value 'JSON-LD contentUrl' $null
    }

    # Player iframes (and JSON-LD embedUrl) for sites yt-dlp supports
    $embeds = @()
    foreach ($tag in [regex]::Matches($text, '(?i)<iframe\b[^>]*>')) {
        $src = Get-GrabAttr $tag.Value 'src'
        if (-not $src) { $src = Get-GrabAttr $tag.Value 'data-src' }
        if ($src) { $embeds += , @($src, '<iframe> player') }
    }
    foreach ($mm in [regex]::Matches($text, '"embedUrl"\s*:\s*"([^"]+)"')) { $embeds += , @($mm.Groups[1].Value, 'JSON-LD embedUrl') }
    foreach ($e in $embeds) {
        $abs = Resolve-GrabUrl $base $e[0]
        if ($abs -and $abs -match $script:EmbedPattern) { [void](Add-GrabFinding $Findings $abs 'Embed' $e[1] $null) }
    }

    # Media URLs anywhere else: inline player config, data attributes, scripts.
    $absPattern = '(?i)(?:https?:)?//[^\s"''<>()\\]+?\.(?:mp4|webm|m4v|m3u8|mpd)(?:\?[^\s"''<>\\]*)?(?=["''\s<>),\\]|$)'
    foreach ($mm in [regex]::Matches($text, $absPattern)) { & $consider $mm.Value 'page script/config' $null }
    $relPattern = '(?i)["''](/[^"''\s<>]+?\.(?:mp4|webm|m4v|m3u8|mpd)(?:\?[^"''\s<>]*)?)["'']'
    foreach ($mm in [regex]::Matches($text, $relPattern)) { & $consider $mm.Groups[1].Value 'page script/config' $null }
}

# ---------------------------------------------------------------- inspect: checking sources

function Set-GrabProbeResult($Item, $Result) {
    $Item.Status = $Result.Status
    $fromBrowser = $Item.Method -like 'browser*'
    if (-not $Result.Status) {
        $Item.Note = "could not check: $($Result.Error)"
        return $false
    }
    if ($Result.Status -eq 401 -or $Result.Status -eq 403) {
        $Item.Blocked = $true
        if ($fromBrowser) {
            $Item.Note = "HTTP $($Result.Status) outside the browser: needs that browser session (login/cookies), or the link expired"
        } else {
            $Item.Note = "HTTP $($Result.Status): needs a logged-in session, or the link expired"
        }
        return $false
    }
    if ($Result.Status -eq 404 -or $Result.Status -eq 410) {
        $Item.Blocked = $true
        $Item.Note = "HTTP $($Result.Status): no longer available (expired or removed)"
        return $false
    }
    if ($Result.Status -ge 400) {
        $Item.Blocked = $true
        $Item.Note = "HTTP $($Result.Status) from the server"
        return $false
    }
    if ($Result.ContentType -like 'text/html*') {
        $Item.Blocked = $true
        $Item.Note = 'returned a web page instead of media (expired link or login required)'
        return $false
    }
    $true
}

function Read-GrabHls($Item, [string]$Body) {
    if ($Body -notmatch '^\s*#EXTM3U') {
        $Item.Blocked = $true; $Item.Note = 'not a valid HLS playlist'
        return
    }
    if ($Body -match '#EXT-X-(SESSION-)?KEY:[^\r\n]*(METHOD=SAMPLE-AES|KEYFORMAT="(com\.apple\.streamingkeydelivery|urn:uuid:))') {
        $Item.Drm = $true
    }
    $lines = $Body -split "\r?\n"
    $heights = @(); $variants = @()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -notlike '#EXT-X-STREAM-INF:*') { continue }
        $res = [regex]::Match($lines[$i], 'RESOLUTION=(\d+)x(\d+)')
        if ($res.Success) { $heights += [int]$res.Groups[2].Value }
        for ($j = $i + 1; $j -lt $lines.Count; $j++) {
            $line = $lines[$j].Trim()
            if ($line -and -not $line.StartsWith('#')) {
                $v = Resolve-GrabUrl ([Uri]$Item.Url) $line
                if ($v) { $variants += $v }
                break
            }
        }
    }
    $Item.Variants = $variants
    if ($heights) { $Item.Resolution = 'up to {0}p' -f ($heights | Measure-Object -Maximum).Maximum }
}

function Read-GrabDash($Item, [string]$Body) {
    if ($Body -notmatch '<MPD\b') {
        $Item.Blocked = $true; $Item.Note = 'not a valid DASH manifest'
        return
    }
    if ($Body -match '<ContentProtection\b') { $Item.Drm = $true }
    $heights = @([regex]::Matches($Body, '<Representation\b[^>]*\sheight="(\d+)"') | ForEach-Object { [int]$_.Groups[1].Value })
    if ($heights) { $Item.Resolution = 'up to {0}p' -f ($heights | Measure-Object -Maximum).Maximum }
}

function Get-GrabProbeResolution([string]$Url, [string]$Referer) {
    # ffprobe reads just the header (with ranged reads); -rw_timeout bounds stalls.
    $out = & ffprobe -v error -rw_timeout 8000000 -user_agent $script:UserAgent -headers "Referer: $Referer`r`n" `
        -select_streams v:0 -show_entries stream=width,height -of csv=s=x:p=0 -i $Url 2>$null
    $m = [regex]::Match("$out", '(\d+)x(\d+)')
    if (-not $m.Success) { return '' }
    $w = [int]$m.Groups[1].Value; $h = [int]$m.Groups[2].Value
    if ($w -ge $h) { "${h}p" } else { "${w}x${h}" }
}

function Update-GrabFinding($Item, [string]$PageUrl, [bool]$HasFfprobe) {
    $Item.Checked = $true
    switch ($Item.Kind) {
        'Embed' { return }   # yt-dlp extracts these; nothing to probe
        { $_ -eq 'HLS' -or $_ -eq 'DASH' } {
            $r = Invoke-GrabHttp -Url $Item.Url -Referer $PageUrl -MaxBytes 2MB -TimeoutSec 10
            if (-not (Set-GrabProbeResult $Item $r)) { return }
            if ($Item.Kind -eq 'HLS') { Read-GrabHls $Item $r.Body } else { Read-GrabDash $Item $r.Body }
            if ($Item.Drm) { $Item.Note = 'DRM-protected: Grab will not download this' }
            return
        }
        default {
            $r = Invoke-GrabHttp -Url $Item.Url -Method HEAD -Referer $PageUrl -TimeoutSec 8
            if ($r.Status -lt 200 -or $r.Status -ge 300 -or $r.Length -lt 0) {
                # Plenty of servers refuse HEAD or omit the size; ask for one byte.
                $r2 = Invoke-GrabHttp -Url $Item.Url -Referer $PageUrl -FirstByte -TimeoutSec 8
                if ($r2.Status) { $r = $r2 }
            }
            if ($r.Length -gt 0) { $Item.Size = $r.Length }
            if ($Item.Kind -eq 'Unknown' -and $r.ContentType) {
                $k = Get-GrabMediaKind $Item.Url $r.ContentType
                if ($k -and $k -ne 'Segment') { $Item.Kind = $k }
            }
            if ((Set-GrabProbeResult $Item $r) -and $HasFfprobe) {
                $Item.Resolution = Get-GrabProbeResolution $Item.Url $PageUrl
            }
        }
    }
}

function Complete-GrabFindings($Findings, [string]$PageUrl) {
    $hasFfprobe = [bool](Get-Command ffprobe -ErrorAction SilentlyContinue)
    $todo = @($Findings.Items | Where-Object { -not $_.Checked } | Select-Object -First $script:InspectMaxChecks)
    if ($todo.Count) { Write-Host "  Checking $($todo.Count) source(s)..." -ForegroundColor DarkGray }
    foreach ($item in $todo) {
        Update-GrabFinding $item $PageUrl $hasFfprobe
        Write-GrabDebug "checked $($item.Kind) $(Format-GrabSafeUrl $item.Url): HTTP $($item.Status) $($item.Resolution) $(Format-GrabSize $item.Size) $($item.Note)"
    }

    # A master HLS playlist already offers every quality; hide its variants.
    $covered = @{}
    foreach ($i in $Findings.Items) { foreach ($v in $i.Variants) { $covered[(Get-GrabUrlKey $v)] = $true } }
    $keep = @($Findings.Items | Where-Object { -not $covered[$_.Key] })
    if ($keep.Count -ne $Findings.Items.Count) {
        Write-GrabDebug "hid $($Findings.Items.Count - $keep.Count) HLS variant playlist(s) covered by a master playlist"
    }
    # Usable sources first; blocked/DRM ones stay listed, at the end.
    $ordered = @($keep | Where-Object { -not ($_.Blocked -or $_.Drm) }) + @($keep | Where-Object { $_.Blocked -or $_.Drm })
    $Findings.Items.Clear()
    foreach ($i in $ordered) { [void]$Findings.Items.Add($i) }
}

# ---------------------------------------------------------------- inspect: browser

# Chromium-based browsers only: they speak the DevTools protocol we need.
# GRAB_BROWSER (a full path) overrides the search.
function Find-GrabBrowser {
    if ($env:GRAB_BROWSER) {
        if (Test-Path -LiteralPath $env:GRAB_BROWSER) {
            return [pscustomobject]@{ Name = [IO.Path]::GetFileNameWithoutExtension($env:GRAB_BROWSER); Path = $env:GRAB_BROWSER }
        }
        Write-Host "  GRAB_BROWSER is set but the file doesn't exist: $env:GRAB_BROWSER" -ForegroundColor DarkYellow
    }

    $list = @()
    if ($env:OS -eq 'Windows_NT') {
        $pf = $env:ProgramFiles; $pf86 = ${env:ProgramFiles(x86)}; $la = $env:LOCALAPPDATA
        $list = @(
            "Vivaldi|$la\Vivaldi\Application\vivaldi.exe"
            "Vivaldi|$pf\Vivaldi\Application\vivaldi.exe"
            "Chrome|$pf\Google\Chrome\Application\chrome.exe"
            "Chrome|$pf86\Google\Chrome\Application\chrome.exe"
            "Chrome|$la\Google\Chrome\Application\chrome.exe"
            "Edge|$pf86\Microsoft\Edge\Application\msedge.exe"
            "Edge|$pf\Microsoft\Edge\Application\msedge.exe"
            "Brave|$pf\BraveSoftware\Brave-Browser\Application\brave.exe"
            "Brave|$la\BraveSoftware\Brave-Browser\Application\brave.exe"
            "Chromium|$la\Chromium\Application\chrome.exe"
        )
    } elseif ($IsMacOS) {
        foreach ($root in @('/Applications', (Join-Path $HOME 'Applications'))) {
            $list += @(
                "Vivaldi|$root/Vivaldi.app/Contents/MacOS/Vivaldi"
                "Chrome|$root/Google Chrome.app/Contents/MacOS/Google Chrome"
                "Edge|$root/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"
                "Brave|$root/Brave Browser.app/Contents/MacOS/Brave Browser"
                "Chromium|$root/Chromium.app/Contents/MacOS/Chromium"
            )
        }
    } else {
        foreach ($cmd in 'vivaldi', 'vivaldi-stable', 'google-chrome', 'google-chrome-stable', 'microsoft-edge', 'brave-browser', 'chromium', 'chromium-browser') {
            $c = Get-Command $cmd -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($c) { $list += "$cmd|$($c.Source)" }
        }
    }
    foreach ($entry in $list) {
        $name, $path = $entry -split '\|', 2
        if ($path -and (Test-Path -LiteralPath $path)) { return [pscustomobject]@{ Name = $name; Path = $path } }
    }

    # Fallback: a Chromium that Playwright manages (npx playwright install chromium).
    $roots = @()
    if ($env:PLAYWRIGHT_BROWSERS_PATH) { $roots += $env:PLAYWRIGHT_BROWSERS_PATH }
    if ($env:OS -eq 'Windows_NT') { $roots += (Join-Path $env:LOCALAPPDATA 'ms-playwright') }
    elseif ($IsMacOS) { $roots += (Join-Path $HOME 'Library/Caches/ms-playwright') }
    else { $roots += (Join-Path $HOME '.cache/ms-playwright') }
    foreach ($root in $roots) {
        if (-not $root -or -not (Test-Path -LiteralPath $root)) { continue }
        $dirs = Get-ChildItem -LiteralPath $root -Directory -Filter 'chromium-*' -ErrorAction SilentlyContinue | Sort-Object Name -Descending
        foreach ($d in $dirs) {
            foreach ($rel in @('chrome-win\chrome.exe', 'chrome-win64\chrome.exe',
                               'chrome-mac/Chromium.app/Contents/MacOS/Chromium',
                               'chrome-mac-arm64/Chromium.app/Contents/MacOS/Chromium',
                               'chrome-mac/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing',
                               'chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing',
                               'chrome-linux/chrome', 'chrome-linux64/chrome')) {
                $p = Join-Path $d.FullName $rel
                if (Test-Path -LiteralPath $p) { return [pscustomobject]@{ Name = 'Chromium (Playwright)'; Path = $p } }
            }
        }
    }
    $null
}

function Show-GrabBrowserHelp {
    Write-Host "  Browser inspection needs a Chromium-based browser (Vivaldi, Chrome, Edge," -ForegroundColor DarkYellow
    Write-Host "  Brave or Chromium) and none was found in the usual places. Options:" -ForegroundColor DarkYellow
    if ($env:OS -eq 'Windows_NT') {
        Write-Host "    winget install Google.Chrome      (or Vivaldi.Vivaldi; Edge ships with Windows 11)" -ForegroundColor Yellow
    } elseif ($IsMacOS) {
        Write-Host "    brew install --cask vivaldi        (or google-chrome, microsoft-edge, brave-browser)" -ForegroundColor Yellow
    } else {
        Write-Host "    install chromium or google-chrome with your package manager" -ForegroundColor Yellow
    }
    Write-Host "    npx playwright install chromium   (a separate managed Chromium; needs Node.js)" -ForegroundColor Yellow
    Write-Host "    or point GRAB_BROWSER at a browser executable you already have" -ForegroundColor Yellow
}

function ConvertTo-GrabProcessArg([string]$Arg) {
    # Start-Process joins arguments with spaces on every platform.
    if ($Arg -match '[\s"]') { return '"' + ($Arg -replace '"', '\"') + '"' }
    $Arg
}

function Start-GrabBrowser($Browser) {
    # A brand-new, empty profile: your normal profile, logins and history are
    # never opened or changed. Deleted again in Stop-GrabBrowser.
    $profileDir = Join-Path ([IO.Path]::GetTempPath()) ('grab-inspect-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $profileDir | Out-Null
    $session = [pscustomobject]@{ Process = $null; ProfileDir = $profileDir; Cdp = $null }

    $argv = @(
        "--user-data-dir=$profileDir"
        '--remote-debugging-port=0'          # pick a free port; reported in DevToolsActivePort
        '--no-first-run'
        '--no-default-browser-check'
        '--disable-sync'
        '--disable-extensions'
        '--disable-background-networking'
        '--autoplay-policy=no-user-gesture-required'
        '--new-window'
        'about:blank'
    )
    if ($env:GRAB_HEADLESS) { $argv += '--headless=new' }
    # Chromium refuses to start as root on Linux without this.
    if (-not $IsMacOS -and $env:OS -ne 'Windows_NT' -and (& id -u) -eq '0') { $argv += '--no-sandbox' }

    try {
        # The browser gets its own empty stdin and log files, so it never
        # reads from or writes to this terminal.
        $logs = Join-Path $profileDir 'grab-logs'
        New-Item -ItemType Directory -Force -Path $logs | Out-Null
        $stdin = Join-Path $logs 'in.txt'
        Set-Content -LiteralPath $stdin -Value '' -NoNewline
        $session.Process = Start-Process -FilePath $Browser.Path -PassThru `
            -ArgumentList ($argv | ForEach-Object { ConvertTo-GrabProcessArg $_ }) `
            -RedirectStandardInput $stdin `
            -RedirectStandardOutput (Join-Path $logs 'out.txt') -RedirectStandardError (Join-Path $logs 'err.txt')

        $portFile = Join-Path $profileDir 'DevToolsActivePort'
        $deadline = (Get-Date).AddSeconds(20)
        $lines = @()
        while ($lines.Count -lt 2) {
            if ($session.Process.HasExited) {
                throw "$($Browser.Name) exited right after starting (exit code $($session.Process.ExitCode))."
            }
            if ((Get-Date) -gt $deadline) { throw "$($Browser.Name) didn't open its DevTools port within 20 seconds." }
            Start-Sleep -Milliseconds 200
            if (Test-Path -LiteralPath $portFile) { $lines = @(Get-Content -LiteralPath $portFile -ErrorAction SilentlyContinue) }
        }
        Write-GrabDebug "$($Browser.Name) DevTools on 127.0.0.1:$($lines[0]); temporary profile $profileDir"
        $session.Cdp = Connect-GrabCdp "ws://127.0.0.1:$($lines[0])$($lines[1])"
    } catch {
        # Don't leave a browser or the temporary profile behind.
        Stop-GrabBrowser $session
        throw
    }
    $session
}

function Stop-GrabBrowser($Session) {
    if (-not $Session) { return }
    if ($Session.Cdp) {
        if (-not $Session.Cdp.Closed) { try { [void](Send-GrabCdp $Session.Cdp 'Browser.close' @{}) } catch { } }
        try { $Session.Cdp.Ws.Dispose() } catch { }
    }
    if ($Session.Process) {
        try {
            if (-not $Session.Process.WaitForExit(5000)) { Stop-Process -Id $Session.Process.Id -Force -ErrorAction SilentlyContinue }
        } catch { }
    }
    # The browser may hold files for a moment after exiting (Windows).
    for ($i = 0; $i -lt 10 -and (Test-Path -LiteralPath $Session.ProfileDir); $i++) {
        Remove-Item -LiteralPath $Session.ProfileDir -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $Session.ProfileDir) { Start-Sleep -Milliseconds 300 }
    }
}

# --- minimal Chrome DevTools Protocol client over System.Net.WebSockets

function Connect-GrabCdp([string]$WsUrl) {
    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    # Localhost only: never route this through a configured HTTP proxy.
    try { $ws.Options.Proxy = New-Object System.Net.WebProxy } catch { }
    try { [void]$ws.ConnectAsync([Uri]$WsUrl, [Threading.CancellationToken]::None).Wait(10000) } catch { }
    if ($ws.State -ne 'Open') { throw 'Could not connect to the browser DevTools endpoint.' }
    $buffer = New-Object byte[] 262144
    [pscustomobject]@{
        Ws = $ws; Buffer = $buffer
        Segment = New-Object 'System.ArraySegment[byte]' -ArgumentList (, $buffer)
        Stream = New-Object IO.MemoryStream
        Pending = $null; NextId = 1; Closed = $false
    }
}

function Send-GrabCdp($Cdp, [string]$Method, $Params, [string]$SessionId) {
    $id = $Cdp.NextId++
    $msg = @{ id = $id; method = $Method; params = $Params }
    if ($SessionId) { $msg.sessionId = $SessionId }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($msg | ConvertTo-Json -Depth 8 -Compress))
    $seg = New-Object 'System.ArraySegment[byte]' -ArgumentList (, $bytes)
    try {
        [void]$Cdp.Ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None).Wait(5000)
    } catch { $Cdp.Closed = $true }
    $id
}

# Next message, or $null if none arrives within $WaitMs.
function Receive-GrabCdp($Cdp, [int]$WaitMs) {
    while (-not $Cdp.Closed) {
        if (-not $Cdp.Pending) { $Cdp.Pending = $Cdp.Ws.ReceiveAsync($Cdp.Segment, [Threading.CancellationToken]::None) }
        try {
            if (-not $Cdp.Pending.Wait($WaitMs)) { return $null }
        } catch { $Cdp.Closed = $true; return $null }
        $r = $Cdp.Pending.Result
        $Cdp.Pending = $null
        if ($r.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) { $Cdp.Closed = $true; return $null }
        $Cdp.Stream.Write($Cdp.Buffer, 0, $r.Count)
        if (-not $r.EndOfMessage) { $WaitMs = 5000; continue }
        $json = [Text.Encoding]::UTF8.GetString($Cdp.Stream.ToArray())
        $Cdp.Stream.SetLength(0)
        try { return ($json | ConvertFrom-Json) } catch { return $null }
    }
    $null
}

# Send and wait for the reply, handling any events that arrive meanwhile.
function Invoke-GrabCdp($Cdp, [string]$Method, $Params, [string]$SessionId, $State, $Findings) {
    $id = Send-GrabCdp $Cdp $Method $Params $SessionId
    $deadline = (Get-Date).AddSeconds(10)
    while (-not $Cdp.Closed -and (Get-Date) -lt $deadline) {
        $msg = Receive-GrabCdp $Cdp 250
        if (-not $msg) { continue }
        if ($msg.id -eq $id) { return $msg }
        if ($msg.method) { Receive-GrabCdpEvent $Cdp $msg $State $Findings }
    }
    $null
}

function Initialize-GrabCdpSession($Cdp, [string]$SessionId, $State) {
    if (-not $SessionId -or $State.Sessions.ContainsKey($SessionId)) { return }
    $State.Sessions[$SessionId] = $true
    [void](Send-GrabCdp $Cdp 'Network.enable' @{} $SessionId)
    [void](Send-GrabCdp $Cdp 'Page.enable' @{} $SessionId)
    # Cross-site player iframes and workers are separate targets: attach to
    # them too, paused until their Network domain is on.
    [void](Send-GrabCdp $Cdp 'Target.setAutoAttach' @{ autoAttach = $true; waitForDebuggerOnStart = $true; flatten = $true } $SessionId)
    [void](Send-GrabCdp $Cdp 'Runtime.runIfWaitingForDebugger' @{} $SessionId)
}

function Get-GrabHeader($Headers, [string]$Name) {
    if (-not $Headers) { return $null }
    foreach ($p in $Headers.PSObject.Properties) { if ($p.Name -eq $Name) { return [string]$p.Value } }
    $null
}

function Add-GrabNetworkMedia($Findings, $State, [string]$Url, [string]$Mime, [int]$Status, [long]$Size) {
    if ($Url -notmatch '^https?://') {
        if ($Url -like 'blob:*') { $State.Blobs++ }
        return
    }
    $kind = Get-GrabMediaKind $Url $Mime
    if (-not $kind) { return }
    if ($kind -eq 'Segment') { Add-GrabIgnored $Findings $Url; return }
    # Clear the live "Watching:" line before anything else is printed.
    Write-Host ("`r" + ''.PadRight(90) + "`r") -NoNewline
    if (Add-GrabFinding $Findings $Url $kind 'browser network' $Mime $Status $Size) {
        $State.LastNew = Get-Date
        Write-Host ("  + {0,-16} {1}" -f $script:KindLabels[$kind], (Format-GrabShortUrl $Url 56)) -ForegroundColor Green
    }
}

# Only media-relevant facts are read from events: URL, status, MIME type and
# size. Request/response headers (cookies, authorization) are never stored.
function Receive-GrabCdpEvent($Cdp, $Msg, $State, $Findings) {
    switch ($Msg.method) {
        'Target.attachedToTarget' {
            Initialize-GrabCdpSession $Cdp $Msg.params.sessionId $State
        }
        'Target.targetCreated' {
            # A tab or popup opened from the page (or by you): watch it as well.
            $info = $Msg.params.targetInfo
            if ($State.Main -and $info.type -eq 'page' -and -not $info.attached) {
                [void](Send-GrabCdp $Cdp 'Target.attachToTarget' @{ targetId = $info.targetId; flatten = $true })
            }
        }
        'Network.requestWillBeSent' {
            $State.Requests++
            Add-GrabNetworkMedia $Findings $State $Msg.params.request.url $null 0 -1
        }
        'Network.responseReceived' {
            $r = $Msg.params.response
            $size = [long]-1
            $range = Get-GrabHeader $r.headers 'content-range'
            $length = Get-GrabHeader $r.headers 'content-length'
            if ($range -match '/(\d+)\s*$') { $size = [long]$Matches[1] }
            elseif ($length -and [int]$r.status -eq 200) { $size = [long]$length }
            Add-GrabNetworkMedia $Findings $State $r.url $r.mimeType ([int]$r.status) $size
        }
        'Page.loadEventFired' {
            if ($Msg.sessionId -eq $State.Main -and -not $State.LoadedAt) { $State.LoadedAt = Get-Date }
        }
    }
}

# Open the page in a browser and collect media requests. Returns the page
# title (or '').
function Invoke-GrabBrowserInspect([string]$PageUrl, $Findings, $Browser) {
    $limit = $script:InspectSeconds
    if ($env:GRAB_INSPECT_SECONDS -match '^\d+$') { $limit = [int]$env:GRAB_INSPECT_SECONDS }

    Write-Host ""
    Write-Host "  Opening $($Browser.Name) with a temporary, empty profile (your normal profile" -ForegroundColor DarkGray
    Write-Host "  isn't used or changed). If the video doesn't start by itself, press play" -ForegroundColor DarkGray
    Write-Host "  in that window, or log in there if the site requires it." -ForegroundColor DarkGray
    Write-Host "  Close the browser window when you're done. Grab also stops by itself" -ForegroundColor DarkGray
    $limitText = "$limit seconds"
    if ($limit % 60 -eq 0) { $limitText = "$($limit / 60) minutes" }
    Write-Host "  $($script:InspectIdleSeconds)s after the last new find, or after $limitText." -ForegroundColor DarkGray
    Write-Host ""

    $state = @{ Sessions = @{}; Main = $null; LoadedAt = $null; LastNew = Get-Date; Requests = 0; Blobs = 0 }
    $session = $null
    $title = ''
    $reason = 'time limit reached'
    try {
        $session = Start-GrabBrowser $Browser
        $cdp = $session.Cdp
        $targets = Invoke-GrabCdp $cdp 'Target.getTargets' @{} $null $state $Findings
        $page = @($targets.result.targetInfos | Where-Object { $_.type -eq 'page' }) | Select-Object -First 1
        if (-not $page) {
            $created = Invoke-GrabCdp $cdp 'Target.createTarget' @{ url = 'about:blank' } $null $state $Findings
            $page = [pscustomobject]@{ targetId = $created.result.targetId }
        }
        $attach = Invoke-GrabCdp $cdp 'Target.attachToTarget' @{ targetId = $page.targetId; flatten = $true } $null $state $Findings
        $state.Main = $attach.result.sessionId
        if (-not $state.Main) { throw 'Could not attach to the browser tab.' }
        Initialize-GrabCdpSession $cdp $state.Main $state
        [void](Invoke-GrabCdp $cdp 'Target.setDiscoverTargets' @{ discover = $true } $null $state $Findings)
        [void](Send-GrabCdp $cdp 'Page.navigate' @{ url = $PageUrl } $state.Main)

        # Start muted playback of any <video> on the page, a few times while
        # players load. Same as clicking play; nothing is unlocked.
        $nudge = "(() => { let n = 0; document.querySelectorAll('video').forEach(v => { n++; v.muted = true; const p = v.play(); if (p && p.catch) p.catch(() => {}); }); return n; })()"
        $nudgeAt = @(3, 8, 15, 25)
        $nudged = 0

        $started = Get-Date
        $lastDraw = [datetime]::MinValue
        while ($true) {
            $now = Get-Date
            $elapsed = ($now - $started).TotalSeconds
            if ($elapsed -ge $limit) { break }
            if ($cdp.Closed -or $session.Process.HasExited) { $reason = 'browser closed'; break }
            if ($Findings.Items.Count -gt 0 -and ($now - $state.LastNew).TotalSeconds -ge $script:InspectIdleSeconds) {
                $reason = "nothing new for $($script:InspectIdleSeconds)s"; break
            }
            if ($nudged -lt $nudgeAt.Count -and $elapsed -ge $nudgeAt[$nudged]) {
                [void](Send-GrabCdp $cdp 'Runtime.evaluate' @{ expression = $nudge; returnByValue = $true } $state.Main)
                $nudged++
            }

            $msg = Receive-GrabCdp $cdp 200
            while ($msg) {
                if ($msg.method) { Receive-GrabCdpEvent $cdp $msg $state $Findings }
                $msg = Receive-GrabCdp $cdp 0
            }

            if (($now - $lastDraw).TotalSeconds -ge 1) {
                $lastDraw = $now
                $line = "  Watching: {0} found, {1} requests, {2}s left. Close the browser when done." -f $Findings.Items.Count, $state.Requests, [int]($limit - $elapsed)
                Write-Host ("`r" + $line.PadRight(90)) -NoNewline -ForegroundColor DarkGray
            }
        }
        Write-Host ("`r" + ''.PadRight(90) + "`r") -NoNewline
        Write-Host "  Browser inspection finished ($reason)." -ForegroundColor DarkGray

        if (-not $cdp.Closed) {
            $t = Invoke-GrabCdp $cdp 'Runtime.evaluate' @{ expression = 'document.title'; returnByValue = $true } $state.Main $state $Findings
            if ($t -and $t.result -and $t.result.result) { $title = [string]$t.result.result.value }
        }
        Write-GrabDebug "network: $($state.Requests) requests, $($Findings.Ignored) stream fragments ignored, $($state.Blobs) blob: media URLs"
        foreach ($s in $Findings.Samples) { Write-GrabDebug "  ignored fragment: $s" }
        if ($state.Blobs -and -not $Findings.Items.Count) {
            Write-Host "  The player streams through blob: URLs and no manifest request was seen;" -ForegroundColor DarkYellow
            Write-Host "  the stream may be DRM-protected or loaded in a way Grab can't follow." -ForegroundColor DarkYellow
        }
    } catch {
        Write-Host ""
        Write-Host "  Browser inspection failed: $($_.Exception.Message)" -ForegroundColor Red
    } finally {
        Stop-GrabBrowser $session
    }
    $title
}

# ---------------------------------------------------------------- inspect: UI

function Show-GrabInspectList([string]$PageUrl, [string]$Title, $Findings, [switch]$NoClear) {
    if (-not $NoClear) { Show-GrabHeader }
    Write-Host "  Grab - Media Inspector" -ForegroundColor Cyan
    Write-GrabStatus 'Page' ([Uri]$PageUrl).Host
    if ($Title) { Write-GrabStatus 'Title' (Format-GrabSuggestion $Title 70) }
    Write-Host ""
    if (-not $Findings.Items.Count) {
        Write-Host "  No video sources found." -ForegroundColor DarkYellow
        return
    }
    Write-Host "  Discovered media:"
    $n = 0
    foreach ($item in $Findings.Items) {
        $n++
        $parts = @($script:KindLabels[$item.Kind])
        if ($item.Kind -ne 'Embed') {
            if ($item.Resolution) { $parts += $item.Resolution } else { $parts += 'Unknown resolution' }
            $parts += (Format-GrabSize $item.Size)
        }
        Write-GrabItem ([string]$n) ($parts -join ' - ')
        $detail = "      $(Format-GrabShortUrl $item.Url)   (found in: $($item.Method))"
        Write-Host $detail -ForegroundColor DarkGray
        if ($item.Drm) {
            Write-Host "      DRM-protected: Grab will not download this" -ForegroundColor Red
        } elseif ($item.Note) {
            $color = 'DarkGray'
            if ($item.Blocked) { $color = 'DarkYellow' }
            Write-Host "      $($item.Note)" -ForegroundColor $color
        } elseif ($item.Kind -eq 'Embed') {
            Write-Host "      handled by yt-dlp" -ForegroundColor DarkGray
        }
    }
}

# Builds the context Start-GrabMenu/Invoke-GrabDownload use for a picked source.
function New-GrabSource($Item, [string]$PageUrl, [string]$Title) {
    $site = ([Uri]$PageUrl).Host -replace '^www\.', ''
    $label = "$($script:KindLabels[$Item.Kind]) from $site"
    $source = [pscustomobject]@{
        Label = $label
        DisplayUrl = Format-GrabShortUrl $Item.Url
        ExtraArgs = @('--referer', $PageUrl)   # many CDNs only serve to their own pages
        NameTemplate = $null
        ClipTemplate = $null
        FailureHint = ''
    }
    if ($Item.Kind -ne 'Embed') {
        # yt-dlp only sees a bare file URL ("master.m3u8"), so name files
        # after the page: "<site> - <page title> [<file id>].<ext>".
        $prefix = $site
        if ($Title) {
            $t = $Title
            if ($t.Length -gt 100) { $t = $t.Substring(0, 100) }
            $t = ConvertTo-GrabFilename $t
            if ($t) { $prefix = "$site - $t" }
        }
        $prefix = (ConvertTo-GrabFilename $prefix) -replace '%', '%%'
        $source.NameTemplate = "$prefix [%(id)s].%(ext)s"
        $source.ClipTemplate = "$prefix - clip %(section_start)d-%(section_end)d [%(id)s].%(ext)s"
        $source.FailureHint = 'Links found by inspect can expire within minutes; run inspect again for a fresh one.'
    }
    $source
}

function Invoke-GrabInspect {
    param(
        [string]$PageUrl,
        $Settings,
        [bool]$HasFfmpeg,
        [switch]$Browser,
        [switch]$List
    )

    $findings = New-GrabFindings
    $title = ''
    $browserDone = $false
    $askedBrowser = $false

    if (-not $List) { Show-GrabHeader }
    Write-Host "  Inspecting $(Format-GrabShortUrl $PageUrl)" -ForegroundColor DarkGray

    if (-not $Browser) {
        Write-Host "  Reading the page..." -ForegroundColor DarkGray
        $page = Invoke-GrabHttp -Url $PageUrl -MaxBytes 5MB -TimeoutSec 20
        Write-GrabDebug "page: HTTP $($page.Status) $($page.ContentType), $($page.Body.Length) chars, final URL $(Format-GrabSafeUrl $page.FinalUrl) $($page.Error)"
        $directKind = Get-GrabMediaKind $page.FinalUrl $page.ContentType
        if ($page.Status -ge 200 -and $page.Status -lt 300 -and $directKind -and $directKind -ne 'Segment') {
            # The URL is itself a video file or manifest.
            [void](Add-GrabFinding $findings $page.FinalUrl $directKind 'the URL itself' $page.ContentType)
        } elseif ($page.Status -ge 200 -and $page.Status -lt 300) {
            $title = Get-GrabPageTitle $page.Body
            Find-GrabHtmlMedia $page.FinalUrl $page.Body $findings
            Write-GrabDebug "HTML scan: $($findings.Items.Count) candidate(s), $($findings.Ignored) fragment(s) ignored"
        } elseif ($page.Status) {
            Write-Host "  The page answered HTTP $($page.Status) to a plain request (common with bot protection)." -ForegroundColor DarkYellow
        } else {
            Write-Host "  Couldn't read the page: $($page.Error)" -ForegroundColor DarkYellow
        }
    }

    while ($true) {
        $wantBrowser = $false
        if (-not $Browser) { Complete-GrabFindings $findings $PageUrl }   # know what's usable before offering the browser
        $hasUsable = @($findings.Items | Where-Object { -not ($_.Blocked -or $_.Drm) }).Count -gt 0

        if ($Browser -and -not $browserDone) {
            $wantBrowser = $true
        } elseif (-not $browserDone -and -not $askedBrowser -and -not $List) {
            # Offer the browser once, up front, only when the HTML gave nothing usable.
            $askedBrowser = $true
            if (-not $hasUsable) {
                Write-Host ""
                if ($findings.Items.Count) {
                    Write-Host "  Only unusable sources were found in the page itself." -ForegroundColor DarkYellow
                } else {
                    Write-Host "  No video found in the page itself. Many players only request" -ForegroundColor DarkYellow
                    Write-Host "  their video once playback starts." -ForegroundColor DarkYellow
                }
                $answer = (Read-Host "  Watch the page's network traffic in a browser instead? [Y/n]").Trim()
                if ($answer -eq '' -or $answer -match '^[yY]') { $wantBrowser = $true }
            }
        }

        if ($wantBrowser) {
            $browserDone = $true
            $exe = Find-GrabBrowser
            if (-not $exe) {
                Write-Host ""
                Show-GrabBrowserHelp
                if ($List) { return }
                Wait-GrabKey
            } else {
                $t = Invoke-GrabBrowserInspect $PageUrl $findings $exe
                if ($t -and -not $title) { $title = $t }
            }
        }

        Complete-GrabFindings $findings $PageUrl

        if ($List) {
            Write-Host ""
            Show-GrabInspectList $PageUrl $title $findings -NoClear
            if (-not $findings.Items.Count -and -not $browserDone) {
                Write-Host "  Tip: grab inspect <url> --browser watches the page's network traffic instead." -ForegroundColor DarkGray
            }
            Write-Host ""
            return
        }

        Show-GrabInspectList $PageUrl $title $findings
        Write-Host ""
        if (-not $browserDone) { Write-GrabItem 'B' 'Inspect in a browser instead' '(watches network traffic while the page plays)' }
        Write-GrabItem 'P' 'Open the page itself in the grab menu' '(for sites yt-dlp supports directly)'
        Write-GrabItem '0' 'Back'
        Write-Host ""
        $prompt = '  Choose'
        if ($findings.Items.Count) { $prompt = '  Select a source to download' }
        $choice = (Read-Host $prompt).Trim().ToUpperInvariant()

        if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $findings.Items.Count) {
            $item = $findings.Items[[int]$choice - 1]
            if ($item.Drm) {
                Write-Host ""
                Write-Host "  This stream is DRM-protected. Grab doesn't download DRM content." -ForegroundColor Red
                Wait-GrabKey
                continue
            }
            if ($item.Blocked) {
                Write-Host ""
                Write-Host "  Heads up: $($item.Note)." -ForegroundColor DarkYellow
                if (-not $Settings.CookieBrowser) {
                    Write-Host "  If you're logged in to this site in a browser, [C] in the next menu lets yt-dlp use that login." -ForegroundColor DarkYellow
                }
                $answer = (Read-Host "  Try it anyway? [y/N]").Trim()
                if ($answer -notmatch '^[yY]') { continue }
            }
            Start-GrabMenu -Url $item.Url -Settings $Settings -HasFfmpeg $HasFfmpeg -Source (New-GrabSource $item $PageUrl $title)
            continue
        }
        switch ($choice) {
            'B' { if (-not $browserDone) { $Browser = $true } }
            'P' {
                $pageSource = [pscustomobject]@{
                    Label = 'the page itself'; DisplayUrl = Format-GrabShortUrl $PageUrl
                    ExtraArgs = @(); NameTemplate = $null; ClipTemplate = $null; FailureHint = ''
                }
                Start-GrabMenu -Url $PageUrl -Settings $Settings -HasFfmpeg $HasFfmpeg -Source $pageSource
            }
            '0' { return }
            'Q' { return }
        }
    }
}

# The interactive download menu. Used directly by `grab`, and by
# `grab inspect` for the source you pick ($Source set: shows where the media
# came from, names files after the page, and [0] goes back to the list).
function Start-GrabMenu {
    param(
        [string]$Url,
        $Settings,
        [bool]$HasFfmpeg,
        $Source
    )

    # Inspected media gets names built from the page title (yt-dlp only sees a
    # bare file URL); everything else keeps the normal templates.
    $nameTemplate = $script:NameTemplate
    $clipTemplate = $script:ClipTemplate
    if ($Source -and $Source.NameTemplate) {
        $nameTemplate = $Source.NameTemplate
        $clipTemplate = $Source.ClipTemplate
    }
    $baseVideo = @('-o', $nameTemplate)

    while ($true) {
        Show-GrabHeader

        if ($Source) {
            Write-GrabStatus 'Source' $Source.Label 'Cyan'
            Write-GrabStatus 'URL' $Source.DisplayUrl 'Cyan'
        } else {
            Write-GrabStatus 'URL' $Url 'Cyan'
        }
        if ($Settings.CookieBrowser) {
            Write-GrabStatus 'Cookies' $Settings.CookieBrowser 'Green'
        } else {
            Write-GrabStatus 'Cookies' 'off' 'DarkGray'
        }
        if ($Settings.OpenWhenDone) {
            Write-GrabStatus 'Open' 'folder opens when finished' 'Green'
        } else {
            Write-GrabStatus 'Open' 'off' 'DarkGray'
        }
        if (-not $HasFfmpeg) {
            Write-GrabStatus 'ffmpeg' 'NOT FOUND - merging, MP3/M4A and clips will fail (winget install Gyan.FFmpeg)' 'Red'
        }

        # Offer a newly copied link without making you go through [U].
        $clipUrl = $null
        if (-not $Source) { $clipUrl = Get-ClipboardUrl }
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
        if (-not $Source) {
            Write-GrabItem 'I' 'Inspect page for videos' '(finds video files/streams on any web page)'
            Write-GrabItem 'U' 'Enter a different URL'
        }
        Write-GrabItem 'C' 'Browser cookies'
        Write-GrabItem 'O' 'Toggle open folder when finished'
        Write-GrabItem 'Y' 'Update yt-dlp'
        if ($Source) { Write-GrabItem '0' 'Back' } else { Write-GrabItem '0' 'Exit' }
        Write-Host ""

        $choice = (Read-Host "  Choose").Trim().ToUpperInvariant()

        switch ($choice) {

            '1' {
                Invoke-GrabDownload $Url $script:VideoFolder ($baseVideo + @('-f', 'bv*+ba/b')) $Settings $Source
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
                Invoke-GrabDownload $Url $script:VideoFolder $mp4Args $Settings $Source
                Wait-GrabKey
            }

            '3' {
                $mp3Args = $baseVideo + @('-x', '--audio-format', 'mp3', '--audio-quality', '0')
                Invoke-GrabDownload $Url $script:AudioFolder $mp3Args $Settings $Source
                Wait-GrabKey
            }

            '4' {
                $m4aArgs = $baseVideo + @('-x', '--audio-format', 'm4a')
                Invoke-GrabDownload $Url $script:AudioFolder $m4aArgs $Settings $Source
                Wait-GrabKey
            }

            '5' {
                $height = Read-GrabQuality
                if ($height) {
                    $qualityArgs = $baseVideo + @(
                        '-f', "bv*[height<=$height]+ba/b[height<=$height]/b",
                        '--merge-output-format', 'mp4'
                    )
                    Invoke-GrabDownload $Url $script:VideoFolder $qualityArgs $Settings $Source
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
                Invoke-GrabDownload $Url $script:VideoFolder $clipArgs $Settings $Source
                Wait-GrabKey
            }

            '7' {
                $subArgs = $baseVideo + @(
                    '--write-subs', '--write-auto-subs',
                    '--sub-langs', 'en.*',
                    '--convert-subs', 'srt',
                    '--skip-download'
                )
                Invoke-GrabDownload $Url $script:VideoFolder $subArgs $Settings $Source
                Wait-GrabKey
            }

            '8' {
                $thumbArgs = $baseVideo + @('--write-thumbnail', '--convert-thumbnails', 'jpg', '--skip-download')
                Invoke-GrabDownload $Url $script:VideoFolder $thumbArgs $Settings $Source
                Wait-GrabKey
            }

            '9' {
                Write-Host ""
                $listArgs = @('-F')
                if ($Settings.CookieBrowser) { $listArgs += @('--cookies-from-browser', $Settings.CookieBrowser) }
                if ($Source -and $Source.ExtraArgs) { $listArgs += $Source.ExtraArgs }
                & yt-dlp @listArgs -- $Url
                Wait-GrabKey
            }

            'N' {
                if ($clipIsNew) { $Url = $clipUrl }
            }

            'U' {
                if (-not $Source) {
                    $newUrl = Read-GrabUrl
                    if ($newUrl) { $Url = $newUrl }
                }
            }

            'I' {
                if (-not $Source) {
                    Invoke-GrabInspect -PageUrl $Url -Settings $Settings -HasFfmpeg $HasFfmpeg
                }
            }

            'C' {
                Read-GrabCookieBrowser $Settings
            }

            'O' {
                $Settings.OpenWhenDone = -not $Settings.OpenWhenDone
                Save-GrabSettings $Settings
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

# ---------------------------------------------------------------- main

function Show-GrabUsage {
    Write-Host ""
    Write-Host "  grab                           menu for the URL on your clipboard (or asks for one)"
    Write-Host "  grab <url>                     menu for <url>"
    Write-Host "  grab inspect <url>             find videos on a web page, then pick one to download"
    Write-Host "  grab inspect <url> --browser   go straight to watching the page in a browser"
    Write-Host "  grab inspect <url> --list      only list what was found; download nothing"
    Write-Host "  grab inspect <url> --debug     show discovery details (URL query values hidden)"
    Write-Host "  grab help                      this help"
    Write-Host ""
    Write-Host "  Options combine, and -Browser / -List / -Debug work too. In zsh, quote URLs" -ForegroundColor DarkGray
    Write-Host "  that contain ? or & (or use the noglob alias from the README)." -ForegroundColor DarkGray
    Write-Host ""
}

function Read-GrabInspectArgs([string[]]$Tokens, [bool]$DebugSwitch) {
    $opts = [pscustomobject]@{ Url = $null; Browser = $false; List = $false; Debug = $DebugSwitch; Error = '' }
    foreach ($t in $Tokens) {
        if ($t -match '^--?browser$')    { $opts.Browser = $true }
        elseif ($t -match '^--?list$')   { $opts.List = $true }
        elseif ($t -match '^--?debug$')  { $opts.Debug = $true }
        elseif (-not $opts.Url -and (ConvertTo-GrabUrl $t)) { $opts.Url = ConvertTo-GrabUrl $t }
        else { $opts.Error = "Unexpected argument for grab inspect: $t"; break }
    }
    $opts
}

function grab {
    <#
    .SYNOPSIS
    Interactive yt-dlp front end: download video, audio, clips, subtitles and
    thumbnails, or find the videos on any web page with `grab inspect`.
    .EXAMPLE
    grab
    .EXAMPLE
    grab https://www.youtube.com/watch?v=dQw4w9WgXcQ
    .EXAMPLE
    grab inspect https://example.com/some-article --list
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Url,

        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$Rest
    )

    # -Debug is a built-in PowerShell switch; treat it as `inspect --debug`
    # and keep PowerShell's own debug prompts out of the way.
    $debugSwitch = $PSBoundParameters.ContainsKey('Debug')
    $DebugPreference = 'SilentlyContinue'

    if ($Url -in @('help', '--help', '-h', '/?')) { Show-GrabUsage; return }

    if (-not (Get-Command yt-dlp -ErrorAction SilentlyContinue)) {
        Write-Host "yt-dlp not found on PATH. Install it with:" -ForegroundColor Red
        if ($IsMacOS) {
            Write-Host "    brew install yt-dlp ffmpeg" -ForegroundColor Yellow
        } else {
            Write-Host "    winget install yt-dlp.yt-dlp" -ForegroundColor Yellow
        }
        return
    }
    $hasFfmpeg = [bool](Get-Command ffmpeg -ErrorAction SilentlyContinue)

    $settings = Get-GrabSettings

    if ($Url -eq 'inspect') {
        $opts = Read-GrabInspectArgs $Rest $debugSwitch
        if ($opts.Error) {
            Write-Host "  $($opts.Error)" -ForegroundColor Red
            Show-GrabUsage
            return
        }
        $script:InspectDebug = $opts.Debug
        try {
            $target = $opts.Url
            if (-not $target) {
                if ($opts.List) { Write-Host "  grab inspect --list needs a URL." -ForegroundColor Red; return }
                Show-GrabHeader
                $target = Read-GrabUrl
            }
            if (-not $target) { Write-Host "  No URL provided." -ForegroundColor DarkYellow; return }
            Invoke-GrabInspect -PageUrl $target -Settings $settings -HasFfmpeg $hasFfmpeg -Browser:$opts.Browser -List:$opts.List
        } finally {
            $script:InspectDebug = $false
        }
        return
    }

    if ($Rest) {
        Write-Host "  Ignoring extra arguments: $($Rest -join ' ')  (see: grab help)" -ForegroundColor DarkYellow
    }

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

    Start-GrabMenu -Url $Url -Settings $settings -HasFfmpeg $hasFfmpeg
}

Export-ModuleMember -Function grab
