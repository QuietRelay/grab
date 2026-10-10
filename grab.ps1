# Entry point used by the `grab` shell script (macOS Terminal). In PowerShell
# itself, Import-Module Grab.psm1 from your profile instead.
Import-Module (Join-Path $PSScriptRoot 'Grab.psm1') -Force
grab @args
