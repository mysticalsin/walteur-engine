# WALTEUR TEAM MODE launcher (Windows) -- opens one terminal per named peer, each running
# Claude Code with its role charter appended to the system prompt and the peerbus MCP wired.
#
#   .\launch-team.ps1 -Project "C:\path\to\project"                 # full 7-peer team
#   .\launch-team.ps1 -Project . -Agents ATLAS,FORGE,SENTINEL       # minimum viable team
#   .\launch-team.ps1 -DryRun                                       # print, don't launch
#
# What it does per peer: sets WALTEUR_PEER_NAME/ROLE/TEAM_DIR, opens a Windows Terminal tab
# (falls back to separate PowerShell windows if wt is absent), runs `claude` with
# --append-system-prompt <identity + charter pointer + loop instruction>.
# It also ensures the PROJECT's .mcp.json carries the walteur-peerbus server entry (merge,
# never clobber) so every peer gets list_peers/send_message/check_messages/set_summary/board_*.
param(
  [string]$Project = (Get-Location).Path,
  [string[]]$Agents = @(),
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$KitTeam = Split-Path -Parent $MyInvocation.MyCommand.Path
$ManifestPath = Join-Path $KitTeam 'team-manifest.json'
$BusPath = Join-Path $KitTeam 'peerbus-mcp.mjs'
if (-not (Test-Path $ManifestPath)) { throw "team-manifest.json not found next to launcher ($KitTeam)" }
if (-not (Test-Path $BusPath)) { throw "peerbus-mcp.mjs not found next to launcher ($KitTeam)" }
$Project = (Resolve-Path $Project).Path
$Manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json

$Roster = $Manifest.peers
if ($Agents.Count -gt 0) {
  $Roster = $Manifest.peers | Where-Object { $Agents -contains $_.name }
  $missing = $Agents | Where-Object { ($Manifest.peers.name) -notcontains $_ }
  if ($missing) { throw "unknown agent(s): $($missing -join ', ') -- roster: $($Manifest.peers.name -join ', ')" }
}
if ($Roster.Count -lt 1) { throw 'empty roster' }

$TeamDir = Join-Path $Project '_team'
New-Item -ItemType Directory -Force (Join-Path $TeamDir 'inbox') | Out-Null

# -- wire the peerbus into the project's .mcp.json (merge, never clobber) --
$McpPath = Join-Path $Project '.mcp.json'
$busCmdArgs = @(($BusPath -replace '\\', '/'))
if (Test-Path $McpPath) {
  $mcp = Get-Content $McpPath -Raw | ConvertFrom-Json
} else {
  $mcp = [pscustomobject]@{ mcpServers = [pscustomobject]@{} }
}
if (-not $mcp.PSObject.Properties['mcpServers']) { $mcp | Add-Member -NotePropertyName mcpServers -NotePropertyValue ([pscustomobject]@{}) }
$entry = [pscustomobject]@{ command = 'node'; args = $busCmdArgs }
if ($mcp.mcpServers.PSObject.Properties['walteur-peerbus']) {
  $mcp.mcpServers.'walteur-peerbus' = $entry
} else {
  $mcp.mcpServers | Add-Member -NotePropertyName 'walteur-peerbus' -NotePropertyValue $entry
}
if (-not $DryRun) {
  ($mcp | ConvertTo-Json -Depth 8) -replace "`r`n", "`n" | Set-Content -NoNewline -Encoding utf8 $McpPath
  Write-Host "wired walteur-peerbus into $McpPath"
}

# -- compose per-peer launch --
$haveWt = $null -ne (Get-Command wt -ErrorAction SilentlyContinue)
$wtArgs = @()
foreach ($peer in $Roster) {
  $charter = Join-Path $KitTeam $peer.charter
  if (-not (Test-Path $charter)) { throw "charter missing for $($peer.name): $charter" }
  $append = "You are $($peer.name), role: $($peer.role), one of $($Roster.Count) REAL Claude Code peers in WALTEUR TEAM MODE (they are separate terminals, not your subagents). FIRST: read your full charter at `"$charter`" and the protocol at `"$(Join-Path $KitTeam 'TEAM-PROTOCOL.md')`". Then call set_summary to announce yourself, check_messages, and enter your loop. Idle cadence: every $($peer.loop.idle_interval_min) min."
  # inner command: set identity env, cd to project, run claude with the charter appended
  $inner = "`$env:WALTEUR_PEER_NAME='$($peer.name)'; `$env:WALTEUR_PEER_ROLE='$($peer.role)'; `$env:WALTEUR_TEAM_DIR='$TeamDir'; Set-Location '$Project'; claude --append-system-prompt '$($append -replace "'", "''")'"
  if ($DryRun) {
    Write-Host "-- $($peer.name) [$($peer.role)]"
    Write-Host "   $inner"
    continue
  }
  if ($haveWt) {
    if ($wtArgs.Count -gt 0) { $wtArgs += ';' }
    $wtArgs += @('new-tab', '--title', $peer.name, 'powershell', '-NoExit', '-Command', $inner)
  } else {
    Start-Process powershell -ArgumentList @('-NoExit', '-Command', $inner)
    Start-Sleep -Milliseconds 400
  }
}
if (-not $DryRun -and $haveWt) { & wt @wtArgs }
if (-not $DryRun) {
  Write-Host ""
  Write-Host "WALTEUR TEAM launched: $($Roster.name -join ', ')"
  Write-Host "bus: $TeamDir . protocol: $(Join-Path $KitTeam 'TEAM-PROTOCOL.md')"
  Write-Host "verify a run later: bash walteur-kit/hooks/team-coordination-gate.sh (from the project root)"
}
