: << 'CMDBLOCK'
@echo off
setlocal enabledelayedexpansion
REM Cross-platform polyglot wrapper for hook scripts.
REM On Windows: cmd.exe runs the batch portion, which finds and calls bash.
REM On Unix: the shell interprets this as a script (: is a no-op in bash).
REM
REM Hook scripts use extensionless filenames (e.g. "session-start" not
REM "session-start.sh") so Claude Code's Windows auto-detection -- which
REM prepends "bash" to any command containing .sh -- doesn't interfere.
REM
REM `setlocal enabledelayedexpansion` is required so `!ERRORLEVEL!` captures
REM the actual bash exit code rather than the value `%ERRORLEVEL%` had when
REM the parenthesized `if` block was first parsed (which is always 0 on the
REM first call). Without it, hook failures look like successes to Claude
REM Code, which silently breaks PreToolUse approval gating.
REM
REM Usage: run-hook.cmd <script-name> [args...]

set "HOOK_DIR=%~dp0"

if exist "C:\Program Files\Git\bin\bash.exe" (
    "C:\Program Files\Git\bin\bash.exe" "%HOOK_DIR%%~1" %2 %3 %4 %5 %6 %7 %8 %9
    exit /b !ERRORLEVEL!
)
if exist "C:\Program Files (x86)\Git\bin\bash.exe" (
    "C:\Program Files (x86)\Git\bin\bash.exe" "%HOOK_DIR%%~1" %2 %3 %4 %5 %6 %7 %8 %9
    exit /b !ERRORLEVEL!
)

REM No Git-for-Windows bash. The plugin can't operate without it; exit 0 so
REM lifecycle hooks (Stop/SessionEnd) don't block session shutdown (#15). The
REM worker can't run on Windows anyway (tmux dep), and a controller without
REM bash has no .meta file so approve-tool would exit 0 silently for it.
exit /b 0
CMDBLOCK

# Unix: run the named script directly
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_NAME="$1"
shift
exec bash "${SCRIPT_DIR}/${SCRIPT_NAME}" "$@"
