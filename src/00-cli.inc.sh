#!/usr/bin/env bash
#
# SPDX-License-Identifier: Apache-2.0 AND MIT
# Copyright 2026 GigaDuck OÜ
# Conduck-authored portions are Apache-2.0. The marked Project Nayuki
# QR generator block is MIT; see THIRD_PARTY_NOTICES.md.
#
# conduck-connect — pair your self-hosted AI gateway with the Conduck app.
#
# How to run (no install, nothing to compile — this is a plain, unminified shell
# script on purpose, so you can inspect it before running):
#
# Where this should come from:
#   1. Get it over HTTPS from the official release — not forwarded to you by
#      someone else:  https://github.com/gigaduckai/conduck-connect/releases
#   2. Inspect this plain, unminified file before running it when your threat
#      model calls for source review. The release tests the exact shipped artifact.
#   3. Optional integrity check: the release also ships a checksum
#        sha256sum -c conduck-connect.sh.sha256
#        # macOS: shasum -a 256 -c conduck-connect.sh.sha256
#      It catches a corrupted download, but it rides the same release channel —
#      so it can't prove the release itself wasn't swapped.
#   If you got this script any other way, get it from the link above first.
#
#     bash conduck-connect.sh            # welcome menu: setup, check a server,
#                                        #   check an adapter, or re-show a code
#     bash conduck-connect.sh --setup    # go straight to the setup wizard
#     bash conduck-connect.sh --setup --dry-run
#                                        # preview setup; changes nothing
#
# What this script DOES (always with your confirmation, step by step):
#   1. Finds your gateway (OpenClaw, Hermes, or any OpenAI-compatible server).
#   2. Enables the OpenAI-compatible chat endpoint if it is off (the #1 setup trap).
#   3. Helps you expose the gateway over HTTPS (works WITH what you have installed:
#      Tailscale, Cloudflare Tunnel, your own reverse proxy, or a self-signed cert).
#   4. Optionally sets up the agent file lane (rclone WebDAV) so Conduck can hand
#      your agent real files and download its outputs. OpenClaw gets a tool-policy
#      check + TOOLS.md guidance. Hermes gets its API-server file toolset and
#      terminal.cwd checked + verified Hermes context guidance. Every edit is
#      narrow, shown first, and optional.
#   5. Verifies everything with real requests. An OpenClaw/Hermes file lane must
#      pass a real agent read -> byte-identical write sentinel before a code.
#   6. Prints a QR code you scan with the Conduck app — URL, token, and file-lane
#      credentials imported in one scan — nothing to retype on your phone
#      (iPhone or iPad).
#
# What this script NEVER does:
#   - Install your gateway, Tailscale, cloudflared, or any daemon it didn't create.
#   - Modify configs it didn't create without showing you the exact change first.
#   - Send ANY data anywhere except to your own gateway. No telemetry, ever.
#     The QR code is generated locally on this machine.
#   - Make your gateway public without telling you, in plain words, that it will.
#
# Works on Linux and macOS gateway hosts. Requires: bash, curl, python3, openssl.
# No extra install: the QR is rendered locally by a vendored, stdlib-only Python
# encoder (Project Nayuki, MIT — the big, inert block near the end of this file;
# it needs Python 3.7+ — on an older Python you just use the printed code).
# The pairing string is always printed too, so the QR is never required.
#
# Usage:
#   bash conduck-connect.sh                 # welcome menu
#   bash conduck-connect.sh --setup         # setup + verify + pair
#   bash conduck-connect.sh --check-server [url]
#                                           # software NOT built for Conduck:
#                                           # check it against the app's core wire
#   bash conduck-connect.sh --check-adapter [url]
#                                           # check software built specifically
#                                           # for Conduck against its adapter contract
#   bash conduck-connect.sh --show-code     # re-show a SAVED pairing code; no
#                                           # configuration changes, but live
#                                           # verification sends requests and a
#                                           # configured file lane gets live
#                                           # transport verification; OpenClaw/
#                                           # Hermes get a real agent sentinel
#
# Modifiers:
#   bash conduck-connect.sh --setup --dry-run
#                                           # show setup state + plan; change nothing
#   bash conduck-connect.sh --setup --reuse-only
#                                           # advanced: walk setup using only what
#                                           # already exists. The first step that
#                                           # would change host configuration STOPS
#                                           # the run and names it — it is not
#                                           # skipped. Verification still sends
#                                           # requests and may run a small file probe
#   bash conduck-connect.sh --check-adapter --deep [url]
#                                           # add a semantic image-input check
#   bash conduck-connect.sh --check-adapter --files [url]
#                                           # also grade the configured file lane;
#                                           # writes and removes small probe files
#   bash conduck-connect.sh --setup --allow-keyless-public
#                                           # expert: permit a keyless
#                                           # gateway on a public transport during setup
#
# Information:
#   bash conduck-connect.sh --help            # show this complete public command reference
#   bash conduck-connect.sh --version         # print the connector version and exit
#
# Exit status:
#   0  requested action succeeded (or a check passed)
#   1  setup/runtime failure, or a completed check failed
#   2  command-line usage error (unknown/retired flag, invalid combination or URL)
#   128+signal  interrupted by HUP/INT/TERM
#
# Re-running is safe: every step detects existing state and reuses what's done.
# Use --show-code to re-show a saved gateway's code, skipping setup questions
# (handy for pairing a second device).

set -u -o pipefail

VERSION="0.13.0"
PAYLOAD_VERSION=1
