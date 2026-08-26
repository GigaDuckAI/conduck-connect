# ---------------------------------------------------------------- utilities --

# Colour is keyed on stdout being a terminal, not on $TERM alone: a redirected or
# piped run (CI parsing [CHECK_ID] lines) must get clean text, never escape soup.
if [ -t 1 ]; then
  BOLD=$(tput bold 2>/dev/null || true); DIM=$(tput dim 2>/dev/null || true)
  RED=$(tput setaf 1 2>/dev/null || true); GREEN=$(tput setaf 2 2>/dev/null || true)
  YELLOW=$(tput setaf 3 2>/dev/null || true); RESET=$(tput sgr0 2>/dev/null || true)
else
  BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; RESET=""
fi

say()  { printf '%s\n' "$*"; }
head_() { printf '\n%s%s%s\n' "$BOLD" "$*" "$RESET"; }
ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$*"; }
bad()  { printf '  %s✗%s %s\n' "$RED" "$RESET" "$*"; }
note() { printf '  %s%s%s\n' "$DIM" "$*" "$RESET"; }
warn() { printf '%s! %s%s\n' "$YELLOW" "$*" "$RESET"; }
die()  { printf '%sError:%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }
usage_die() { printf '%sUsage error:%s %s\n' "$RED" "$RESET" "$*" >&2; exit 2; }

# The ONE sanitiser for gateway-supplied text on its way to the terminal — model
# ids, Content-Type values, wire error codes. A gateway is not trusted to be
# friendly: an embedded newline forges an extra "[CHECK_ID] …" line in the check
# transcript (a hostile server printing its own green PASS), and an ANSI escape
# repaints or erases what the operator already read. Strips every C0 control and
# DEL, then bounds the length so one reply cannot flood the run. Applied where a
# value LEAVES its parser, so every later print site inherits it.
# `tr`, not python3: this runs on failure paths, and a display helper must not be
# able to fail. C1 (0x80-0x9F) is deliberately left alone — in a UTF-8 terminal
# those bytes only occur inside multi-byte characters, and deleting them would
# mangle a legitimate non-ASCII model id.
safe_display() { # safe_display <value> [max-chars, default 120] -> printable, bounded
  local max="${2:-120}" s
  s=$(printf '%s' "$1" | LC_ALL=C tr -d '\000-\037\177' 2>/dev/null)
  [ "${#s}" -le "$max" ] || s="${s:0:$max}…"
  printf '%s' "$s"
}

# Bracket RANGES in a shell pattern resolve through the locale's COLLATION order,
# not ASCII. Under en_US.UTF-8 — the default on macOS and most desktops, and what
# the CI runners use — [a-z] also matches A-Y, and every alphabetic range, [A-Za-z]
# included, also matches accented letters such as Ä, é and ß. Bash 3.2 has no
# `globasciiranges` to turn that off; LC_COLLATE=C is ignored whenever LC_ALL is
# set; and a global LC_ALL=C would drag LC_CTYPE with it and break the multi-byte
# handling safe_display above depends on. So every class in this script that means
# "ASCII" is written out in full, and tests/run-checks-suite.sh lints for the
# reintroduction of a range. This is not style: the id charset below is the only
# guard on the only irreversible command in the tool.
ASCII_LOWER='abcdefghijklmnopqrstuvwxyz'
ASCII_UPPER='ABCDEFGHIJKLMNOPQRSTUVWXYZ'
ASCII_DIGIT='0123456789'

# THE gateway-id charset — one definition, shared by the saved-profile validator
# (show_qr_validate_profile) and the --forget/--edit guard (manage_id_ok), because
# two literal allowlists for one rule is how they drift apart.
#
# Lowercase letters, digits and hyphens, and nothing else. An id is concatenated
# into $STATE_DIR/profile-<id>.json and into a systemd/launchd unit filename, and
# the default macOS filesystem is case-INSENSITIVE: an accepted uppercase id opens
# the lowercase setup it is not addressing, so --forget would delete a profile
# while every exact string comparison around it still reads "a different setup".
ascii_id_ok() { # ascii_id_ok <id>
  case "${1:-}" in
    ''|*[!abcdefghijklmnopqrstuvwxyz0123456789-]*) return 1 ;;
    *) return 0 ;;
  esac
}

# https://user:pass@host is a legal URL that NO endpoint here may carry. It is a
# credential the app would have to store inside a routing field, and this script
# echoes the URL back on screen, writes it to the pairing profile that
# WHAT-IT-TOUCHES.md calls credential-free, and puts it in the QR. The Conduck app
# refuses userinfo on every persisted endpoint URL, on write and on read alike;
# the connector has to agree, or the wizard happily emits a code the app rejects.
# Pure Bash — doctor_accept_url calls this before the runtime preflight, so it may
# not depend on python3/curl existing. The authority ends at the first / ? or #.
url_has_userinfo() { # url_has_userinfo <url> -> 0 when the authority carries user[:pass]@
  case "$1" in *://*) ;; *) return 1 ;; esac   # no scheme, no authority — let the scheme check answer
  local a="${1#*://}"; a="${a%%[/?#]*}"
  case "$a" in *@*) return 0 ;; *) return 1 ;; esac
}
URL_USERINFO_HINT="A key or password doesn't belong in the address. Drop the \"user:pass@\" part and give the plain URL — it is asked for separately, at a hidden prompt."

