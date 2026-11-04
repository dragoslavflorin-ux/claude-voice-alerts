---
name: claude-voice-alerts
description: Install, reconfigure, diagnose or remove claude-voice-alerts, the voice and on-screen alerts for Claude Code and Claude Cowork on Windows. Use when the user wants alerts when Claude finishes or needs them, wants to change the alert language, voices or messages, says an alert did not sound, or wants to uninstall the alerts.
---

# claude-voice-alerts

Voice and on-screen alerts for Claude Code and Claude Cowork on Windows 10/11.
Installed copy: `~/.claude/hooks/claude-voice-alerts/` (it contains install.ps1, uninstall.ps1, doctor.ps1).
Source: https://github.com/dragoslavflorin-ux/claude-voice-alerts

Run every script with: `powershell -NoProfile -ExecutionPolicy Bypass -File <script> <parameters>`.
Never run the installer without `-Yes` from here: it would wait for keyboard input.

## Install (first time)

1. If `~/.claude/hooks/claude-voice-alerts/install.ps1` does not exist, clone the repo:
   `git clone https://github.com/dragoslavflorin-ux/claude-voice-alerts.git "$env:USERPROFILE\claude-voice-alerts"`
   and use `$env:USERPROFILE\claude-voice-alerts\install.ps1`.
2. Ask the 5 questions with your question tool (one call, several questions where possible):
   - Language: Romana (ro), English (en), Espanol (es), Portugues Brasil (pt), Francais (fr), Deutsch (de), Italiano (it), Other.
     For Other: ask for two exact edge-tts voice names and the 4 messages, and pass `-Language other`.
   - Tone: Playful (default) or Neutral (office).
   - Voice for Claude Code: male or female (or an exact edge-tts voice name). Then the voice for Cowork, the same way.
   - Messages: keep the presets, or write any of the 4 (Claude Code done, Claude Code needs you, Cowork done, Cowork needs you).
   - What to install: both (default), only Claude Code, only Cowork.
3. Run the installer with parameters, for example:
   `install.ps1 -Yes -NoPreview -Language ro -Tone playful -CodeVoice male -CoworkVoice female -Parts both`
   Custom messages: `-CodeDone "..." -CodeNeedsYou "..." -CoworkDone "..." -CoworkNeedsYou "..."`.
   Other options: `-Hotkey Ctrl+Alt+M`, `-CodeMonitor leftmost|rightmost|primary|app`, `-CoworkMonitor app`,
   `-CodeCorner bottom-left|bottom-right|top-left|top-right`, `-CoworkCorner bottom-right`.
4. Show the user the SUMMARY block of the output, including the lines under "To do by hand".
   Exit code 0 = fine, 2 = installed with warnings (read them to the user), 1 = failed.

## Change language, voices or messages

Run the installed `install.ps1 -Yes -NoPreview` with only the parameters that change; everything else keeps the
previous answers. Voices are regenerated only for texts or voices that changed.

## Diagnose ("the alert did not sound")

Run `doctor.ps1` and explain each PROBLEM line and its "What to do" line in simple words.
The log is `~/.claude/hooks/claude-voice-alerts/logs/alerts.log`. Common reasons:
- Cowork: the Claude app was the active window and was used in the last 20 seconds (log line "skip ... Claude in front").
- Cowork: the Claude app was closed or only in the tray, or the sidebar with conversations was hidden.
- Claude Code: the session was started before the install; restart it.

## Uninstall

Run the installed `uninstall.ps1`. It removes only what the installer added and keeps backups of settings.json.

## Stop an alert

Click the row (it also brings that window to front), click the red button, or press the hotkey (default Ctrl+Alt+M).
