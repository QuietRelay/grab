# Testing status

| Platform | Status |
|----------|--------|
| Windows 11, PowerShell | **Tested** by the maintainer (see below) |
| macOS, Terminal / zsh | **Not tested yet** |
| Linux, PowerShell 7.6 | Development checks only (automated, local test server) |

## Windows 11

Tested by the maintainer on Windows 11 with Grab installed from
`QuietRelay/grab` (`main` at commit `5c02200`). Confirmed working:

- Installation from `QuietRelay/grab` using the README's Windows commands
- PowerShell module loading and `grab help`
- `grab inspect`: HTML5 `<video>` discovery
- `grab inspect`: browser inspection and network capture with Vivaldi
- `grab inspect`: HLS manifest detection
- End-to-end download of an inspected video through the normal menu and the
  filename prompt

Not specifically reported: DASH, DRM flagging, expired/403 handling,
Windows PowerShell 5.1 (as opposed to PowerShell 7), Chrome/Edge/Brave
instead of Vivaldi.

## macOS

Not tested yet. Nothing here should be read as confirming that the macOS
launcher (`grab`, `grab.ps1`), the install commands, browser discovery in
`/Applications`, or Finder integration work on a Mac.

## Linux (development only)

Before release, `grab inspect` was exercised on Linux with PowerShell 7.6, a
local test web server and a headless Chromium: direct MP4, HLS (master and
variant), DASH, a DRM-marked DASH manifest, a player that only requests video
once playback starts, a video that only loads inside the browser session,
404/403 links, a page without video, missing-browser messages, the existing
download options (best video, MP4, M4A, clips), the filename prompt, and the
`grab` shell launcher under zsh. Linux is not a supported platform; these runs
only stand in for the parts that behave the same everywhere.
