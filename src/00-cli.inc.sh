#!/usr/bin/env bash
#
# SPDX-License-Identifier: Apache-2.0 AND MIT
# Copyright 2026 GigaDuck OÜ
# Conduck-authored portions are Apache-2.0. The marked Project Nayuki
# QR generator block is MIT; see THIRD_PARTY_NOTICES.md.
#
# conduck-connect — pair your self-hosted AI gateway with the Conduck app.
#
# This is the file's own preamble, for someone who opened the source before
# running it: provenance, what the script does, what it never does, and where the
# rest is written down. `--help` is the command reference and is far shorter.
#
# Where this should come from
#   1. Over HTTPS from the official release — not forwarded to you by someone
#      else:  https://github.com/gigaduckai/conduck-connect/releases
#   2. Read it before running when your threat model calls for source review: it
#      is plain, unminified shell, and the release tests the exact shipped
#      artifact. Reading all of it is a real ask, so there is a second answer —
#      `--setup --dry-run` prints, for your host, every file it would touch and
#      every command it would run, and changes nothing.
#   3. Optional integrity check: the release also ships a checksum
#        sha256sum -c conduck-connect.sh.sha256
#        # macOS: shasum -a 256 -c conduck-connect.sh.sha256
#      It catches a corrupted download, but it rides the same release channel —
#      so it can't prove the release itself wasn't swapped.
#   If you got this script any other way, get it from the link above first.
#
# What this script DOES (with host and network changes shown for approval)
#   1. Finds your gateway (OpenClaw, Hermes, or any OpenAI-compatible server).
#   2. Enables the OpenAI-compatible chat endpoint if it is off. OpenClaw and
#      Hermes both ship it off, so the gateway looks healthy while
#      /v1/chat/completions answers 404 and no app can connect.
#   3. Helps you expose the gateway over HTTPS, working WITH what you already
#      have installed: Tailscale, Cloudflare Tunnel, or your own reverse proxy.
#      Whatever the path, the certificate has to be one your devices already
#      trust; a self-signed one stops the run, and the script names the free ways
#      to get a real one.
#   4. Optionally sets up the agent file lane (rclone WebDAV) so Conduck can hand
#      your agent real files and download its outputs. The agent-side checks are
#      gateway-aware (README.md names them per gateway), and every edit they
#      suggest is narrow, shown first, and optional.
#   5. Verifies everything with real requests. An OpenClaw/Hermes file lane must
#      pass a real agent read -> byte-identical write sentinel before a code.
#   6. Prints a setup code — as a QR you scan with the Conduck app, and as text.
#      URL, key, and file-lane password arrive in one scan; nothing to
#      retype on your phone (iPhone or iPad).
#   7. Afterwards: lists what it set up, changes one thing about a saved setup
#      without re-asking the rest, and removes one completely — the file-lane
#      service, its password and the saved gateway. Removal never deletes the
#      folder you shared, and it asks you to type the setup's id first.
#
# What this script NEVER does
#   - Install your gateway, Tailscale, cloudflared, rclone, or any background
#     program it didn't create.
#   - Modify configs it didn't create without showing you the exact change first.
#   - Send telemetry, a usage count, or a version ping — to us or to anyone.
#     There is no collection endpoint anywhere in this file. That is deliberately
#     a claim about the file rather than about us, so you can settle it by reading
#     instead of by trusting. The QR is drawn here too, by the vendored encoder
#     near the end of this file.
#   - Make your gateway public without telling you, in plain words, that it will.
#
# Where its own requests go
#   The HTTP and TLS probes this script makes reach two places only: the gateway
#   you name and the file lane you configure. Third-party contact happens on one
#   path and only one — the exposure tool YOU picked, doing the job you picked it
#   for. `tailscale serve` / `tailscale funnel` register the mapping with
#   Tailscale's control plane, each shown in full and approved before it runs; the
#   Cloudflare path runs `cloudflared tunnel list` to read the tunnels your
#   existing Cloudflare login can already see, so it can name yours back to you.
#   Both are that vendor's own client, on this machine, signed in as you.
#   Reading local state is a different thing and is not gated on your choice:
#   `tailscale status` and `tailscale serve status` ask the daemon on THIS
#   machine, so the menu can label what you already have and the port logic never
#   has to guess. Choose "I run my own HTTPS" and no mapping change and no account
#   lookup is ever requested; rclone serves WebDAV on loopback and makes no
#   outbound request of its own. README.md and SECURITY.md state the same
#   carve-out.
#
# Commands — three a script can drive, five need a person
#   Scriptable: --check-server [url], --check-adapter [url] and --list [--json].
#   Set CI=1 and the two checks never prompt; the last line is always a machine
#   summary, and the exit status is the verdict. --list asks nothing in any case:
#   it reports the setups saved on this machine, with no key, password or setup
#   code anywhere in its output.
#   Need a person at a terminal: no arguments (the welcome menu), --setup,
#   --show-code, --edit [id] and --forget <id>. Setup ends in a setup code that
#   somebody scans with the Conduck app on a phone, so a machine cannot finish it —
#   run the checks, then hand the --setup command to your operator. The wizard is
#   interactive and needs a real terminal: prompts cannot be piped in and there are
#   no non-interactive answer flags, so a tool driving it needs a real PTY. --edit
#   and --forget refuse a run with nobody there for their own reason — each ends in
#   a decision about one specific saved setup, and removal is confirmed by typing
#   its id rather than by pressing Enter.
#   `--help` lists every command, option and example. `--version` prints the
#   version and exits.
#
# Environment
#   CONDUCK_TOKEN=<key>     the key for a check, so it never reaches your
#                           shell history or argv. Export it EMPTY to declare a
#                           keyless target deliberately.
#   CONDUCK_CHECK_SERVER_MODEL=<model-id>
#                           --check-server only: grade the model you plan to use,
#                           rather than whichever id /v1/models lists FIRST — on a
#                           server offering many, listing order decides the verdict.
#   CI=1                    never prompt (1/true/yes, any case). Worth setting in
#                           any scripted run: a check that PASSES otherwise offers
#                           to continue into setup, and under a PTY with nobody
#                           watching, that offer waits forever — after the machine
#                           summary has already printed exit=0.
#
# Exit status
#   0  requested action succeeded (or a check passed)
#   1  setup/runtime failure, or a completed check failed
#   2  command-line usage error (unknown/retired flag, invalid combination or URL)
#   3  stopped by the operator before completion (q at a prompt, or Back out of a
#      run) — no setup code was printed, so a wrapper must not read it as a pairing
#   4  this action requires an interactive terminal
#   128+signal  interrupted by HUP/INT/TERM
#
# Interactive controls
#   i  explain the current bounded decision, then ask it again
#   q  stop cleanly (does not undo changes you already approved)
#   b  go back only where the prompt offers it; Back is navigation, not undo
#   Every interactive prompt states what pressing Enter will do.
#
# Requirements: a Linux or macOS gateway host with bash, curl, python3 and
# openssl. Nothing to install, nothing to compile. The QR is rendered locally by
# a vendored, stdlib-only Python encoder (Project Nayuki, MIT — the big, inert
# block near the end of this file; it wants Python 3.7+). The setup code is
# always printed as text as well, so the QR is never required.
#
# Re-running is safe: every step detects existing state and reuses what's done.
# --show-code re-shows a saved gateway's code without the setup questions — handy
# for pairing your own second device, and the code is the same reusable secret, so
# treat every copy of it like the key it carries.
#
# Once something is set up you don't have to walk the wizard again to change it.
# --list shows every saved setup and whether its file-lane service is running,
# --edit [id] re-asks ONE value — the web address a restarted quick tunnel just
# changed, the model, the shared folder — and re-verifies only what that affects,
# and --forget <id> removes one setup's service, password and saved gateway. It
# leaves the folder you shared, your agent's own files, and the pairing already on
# your phone exactly where they are, and says so before it starts.
#
# Where the rest is written down
#   README.md            overview, audit-first install, common commands
#   MANUAL.md            full command reference, operation, troubleshooting
#   SECURITY.md          threat model, what is stored where, how to report
#   WHAT-IT-TOUCHES.md   every path read or written, with undo steps
#   https://conduck.com  the app, and the adapter contract these checks grade
#                        against
#   src/                 this artifact is assembled from the modules listed in
#                        src/manifest.txt, each owning one stage of the run — read
#                        the module that names your question, not the whole file.

set -u -o pipefail

VERSION="0.15.0"
PAYLOAD_VERSION=1
