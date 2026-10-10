# grab: an interactive yt-dlp menu

One app for Windows and macOS: all the logic lives in `Grab.psm1` (PowerShell
7 or Windows PowerShell 5.1). On macOS a tiny `grab` shell script runs that
same module, so you can use it straight from Terminal/zsh.

| File | Used on | What it is |
|------|---------|------------|
| `Grab.psm1` | both | the whole app: menu, downloads, `grab inspect` |
| `grab` | macOS | Terminal launcher (runs `grab.ps1` with `pwsh`) |
| `grab.ps1` | macOS | loads the module and passes your arguments to it |

Tested on Windows 11. macOS is not tested yet; see [TESTING.md](TESTING.md).

## Install on Windows 11 (PowerShell)

```powershell
winget install yt-dlp.yt-dlp
winget install Gyan.FFmpeg          # needed for MP4 merging, MP3/M4A, clips and inspect's resolution check

New-Item -ItemType Directory -Force "$HOME\Tools\Grab" | Out-Null
Invoke-WebRequest "https://raw.githubusercontent.com/QuietRelay/grab/main/Grab.psm1" -OutFile "$HOME\Tools\Grab\Grab.psm1"
Unblock-File "$HOME\Tools\Grab\Grab.psm1"
Add-Content $PROFILE 'Import-Module "$HOME\Tools\Grab\Grab.psm1"'
```

Open a new terminal. If `$PROFILE` doesn't exist yet, first run
`New-Item -Force $PROFILE`. To update later, re-run the `Invoke-WebRequest`
line.

## Install on macOS (Terminal / zsh)

```zsh
brew install --cask powershell
brew install yt-dlp ffmpeg

mkdir -p ~/Tools/Grab && cd ~/Tools/Grab
for f in Grab.psm1 grab grab.ps1; do
  curl -fsSLO "https://raw.githubusercontent.com/QuietRelay/grab/main/$f"
done
chmod +x grab
echo "alias grab='noglob ~/Tools/Grab/grab'" >> ~/.zshrc
source ~/.zshrc
```

`noglob` stops zsh from treating the `?` in pasted URLs as a wildcard
("no matches found"). URLs containing `&` still need quotes:
`grab 'https://example.com/watch?a=1&b=2'`. To update later, re-run the
`for` loop.

Inside `pwsh` on macOS you can also `Import-Module ~/Tools/Grab/Grab.psm1`
exactly like on Windows.

## Use

Copy a link, then type `grab`. The URL on your clipboard is picked up
automatically (press Enter to accept it). `grab <url>` also works.

Before each download you're asked for a filename, with the default shown in
brackets. Press Enter to keep it, or type a name without an extension (yt-dlp
adds `.mp4`, `.mp3`, etc.).

After each download you land back on the menu with the same URL, so you can
grab the video, then the MP3, then the thumbnail. If you copy a new link while
the menu is open, a `[N] Use new clipboard URL` option shows up.

| Key | What it does |
|-----|--------------|
| 1-9 | The downloads (video → `~/Downloads/Videos`, audio → `~/Downloads/Audio`) |
| I   | Inspect the page for videos (see below) |
| N   | Switch to the link you just copied |
| U   | Type or paste a different URL |
| C   | Use your login cookies from Firefox/Chrome/Edge/Brave/... |
| O   | Turn "open the download folder when done" on or off (Explorer also highlights the file) |
| Y   | Update yt-dlp (do this first when a site stops working) |
| 0   | Exit |

The cookie and open-folder choices are saved in `~/.grab.json`.

**Cookies:** Firefox is the most reliable. Chrome, Edge and Brave lock their
cookie database while running, and newer Chrome builds encrypt cookies in a
way yt-dlp often can't read. Close the browser completely, or use Firefox.

## Finding videos on other pages: `grab inspect`

For pages yt-dlp doesn't know (news articles, product pages, small sites),
`grab inspect` looks for the video itself:

```
grab inspect <url>             find videos, then pick one to download
grab inspect <url> --browser   skip straight to watching the page in a browser
grab inspect <url> --list      only list what was found; download nothing
grab inspect <url> --debug     show how each source was found (URL query values hidden)
grab help
```

`-Browser`, `-List` and `-Debug` work too. `[I]` in the menu does the same for
the current URL.

1. **Page HTML.** Grab reads the page once and looks at `<video>`/`<source>`
   tags, `og:video` and `twitter:player:stream` meta tags, JSON-LD
   `contentUrl`, player iframes yt-dlp supports (YouTube, Vimeo, Wistia,
   Brightcove, JW Player, ...), and `.mp4`/`.webm`/`.m4v`/`.m3u8`/`.mpd`
   URLs inside the page's player config.
2. **Browser (optional, always asks first).** If that finds nothing usable,
   Grab offers to open the page in a Chromium-based browser and watch its
   network traffic while the video plays. It starts muted playback for you; if
   the player needs a click (or a login), do it in that window. Close the
   window when you're done; Grab also stops 20 seconds after its last new find,
   or after 2 minutes.

Each source is then checked (HTTP status, size, and resolution via `ffprobe`
when ffmpeg is installed) and listed:

```
  Discovered media:
  [1] MP4 Video - 1080p - 24.3 MB
      cdn.example.com/media/clip.mp4   (found in: <video> tag)
  [2] HLS Stream - up to 1080p - Unknown size
      cdn.example.com/hls/master.m3u8   (found in: browser network)
```

Unknown values are shown as Unknown, not guessed. Pieces of a stream (`.ts`,
`.m4s`, ranged chunks) are hidden, and quality variants of an HLS master
playlist are folded into it. Expired links (404), links that need a
login (401/403), and DRM-protected streams stay in the list with a warning.
Grab never downloads DRM content.

Picking a source opens the normal menu for it: the same options, the filename
prompt (defaulting to `<site> - <page title> [<file id>]`), and the same
folders. `[0]` takes you back to the list. `[P]` sends the page URL itself to
the normal menu instead.

### Browsers

Grab uses a browser that's already installed. It looks for Vivaldi, Chrome,
Edge, Brave and Chromium in their standard locations (on Windows under
Program Files/AppData, on macOS in `/Applications` and `~/Applications`). If
none is found, it uses a Playwright-managed Chromium when one is installed
(`npx playwright install chromium`, needs Node.js). To use a specific
browser, set `GRAB_BROWSER` to its executable, e.g.
`/Applications/Vivaldi.app/Contents/MacOS/Vivaldi`.

The browser always starts with a **new, empty, temporary profile** that is
deleted afterwards. Your normal profile, logins, history and extensions are
never opened or changed. If a site needs a login, log in inside that window
(it's forgotten afterwards). Nothing beyond a browser is required; normal
`grab` downloads don't touch any of this.

### Limits

- A video that only plays inside the browser session (it shows "HTTP 403
  outside the browser") usually also needs your login for yt-dlp. Try `[C]`
  cookies, or it may simply have expired.
- Links found this way are often signed and expire within minutes. If a
  download fails, run inspect again for a fresh link.
- Players that build the stream in the page (`blob:` URLs) without fetching a
  manifest can't be followed; this is often a sign of DRM.
- Video fetched by a service worker isn't seen.
- yt-dlp prints the full media URL (including any token) while it downloads.
