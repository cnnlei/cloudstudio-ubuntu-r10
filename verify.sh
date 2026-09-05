#!/usr/bin/env bash
set -u
printf 'OS: '; . /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}" || true
printf 'PID1: '; ps -p 1 -o comm= 2>/dev/null || true
printf 'Node: '; node -v 2>/dev/null || echo missing
printf 'CodeBuddy: '; command -v codebuddy 2>/dev/null || echo missing
printf 'cs-init: '; [ -x /usr/local/sbin/cs-init ] && grep -m1 '^# VERSION:' /usr/local/sbin/cs-init || echo missing
printf 'netapp: '; command -v netapp 2>/dev/null || echo missing
[ -x /usr/local/sbin/cs-init ] && /usr/local/sbin/cs-init status || true
