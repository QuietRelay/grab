# grab: an interactive yt-dlp menu

## Install (one time)

```powershell
winget install yt-dlp.yt-dlp
winget install Gyan.FFmpeg          # needed for MP4 merging, MP3/M4A and clips

# put Grab.psm1 somewhere permanent, e.g. $HOME\Tools\Grab\Grab.psm1 (copy it out of this repo), then:
Unblock-File "$HOME\Tools\Grab\Grab.psm1"
Add-Content $PROFILE 'Import-Module "$HOME\Tools\Grab\Grab.psm1"'
```

Open a new terminal. If `$PROFILE` doesn't exist yet, first run
`New-Item -Force $PROFILE`.

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
| 1-9 | The downloads (video → `~\Downloads\Videos`, audio → `~\Downloads\Audio`) |
| N   | Switch to the link you just copied |
| U   | Type or paste a different URL |
| C   | Use your login cookies from Firefox/Chrome/Edge/Brave/... |
| O   | Turn "open Explorer with the file selected when done" on or off |
| Y   | Update yt-dlp (do this first when a site stops working) |
| 0   | Exit |

The cookie and open-folder choices are saved in `~\.grab.json`.

**Cookies:** Firefox is the most reliable. Chrome, Edge and Brave lock their
cookie database while running, and newer Chrome builds encrypt cookies in a
way yt-dlp often can't read. Close the browser completely, or use Firefox.
