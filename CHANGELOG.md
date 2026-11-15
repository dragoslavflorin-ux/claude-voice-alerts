# Changelog

## 2.0.1-beta.1 (2026-11-15, pre-release)

### Fixed
- Cowork alerts work again with the Claude desktop app 5.x: the conversation list changed its structure (status after the title, every row wrapped in its own groups, no status element on an idle row). One parser now reads the layouts of 4.x and 5.x, with test fixtures for each.
- The Cowork watcher no longer grows in memory: it reads the app through the native UI Automation client and releases every object right after use (v2.0.0 grew about 100 MB per hour). A read now covers only the conversation list (about 180 elements instead of the whole window).
- No second "done" a few seconds after a real one: the app shows "Running" for under a second when a conversation is opened, so a conversation counts as running only when two reads in a row see it; plus 10 seconds between two "done" alerts for the same conversation.
- Uninstall works when run from the install folder, and says "removed" only for what is really gone. A second run no longer makes another backup of settings.json. The final message says what is kept on purpose (settings backups, Python, edge-tts).
- Doctor checks the 5 Claude Code hooks one by one (Stop, Notification, PreToolUse, PostToolUse, UserPromptSubmit) and names the missing ones.

### Changed
- The Cowork watcher reads every 1.5 seconds while a conversation runs or waits, every 5 seconds otherwise.
- The Cowork log records every change of state of a conversation (`row [title] other -> active`), so a wrong alert can be explained from the log.
- Safety net: above 300 MB of private memory the watcher hands its state (conversations, running times, alerts on screen) to a new instance and exits.
- Installer: the "cannot read the sidebar" warning is printed once, not twice.
- README: Git for Windows in Requirements; open the Claude app before installing; where to run the uninstaller and what it keeps; Cowork tasks under about 3 seconds in the open conversation give no alert.

## 2.0.0 (2026-11-09)

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
- Cowork: works with the current sidebar of the Claude desktop app (Chats and tasks, status shown inside a group while a task runs).
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
