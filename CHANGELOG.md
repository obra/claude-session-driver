# Changelog

## [1.0.1] - 2026-02-22

### Fixed
- Hooks no longer fire in non-worker sessions. Previously, the PreToolUse
  hook polled for 30 seconds on every tool call even in normal interactive
  and --dangerously-skip-permissions sessions. Hooks now check for the .meta
  file created by launch-worker.sh and exit immediately when absent.

## [1.0.0] - 2026-02-19

### Added
- Initial release: launch, control, and monitor Claude Code worker sessions
  via tmux with lifecycle event hooks and controller-gated tool approval.
