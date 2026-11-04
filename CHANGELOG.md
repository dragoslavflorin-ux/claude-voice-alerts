# Changelog

## 2.0.0 (2026-11-04)

Renamed from claude-alerte-vocale to claude-voice-alerts. International release.

### Added
- One alert hub for everything: one window per part (Claude Code, Cowork) with one row per alert: project or conversation title, message, and how long it has been waiting. Up to 5 rows, then "+N more".
- Alerts per Claude Code session: a tool call or a new prompt in one terminal clears only its own alert. Several terminals in parallel no longer cancel each other.
- "Needs you" alerts for questions (AskUserQuestion), plan approval (ExitPlanMode) and MCP elicitation, besides permission prompts.
- Click a row: the alert closes and its window comes to front (terminal or editor of the session; the Claude app with the conversation opened).
- Voices take turns when both parts alert at once. After the voice limit the window stays until clicked (`keep_window_after_timeout`).
- Cowork: alerts when the Claude app is in front but unused for 20 seconds (`cowork_idle_seconds`); alerts clear when the conversation is read, approved or restarted anywhere, including on the phone.
- Cowork: detects conversations that finish while open, short tasks finished between two reads, questions ("Awaiting answer"), conversations with identical titles, and titles generated after the first reply.
- Cowork: works with every language of the Claude app; status labels are read from the installed app.
- Multi-monitor placement per part (`primary`, `leftmost`, `rightmost`, `app`) and corner, with DPI scaling of the target monitor.
- `min_task_seconds`: no alert for short tasks.
- 7 languages (ro, en, es, pt-BR, fr, de, it) plus "Other" with any edge-tts voice; playful and neutral presets; any male/female combination; custom messages.
- Interactive installer with parameters for unattended installs, previous answers as defaults, voice preview.
- `doctor.ps1` health check, `SKILL.md` for Claude Code, shared log with rotation.

### Changed
- Installs into `~/.claude/hooks/claude-voice-alerts/`. The stop shortcut moved from the Desktop to the Start menu.
- The PostToolUse and UserPromptSubmit hooks no longer start PowerShell: about 40 ms with Git Bash, and they read only the start of the hook input.
- MP3 voices are played directly; ffmpeg is no longer needed. edge-tts is upgraded at every install; if it fails, a Windows voice is used.
- The Cowork watcher starts without VBScript.

### Fixed
- The install check could report 0 errors when the alert window did not appear.
- Cowork: a short read failure reset the state and lost transitions.
- Cowork: rows in states the watcher did not know (Awaiting answer, Using the browser, Unread response, Done) were ignored.
- Cowork: titles ending in "New" were ignored; scheduled tasks are now recognized by their badge.
- Messages with quotes or apostrophes broke the alert; text is no longer passed on the command line.
- Long messages were cut; they now wrap on two lines.
- Shortcuts could not be created in folders with non-ANSI characters (for example a user name with diacritics).

### Upgrade from 1.x
Run the new installer: it removes the v1 hooks, scripts, voices and shortcuts and keeps your other settings.

## 1.0.0 (2026-11-04)

First release (as claude-alerte-vocale): Romanian voice alerts for Claude Code (bottom left) and Claude Cowork (bottom right), install and uninstall scripts.
