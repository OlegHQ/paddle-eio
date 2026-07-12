#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -eq 0 ]; then
  echo "usage: scripts/secret-safe-exec.sh COMMAND [ARG ...]" >&2
  exit 64
fi

: "${HOME:?HOME must be set}"
: "${PATH:?PATH must be set}"

safe_env=(
  "HOME=${HOME}"
  "PATH=${PATH}"
)

pass_if_set() {
  local name
  for name in "$@"; do
    if [[ -v "$name" ]]; then
      safe_env+=("${name}=${!name}")
    fi
  done
}

# Only build-tool settings cross this boundary. Compiler flags on this list
# must not contain credentials. Application, provider, Vault, proxy, SSH-agent,
# and CI credential variables stay out of Dune's `_build/trace.csexp`.
pass_if_set \
  USER LOGNAME SHELL TERM COLORTERM NO_COLOR CLICOLOR CLICOLOR_FORCE \
  LANG LC_ALL LC_CTYPE LC_MESSAGES TZ \
  TMPDIR TMP TEMP \
  XDG_CACHE_HOME XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME \
  OPAMROOT OPAMSWITCH OPAMCOLOR OPAMUTF8 OPAMJOBS OPAMYES \
  CC CXX AR RANLIB PKG_CONFIG PKG_CONFIG_PATH \
  C_INCLUDE_PATH CPLUS_INCLUDE_PATH LIBRARY_PATH \
  CFLAGS CPPFLAGS CXXFLAGS LDFLAGS OCAMLPARAM OCAMLRUNPARAM OCAMLOPTFLAGS \
  DUNE_CACHE DUNE_CACHE_ROOT DUNE_JOBS \
  SSL_CERT_FILE SSL_CERT_DIR SOURCE_DATE_EPOCH

exec env -i "${safe_env[@]}" "$@"
