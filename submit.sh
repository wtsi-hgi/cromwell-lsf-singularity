#!/usr/bin/env bash

# Cromwell Containerisation-Agnostic Submission Wrapper
# Christopher Harrison <ch12@sanger.ac.uk>

set -euo pipefail

readonly BINARY="$(readlink -fn "$0")"
readonly PROGNAME="$(basename "${BINARY}")"

stderr() {
  local message="$*"

  [[ -t 2 ]] && message="$(tput setaf 1)${message}$(tput sgr0)"
  >&2 echo "${message}"
}

usage() {
  cat <<-EOF
	Usage: ${PROGNAME} MODE [OPTIONS...] COMMAND [COMMAND OPTIONS...]
	
	Common Options (available to all MODEs):
	
	  --group GROUP    The Fairshare group under which to run
	  --queue QUEUE    LSF queue in which to run [default: normal]
	  --cores CORES    The number of cores required [default: 1]
	  --memory MEMORY  The memory required, in MB [default: 1000]
	  --stdout FILE    Where to write the job's stdout stream
	  --stderr FILE    Where to write the job's stderr stream
	
	The following MODEs are available:
	EOF

  # Extract documentation from mode functions
  awk '
    BEGIN {
      in_mode = 0
    }

    /^mode_\w+\(\) {/ {
      print ""
      print gensub(/mode_(\w+)\(\) {/, "\\1:", 1)
      in_mode = 1
      next
    }

    in_mode && /^  #@/ {
      print gensub(/^  #@ ?/, "  ", 1)
    }

    in_mode && !/^  #/ {
      in_mode = 0
    }
  ' "${BINARY}"
}

mode_vanilla() {
  #@ Submit your job directly on the execution node of the LSF cluster
  true
}

mode_singularity() {
  #@ Submit your job inside a Singularity container on the LSF cluster
  #@
  #@ Options:
  #@
  #@   CONTAINER          Docker container identifier
  #@   --mount DIRECTORY  Directory to mount (optional)
  #@   --mounts FILE      File of mount points, one per line (optional)
  #@
  #@ The CONTAINER may be a local image, shub:// or docker:// URI.
  #@ Multiple DIRECTORY mounts may be specified, with or without a file
  #@ of mount points.
  # n.b., This is just a special-case of the vanilla-LSF mode
  true
}

mode_docker() {
  #@ Submit your job inside a Docker container on the LSF cluster
  #@
  #@ Options:
  #@
  #@   CONTAINER          Docker container identifier
  #@   --mount DIRECTORY  Directory to mount (optional)
  #@   --mounts FILE      File of mount points, one per line (optional)
  #@
  #@ The CONTAINER may be a local image or one provided by DockerHub, or
  #@ some other recognised repository. Multiple DIRECTORY mounts may be
  #@ specified, with or without a file of mount points.
  # n.b., This is just a special-case of the Singularity mode
  true
}

main() {
  if (( $# < 2 )); then
    stderr "Not enough arguments provided!"
    usage
    exit 1
  fi

  local mode="$1"
  if ! grep -Fq "mode_${mode}() {" "${BINARY}"; then
    stderr "No such mode \"${mode}\"!"
    usage
    exit 1
  fi

  local -a args=("${@:2}")
  "mode_${mode}" "${args[@]}"
}

main "$@"
