#!/bin/bash

[ -n "${H_GUARD_UTIL:-}" ] && return
readonly H_GUARD_UTIL=1

COLOR_RED="\033[0;31m"
COLOR_GREEN="\033[0;32m"
COLOR_BOLD="\033[1m"
COLOR_RESET="\033[0m"

function echo_normal()
{
  echo -e "${COLOR_GREEN}[+] ${COLOR_RESET}$1${COLOR_RESET}"
}

function echo_error()
{
  echo -e "${COLOR_RED}${COLOR_BOLD}[!] ERROR${COLOR_RESET}: $1${COLOR_RESET}"
}
