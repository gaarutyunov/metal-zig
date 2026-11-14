#!/bin/sh
# Simulates typing a command at a prompt, then runs it (for terminal recordings).
cd "$1" || exit 1
shift
perl -e '$| = 1; print "\e[1;32m\$\e[0m "; for (split //, join(" ", @ARGV)) { print; select(undef, undef, undef, 0.06) } print "\n"' "$@"
"$@"
perl -e 'select(undef, undef, undef, 2.5)'
