#!/bin/zsh
# Params arrive as $1…, as PEEKY_PARAM_<NAME>, and as JSON on stdin.
name="${PEEKY_PARAM_NAME:-Peeky}"
say "Hello, ${name}" >/dev/null 2>&1 &
echo "Hello, ${name}! (from ${PEEKY_EXTENSION_ID} in ${PEEKY_FRONT_APP:-somewhere})"