# The ONE answer to "is this an address only the local network can reach?", shared
# by every prompt in this script that may accept a plain-http endpoint. It exists
# because the Conduck app applies exactly this rule to every address it stores, and
# the two have to agree: a wizard that accepted MORE would mint a setup code that
# imports and then fails on the phone, and one that accepted LESS would refuse an
# address the app is perfectly happy with.
#
# It is not a security boundary and not this tool's opinion. Apple's App Transport
# Security decides from the address STRING, before any connection is attempted: a
# loopback or private IPv4 literal, an IPv6 ULA or link-local literal and a
# `.local` name are all permitted over plain http; a dotted domain name is refused
# even when it resolves onto the very same private network, and so is the
# carrier-grade NAT range an overlay VPN hands out. This function predicts that
# verdict, so the refusal lands here in words instead of arriving later inside the
# app as an unexplained failure.
#
# WHERE A CASE WAS NEVER MEASURED AGAINST ATS, THE KERNEL DECIDES IT. This path
# hands over a bearer token in CLEARTEXT, so an unmeasured shape is allowed only
# when a wrong prediction cannot cost the secret — that is, when the kernel
# confines the traffic whichever way the verdict went. Two ranges qualify and stay
# local: `127.0.0.0/8` past `127.0.0.1` (the kernel routes the whole /8 to `lo0`,
# so a packet cannot leave the machine) and `fe80::/10` (link-local by definition,
# and its IPv4 twin `169.254/16` WAS measured permitted). Every other unmeasured
# shape is one a resolver or a route could carry beyond the local network, and is
# refused: `0.0.0.0/8`, its IPv6 twin `::`, deprecated site-local `fec0::/10`, and
# every single-label name. The asymmetry is the whole rule — a wrong refusal costs
# one message, a wrong allowance costs the token.
#
# Pure Bash for the same reason url_has_userinfo is — doctor_accept_url runs before
# the runtime preflight, so this may not depend on python3, curl, or even `tr`
# existing. That is why every letter comparison below is spelled in both cases
# rather than lowercased first.
#
# WHERE IT DELIBERATELY REFUSES MORE THAN THE APP DOES. The app classifies with
# inet_aton, the platform's own legacy grammar and the one the resolver itself
# falls back to, which reads `2130706433`, `0x7f.0.0.1`, `0177.0.0.1` and `127.1`
# as addresses — and reads `010.1.1.1` as 8.1.1.1, a PUBLIC host. Bash cannot
# reproduce that grammar, and guessing at it has an asymmetric cost: refusing an
# address the app would have taken costs one retype, while accepting one the app
# refuses mints a code that fails on somebody's phone with nothing here to explain
# it. So a numeric host that is not a canonical four-part dotted quad is refused,
# which is also what keeps `0xc0a80101` and `134744072` out — they are addresses
# to the resolver, and one of them is 8.8.8.8.
#
# The same asymmetry covers IPv6, where it now costs only the IPv4-mapped
# (`::ffff:192.168.1.1`) and IPv4-compatible (`::192.168.1.1`) forms: the app
# unwraps those onto the IPv4 table and this function refuses them, because
# reproducing that unwrap in shell buys nothing an operator can plausibly type at
# this prompt. Site-local `fec0::/10` is refused on BOTH sides and is no longer a
# divergence. Direction is safe throughout: across the whole table there is no
# host this function accepts and the app refuses, only hosts it refuses and the
# app would have taken.
url_is_local_host() { # url_is_local_host <host[:port]> -> 0 when only the local network reaches it
  local h="$1" hx o o1 o2 rest
  # Junk first. curl and Foundation both end an authority at the first / ? or #,
  # and an `@` inside one is userinfo — http://192.168.1.1@evil.example is a REMOTE
  # host wearing a private address as a username, which is the exact trap this
  # function exists not to fall into. None of these may be read as part of a host.
  case "$h" in
    ''|*@*|*/*|*'?'*|*'#'*|*[[:space:]]*) return 1 ;;
  esac
  case "$h" in
    \[*)
      # A bracketed IPv6 literal, with or without a :port.
      case "$h" in
        \[*\]|\[*\]:*) ;;
        *) return 1 ;;                      # a bracket opened and never closed
      esac
      h="${h#\[}"; h="${h%%\]*}"
      # A zone id names an interface, not a different address, and it has to come
      # off BEFORE the literal is read: a parser handed `fe80::1%en0` whole reads a
      # DIFFERENT address from the one `fe80::1` names.
      case "$h" in *%*) h="${h%%\%*}" ;; esac
      [ -n "$h" ] || return 1
      case "$h" in *[!0123456789ABCDEFabcdef:]*) return 1 ;; esac
      case "$h" in
        ::1) return 0 ;;                    # loopback
        # Unspecified `::`, the IPv6 twin of 0.0.0.0. Never measured against ATS,
        # not confined to this machine the way loopback is, and nobody types it
        # for a real server. Refused, per the unmeasured rule in the header.
        ::)  return 1 ;;
      esac
      # ULA fc00::/7 and link-local fe80::/10, matched on the FULL first hextet and
      # never on a text prefix: `fc0::1` is 0x0fc0 and `fe8::1` is 0x0fe8 — neither
      # is in either range, yet both open with the letters a prefix test looks for.
      hx="${h%%:*}"
      case "$hx" in
        [Ff][CcDd][0123456789ABCDEFabcdef][0123456789ABCDEFabcdef]) return 0 ;;
        [Ff][Ee][89ABab][0123456789ABCDEFabcdef]) return 0 ;;
        # Deprecated site-local fec0::/10 (fec0–feff), its own arm rather than the
        # default so the refusal reads as deliberate: unmeasured against ATS,
        # deprecated since RFC 3879, and — unlike link-local — routable beyond the
        # link, so a wrong guess here could put the token on somebody else's wire.
        [Ff][Ee][CcDdEeFf][0123456789ABCDEFabcdef]) return 1 ;;
      esac
      return 1 ;;                           # global unicast, NAT64, IPv4-mapped forms
  esac
  case "$h" in
    *:*:*) return 1 ;;                      # an unbracketed IPv6 literal is not a legal authority
    *:*)   h="${h%%:*}" ;;                  # host:port
  esac
  [ -n "$h" ] || return 1
  # `myhost.local.` is the explicit-FQDN spelling of `myhost.local`, resolves
  # identically, and fails a `.local` suffix test unless the dot comes off. Exactly
  # one dot comes off: stripping a run of them is the classic suffix-bypass shape.
  # The strip cannot flip a verdict: a single label is refused rooted or not, and
  # `localhost`, `local` and `*.local` mean the same thing rooted.
  case "$h" in *.) h="${h%.}" ;; esac
  [ -n "$h" ] || return 1
  case "$h" in
    *[!0123456789.]*) ;;                    # holds a letter or a hyphen — a name, below
    *)
      # Digits and dots only: it is an address in canonical form, or it is nothing.
      case "$h" in *.*.*.*.*) return 1 ;; esac        # five labels or more
      case "$h" in *.*.*.*) ;; *) return 1 ;; esac    # fewer than four
      o1="${h%%.*}"; rest="${h#*.}"
      o2="${rest%%.*}"; rest="${rest#*.}"
      for o in "$o1" "$o2" "${rest%%.*}" "${rest#*.}"; do
        case "$o" in
          ''|*[!0123456789]*) return 1 ;;
          0) ;;                             # a lone zero is canonical
          0*) return 1 ;;                   # a leading zero is OCTAL to inet_aton
        esac
        [ "${#o}" -le 3 ] || return 1
        [ "$o" -le 255 ] || return 1
      done
      case "$o1" in
        # "This network" 0.0.0.0/8. `http://0/` reaches THIS host on Darwin, which
        # is exactly why it is a classic SSRF bypass string — and it is unmeasured
        # against ATS, NOT kernel-confined the way 127/8 is, and nobody types it
        # for a real server (a loopback user has `localhost` and `127.0.0.1`).
        # Refused, per the header. The short inet_aton spellings of the same thing
        # (`0`, `0.1`) never reach this arm: the canonical-quad test above already
        # refuses everything that is not four dotted octets.
        0)   return 1 ;;
        10)  return 0 ;;
        127) return 0 ;;
        169) if [ "$o2" = "254" ]; then return 0; fi; return 1 ;;
        172) if [ "$o2" -ge 16 ] && [ "$o2" -le 31 ]; then return 0; fi; return 1 ;;
        192) if [ "$o2" = "168" ]; then return 0; fi; return 1 ;;
        100)
          # Carrier-grade NAT, 100.64.0.0/10 — the range an overlay VPN such as
          # Tailscale hands out. Its own arm rather than the default, because this
          # is the surprising exclusion and a reader has to be able to see it was
          # deliberate: measured on iOS, a plain-http request to a 100.64/10 address
          # is refused before it is attempted, exactly like a public one. A tailnet
          # address wants the https certificate Tailscale Serve issues for it
          # anyway, which is what option 1 of the exposure menu sets up.
          return 1 ;;
      esac
      return 1 ;;
  esac
  case "$h" in
    [Ll][Oo][Cc][Aa][Ll][Hh][Oo][Ss][Tt]) return 0 ;;
    [Ll][Oo][Cc][Aa][Ll]) return 0 ;;
    *.[Ll][Oo][Cc][Aa][Ll]) return 0 ;;     # mDNS/Bonjour
  esac
  # EVERY OTHER NAME IS REFUSED — two families, one verdict, refused for different
  # reasons.
  #
  # A DOTTED NAME, however private the machine behind it: the platform decides from
  # the string, so a split-horizon name pointing straight at a LAN box collects the
  # same refusal as a public one.
  #
  # A SINGLE LABEL, rooted or not — `nas`, `ollama`, `uz`, `uz.`. The hopeful
  # reading is that a dotless name can only resolve through mDNS or this device's
  # own search domain, both of them the local link. It is wrong: real one-label
  # TLDs answer at the public DNS root with apex A records (`dig +short A uz.` ->
  # 91.212.89.8, measured), so a resolver that falls through its search domains to
  # the root would carry the bearer token in cleartext to a public host. Nothing
  # that worked is lost — an unresolvable label dead-ends at "host not found"
  # either way — and the refusal copy names the two spellings of the same machine
  # that DO work: its IP literal, or its `.local` name. The app draws exactly this
  # line, and the two have to agree.
  return 1
}
# The refusal and the caveat, in one place each, because both are said at more than
# one prompt and two spellings of one fact are two chances to drift. The refusal
# names the spellings that DO work rather than the rule it is applying — and it
# names BOTH of them, because `.local` is the one that rescues the operator whose
# single-label `nas` was just turned down. The caveat names what is actually at
# risk and what the lane cannot do, and gives no instruction, because by then the
# operator has chosen and being lectured is not information.
#
# The app says the same two things in its own words. It attributes the rule to
# "Apple" rather than to iOS because the same string renders on a Mac, and this
# script says "Apple" for the same reason. Where the app says "this network" it is
# running on the phone; this script runs on the server, so it says "that network".
URL_PLAIN_HTTP_HINT="Apple allows plain http:// only to an address on your own network. Use the server's IP address or its name ending in .local, or https:// for anywhere else."
URL_PLAIN_HTTP_WARNING="Not encrypted — anyone on that network can read your messages and your key. Works only on that network — not in the car or out with the Watch."

OS="$(uname -s)"   # Linux | Darwin
# ${HOME:-} so a check run in a HOME-less environment (a bare CI shell) doesn't
# abort here under `set -u` on a path it never uses; the wizard would fail later
# anyway if it genuinely needed a state dir, which is the correct place to notice.
#
# Resolved ABOVE the argument loop because --help names this directory, and the
# argument loop runs the moment the script is read: a definition further down the
# file would be an unbound variable by the time `--help` printed.
STATE_DIR="${XDG_CONFIG_HOME:-${HOME:-}/.config}/conduck"

DRY_RUN=false
REUSE_ONLY=false
SHOW_QR=false
ALLOW_KEYLESS_PUBLIC=false
DOCTOR=false
DOCTOR_DEEP=false
DOCTOR_FILES=false
COMPAT=false
CHECK_URL=""
COMMAND=""         # menu | setup | check-server | check-adapter | show-code | list | edit | forget
SETUP_FROM_CHECK=false
# Which check handed off (server | adapter). Read only for prompt wording, and
# held as state because the identity question it phrases is asked later than the
# handoff — inside run_setup, under the single-instance lock.
SETUP_FROM_CHECK_KIND=""
CLI_ARG_COUNT=$#
# Legacy compatibility (see the --generic arm below). SETUP_GATEWAY_HINT skips
# gateway detection entirely; it is set ONLY by --generic and never by the new CLI.
SETUP_GATEWAY_HINT=""
LEGACY_GENERIC=false

# What argv said about the manage commands. The values the manage module actually
# reads are $MANAGE_JSON and $MANAGE_ID, and validate_cli assigns them from these
# two — for the same reason CLI_REUSE_ONLY exists, plus one that is specific to
# this pair. The argument loop below runs while THIS module is being read, and the
# manage module is read after it, so anything that module initialises at file
# scope lands on top of a value parsed here. Holding the parsed answer in a global
# the manage module has no reason to touch, and handing it over at validate_cli
# time — which runs once the whole script is assembled — makes the two modules
# independent of their order in src/manifest.txt.
CLI_MANAGE_JSON=false

# True only while the run was ENTERED from the welcome menu, which is the one
# case where "stop" has somewhere to go back to. A run started as
# `--setup`/`--check-adapter`/… was launched at a shell prompt the operator is
# already standing at, so offering to "return to the menu" there would invent a
# screen they never asked for.
MENU_HUB=false
# The exit status a menu-entered command uses to say "I am done, show the menu
# again" instead of "the program is finished". It travels as a status because the
# command runs in a subshell (see menu_hub_loop) — every other channel out of a
# subshell is a string on a stream some caller is already parsing.
MENU_RETURN_STATUS=20

set_command() { # set_command <command>
  if [ -n "$COMMAND" ]; then
    usage_die "Choose one action only: --setup, --check-server, --check-adapter, --show-code, --list, --edit or --forget."
  fi
  COMMAND="$1"
}

# --help is COMPOSED, not extracted from the file header. The two have different
# readers and cannot be the same text: the header is a preamble for somebody who
# already opened the file in a pager and is committed to reading it, so it can
# afford SPDX lines, download provenance and a manifesto. `--help` is the first
# command a stranger types to decide whether to keep going, and it has to open
# with a synopsis, fit near a screen, and end with somewhere else to look.
#
# The COMMANDS split is load-bearing, not cosmetic: three of the eight commands are
# fully machine-drivable and five are not, and nothing else in the project says
# which. --setup ends in a QR code a person scans with a phone, so no amount of
# scripting finishes it — an agent that learns this here stops trying.
print_help() {
  say "conduck-connect $VERSION — pair your self-hosted AI gateway with the Conduck app."
  say ""
  say "SYNOPSIS"
  say "  bash conduck-connect.sh [--setup | --check-server [url] | --check-adapter [url]"
  say "                          | --show-code | --list [--json] | --edit [id]"
  say "                          | --forget <id>] [options]"
  say ""
  say "COMMANDS — scriptable (pass the url, set CI=1; no terminal needed)"
  say "  --check-server [url]   Grade software NOT built for Conduck against the app's core"
  say "                         wire protocol. Ends in one machine-readable summary line."
  say "  --check-adapter [url]  Grade software built specifically for Conduck against its"
  say "                         adapter contract. Ends in one machine-readable summary line."
  say "  --list [--json]        List what is already set up on this machine: each saved"
  say "                         gateway's id, address, transport, model and shared folder,"
  say "                         and whether its file-lane service is running. Asks nothing,"
  say "                         changes nothing, and prints no key, password or setup code."
  say ""
  say "COMMANDS — need a person at a terminal"
  say "  (no command)           Welcome menu: pick one of the actions below."
  say "  --setup                Set up, verify and pair a gateway. It ends in a QR code"
  say "                         somebody scans with the Conduck app on an iPhone or iPad,"
  say "                         so a machine cannot finish it."
  say "  --show-code            Re-show a SAVED setup code, to pair another device. Changes"
  say "                         no configuration; live verification still sends requests."
  say "  --edit [id]            Change ONE thing about a saved setup — its web address, its"
  say "                         model, its shared folder — and re-verify only what that"
  say "                         changed. Removal lives here too. Without an id, it asks"
  say "                         which saved setup you mean."
  say "  --forget <id>          Remove one saved setup: stop and delete its file-lane"
  say "                         service, its saved password and its saved gateway."
  say "                         You confirm by typing the id, not by pressing Enter. It"
  say "                         never deletes your shared folder, and exits 1 if no setup"
  say "                         has that id — run --list to see the ids."
  say ""
  say "OPTIONS"
  say "  --json                 With --list: machine-readable output instead of the report."
  say "  --dry-run              With --setup: print the whole plan and change nothing."
  say "  --reuse-only           With --setup: use only what already exists. The first step"
  say "                         that would change host configuration stops the run and names"
  say "                         it — it is not skipped."
  say "  --allow-keyless-public With --setup: expert — permit a gateway with no key on a"
  say "                         publicly reachable transport."
  say "  --deep                 With --check-adapter: add a semantic image-input check."
  say "  --files                With --check-adapter: also grade the file lane — the one"
  say "                         already paired, or one named with CONDUCK_FILES_* (below)."
  say "                         Writes and removes small probe files."
  say ""
  say "  bash conduck-connect.sh --help       print this reference and exit"
  say "  bash conduck-connect.sh --version    print the version and exit"
  say ""
  say "ENVIRONMENT"
  say "  CONDUCK_TOKEN               The key for a check, so it never reaches your"
  say "                              shell history or argv."
  say "  CONDUCK_CHECK_SERVER_MODEL  --check-server only: grade the model you plan to use."
  say "                              Without it the named-model checks take whichever id"
  say "                              /v1/models happens to list first."
  say "  CI=1                        Never wait for a person: a passing check prints its"
  say "                              summary and exits instead of offering to continue into"
  say "                              setup. Accepts 1, true or yes."
  say "  CONDUCK_FILES_URL           --check-adapter --files on a machine that has NOT been"
  say "  CONDUCK_FILES_DIR           through --setup (every build rig): name the lane to grade."
  say "  CONDUCK_FILES_PASS          URL is the file server's address (https://…, or http://"
  say "  CONDUCK_FILES_USER          toward an address on your own network); DIR is the same"
  say "                              absolute folder the adapter was given; PASS is its password;"
  say "                              USER defaults to conduck. Set all of URL/DIR/PASS together,"
  say "                              or none."
  say ""
  say "EXIT STATUS"
  say "  0  requested action succeeded (or a check passed)"
  say "  1  setup/runtime failure, or a completed check failed"
  say "  2  command-line usage error (unknown/retired flag, invalid combination or URL)"
  say "  3  stopped by the operator before completion (q at a prompt, or Back out of a run)"
  say "  4  this action requires an interactive terminal"
  say "  128+signal  interrupted by HUP/INT/TERM"
  say ""
  say "EXAMPLES"
  say "  bash conduck-connect.sh --setup --dry-run   # see every change first; change nothing"
  say "  bash conduck-connect.sh --setup             # set up, verify, print the setup code"
  say "  CI=1 CONDUCK_TOKEN=… bash conduck-connect.sh --check-adapter https://ai.example.com"
  say "  bash conduck-connect.sh --list              # what this machine already has set up"
  say "  bash conduck-connect.sh --edit my-gateway   # the quick tunnel handed out a new"
  say "                                              # address overnight: give this one setup"
  say "                                              # the new one and leave the rest alone"
  say ""
  say "FILES"
  say "  $STATE_DIR"
  say "      Saved gateways and file-lane passwords. A gateway key is never stored."
  say "      --list reports what is in here; --forget <id> removes one setup's share of it."
  say ""
  say "SEE ALSO"
  say "  https://conduck.com/setup/   setup guides and the adapter contract"
  say "  WHAT-IT-TOUCHES.md           every path this reads or writes, and how to undo it"
  say "  The comment header at the top of this file — what it does, what it never does,"
  say "  and where an official copy comes from."
}

# Temporary pre-0.13 subcommand spellings were published briefly. They do not
# remain aliases, but people following an old instruction deserve the exact
# replacement instead of a generic positional-argument failure.
case "${1:-}:${2:-}" in
  setup:*)       usage_die "The retired setup subcommand is now --setup (try --help)." ;;
  show-code:*)   usage_die "The retired show-code subcommand is now --show-code (try --help)." ;;
  check:server)  usage_die "The retired check server form is now --check-server [url] (try --help)." ;;
  check:adapter) usage_die "The retired check adapter form is now --check-adapter [url] (try --help)." ;;
esac

for arg in "$@"; do
  case "$arg" in
    --setup)         set_command "setup" ;;
    --check-server)  set_command "check-server" ;;
    --check-adapter) set_command "check-adapter" ;;
    --show-code)     set_command "show-code" ;;
    # The three manage commands. Their optional/required id arrives through the
    # same single positional slot the checks use for a URL — see CLI_POSITIONAL
    # below, and validate_cli, which is where a positional gets its meaning.
    --list)          set_command "list" ;;
    --edit)          set_command "edit" ;;
    --forget)        set_command "forget" ;;
    --json)     CLI_MANAGE_JSON=true ;;
    --dry-run)  DRY_RUN=true ;;
    --reuse-only) REUSE_ONLY=true ;;
    --allow-keyless-public) ALLOW_KEYLESS_PUBLIC=true ;;
    --deep)     DOCTOR_DEEP=true ;;
    --files)    DOCTOR_FILES=true ;;
    --version)
      [ "$CLI_ARG_COUNT" = "1" ] || usage_die "--version must be used by itself."
      say "conduck-connect $VERSION"; exit 0 ;;
    -h|--help)
      [ "$CLI_ARG_COUNT" = "1" ] || usage_die "$arg must be used by itself."
      print_help; exit 0 ;;
    # --- compatibility with pre-0.13.0 spellings -------------------------------
    # Conduck app builds already on the App Store emit `--generic` verbatim, and
    # every client resolves releases/latest, so an old install always downloads the
    # newest script. --generic therefore stays FUNCTIONAL (not merely diagnosed) and
    # cannot be removed on a later release while those builds exist. It is
    # compatibility plumbing: deliberately absent from --help and the welcome menu.
    # It preserves its original meaning — skip gateway detection so a stray OpenClaw
    # or Hermes install on the same host can never become the default.
    --generic)
      set_command "setup"
      SETUP_GATEWAY_HINT="custom"
      LEGACY_GENERIC=true ;;
    # The rest were only ever typed by a human from docs, so a named error that
    # points at the replacement is enough — no behavior is preserved.
    --doctor)   usage_die "--doctor is now --check-adapter (try --help)." ;;
    --compat)   usage_die "--compat is now --check-server (try --help)." ;;
    --show-qr)  usage_die "--show-qr is now --show-code (try --help)." ;;
    --openclaw|--hermes)
      usage_die "$arg is gone — run --setup and pick your gateway from the list (try --help)." ;;
    -*) usage_die "Unknown argument: $arg (try --help)" ;;
    *)  if [ -z "$CHECK_URL" ]; then CHECK_URL="$arg"
        else usage_die "Unknown argument: $arg (try --help)"; fi ;;
  esac
done

if [ -z "$COMMAND" ]; then
  if [ "$CLI_ARG_COUNT" = "0" ]; then
    COMMAND="menu"
  else
    usage_die "Choose an action: --setup, --check-server, --check-adapter, --show-code, --list, --edit or --forget (try --help)."
  fi
fi

# There is ONE positional slot, and which command reads it decides what it means:
# an address to grade for --check-server/--check-adapter, the id of a saved setup
# for --edit/--forget. Captured here, once, before any action runs — the same
# discipline as the CLI_ captures below, and for the same reason: validate_cli
# hands it to BOTH $CHECK_URL and $MANAGE_ID on every pass through the hub, so it
# has to be a value argv owns rather than one an earlier action may have rewritten.
CLI_POSITIONAL="$CHECK_URL"

# Is this a real person at a terminal? Checks use this to offer setup after a
# PASS. A CI job or redirected/piped invocation must always print its summary
# and exit without waiting for an answer.
interactive_terminal() {
  case "${CI:-}" in 1|true|TRUE|yes|YES) return 1 ;; esac
  [ -t 0 ] && [ -t 1 ]
}

# True only when a profile this version can actually use exists. The validator
# is defined in the --show-code module and shared with its picker/loader, so the
# menu can never advertise an entry those paths would reject moments later.
#
# A profile FILE that exists and does NOT validate is a third state, and it has to
# be carried out of here rather than folded into "no profile": the two lead to
# opposite advice. "Run setup once" rewrites profile-<id>.json, so offering it for
# a file a NEWER conduck-connect wrote is how an older script destroys recoverable
# state. The count and the validator's own first reason travel back with the
# answer — the validator is the only place that knows whether the file is corrupt
# (setup IS the fix) or from the future (updating this script is).
SAVED_PROFILE_REJECTED=0
SAVED_PROFILE_REJECT_REASON=""
saved_profile_exists() {
  local p
  SAVED_PROFILE_REJECTED=0
  SAVED_PROFILE_REJECT_REASON=""
  for p in "$STATE_DIR"/profile-*.json; do
    [ -f "$p" ] || continue
    if show_qr_validate_profile "$p"; then
      # A usable profile answers the question; the rejections behind it are the
      # picker's business, not the menu's.
      SAVED_PROFILE_REJECTED=0
      SAVED_PROFILE_REJECT_REASON=""
      return 0
    fi
    SAVED_PROFILE_REJECTED=$((SAVED_PROFILE_REJECTED+1))
    [ -n "$SAVED_PROFILE_REJECT_REASON" ] || SAVED_PROFILE_REJECT_REASON="$PROFILE_VALIDATION_ERROR"
  done
  return 1
}

# Which entry each menu number dispatches to, filled in by choose_main_action as it
# draws the list. It is a global only because the numbering is computed: the answer
# comes back as "5", and nothing else in the process knows what 5 was.
MENU_ACTIONS=()

choose_main_action() {
  # Evaluated ONCE: the answers decide four lines below them, and each validation
  # pass re-parses every profile on disk.
  local have_saved=false have_setups=false p
  saved_profile_exists && have_saved=true
  # A DIFFERENT question from the one above it, and the difference is the whole
  # reason the manage entries exist. "Show a saved setup code" has to hand the app
  # a profile THIS version can parse. Looking at what is saved, re-pointing it and
  # removing it work on the files themselves — and a profile this version cannot
  # read is exactly the thing somebody wants to look at and get rid of, so gating
  # those on a successful parse would hide the options in the one state that needs
  # them most. The cheap glob is deliberate: it settles the question without
  # reading, parsing or validating anything.
  for p in "$STATE_DIR"/profile-*.json; do
    if [ -f "$p" ]; then have_setups=true; break; fi
  done
  # Reaching the menu is what makes "back to the menu" a real destination later.
  MENU_HUB=true
  say "${BOLD}conduck-connect $VERSION — pair your self-hosted AI gateway with Conduck${RESET}"
  say ""
  # The introduction lives HERE, not only behind --help, because the person who
  # most needs it is the one deciding whether to trust this at all — and they
  # have not typed a flag yet. It says the payoff (a QR code, scanned with the
  # app on a phone), the safety rule, and the way to preview the whole thing,
  # because those are the three facts that decide whether a stranger continues.
  say "  I pair a gateway you already run — OpenClaw, Hermes, or any OpenAI-compatible"
  say "  server — with the Conduck app, and finish by printing a QR code you scan with"
  say "  the app on your iPhone or iPad."
  # "No telemetry" is the strong claim and it is unqualified. "I talk only to your
  # own gateway" is NOT, and must never be said here: the Cloudflare and Tailscale
  # paths contact that vendor with the operator's own client and credentials. The
  # header's "Where its own requests go" carves that out in full; a six-line intro
  # cannot, so it says the part that is true absolutely and points at the rest
  # rather than overclaiming on the one screen a skeptic reads first.
  say "  Nothing on this machine changes without your approval, and you see the exact"
  say "  command first. No telemetry, ever — the only third-party contact is the tunnel"
  say "  tool you pick, and it asks first. Run me with --setup --dry-run to walk the"
  say "  whole thing and change nothing."
  say "  I remember what I set up in $STATE_DIR."
  # Option 4 genuinely cannot be offered for a profile this version cannot read,
  # but going quiet about it is what turns an unreadable profile into a lost one:
  # the operator reads "no saved code", picks 1, and setup overwrites the file.
  if ! $have_saved && [ "$SAVED_PROFILE_REJECTED" -gt 0 ]; then
    say ""
    if [ "$SAVED_PROFILE_REJECTED" = "1" ]; then
      warn "There IS a saved setup code on this machine, and this version can't read it — so \"Show a saved setup code\" is not on the list below."
    else
      warn "There are $SAVED_PROFILE_REJECTED saved setup codes on this machine, and this version can't read any of them — so \"Show a saved setup code\" is not on the list below."
    fi
    note "$SAVED_PROFILE_REJECT_REASON"
    note "Setting up again REPLACES the saved file, so read that line before choosing 1."
    # Which is no longer the only way to deal with it, and saying so here is the
    # point of the warning: the entries that manage what is already set up are on
    # the list below (they are offered for a file that EXISTS, parsed or not), so
    # the operator has a way out that does not overwrite anything.
    note "You don't have to set up again to deal with it — the last two options below work on"
    note "the saved files themselves, so this one can be looked at and removed instead."
  fi
  say ""
  say "  What would you like to do?"
  # The numbers are COMPUTED rather than written into the strings. Three entries
  # are conditional and they answer two different questions (see have_saved and
  # have_setups above), so any hardcoded numbering has a reachable state — an
  # unreadable profile — where the list skips one. A menu that jumps from 3 to 5
  # reads as a bug in the tool rather than as an option somebody chose not to show.
  #
  # Item 1 names the products because that is the word the user was given. Told
  # "I installed OpenClaw for you", nobody maps that onto "set up and pair a
  # gateway" — and 2 and 3 are marked as diagnostics so a first-timer does not
  # read three equal-looking options and pick the wrong one. The manage entries
  # come last because they are useless until something has been set up, and they
  # say what they DO rather than naming their flags: nobody arrives here looking
  # for "--edit", they arrive because an address stopped working.
  local n=0
  MENU_ACTIONS=()
  n=$((n+1)); MENU_ACTIONS[$n]="setup"
  say "    $n) Set up and pair a gateway (OpenClaw, Hermes, or any OpenAI-compatible"
  say "       server) — start here"
  n=$((n+1)); MENU_ACTIONS[$n]="check-server"
  say "    $n) Check a server that was NOT built for Conduck (diagnostic; changes nothing)"
  n=$((n+1)); MENU_ACTIONS[$n]="check-adapter"
  say "    $n) Check an adapter built for Conduck (diagnostic; changes nothing)"
  if $have_saved; then
    n=$((n+1)); MENU_ACTIONS[$n]="show-code"
    say "    $n) Show a saved setup code (pair another device)"
  fi
  if $have_setups; then
    n=$((n+1)); MENU_ACTIONS[$n]="list"
    say "    $n) See what this machine already has set up"
    n=$((n+1)); MENU_ACTIONS[$n]="edit"
    say "    $n) Change one of them — a new web address, a different model — or remove it"
  fi
  say "    q) Exit"
  say ""
  # The regex still admits q even though require_choice intercepts it and returns
  # 11: a menu whose accept pattern silently disagreed with the list on screen
  # would be one more thing to keep in sync for no gain.
  local choice regex="^([1-$n]|[qQ])\$" rc=0
  choice=$(require_choice "Choose an option" "$regex" "nav.main") || rc=$?
  case "$rc" in
    0) ;;
    # q at the FRONT DOOR is a completed choice, not an aborted run: the operator
    # looked at the options and picked "none". It leaves by the same quiet path as
    # option q on the list, and the process still exits 0 — a wrapper must not read
    # "I decided not to start" as "setup failed".
    11) COMMAND="exit"; return 0 ;;
    *) die "$NO_ANSWER" ;;
  esac
  case "$choice" in
    q|Q) COMMAND="exit" ;;
    *)   COMMAND="${MENU_ACTIONS[$choice]}" ;;
  esac
}

# The menu is a HUB, not a launcher: an action reached from it returns to it, so
# a wrong turn costs one action instead of the whole session. A run started by
# flag never enters this loop: there is no menu behind it to come back to.
#
# The chosen action runs in a SUBSHELL, which buys two things at once. Every
# command in this tool ends by calling `exit`, and a subshell turns that into a
# status this loop can read; and each pass starts from the globals the script was
# launched with, so a half-filled GW_* draft from an abandoned setup cannot leak
# into the next action. The EXIT traps a command installs — the exposure-undo
# backstop, the setup-lock release, the machine summary — still fire at the end of
# ITS pass, which is exactly where they belong.
#
# The subshell's protection has ONE hole, and it is the line above the subshell:
# choose_main_action and validate_cli run in the PARENT, so they are the only code
# in the tool whose writes outlive an action. Every global either of them touches
# is therefore re-derived on entry rather than left where the last pass put it —
# validate_cli states that as a contract where it is defined, because it is the one
# a new derived flag will break.
#
# 99-main.inc.sh owns the dispatch and defines dispatch_menu_command. Absent that
# function this degrades to a single pass rather than failing: a foundation module
# may not be able to break the program by landing on its own.
menu_hub_loop() {
  local rc
  while true; do
    choose_main_action
    [ "$COMMAND" = "exit" ] && return 0
    declare -F dispatch_menu_command >/dev/null 2>&1 || return 0
    validate_cli
    # The trap environment a flag-entered run is given at file scope, re-armed HERE
    # because bash resets every caught trap on entering a subshell. Without it an
    # action chosen from the menu runs with no EXIT backstop and no signal routing
    # at all, and the parent's traps cannot stand in: they fire in the PARENT, where
    # the dead child's state never existed.
    #
    # --show-code is where that is visibly lossy — it arms no trap of its own, and
    # the agent sentinel's last DELETE-and-prove pass plus the "remove this exact
    # file later" warning reach the operator through on_exit and nowhere else. The
    # checks and setup escape it only because they re-arm their own traps first, and
    # they still do: an action that wants something stronger replaces these, exactly
    # as it does at file scope.
    #
    # Guarded, for the same reason the dispatch below is: a foundation module may not
    # be able to break the program by landing before the module that defines on_exit.
    (
      if declare -F on_exit >/dev/null 2>&1; then
        trap on_exit EXIT
        trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM
      fi
      dispatch_menu_command
    ); rc=$?
    [ "$rc" = "$MENU_RETURN_STATUS" ] || exit "$rc"
    COMMAND="menu"
    say ""
  done
}

# What argv said about each modifier, captured once, before any action can change
# it. These are the restore sources for validate_cli below, and none of them can be
# spelled inline there as a constant: the setup arm sets no value at all, so a plain
# `REUSE_ONLY=false` reset would silently drop a `--setup --reuse-only` the operator
# did pass. Every flag the argument loop can set has a capture here, including the
# ones no action rewrites today — a modifier with a CLI_ twin cannot be restored to
# the wrong value, and one without a twin is a hole nobody sees until a hub session
# lands in it.
CLI_DRY_RUN=$DRY_RUN
CLI_REUSE_ONLY=$REUSE_ONLY
CLI_ALLOW_KEYLESS_PUBLIC=$ALLOW_KEYLESS_PUBLIC
CLI_DOCTOR_DEEP=$DOCTOR_DEEP
CLI_DOCTOR_FILES=$DOCTOR_FILES

# ------------------------------------------------------- the modifier table --
#
# Which modifiers a command ACCEPTS is declared per command, in one place, and
# every modifier a command does not name is refused. That direction is the design.
# The shape it replaces is a hand-written list of REJECTIONS per command, which
# defaults to ALLOW: a flag missing from one arm's list is accepted in silence and
# then honoured by code that runs much later, long after the operator could have
# been told. That has failed twice — --reuse-only surviving a check into the next
# hub action, and --edit/--forget walking a picker, a setup summary and a live probe
# before the file lane's own guard stopped the run one prompt short of the change.
#
# Default-DENY inverts the cost of forgetting. A modifier added to the argument loop
# and left out of a command's accept list is refused by that command at exit 2,
# before anything is asked. For a flag that should have been allowed that is the
# wrong answer — but it is a LOUD wrong answer, and the very first run finds it,
# which is the property the other direction can never have.
#
# The order below is the order a clash is reported when an invocation carries more
# than one, so it is fixed rather than alphabetical: the positional first, because a
# command that takes no id at all should say so before it grades the flags around
# it, then the modifiers in the order the arms have always met them.
CLI_MODIFIERS="positional dry-run reuse-only deep files allow-keyless-public json"

# Did argv set this modifier? The ONLY reader of the flag globals, so a modifier
# renamed in the argument loop breaks here rather than in seven command arms.
cli_modifier_set() { # cli_modifier_set <modifier>
  case "$1" in
    positional)           [ -n "$CHECK_URL" ] ;;
    dry-run)              $DRY_RUN ;;
    reuse-only)           $REUSE_ONLY ;;
    deep)                 $DOCTOR_DEEP ;;
    files)                $DOCTOR_FILES ;;
    allow-keyless-public) $ALLOW_KEYLESS_PUBLIC ;;
    json)                 $MANAGE_JSON ;;
    # An accept list naming a modifier the argument loop cannot set is a typo, and
    # a typo in an accept list reads as a silent permission — the exact failure this
    # table exists to end. It stops the run instead.
    *) die "Internal error: unknown CLI modifier '$1'." ;;
  esac
}

# What to say when this command cannot take it. All the wording for one modifier
# lives in one arm, because these sentences are met side by side by the same person
# trying two spellings of one idea, and each has to name why THIS command cannot
# take the flag rather than restate the flag back at them.
cli_modifier_refusal() { # cli_modifier_refusal <modifier> -> the sentence for $COMMAND
  case "$1" in
    positional)
      case "$COMMAND" in
        list) printf '%s' "--list takes no id — it lists every saved setup. Use --edit <id> or --forget <id> to act on one." ;;
        *)    printf '%s' "A URL argument only works with --check-server or --check-adapter." ;;
      esac ;;
    dry-run)
      case "$COMMAND" in
        check-server)  printf '%s' "--check-server sends live requests, so it doesn't combine with --dry-run." ;;
        check-adapter) printf '%s' "--check-adapter sends live requests, so it doesn't combine with --dry-run." ;;
        show-code)     printf '%s' "--show-code changes no configuration but performs live verification; it doesn't combine with --dry-run." ;;
        list)          printf '%s' "--list already changes nothing, so it doesn't combine with --dry-run." ;;
        edit)          printf '%s' "--edit asks before every change and shows you each one, so it doesn't combine with --dry-run." ;;
        forget)        printf '%s' "--forget names everything it will remove and asks you to type the id before it removes any of it; it doesn't combine with --dry-run." ;;
        *)             printf '%s' "--dry-run is a setup modifier; it only works with --setup." ;;
      esac ;;
    reuse-only)
      case "$COMMAND" in
        check-server)  printf '%s' "--reuse-only is a setup modifier; --check-server already changes no host configuration." ;;
        check-adapter) printf '%s' "--reuse-only is a setup modifier; --check-adapter already changes no host configuration unless --files is requested." ;;
        show-code)     printf '%s' "--reuse-only is a setup modifier; --show-code already changes no host configuration." ;;
        list)          printf '%s' "--reuse-only is a setup modifier; --list only reports what is already saved." ;;
        # The two that change things get the fuller sentence, because refusing the
        # flag here looks backwards until you read why: --reuse-only cannot make
        # these safer, it can only make them refuse, at the end, the one change the
        # command was named for.
        edit)          printf '%s' "--reuse-only is a setup modifier, and --edit exists to change one saved setup: a mode that forbids changes would walk you through the questions and then refuse the edit you asked for." ;;
        forget)        printf '%s' "--reuse-only is a setup modifier, and --forget exists to remove one saved setup: a mode that forbids changes would list everything it will remove and then refuse the removal you asked for." ;;
        *)             printf '%s' "--reuse-only is a setup modifier." ;;
      esac ;;
    deep)
      case "$COMMAND" in
        check-server) printf '%s' "--deep only works with --check-adapter; --check-server already reports image capability." ;;
        *)            printf '%s' "--deep only works with --check-adapter." ;;
      esac ;;
    files) printf '%s' "--files only works with --check-adapter." ;;
    allow-keyless-public)
      case "$COMMAND" in
        check-server)  printf '%s' "--allow-keyless-public is a setup modifier; --check-server never publishes anything." ;;
        check-adapter) printf '%s' "--allow-keyless-public is a setup modifier; --check-adapter never publishes anything." ;;
        list)          printf '%s' "--allow-keyless-public is a setup modifier; --list publishes nothing." ;;
        *)             printf '%s' "--allow-keyless-public is a setup modifier." ;;
      esac ;;
    json)
      case "$COMMAND" in
        check-server|check-adapter) printf '%s' "--json only works with --list; a check ends in its own machine summary line." ;;
        *)                          printf '%s' "--json only works with --list." ;;
      esac ;;
  esac
}

# Refuse every modifier this command did not name. One call per arm, and it is the
# only thing standing between argv and an action that would carry a flag it has no
# meaning for all the way to the code that reads it.
cli_accept_only() { # cli_accept_only [modifier…]
  local m accepted=" $* "
  for m in $CLI_MODIFIERS; do
    case "$accepted" in *" $m "*) continue ;; esac
    cli_modifier_set "$m" || continue
    usage_die "$(cli_modifier_refusal "$m")"
  done
}

# validate_cli is a PURE FUNCTION of argv and $COMMAND, and that is a contract, not
# an observation: menu_hub_loop calls it in the PARENT shell once per action, so any
# global it writes and does not re-derive is carried into every later action of the
# session. The action itself runs in a subshell and cannot leak — this function is
# the one place at the hub that can.
#
# So every global it writes is reset from its argv value on entry, ALL of them
# together in the block below, and a new derived flag belongs in that block the day
# it is added. Two ways the omission bites, both silent to the operator who caused
# it: a check leaves REUSE_ONLY true, so the next "set up and pair" at the menu runs
# a reuse-only setup that refuses every change it was chosen to make; and the check
# arms' own `--reuse-only is a setup modifier` guard then reads that leftover as a
# flag on the command line and kills the whole session at exit 2 — from the parent
# shell, so the hub cannot even redraw.
#
# Nothing there may be reset to a hardcoded constant for the same reason the CLI_
# captures exist: the reset restores what the operator TYPED, and only the three
# derived-from-$COMMAND flags — DOCTOR, COMPAT, SHOW_QR — have no argv spelling of
# their own and so can be reset to false.
#
# The arms themselves are one `cli_accept_only` call each, naming what the command
# takes. Together the two halves are the whole contract: the reset block decides
# what argv means on this pass, the accept list decides what the command will carry
# out of here. Read down the accept lists and they say exactly what `--help` says
# one screen up — "--dry-run: With --setup", "--json: With --list" — which is the
# point. Those sentences are the promise; before this shape they were a promise
# four commands quietly broke.
validate_cli() {
  DOCTOR=false; COMPAT=false; SHOW_QR=false
  DRY_RUN=$CLI_DRY_RUN; REUSE_ONLY=$CLI_REUSE_ONLY
  DOCTOR_DEEP=$CLI_DOCTOR_DEEP; DOCTOR_FILES=$CLI_DOCTOR_FILES
  ALLOW_KEYLESS_PUBLIC=$CLI_ALLOW_KEYLESS_PUBLIC
  # The manage module's two inputs, handed over from what argv said. This is also
  # the line that keeps the menu path and the flag path honest about them: a
  # menu-entered --edit has no id on the command line, so it gets the empty string
  # here and asks which saved setup the operator means — the same code path as
  # `--edit` with no argument, rather than a second one that guesses.
  MANAGE_JSON=$CLI_MANAGE_JSON
  # One positional slot, restored to both names that read it: the checks call it a
  # URL, the manage commands call it an id, and neither may inherit what the other
  # left behind on an earlier pass through the hub.
  CHECK_URL=$CLI_POSITIONAL; MANAGE_ID=$CLI_POSITIONAL
  case "$COMMAND" in
    setup)
      cli_accept_only dry-run reuse-only allow-keyless-public
      ;;
    check-server)
      COMPAT=true
      # Ahead of the accept list on purpose: an address this command cannot grade is
      # the more useful thing to say first when the invocation is wrong in two ways.
      if [ -n "$CHECK_URL" ] && ! doctor_accept_url "$CHECK_URL" >/dev/null; then
        # The userinfo case gets its own message, and deliberately does NOT echo
        # the URL back: the rejected value contains the password.
        url_has_userinfo "$CHECK_URL" && usage_die "$URL_USERINFO_HINT"
        usage_die "Can't test '$CHECK_URL' — use https://… (or http:// toward an address on your own network for a local test)."
      fi
      cli_accept_only positional
      REUSE_ONLY=true
      ;;
    check-adapter)
      DOCTOR=true
      if [ -n "$CHECK_URL" ] && ! doctor_accept_url "$CHECK_URL" >/dev/null; then
        # The userinfo case gets its own message, and deliberately does NOT echo
        # the URL back: the rejected value contains the password.
        url_has_userinfo "$CHECK_URL" && usage_die "$URL_USERINFO_HINT"
        usage_die "Can't test '$CHECK_URL' — use https://… (or http:// toward an address on your own network for a local test)."
      fi
      cli_accept_only positional deep files
      REUSE_ONLY=true
      ;;
    show-code)
      SHOW_QR=true
      cli_accept_only
      REUSE_ONLY=true
      ;;
    # The three manage commands. --list is the scriptable one and is a pure read:
    # it takes no id (it shows every setup, which is how you find an id), and it is
    # marked reuse-only so that any shared step it reaches can only report, never
    # reconfigure. --edit and --forget are the two that change things, so neither
    # is marked reuse-only — a flag that made the edit screen refuse the edit it
    # was chosen to make would be a trap, not a safety belt, which is also why both
    # accept lists leave --reuse-only out and let it be refused up front.
    list)
      cli_accept_only json
      REUSE_ONLY=true
      ;;
    edit)
      cli_accept_only positional
      ;;
    forget)
      # The one required argument in the whole CLI. Removal is irreversible, so
      # there is no "pick one for me" fallback on the flag path: a wrapper that
      # meant a different setup would get a picker it cannot answer, and a person
      # who has forgotten the id is one command away from seeing all of them.
      [ -n "$MANAGE_ID" ] || usage_die "--forget needs the id of the setup to remove: --forget <id>. Run --list to see the ids."
      cli_accept_only positional
      ;;
    exit) ;;
    *) die "Internal error: unknown action '$COMMAND'." ;;
  esac
}

# PLAN[] accumulates human-readable "would do" lines for --dry-run.
PLAN=()
plan_add() { PLAN+=("$*"); }

# Explain one bounded prompt without changing its answer. Most callers pass an
# action id that the explanation catalogue resolves; the few older/specialised
# menus pass their existing help function instead. Keeping this indirection here
# makes the prompt primitives usable in isolated tests and in partial-source
# harnesses too: when the catalogue is not loaded, `i` still gives an honest
# generic explanation rather than failing.
explain_prompt() { # explain_prompt [action-id | help-function]
  local help="${1:-}"
  case "$help" in
    ''|*[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_]*) ;;
    *) if declare -F "$help" >/dev/null 2>&1; then "$help"; return 0; fi ;;
  esac
  if declare -F explain_action >/dev/null 2>&1; then
    explain_action "${help:-general}"
    return 0
  fi
  say ""
  say "  ${BOLD}About this step${RESET}"
  say "  This question controls the action described immediately above it."
  say "  Answering No or skipping leaves that action undone; it does not undo"
  say "  anything you approved earlier in this run."
  say ""
}

# Is the command this run is executing one that cannot have changed anything?
#
# The three read-only commands — --check-server, --check-adapter and --show-code —
# reach every prompt primitive the wizard does, so they reach quit_run too, and the
# wizard's "here is what stays in place" wording is a false alarm in every word of it
# there. Telling somebody who stopped a DIAGNOSTIC that their run may have left
# config edits, restarts and services behind sends them hunting through a machine
# nothing touched, in the one message whose whole job is to leave them correctly
# informed.
#
# The FLAGS are the authority, never $COMMAND, and the difference is load-bearing:
# a passing check that hands off into setup clears all three in
# finish_successful_check, at exactly the moment the wizard wording becomes the true
# one. The same q, one screen later in the same process, then has genuinely approved
# changes behind it and must say so.
#
# It answers NO on anything it cannot prove, which is why each flag is compared as
# a string with an explicit default instead of run as `$DOCTOR || $COMPAT || …`.
# quit_run is the most-lifted function in the test suites — three harnesses stub it
# and one extracts it — and a bare `$DOCTOR` in a harness that did not carry the
# flag expands to an EMPTY command, which bash scores 0. That reads as "nothing
# changed" for a run that may have changed plenty, and it is the one wrong answer
# this predicate must never give.
run_changes_nothing() {
  [ "${DOCTOR:-false}" = "true" ] && return 0
  [ "${COMPAT:-false}" = "true" ] && return 0
  [ "${SHOW_QR:-false}" = "true" ] && return 0
  return 1
}

# Stop cleanly; EXIT traps still report any exposure undo commands.
#
# The status is 3, not 0. A wrapper — a CI job, an agent driver, the Conduck app's
# own launcher — has no other way to tell "the operator stopped this halfway" from
# "the gateway is paired", and reading an abandoned setup as a success is the
# expensive direction of that mistake. Choosing q at the WELCOME MENU is not this:
# that is a completed choice and leaves by choose_main_action's exit arm at 0.
#
# It is also the last screen of an interrupted run, so it is the right place to
# say the one thing the header promises and no user is ever told: coming back
# costs nothing, because every step detects what is already done.
quit_run() {
  local reply
  say ""
  if run_changes_nothing; then
    note "Stopped here. Nothing was changed — this command edits no configuration, starts"
    note "or stops no service, and publishes nothing."
    # The one exception, and it is the operator's own shared folder rather than any
    # configuration: --files writes probe files. It is named here because the removal
    # runs from an EXIT trap that fires AFTER this screen (doctor_on_exit →
    # doctor_files_cleanup_backstop), and the sentence is written to stay true whether
    # or not that trap finds anything left to report. Compared as a string with a
    # default for the same harness reason run_changes_nothing is.
    if [ "${DOCTOR_FILES:-false}" = "true" ]; then
      note "--files writes small conduck-check-* probe files to your shared folder and removes"
      note "them again; if this run stopped between the two, their names are printed below."
    fi
    note "Re-run it any time; it saves nothing between runs, so it simply starts over."
  else
    note "Stopped here. No further setup actions will run."
    note "This does not undo changes you already approved: config edits, restarts,"
    note "services, folders, and commands stay in place."
    note "If this run applied a tracked Tailscale exposure, its exact undo commands"
    note "are printed below and kept for the next run. A Cloudflare or reverse-proxy"
    note "command you ran remains yours to undo."
    note "Re-run me any time; every step detects what's already done and reuses it."
  fi
  # Offered only to a run that CAME from the menu — see MENU_HUB. The default is
  # still to stop: somebody who typed q wants out, and making them type it twice
  # would be a worse trade than one extra line for the person who mis-stepped.
  if [ "${MENU_HUB:-false}" = "true" ] && interactive_terminal; then
    say ""
    while true; do
      read -r -p "  Enter = stop; m = back to the menu: " reply || break
      case "$reply" in
        '') break ;;
        [mM]) exit "${MENU_RETURN_STATUS:-20}" ;;
        *) warn "Press Enter to stop, or m to go back to the menu." ;;
      esac
    done
  fi
  exit 3
}

# Did a REJECTED answer look like a pasted credential rather than a typed one?
# Shape only — length and character mix. It never tests for a known token prefix
# and never stores, returns or echoes the value: the whole point is that the
# string must not travel one step further than the terminal that already showed
# it.
#
# Deliberately loose. A false positive costs three lines of advice; a false
# negative leaves a live token in someone's scroll-back. It misses long
# all-lowercase passphrases, anything under 16 characters, and anything
# containing a space, and it fires on long hyphenated model ids — all acceptable
# at prompts whose real answers are y, n, a small number, a URL, or Enter.
# bash 3.2 only: `case` globs and ${#s}; no [[ =~ ]], no ${s,,}.
looks_like_a_secret() { # looks_like_a_secret <answer>
  local s="$1" lower
  [ "${#s}" -ge 16 ] || return 1
  # Lowercase BEFORE the scheme test, or HTTPS://Example1.com survives it and
  # then trips the digit rule below.
  lower=$(printf '%s' "$s" | tr '[:upper:]' '[:lower:]')
  case "$lower" in http://*|https://*) return 1 ;; esac   # an address is not a secret
  case "$s" in *[[:space:]]*) return 1 ;; esac             # a sentence is not a paste
  case "$s" in *[0-9]*) return 0 ;; esac
  case "$s" in *[ABCDEFGHIJKLMNOPQRSTUVWXYZ]*) case "$s" in *[abcdefghijklmnopqrstuvwxyz]*) return 0 ;; esac ;; esac
  return 1
}

# Said once, by the prompt that just refused a credential-shaped answer. It must
# never print the value back: the defect being reported is ONE copy of the token
# on screen, and repeating it for clarity would make two. Everything goes to
# stderr, so the prompts whose callers capture them with $() stay clean.
#
# The middle line turns on whether input is a terminal. Under a pipe `read` does
# not echo, so "it is on your screen" would be false — and a warning that states
# something the operator can see is untrue is how they learn to skip the next one.
warn_answer_looked_like_a_secret() {
  warn "That looked like a key or password, and this question is not where one goes." >&2
  if [ -t 0 ]; then
    warn "It was shown as you typed it, so it is in this terminal's scroll-back." >&2
  else
    warn "Assume this session may have recorded it." >&2
  fi
  warn "If it was real, rotate it. A key or password is only ever asked for at a hidden prompt —" >&2
  warn "one that shows nothing at all while you type." >&2
}

# ------------------------------------------------------- the prompt contract --
#
# EVERY prompt in this tool offers the same controls, and every prompt shows the
# ones it actually honours. The rule that keeps those two facts in sync: a key is
# a control at a prompt IF AND ONLY IF that prompt's own suffix advertises it.
# The suffix is rendered from the same parameters that decide the behaviour
# (control_suffix below), so the two cannot drift.
#
#   i  explain this question, then ask it again
#   b  go back — offered only where the caller can actually honour it
#   q  stop the run
#
# The five value primitives (ask, ask_default, ask_secret, ask_url,
# require_choice) are all captured by their callers with $(…), and that one fact
# shapes the whole contract. The ANSWER has to travel on stdout, so the INTENT
# travels on the exit status — a sentinel string on stdout cannot work, because a
# user's real answer could legitimately be the single letter "q". And `q` cannot
# stop the run from inside the primitive either: a die or an exit inside $(…)
# kills the subshell only, and the wizard walks on with an empty answer.
#
#   rc 0   the value is on stdout
#   rc 10  the user pressed b   (only reachable when the caller passed allow-back)
#   rc 11  the user pressed q   → the CALLER must call quit_run
#   rc 1   EOF / no answer      → the caller dies with "$NO_ANSWER"
#
# prompt_into (below) is the one-line caller side of all four cases. confirm and
# print_and_wait are NOT captured, so they keep acting on q themselves.

# read -r -p writes its prompt only when stdin is a terminal. Left to `read`
# alone, every prompt in this tool is therefore invisible under a pipe, a here-doc
# or an agent driver — the transcript shows a menu and then nothing, and the
# machine on the other end cannot tell which question it is answering. Re-emit it
# on stderr in exactly that case. With a newline, because nothing echoes the
# answer back there and the next line of output would otherwise be glued to the
# question.
prompt_echo() { # prompt_echo <prompt-text>
  [ -t 0 ] || printf '%s\n' "$1" >&2
}

control_keys() { # control_keys [allow-back] -> "i = explain[; b = back]; q = stop"
  case "${1:-false}" in
    true|1|yes) printf 'i = explain; b = back; q = stop' ;;
    *)          printf 'i = explain; q = stop' ;;
  esac
}

control_suffix() { # control_suffix <what-Enter-does> [allow-back]
  printf 'Enter = %s; %s' "$1" "$(control_keys "${2:-false}")"
}

# A control key typed at a FREE-TEXT prompt is genuinely ambiguous: "q" is both
# the stop key and a string somebody could want as a gateway name. Both silent
# readings lose something real. Read as data, "q" names the gateway and mints the
# permanent id `custom-q` — the id the systemd unit, the rclone credential and the
# saved profile are all filed under, discovered long after the keystroke. Read as
# a control, a legitimate answer disappears. So ask, once, with the CONTROL as the
# Enter default: the overwhelmingly common reading costs no keystroke, and the
# rare literal one costs a single "y".
#
# It reads y/n itself rather than calling confirm, because confirm honours i/b/q
# too and would feed this question straight back into the ambiguity it exists to
# resolve. Everything is on stderr: every caller is inside $(…).
prompt_wants_literal() { # prompt_wants_literal <key> <what-the-control-does> -> 0 literal / 1 control / 2 no answer
  local p reply
  p="  Use \"$1\" as your answer instead of $2? [y/N] "
  while true; do
    prompt_echo "$p"
    read -r -p "$p" reply || return 2
    case "$reply" in
      [yY]|[yY][eE][sS]) return 0 ;;
      ''|[nN]|[nN][oO])  return 1 ;;
      *) warn "Please answer y or n; Enter means no." >&2 ;;
    esac
  done
}

# The control decision for one reply at a free-text value prompt, shared by ask
# and ask_default. Returns 0 = treat the reply as data, 2 = an explanation was
# shown, ask again, and otherwise the prompt contract's own statuses.
value_prompt_control() { # value_prompt_control <reply> [action-id] [allow-back]
  local reply="$1" action="${2:-}" allow_back="${3:-false}"
  case "$reply" in
    [iI])
      prompt_wants_literal "$reply" "showing an explanation"
      case $? in 0) return 0 ;; 2) return 1 ;; esac
      explain_prompt "$action" >&2
      return 2 ;;
    [qQ])
      prompt_wants_literal "$reply" "stopping the run"
      case $? in 0) return 0 ;; 2) return 1 ;; esac
      return 11 ;;
    [bB])
      # Back is not advertised here, so it is not a control here — a prompt that
      # took "b" as a control it never offered would be the same defect this
      # contract exists to prevent, pointing the other way.
      case "$allow_back" in true|1|yes) ;; *) return 0 ;; esac
      prompt_wants_literal "$reply" "going back"
      case $? in 0) return 0 ;; 2) return 1 ;; esac
      return 10 ;;
  esac
  return 0
}

# The caller side of the contract, in one line per call site:
#
#   prompt_into GW_NAME ask "  A short name for it" "My gateway" "" "gateway.custom.name"
#   prompt_into GW_URL ask_url "Its address" "https://ai.example.com" 0 "" "id" true || return 10
#
# It returns 0 with the answer in the named variable, or 10 when the user went
# back — and 10 is only reachable if this call passed allow-back, so a call site
# that never offers Back can ignore the failure branch entirely. It deliberately
# does NOT return for q or for a closed stdin: acting on those is the whole reason
# it exists, and it can only be done here, in the parent shell, outside the $(…)
# the primitive ran in.
prompt_into() { # prompt_into <variable> <primitive> [primitive args…]
  local __var="$1" __value __rc=0
  shift
  __value=$("$@") || __rc=$?
  case "$__rc" in
    0)  printf -v "$__var" '%s' "$__value"; return 0 ;;
    10) return 10 ;;
    11) quit_run ;;
    *)  die "$NO_ANSWER" ;;
  esac
}

confirm() {  # confirm "question" [action-id] [allow-back] -> 0 yes / 1 no / 10 back
  local reply action="${2:-general}" allow_back="${3:-false}" p question
  p="$1 [y/N] ($(control_suffix "No" "$allow_back")): "
  # Most call sites indent their question for the screen; the EOF line below
  # quotes it mid-sentence, where that indent would read as a typo.
  question="${1#"${1%%[![:space:]]*}"}"
  while true; do
    prompt_echo "$p"
    if ! read -r -p "$p" reply; then
      # No is the safe reading of a closed stdin, so that is the answer — but said
      # out loud. Silently, it is indistinguishable from a deliberate No, and a
      # truncated pipe then declines every gate in the run without a word. Naming
      # the question is what makes the transcript diagnosable afterwards: a "No"
      # attributed to the wrong step is guesswork three screens later.
      warn "No answer — treating this as No: $question"
      return 1
    fi
    case "$reply" in
      [yY]|[yY][eE][sS]) return 0 ;;
      ''|[nN]|[nN][oO]) return 1 ;;
      [iI]|\?) explain_prompt "$action" ;;
      [qQ]) quit_run ;;
      [bB])
        case "$allow_back" in true|1|yes) return 10 ;; esac
        warn "Back is not available at this step; choose Yes, No, info, or stop."
        ;;
      *) if looks_like_a_secret "$reply"; then warn_answer_looked_like_a_secret; fi
         warn "Please answer y or n, press Enter for No, i for an explanation, or q to stop." ;;
    esac
  done
}

# Free-text value prompt. Captured with $(…), so every human-facing line goes to
# stderr and the controls travel out on the exit status (see the contract above).
ask() {  # ask "prompt" "default" [blank-meaning] [action-id] [allow-back] -> answer on stdout
  local reply default="${2:-}" blank_meaning="${3:-leave blank}"
  local action="${4:-}" allow_back="${5:-false}" enter p rc
  if [ -n "$default" ]; then enter="$default"; else enter="$blank_meaning"; fi
  p="$1 ($(control_suffix "$enter" "$allow_back")): "
  while true; do
    prompt_echo "$p"
    if ! read -r -p "$p" reply; then
      ask_report_no_answer "$default" "$blank_meaning"
      printf '%s' "$default"; return 0
    fi
    value_prompt_control "$reply" "$action" "$allow_back"; rc=$?
    case "$rc" in
      0) printf '%s' "${reply:-$default}"; return 0 ;;
      2) continue ;;
      1) ask_report_no_answer "$default" "$blank_meaning"
         printf '%s' "$default"; return 0 ;;
      *) return "$rc" ;;
    esac
  done
}

# EOF at a defaulted value prompt takes the default — that is what makes a
# scripted run reproducible — but never in silence. A piped run that accepts
# $HOME/.openclaw/workspace as "the agent's working folder" with nobody in the
# room has to leave a trace that the question went unanswered; without one, the
# transcript records a decision that no person made.
ask_report_no_answer() { # ask_report_no_answer <default> <blank-meaning>
  if [ -n "$1" ]; then
    warn "No answer — using the default: $1" >&2
  else
    warn "No answer — leaving this blank ($2)." >&2
  fi
}

# Value prompt with a clear, visually-distinct default (NOT a [y/N]). Echoes the
# resolved value back so a mis-typed answer is obvious immediately.
ask_default() {  # ask_default "prompt" "default" [action-id] [allow-back] -> resolved value
  local reply default="$2" action="${3:-}" allow_back="${4:-false}" p rc
  say "  $1" >&2
  # "Press Enter to use: X" already says what Enter does, so only the keys are
  # appended here — repeating "Enter = X" on the same line would read as a second,
  # different default.
  p="  Press Enter to use: $default  (or type a value; $(control_keys "$allow_back")) > "
  while true; do
    prompt_echo "$p"
    if ! read -r -p "$p" reply; then
      ask_report_no_answer "$default" ""
      printf '%s' "$default"; return 0
    fi
    value_prompt_control "$reply" "$action" "$allow_back"; rc=$?
    case "$rc" in
      0) reply="${reply:-$default}"
         printf '  %s→ using %s%s\n' "$DIM" "$reply" "$RESET" >&2
         printf '%s' "$reply"; return 0 ;;
      2) continue ;;
      1) ask_report_no_answer "$default" ""
         printf '%s' "$default"; return 0 ;;
      *) return "$rc" ;;
    esac
  done
}

# Secret prompt — never echoes the input to the terminal.
# Returns NONZERO when the input ended (EOF) rather than when the user chose an
# empty answer. The two are not the same: a deliberate Enter is the app's explicit
# keyless scheme, while EOF means nobody was asked at all. Callers that treat an
# empty token as "keyless" MUST pair this with `|| die`, or a redirected run would
# infer no-auth from a missing answer — the fail-closed-auth invariant.
#
# `i` and `q` are read as controls here with NO "did you mean it literally?"
# question, unlike the visible value prompts. A key that is exactly one
# character is not a real key, so there is nothing to disambiguate — and the two
# failure modes are wildly asymmetric. Taking `q` as a control costs a stopped run
# the operator asked for; taking it as data costs a run that authenticates with
# the single byte "q", fails verification minutes later somewhere else entirely,
# and gives nobody a reason to suspect the keystroke that caused it. Back is not
# offered at all: a hidden prompt has no visible state to return to.
ask_secret() {  # ask_secret "prompt" "empty-meaning" [action-id] -> secret (hidden); 1 EOF, 11 stop
  local reply empty_meaning="${2:-leave empty}" action="${3:-}" p
  p="  $1 (Enter = $empty_meaning; $(control_keys false)): "
  while true; do
    prompt_echo "$p"
    if ! read -rs -p "$p" reply; then
      printf '\n' >&2
      return 1
    fi
    printf '\n' >&2
    case "$reply" in
      [iI]) explain_prompt "$action" >&2; continue ;;
      [qQ]) return 11 ;;
    esac
    printf '%s' "$reply"
    return 0
  done
}

# A choice with NO Enter-default — loops until the answer matches the regex.
# Callers capture this with $(), so EVERY human-facing line goes to stderr —
# a retry warning on stdout would be captured as part of the answer, and a typo
# would then silently decide a safety question. On EOF it RETURNS NONZERO rather
# than calling die: a `die` inside $() kills only the subshell, so the parent
# must be the one to stop (every caller pairs this with `|| die`).
# Optional 3rd arg names an action id or help function: answering `i` (or the
# older `?` alias) prints it and re-asks. `q` is always recognised, even when the
# caller's own regex does not list it, and leaves on rc 11 for the parent to act
# on — the same status every other captured primitive uses.
# Help is ADDITIVE only — it explains the same options in plain words, never
# changes them (the canonical menu/prompt strings stay the single source).
# The help function's stdout is redirected to stderr here, same $()-capture rule.
#
# allow_back makes the PRIMITIVE render `b = back` and own the refusal wording,
# so the one prompt where Back genuinely works cannot be the one whose control
# list denies it. When it is off, `b` falls through to the caller's own regex, so
# a menu whose pattern already admits it still honours it — the suffix never
# claims a control this prompt would refuse, and never hides one it would accept.
#
# The Enter clause says what Enter DOES. "No default" would describe the
# implementation — that no default value is bound here — in the one place the
# reader is looking for an answer to "what happens if I press Enter?", and this is
# the very first prompt the tool ever shows.
require_choice() {  # require_choice "prompt" "regex" [action-id | help-fn] [allow-back] -> choice
  local reply action="${3:-general}" allow_back="${4:-false}" p
  p="  $1 ($(control_suffix "ask again" "$allow_back")): "
  while true; do
    prompt_echo "$p"
    read -r -p "$p" reply \
      || return 1     # closed stdin — never spin the loop
    case "$reply" in
      [iI]|\?) explain_prompt "$action" >&2; continue ;;
      [qQ]) return 11 ;;
      [bB]) case "$allow_back" in true|1|yes) return 10 ;; esac ;;
      # Enter is now an advertised no-op, so it re-asks without being told off;
      # the reminder is a note rather than a warning because pressing Enter at a
      # question with no default is not a mistake, it is a pause.
      '') note "Nothing chosen — the options are above." >&2; continue ;;
    esac
    if [[ "$reply" =~ $2 ]]; then printf '%s' "$reply"; return 0; fi
    case "$reply" in
      [bB]) warn "Back is not available at this step; choose one of the options above, i for an explanation, or q to stop." >&2
            continue ;;
    esac
    if looks_like_a_secret "$reply"; then warn_answer_looked_like_a_secret; fi
    warn "Please enter one of the listed options." >&2
  done
}

NO_ANSWER="No answer (the input ended). Run me from a terminal, where I can ask you questions."

# A URL prompt that NEVER aborts on a typo — loops until it gets an address this
# tool will pair (or blank, when allow_blank=1, where leaving it out is a valid
# choice). Trims whitespace, accepts a capitalised scheme, always shows an example.
# All human output goes to stderr so $(...) captures only the URL.
#
# What it accepts is the app's own admissibility rule, applied here so the wizard
# cannot mint a setup code the app then refuses: any https:// address, or a plain
# http:// one whose host only the local network can reach (url_is_local_host). The
# advertised shape stays https — the prompt, the example and the footer all name it,
# and plain http is taken when it is TYPED and never suggested, defaulted to, or
# supplied by prepending a scheme to a schemeless answer.
#
# The controls are checked BEFORE any trimming or validation, and with no
# "did you mean it literally?" question: nothing that fails that test can
# be a legal answer here, so `i`, `b` and `q` are unambiguous. Without them the
# loop has no exit at all, and that matters more here than anywhere else — both
# mandatory call sites sit immediately after a commitment the user may have made
# wrongly, and Ctrl-C, the only remaining way out, throws away every answer given
# so far, because nothing is saved until pairing.
ask_url() {  # ask_url "prompt" "example" [allow_blank] [blank-meaning] [action-id] [allow-back] -> URL or ""
  local prompt="$1" example="$2" allow_blank="${3:-0}"
  local blank_meaning="${4:-skip}" action="${5:-}" allow_back="${6:-false}"
  local reply enter p hostport
  say "  $prompt" >&2
  if [ "$allow_blank" = "1" ]; then enter="$blank_meaning"; else enter="ask again"; fi
  p="  https URL (e.g. $example; $(control_suffix "$enter" "$allow_back")) > "
  while true; do
    prompt_echo "$p"
    read -r -p "$p" reply || return 1
    case "$reply" in
      [iI]) explain_prompt "$action" >&2; continue ;;
      [qQ]) return 11 ;;
      [bB])
        case "$allow_back" in true|1|yes) return 10 ;; esac
        warn "Back is not available at this step; type an https:// URL, i for an explanation, or q to stop." >&2
        continue ;;
    esac
    reply="${reply#"${reply%%[![:space:]]*}"}"; reply="${reply%"${reply##*[![:space:]]}"}"
    while [ "${reply%/}" != "$reply" ]; do reply="${reply%/}"; done   # trailing / would make //v1/… requests
    if [ -z "$reply" ]; then
      [ "$allow_blank" = "1" ] && return 0
      warn "Please enter an https:// URL, for example $example." >&2; continue
    fi
    case "$reply" in
      [Hh][Tt][Tt][Pp][Ss]://*) reply="https://${reply#*://}" ;;
      [Hh][Tt][Tt][Pp]://*)     reply="http://${reply#*://}" ;;
    esac
    # Userinfo is refused on BOTH schemes, and BEFORE the scheme is graded, because
    # http://192.168.1.10@evil.example is a remote host wearing a private address as
    # a username — the private-looking half is the bait, so the credential has to be
    # named first or the local arm below would answer about the wrong host.
    if url_has_userinfo "$reply"; then
      warn "$URL_USERINFO_HINT" >&2; continue
    fi
    case "$reply" in
      https://?*) printf '  %s→ using %s%s\n' "$DIM" "$reply" "$RESET" >&2; printf '%s' "$reply"; return 0 ;;
      http://?*)
        # The authority ends at the first / ? or #, the same cut url_has_userinfo
        # makes, so a path or a query cannot smuggle a host past the classifier.
        hostport="${reply#http://}"; hostport="${hostport%%[/?#]*}"
        if url_is_local_host "$hostport"; then
          warn "$URL_PLAIN_HTTP_WARNING" >&2
          printf '  %s→ using %s%s\n' "$DIM" "$reply" "$RESET" >&2; printf '%s' "$reply"; return 0
        fi
        warn "$URL_PLAIN_HTTP_HINT" >&2 ;;
      *)          if looks_like_a_secret "$reply"; then warn_answer_looked_like_a_secret; fi
                  # A schemeless answer keeps its https refusal and is never given a
                  # scheme here. Prepending http:// to a bare host is how plain http
                  # becomes the default nobody chose.
                  warn "That has to start with https:// — for example $example. Try again." >&2 ;;
    esac
  done
}

# Rung 1 of the consent ladder: a single command we run for you, with consent.
# In --dry-run it is only recorded; in --reuse-only it is refused (see mutate_guard).
# Action ids affect explanation copy only; the command, mutation guard and
# consent result are otherwise unchanged.
run_step() {  # run_step "action-id" "description" cmd args...
  local action="$1" desc="$2"; shift 2
  if $DRY_RUN; then plan_add "RUN  $*"; note "(dry-run: would run — $desc)"; return 0; fi
  mutate_guard "$desc" || return 1
  say ""
  say "  I'd like to run:  ${BOLD}$*${RESET}"
  if confirm "  Run it now?" "$action"; then "$@"; else
    warn "Skipped: $desc"
    return 1
  fi
}

file_mode_is_open() { # file_mode_is_open <file> [octal mask, default 077] -> 0 when a mask bit is set
  # python3 is a hard preflight requirement on every path that calls this; a
  # missing one answers "not open" and stays quiet rather than warning blindly.
  # The mask is a parameter because "another account can READ this" and "another
  # account can REPLACE this" are different harms that need different words: 077
  # is any access at all, 022 is group/other WRITE.
  python3 -c 'import os,sys; sys.exit(0 if os.stat(sys.argv[1]).st_mode & int(sys.argv[2], 8) else 1)' \
    "$1" "${2:-77}" 2>/dev/null
}

# Rung 1b: a file the USER owns whose MODE is too open for a secret we just helped
# put in it. A file's permissions are part of its configuration, so this goes
# through run_step like any other change to something we did not create — the
# exact command is printed and nothing happens without a yes. A silent chmod
# would break "never changes a config it didn't create without showing you the
# exact change first" even though it touches no content.
# The two NON-success arms carry as much weight as the success one: a declined or
# failed chmod leaves a live credential readable by every account on the box, and
# going quiet there would be a worse outcome than the silent chmod this gate
# replaced. So the final state is RE-READ from the file rather than inferred from
# run_step's exit code — "still exposed" is then a fact about the file, not a
# guess about why, and it is correct whether the user declined, the chmod failed,
# or something else moved the mode underneath us.
secure_owned_file_mode() { # secure_owned_file_mode <file> <what-is-inside> -> 1 if still open
  local f="$1" what="$2"
  file_mode_is_open "$f" || return 0
  warn "$f can be read by other accounts on this machine — $what is inside it."
  run_step "security.owned_file.chmod_0600" \
    "tighten $f to 0600 so only you can read $what" chmod 600 "$f" || true
  if $DRY_RUN; then return 0; fi     # run_step only recorded the plan; nothing changed yet
  if file_mode_is_open "$f"; then
    warn "$what is STILL readable by other accounts on this machine."
    warn "Fix it when you can:  chmod 600 $f"
    return 1
  fi
  ok "Tightened — only you can read $f now."
  return 0
}

# The ONE way $STATE_DIR is created. It holds fileserver-*.cred/.env and
# profile-*.json, so it is created 0700: at the ambient 0755 any other account
# on the box can list which gateways this user has paired, and the file names
# alone carry that.
#
# `mkdir -p` is a no-op on a directory that ALREADY exists, mode included, so
# creating it under `umask 077` only ever secures a first run. A $STATE_DIR that
# an earlier version, a different umask, or the user's own `mkdir` left open keeps
# that mode for good — the files inside stay 0600, but the directory holding them
# does not, and nothing ever says so. A directory we may not have created is not
# re-chmodded silently (same rule as the agent workspace), so the exposure is
# REPORTED, once per run, with the exact fix.
#
# Group/other WRITE is graded apart from read, because the read wording badly
# understates it. 0600 on fileserver-<id>.cred protects what is INSIDE the file;
# in a writable directory any local account can replace the whole file, and
# rclone then reads its password out of somebody else's copy at the next start.
# Same for profile-<id>.json, which is the record --show-code rebuilds a pairing
# code from.
STATE_DIR_EXPOSURE_REPORTED=false
ensure_state_dir() {  # -> 1 when the directory does not exist and could not be created
  ( umask 077; mkdir -p "$STATE_DIR" ) 2>/dev/null || return 1
  $STATE_DIR_EXPOSURE_REPORTED && return 0
  file_mode_is_open "$STATE_DIR" || return 0
  STATE_DIR_EXPOSURE_REPORTED=true
  if file_mode_is_open "$STATE_DIR" 22; then
    warn "$STATE_DIR is WRITABLE by other accounts on this machine (it already existed with that mode)."
    warn "Any local account can swap the files in it — including the file-server password rclone reads when it starts, and the saved profile that says where your gateway is."
    warn "Their 0600 protects what is inside those files, not the folder that holds them."
  else
    warn "$STATE_DIR can be listed by other accounts on this machine (it already existed with that mode)."
    warn "The password files inside are 0600, but the folder itself names every gateway you have paired."
  fi
  warn "Fix it when you can:  chmod 700 $STATE_DIR"
  return 0
}

# ------------------------------------------------------ single-instance setup --
# Two setup runs at once are not merely racy, they are silently destructive. Both
# scan the same loopback range and settle on the SAME free port (the bind probe
# closes its socket immediately, so it reserves nothing), both write
# conduck-files-$GW_ID and fileserver-$GW_ID.cred/.env, and both finish by writing
# profile-$GW_ID.json — which is a whole-file overwrite, so a run whose lane lost
# the port race erases a live file server from the record the winner just saved.
# Sequential re-runs are idempotent by design; only the overlap breaks.
#
# `mkdir` is the gate, not `flock`: macOS ships no flock binary, and mkdir is the
# one create-or-fail primitive that is atomic on every filesystem a $HOME lands on.
#
# Nothing here ever WAITS, so there is no deadlock to have: a run either takes the
# lock, reclaims provable debris, or stops with what holds it and what to do.
#
# The lock's authority is the LIVENESS of the process named inside it, never the
# existence of the directory. That is what makes a SIGKILL, a reboot, or a power
# cut recoverable with no human in the loop — the debris names a pid that is gone,
# and the next run reclaims it. Existence-as-authority would block every future
# run for good, which is the one failure mode a lock like this must not have.
SETUP_LOCK_PATH=""       # set only while WE hold it — the release deletes this exact path
SETUP_LOCK_HELD=false

# What identifies a process beyond its number: its command line. A pid alone is
# not identity — after a reboot the same number belongs to something else, and a
# lock that outlived a kill would then read as held forever. `ps -p <pid> -o
# command=` is the one spelling Linux and macOS agree on. The stored value and the
# live one both come through THIS helper, so the bound and the control-stripping
# can never make a living holder look like a stranger.
setup_lock_proc_sig() { # setup_lock_proc_sig <pid> -> its command line (empty when the process is gone)
  local s
  s=$(ps -p "$1" -o command= 2>/dev/null | head -1) || s=""
  safe_display "$s" 200
}

# Who holds <lock-dir>, and can this run even tell? Echoes "held<TAB><what to tell
# the user>" or "stale<TAB><why it is debris>". Reads only.
setup_lock_holder_state() { # setup_lock_holder_state <lock-dir>
  local lock="$1" pid="" host="" sig="" live=""
  if [ -r "$lock/owner" ]; then
    { IFS= read -r pid; IFS= read -r host; IFS= read -r sig; } < "$lock/owner" 2>/dev/null || true
  fi
  case "$pid" in
    ''|*[!0-9]*)
      # No owner record at all. Either a run died in the sliver between creating
      # the directory and writing the record, or a run is inside that sliver right
      # now — and only age separates those. A minute is orders of magnitude longer
      # than the two statements it spans, so an older record-less lock is debris
      # while a younger one is a run that is starting.
      if [ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
        printf 'stale\t%s' "it names no process (a run was interrupted before it could record one)"
      else
        printf 'held\t%s' "another conduck-connect setup is starting on this machine"
      fi
      return 0 ;;
  esac
  if [ -n "$host" ] && [ "$host" != "$(uname -n 2>/dev/null)" ]; then
    # A $HOME on a network share is ONE lock for several machines. Process $pid
    # means nothing here, so this run may not judge it and must not steal it.
    printf 'held\t%s' "a setup on $host holds it (process $pid), and this machine cannot tell whether that run is still alive"
    return 0
  fi
  # Probe `ps` against our OWN pid first: a stripped container may have no usable
  # one, and "ps printed nothing" would otherwise read as "the holder is gone".
  # Unknowable liveness fails CLOSED — never steal a lock on a guess.
  if [ -z "$(setup_lock_proc_sig $$)" ]; then
    printf 'held\t%s' "it names process $pid, and this box has no usable 'ps' for me to check whether that run is still alive"
    return 0
  fi
  live=$(setup_lock_proc_sig "$pid")
  if [ -z "$live" ]; then
    printf 'stale\t%s' "process $pid is gone"
  elif [ "$live" != "$sig" ]; then
    printf 'stale\t%s' "process $pid belongs to another program now"
  else
    printf 'held\t%s' "another conduck-connect setup is running here (process $pid)"
  fi
}

setup_lock_acquire() {
  # No state directory means nowhere to put a lock. Don't stop the run over it —
  # it will fail soon on its own merits, with a better diagnosis than this one.
  ensure_state_dir || return 0
  local lock="$STATE_DIR/setup.lock" state kind why attempt=0
  # Bounded, because the loop's "reclaim debris and try again" arm is the only one
  # that repeats: an adversary re-creating the lock in that window must not be able
  # to spin us forever.
  while [ "$attempt" -lt 3 ]; do
    attempt=$((attempt+1))
    if mkdir "$lock" 2>/dev/null; then
      if ( umask 077; printf '%s\n%s\n%s\n' \
             "$$" "$(uname -n 2>/dev/null)" "$(setup_lock_proc_sig $$)" > "$lock/owner" ) 2>/dev/null; then
        # Ownership is CONFIRMED from the file, never inferred from mkdir having
        # succeeded: two runs that both find the same debris can both clear it, and
        # the second clear would take out the winner's fresh lock. A record naming
        # somebody else means they got it — loop, find it held, and stop saying so.
        # This narrows that window rather than closing it: doing better needs a
        # second lock to serialise the reclaim, and a second lock is one more thing
        # a SIGKILL can strand, which is the failure this whole design avoids.
        if [ "$(head -1 "$lock/owner" 2>/dev/null || true)" = "$$" ]; then
          SETUP_LOCK_PATH="$lock"; SETUP_LOCK_HELD=true
          return 0
        fi
        continue
      fi
      # A lock no later run can judge is worse than no lock: it would be reclaimed
      # by the age rule while this run is still going. Drop it and say so instead.
      rm -rf "$lock" 2>/dev/null || true
      warn "Couldn't write $lock/owner, so I can't guard against a second setup running at the same time. Don't start another one until this run finishes."
      return 0
    fi
    state=$(setup_lock_holder_state "$lock")
    kind="${state%%$'\t'*}"; why="${state#*$'\t'}"
    if [ "$kind" = "held" ]; then
      die "I won't start a second setup on this machine: $why. Two at once pick the same loopback port and the same service name, and whichever finishes second overwrites the first one's saved profile. Let that run finish (or stop it), then re-run me. If you are certain nothing else is running, remove the lock and re-run me:  rm -rf $lock"
    fi
    note "Clearing a leftover setup lock — $why."
    rm -rf "$lock" 2>/dev/null || true
  done
  die "Couldn't take the setup lock at $lock — something keeps re-creating it. Remove it and re-run me:  rm -rf $lock"
}

# Released on EVERY exit path: the caller composes this into the EXIT trap, which
# covers `die` and the plain end of the run, and HUP/INT/TERM are routed through
# `exit` so they land there too. Idempotent, and it removes ONLY the path this run
# created — a run that never took the lock must never delete the one another run
# is holding.
setup_lock_release() {
  $SETUP_LOCK_HELD || return 0
  SETUP_LOCK_HELD=false
  [ -n "$SETUP_LOCK_PATH" ] || return 0
  rm -rf "$SETUP_LOCK_PATH" 2>/dev/null || true
  SETUP_LOCK_PATH=""
}

# Rung 2: a change to something YOU own — we print the exact command, you run it.
print_and_wait() {  # print_and_wait "action-id" "why" "command shown to user"
  local action="$1" why="$2" command="$3"
  if $DRY_RUN; then plan_add "YOU RUN  $command  ($why)"; note "(dry-run: you would run the above)"; return 0; fi
  mutate_guard "$why"
  say ""
  say "  This touches something you own, so you run it (copy-paste, e.g. in a"
  say "  second terminal):"
  say ""
  printf '    %s%s%s\n' "$BOLD" "$command" "$RESET"
  say ""
  note "$why"
  # Enter means NO here, exactly as it does at every confirm on screen, and the
  # match is the whole point: this prompt and a mutation gate sit six lines apart
  # in the gateway step. If Enter here asserted "yes, I already ran your command",
  # anybody in Enter-rhythm would claim to have applied a config change they never
  # applied — and the tool would diagnose the verification failure that causes as a
  # gateway fault, sending them to look in the one place the problem is not. An
  # assertion about what the user did costs a deliberate keystroke; skipping does
  # not. `s` stays an alias for skip: it is the documented key and it still fits.
  local reply p
  p="  Did you run it? [y/N] ($(control_suffix "No, skip" false)): "
  while true; do
    prompt_echo "$p"
    if ! read -r -p "$p" reply; then
      warn "No answer — treating this step as skipped."
      return 1
    fi
    case "$reply" in
      [yY]|[yY][eE][sS]) return 0 ;;
      ''|[nN]|[nN][oO]|[sS]) return 1 ;;
      [iI]|\?) explain_prompt "$action" ;;
      [qQ]) quit_run ;;
      *) if looks_like_a_secret "$reply"; then warn_answer_looked_like_a_secret; fi
         warn "Please answer y once you have run it, press Enter to skip it, i for an explanation, or q to stop." ;;
    esac
  done
}

# --reuse-only safety: refuse any mutation that isn't a pure reuse of existing state.
mutate_guard() {  # mutate_guard "what would change"
  if $REUSE_ONLY; then
    die "--reuse-only mode is on, so I won't change anything (this step would: $1). Re-run without --reuse-only when you're ready to let me apply changes to this machine."
  fi
  return 0
}

need() { command -v "$1" >/dev/null 2>&1; }
have() { command -v "$1" >/dev/null 2>&1; }

# The escalation prefix for a command that has to run as root. A hardcoded `sudo`
# is wrong in three real environments: a root shell needs no prefix at all, the
# minimal Alpine/Debian images that run as root ship no `sudo` binary (so the
# prefixed command dies with "command not found"), and OpenBSD-lineage setups
# carry `doas` instead. Empty output means "run it as root yourself" — the caller
# prints the bare command rather than inventing a dependency.
priv_prefix() { # priv_prefix -> sudo | doas | (empty)
  [ "$(id -u 2>/dev/null)" = 0 ] && return 0
  if have sudo; then printf 'sudo'
  elif have doas; then printf 'doas'
  fi
}

# The install line a Linux user can actually run. Detection is by BINARY
# (`command -v`), never by parsing `/etc/os-release`: the binary is what the
# printed command invokes, while `ID`/`ID_LIKE` lie on derivatives and on
# containers built FROM another base. The caller presents it as *detected*, not
# as "your distribution's command" — a box with two managers installed takes the
# first probe, and the wording has to leave room for that.
#
# Package NAMES are mapped wherever they diverge from the command name, because a
# confidently printed `pacman -S python3` dies with "target not found": worse than
# generic advice, since it reads as authoritative and is wrong. Arch/Manjaro have
# no `python3` package at all (their Python 3 is `python`), and Gentoo needs
# category-qualified atoms. Never map onto a library package (`openssl-libs`,
# `libssl3`) — those are routinely installed while the `openssl` CLI is missing,
# which is exactly the case that got us here. An unrecognised manager prints
# nothing, and the caller names the packages instead: honest beats wrong.
linux_install_cmd() { # linux_install_cmd <command-name>… -> "<manager>\t<command>", or empty
  local priv mgr pkgs="" body="" p
  priv=$(priv_prefix); [ -n "$priv" ] && priv="$priv "
  if   have apt-get;      then mgr="apt-get"
  elif have dnf;          then mgr="dnf"
  elif have yum;          then mgr="yum"
  elif have zypper;       then mgr="zypper"
  elif have pacman;       then mgr="pacman"
  elif have apk;          then mgr="apk"
  elif have xbps-install; then mgr="xbps-install"
  elif have emerge;       then mgr="emerge"
  else return 0
  fi
  for p in "$@"; do
    case "$mgr:$p" in
      pacman:python3) p="python" ;;
      emerge:curl)    p="net-misc/curl" ;;
      emerge:python3) p="dev-lang/python" ;;
      emerge:openssl) p="dev-libs/openssl" ;;
      emerge:rclone)  p="net-misc/rclone" ;;
    esac
    pkgs="$pkgs $p"
  done
  case "$mgr" in
    apt-get)      body="${priv}apt-get update && ${priv}apt-get install -y$pkgs" ;;
    dnf|yum)      body="${priv}$mgr install -y$pkgs" ;;
    zypper)       body="${priv}zypper --non-interactive install$pkgs" ;;
    # Arch does not support partial upgrades, so `-Sy` without `-u` is the classic
    # way to break a box — and a setup wizard has no business prescribing a full
    # system upgrade either. `-S --needed` is the non-expansive form; a stale
    # package database is the user's own `pacman -Syu` to run.
    pacman)       body="${priv}pacman -S --needed$pkgs" ;;
    # --no-cache fetches the index inline: minimal images ship without one, and a
    # bare `apk add` there fails with "unable to select packages".
    apk)          body="${priv}apk add --no-cache$pkgs" ;;
    xbps-install) body="${priv}xbps-install -Sy$pkgs" ;;
    emerge)       body="${priv}emerge --ask$pkgs" ;;
  esac
  printf '%s\t%s' "$mgr" "$body"
}

# Collect ALL missing required tools and report together, with install hints.
preflight() {
  local missing=()
  # openssl is only used by the wizard, to mint credentials and to read a
  # failing certificate's own diagnosis; the two standalone checks never reach
  # it, so don't gate a live diagnostic on a tool it doesn't use.
  local tools="curl python3"; { $DOCTOR || $COMPAT; } || tools="$tools openssl"
  for t in $tools; do need "$t" || missing+=("$t"); done
  if [ ${#missing[@]} -gt 0 ]; then
    bad "Missing required tool(s): ${missing[*]}"
    case "$(uname -s)" in
      Linux)
        # This is the last thing the user reads before the hard exit below, so it
        # has to be a command their box will accept — not Debian's.
        local hint; hint=$(linux_install_cmd "${missing[@]}")
        if [ -n "$hint" ]; then
          note "Detected ${hint%%$'\t'*} — install with:  ${hint#*$'\t'}"
          [ "$(id -u 2>/dev/null)" = 0 ] || [ -n "$(priv_prefix)" ] \
            || note "Run that as root: this shell is neither root nor has sudo/doas."
        else
          note "Install with your distribution's package manager:  ${missing[*]}"
        fi
        ;;
      Darwin) note "Install with Homebrew:     brew install ${missing[*]}" ;;
    esac
    die "Install the tool(s) above, then re-run me."
  fi
}

b64_nowrap() { # stdin -> single-line base64
  if base64 --help 2>&1 | grep -q -- '-w'; then base64 -w0; else base64 | tr -d '\n'; fi
}

# Read a value from a JSON *or* JSON5 config. Strict json.load first; on failure a
# string-aware strip of // and /* */ comments + trailing commas, then strict again
# (OpenClaw writes plain JSON, but its config format legalises JSON5). If both fail,
# fail empty (unchanged behaviour). Ops:
#   get      -> a scalar leaf value; empty for absent/null/non-scalar
#   classify -> "absent" | "ref" (an object/array or a "${…}" placeholder — an
#               indirect secret we must NOT use) | "literal\t<value>"
json_query() { # json_query <file> <op:get|classify|type> <dotted.path>  (empty output when absent)
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys

def strip_json5(s):
    # Remove // and /* */ comments, then trailing commas — but NEVER touch bytes
    # inside a "…" or '…' literal (a // inside a value must survive verbatim).
    out = []; i = 0; n = len(s); q = ''
    while i < n:
        c = s[i]
        if q:
            out.append(c)
            if c == '\\' and i + 1 < n:
                out.append(s[i+1]); i += 2; continue
            if c == q: q = ''
            i += 1; continue
        if c == '"' or c == "'":
            q = c; out.append(c); i += 1; continue
        if c == '/' and i + 1 < n and s[i+1] == '/':
            i += 2
            while i < n and s[i] != '\n': i += 1
            continue
        if c == '/' and i + 1 < n and s[i+1] == '*':
            i += 2
            while i + 1 < n and not (s[i] == '*' and s[i+1] == '/'): i += 1
            i += 2; continue
        out.append(c); i += 1
    t = ''.join(out)
    res = []; i = 0; n = len(t); q = ''
    while i < n:
        c = t[i]
        if q:
            res.append(c)
            if c == '\\' and i + 1 < n:
                res.append(t[i+1]); i += 2; continue
            if c == q: q = ''
            i += 1; continue
        if c == '"' or c == "'":
            q = c; res.append(c); i += 1; continue
        if c == ',':
            j = i + 1
            while j < n and t[j] in ' \t\r\n': j += 1
            if j < n and (t[j] == '}' or t[j] == ']'):
                i += 1; continue
        res.append(c); i += 1
    return ''.join(res)

def load(path):
    raw = open(path).read()
    try:
        return json.loads(raw)
    except Exception:
        return json.loads(strip_json5(raw))

def scalar(v):
    if v is True: return "true"
    if v is False: return "false"
    return str(v)

path, op, dotted = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    obj = load(path)
except Exception:
    if op == "classify" or op == "type": sys.stdout.write("absent")
    sys.exit(0)
cur = obj
try:
    for part in dotted.split('.'):
        cur = cur[part]
except Exception:
    if op == "classify" or op == "type": sys.stdout.write("absent")
    sys.exit(0)
if op == "type":
    if cur is None: sys.stdout.write("null")
    elif isinstance(cur, bool): sys.stdout.write("boolean")
    elif isinstance(cur, dict): sys.stdout.write("object")
    elif isinstance(cur, list): sys.stdout.write("array")
    elif isinstance(cur, str): sys.stdout.write("string")
    elif isinstance(cur, (int, float)): sys.stdout.write("number")
    else: sys.stdout.write("unknown")
    sys.exit(0)
if op == "classify":
    if isinstance(cur, (dict, list)):
        sys.stdout.write("ref")
    elif cur is None or cur == "":
        sys.stdout.write("absent")
    else:
        s = scalar(cur)
        sys.stdout.write("ref" if s.startswith("${") else "literal\t" + s)
    sys.exit(0)
if cur is True: print("true")
elif cur is False: print("false")
elif isinstance(cur, (dict, list)): pass
elif cur is not None: print(cur)
PY
}

json_get() { json_query "$1" "get" "$2"; }   # scalar leaf value (empty when absent)
json_type() { json_query "$1" "type" "$2"; } # JSON type, or "absent"

env_get() { # env_get <file> <KEY>  (last assignment wins; strips quotes)
  [ -f "$1" ] || return 0
  sed -n "s/^[[:space:]]*${2}=//p" "$1" | tail -1 | sed 's/^"\(.*\)"$/\1/' | sed "s/^'\(.*\)'$/\1/"
}

# Sanitize a free-form gateway name into a safe id token (ascii_id_ok's charset,
# no injection). LC_ALL=C is scoped to each tr and cannot reach anything else: GNU
# tr documents both ranges and multi-byte handling as non-portable, and [:upper:]
# means "uppercase per LC_CTYPE", which in a UTF-8 locale includes Ä — folding it
# to a lowercase Ä that the -cs pass would then have to strip anyway.
slug() { printf '%s' "$1" | LC_ALL=C tr "$ASCII_UPPER" "$ASCII_LOWER" | LC_ALL=C tr -cs "$ASCII_LOWER$ASCII_DIGIT" '-' | sed 's/^-*//;s/-*$//' | cut -c1-32; }

normalize_gateway_base_url() { # normalize_gateway_base_url <url> -> echoes the app-parity base URL
  # Mirror of the app's SettingsViewModel.normalizedGatewayBaseURL — keep the two
  # in lockstep (parity fixtures belong in the public repo's CI; land them there
  # at release — no CI guards this today). Users paste the
  # full endpoint their server's docs name (Ollama/LiteLLM write it as "…/v1"),
  # but the app and this script both append /v1/… themselves — a base that
  # already ends in it would 404 every request. Segment-wise on the URL PATH (a
  # host or segment that merely contains "v1" is untouched): strip exactly ONE
  # terminal /v1/chat/completions, /v1/models, or /v1 (longest first), drop
  # query+fragment, keep port and any legitimate path prefix.
  # Suffix comparison runs on percent-DECODED segments (Foundation's
  # URLComponents.path decodes, so the app recognizes an encoded "/v1" too);
  # the surviving path is emitted exactly as typed — no re-encoding surprises.
  printf '%s' "$1" | python3 -c '
import sys
from urllib.parse import urlsplit, urlunsplit, unquote
u = urlsplit(sys.stdin.read().strip())
segs = [s for s in u.path.split("/") if s]
dec = [unquote(s) for s in segs]
for suf in (["v1", "chat", "completions"], ["v1", "models"], ["v1"]):
    if len(dec) >= len(suf) and dec[-len(suf):] == suf:
        del segs[-len(suf):]
        break
sys.stdout.write(urlunsplit((u.scheme, u.netloc, "/" + "/".join(segs) if segs else "", "", "")))' 2>/dev/null
}

apply_gateway_url_normalization() { # rewrites GW_URL in place; says so when it changed
  local norm; norm=$(normalize_gateway_base_url "$GW_URL")
  [ -n "$norm" ] || return 0   # python hiccup → keep the URL as typed
  if [ "$norm" != "$GW_URL" ]; then
    note "Using $norm — Conduck adds /v1/… itself, so the base address must not already end in it."
    GW_URL="$norm"
  fi
}
