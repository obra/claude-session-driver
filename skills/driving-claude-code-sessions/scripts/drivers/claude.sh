#!/bin/bash
# Claude Code harness driver for csd. Sourced, not executed. Implements the
# harness slot contract (docs/superpowers/specs/2026-06-05-csd-multiharness-design.md).

harness_id()            { echo "claude"; }
harness_bin()           { echo "${CSD_CLAUDE_BIN:-claude}"; }
harness_control_plane() { echo "hooks"; }
harness_id_strategy()   { echo "assign"; }
harness_quit_keys()     { echo "/exit"; }
