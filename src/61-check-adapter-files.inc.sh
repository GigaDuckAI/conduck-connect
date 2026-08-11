# ----------------------------------------------------- check-adapter --files --
#
# The file-lane probes: the ONE adapter-check profile that mutates. Three independent
# tiers, three independent meters:
#   tier 1  file_transport — this host's WebDAV <-> disk lane: auth on the
#           routes that actually carry user bytes, write-through fidelity,
#           direct-write freshness (the rclone --dir-cache-time trap that hid
#           agent-written files from the app), ranged-probe compatibility,
#           nested folders (tri-state — the app has a flat fallback), DELETE.
#   tier 2  file_access — one real chat turn: the SELECTED model must copy a
#           sentinel byte-for-byte to the folder root and name it detectably.
#           Graded with the app's REAL wire text (the input-reference block +
#           [Conduck file transfer] instruction from ConverseRequest.swift,
#           golden-locked) and the app's REAL detector rules (allowlist,
#           inbound exclusion, 5-candidate cap).
#   tier 3  file_e2e — the combined delivery path, probed the way the app
#           probes it: ONE immediate ranged GET when the reply lands (no
#           retry, no grace), then a separate full download byte-compare.
# A PASS proves: this host's lane + the selected model, through this adapter,
# delivered one detectable output file. It does NOT prove public exposure,
# remote-device reachability, other models, or folder confinement.
#
# Safety: every artifact name carries a per-run nonce and the recognizable
# conduck-check- prefix; targets are REGISTERED before creation and removed
# by exact name only (never a glob); direct-disk operations revalidate the
# folder's pinned device+inode first; cleanup failure is ERROR, not silence.

DF_URL=""; DF_DIR=""; DF_CRED=""; DF_USER="conduck"
DF_DEV_INO=""      # "<dev>:<ino>" pinned at resolve time — every direct disk op revalidates
DF_RUN=""          # per-run namespace nonce; every artifact name carries it
DF_ARTS=()         # "tier<TAB>kind<TAB>relkey" — registered BEFORE creation; tier T|A, kind file|dir
DF_AGENT_RAN=false
DF_WROTE=false     # true once a mutating operation could have created something. DF_ARTS
                   # proves only INTENT (registration precedes creation, by design), so
                   # anything that sends the operator looking keys off THIS flag.
df_register() { DF_ARTS+=("$1"$'\t'"$2"$'\t'"$3"); }

# The file lane's own curl: same egress isolation as the chat probes (`-q`
# ignores ~/.curlrc, --noproxy refuses every proxy — a proxy answering these
# would grade the wrong server, or receive the file credential), credential on
# a stdin curl config, never argv. Kinds: real | wrong (fixed harmless
# literal) | none (no Authorization at all).
doctor_curl_fs() { # doctor_curl_fs <real|wrong|none> <curl args…>
  local kind="$1"; shift
  case "$kind" in
    real)
      credential_value_safe "$DF_CRED" || return 2
      credential_value_safe "$DF_USER" || return 2
      local cred="$DF_CRED" user="$DF_USER"
      cred="${cred//\\/\\\\}"; cred="${cred//\"/\\\"}"
      user="${user//\\/\\\\}"; user="${user//\"/\\\"}"
      printf 'user = "%s:%s"\n' "$user" "$cred" \
        | curl -q -sS --max-time 30 --noproxy '*' --config - "$@" ;;
    wrong) curl -q -sS --max-time 30 --noproxy '*' -u "$DF_USER:conduck-check-wrong-cred" "$@" ;;
    none)  curl -q -sS --max-time 30 --noproxy '*' "$@" ;;
  esac
}
doctor_fs_code() { # doctor_fs_code <real|wrong|none> [curl args…] <url> -> echoes 3-digit code, 000 on transport failure
  local code
  code=$(doctor_curl_fs "$1" -o /dev/null -w '%{http_code}' "${@:2}" 2>/dev/null) || true
  case "$code" in [0-9][0-9][0-9]) printf '%s' "$code" ;; *) printf '000' ;; esac
}
# The ONE door for every mutating WebDAV verb (PUT, MKCOL) — same contract as
# doctor_fs_code, plus the DF_WROTE bookkeeping. An ANSWERED request may have
# created something even when it rejected the write, and even somewhere this
# host cannot see (a server serving a DIFFERENT directory than the one on
# record is exactly what FILES_WRITE_THROUGH exists to catch), so any status
# counts. A 000 means no server answered at all: nothing can have been created,
# and a later DELETE to the same silent lane cannot remove anything either.
doctor_fs_write() { # doctor_fs_write <real|wrong|none> [curl args…] <url> -> echoes 3-digit code
  local code
  code=$(doctor_fs_code "$@")
  [ "$code" = "000" ] || DF_WROTE=true
  printf '%s' "$code"
}

doctor_files_dir_ok() { # the pinned-identity gate before EVERY direct disk operation
  local now
  now=$(python3 -c 'import os, sys
try:
    st = os.stat(sys.argv[1]); print("%d:%d" % (st.st_dev, st.st_ino))
except Exception: pass' "$DF_DIR" 2>/dev/null)
  [ -n "$DF_DEV_INO" ] && [ "$now" = "$DF_DEV_INO" ]
}

# doctor_files_disk_verify <relkey> <expected-content-file>
# -> echoes OK | MISSING | MISMATCH | NOTREGULAR | TOOBIG | UNSAFE
doctor_files_disk_verify() {
  doctor_files_dir_ok || { printf 'UNSAFE'; return 0; }
  python3 - "$DF_DIR" "$1" "$2" <<'PY' 2>/dev/null || printf 'UNSAFE'
import os, stat, sys
root, rel, expf = sys.argv[1], sys.argv[2], sys.argv[3]
p = os.path.join(root, rel)
rp = os.path.realpath(p)
if not (rp == root or rp.startswith(root + os.sep)):
    print("UNSAFE"); sys.exit(0)
try:
    st = os.lstat(p)
except FileNotFoundError:
    print("MISSING"); sys.exit(0)
except Exception:
    print("UNSAFE"); sys.exit(0)
if not stat.S_ISREG(st.st_mode):
    print("NOTREGULAR"); sys.exit(0)
if st.st_size > 1048576:
    print("TOOBIG"); sys.exit(0)
exp = open(expf, "rb").read()
fd = os.open(p, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
got = os.read(fd, 1048577)
os.close(fd)
print("OK" if got == exp else "MISMATCH")
PY
}

# Resolve ONE immutable file-lane context (URL + credential + folder) and pin
# the folder's identity. Two sources, never mixed: the CONDUCK_FILES_* env
# overrides (all-or-nothing — CI rigs, manual setups), or the saved pairing
# profile whose gateway.url equals the doctor's target (EXACTLY one match),
# corroborated against the live unit before any direct-disk authority is
# granted. Everything lands under FILES_CONFIG.
doctor_files_resolve() {
  local src out
  if [ -n "${CONDUCK_FILES_URL:-}${CONDUCK_FILES_DIR:-}${CONDUCK_FILES_PASS:-}" ]; then
    src="env overrides"
    if [ -z "${CONDUCK_FILES_URL:-}" ] || [ -z "${CONDUCK_FILES_DIR:-}" ] || [ -z "${CONDUCK_FILES_PASS:-}" ]; then
      d_bad FILES_CONFIG "CONDUCK_FILES_* overrides are all-or-nothing — set URL + DIR + PASS together"
      d_say FILES_CONFIG "(mixing an overridden URL with a discovered folder could grade one lane and mutate another)"
      return 1
    fi
    if ! credential_value_safe "$CONDUCK_FILES_PASS" \
       || ! credential_value_safe "${CONDUCK_FILES_USER:-conduck}"; then
      d_bad FILES_CONFIG "CONDUCK_FILES_PASS/CONDUCK_FILES_USER contain control characters — refusing"
      return 1
    fi
    if ! DF_URL=$(doctor_accept_url "$CONDUCK_FILES_URL"); then
      if url_has_userinfo "$CONDUCK_FILES_URL"; then
        d_bad FILES_CONFIG "CONDUCK_FILES_URL carries a \"user:pass@\" credential in the address — give the plain URL"
        d_say FILES_CONFIG "(the file-lane password goes in CONDUCK_FILES_PASS, the user in CONDUCK_FILES_USER)"
      else
        d_bad FILES_CONFIG "CONDUCK_FILES_URL must be https://… or http:// toward this machine (127.0.0.1/localhost)"
      fi
      return 1
    fi
    DF_DIR="$CONDUCK_FILES_DIR"; DF_CRED="$CONDUCK_FILES_PASS"; DF_USER="${CONDUCK_FILES_USER:-conduck}"
  else
    src="saved profile"
    out=$(python3 - "$GW_URL" "$STATE_DIR" <<'PY' 2>/dev/null
import glob, json, os, sys
want = sys.argv[1].rstrip("/").lower()
hits = []
for pf in sorted(glob.glob(os.path.join(sys.argv[2], "profile-*.json"))):
    try:
        d = json.load(open(pf))
    except Exception:
        continue
    gw = d.get("gateway") or {}
    fs = d.get("fileServer")
    url = (gw.get("url") or "").rstrip("/").lower()
    if url == want and isinstance(fs, dict):
        hits.append((gw.get("id") or "", str(fs.get("localPort") or ""), fs.get("folder") or ""))
if len(hits) != 1:
    print("COUNT %d" % len(hits))
else:
    print("OK")
    for field in hits[0]:
        print(field)
PY
)
    case "$out" in
      OK*) ;;
      "COUNT 0"|"")
        d_bad FILES_CONFIG "no saved pairing profile with a file lane matches this URL"
        d_say FILES_CONFIG "(the profile route works on the machine the wizard ran on, against the same gateway URL —"
        d_say FILES_CONFIG " anywhere else, set CONDUCK_FILES_URL + CONDUCK_FILES_DIR + CONDUCK_FILES_PASS explicitly)"
        return 1 ;;
      *)
        d_bad FILES_CONFIG "more than one saved profile matches this URL — ambiguous, refusing to guess"
        d_say FILES_CONFIG "(set CONDUCK_FILES_URL + CONDUCK_FILES_DIR + CONDUCK_FILES_PASS to pick one lane explicitly)"
        return 1 ;;
    esac
    local pid pport pfolder
    pid=$(printf '%s\n' "$out" | sed -n '2p')
    pport=$(printf '%s\n' "$out" | sed -n '3p')
    pfolder=$(printf '%s\n' "$out" | sed -n '4p')
    [ -n "$pid" ] || { d_bad FILES_CONFIG "the matching profile carries no gateway id — re-run the wizard to refresh it"; return 1; }
    # existing_fs_config keys its unit/state lookups off GW_ID — safe to set
    # here: doctor mode never writes profiles or units (REUSE_ONLY is forced).
    GW_ID="$pid"
    if ! existing_fs_config; then
      d_bad FILES_CONFIG "the profile names a file lane, but no live file-server unit + credential was found for it"
      d_say FILES_CONFIG "(re-run the wizard to repair the lane, or use the CONDUCK_FILES_* overrides)"
      return 1
    fi
    # Corroborate profile vs unit BEFORE granting direct-disk authority: the
    # unit's folder parse is best-effort text extraction; the profile is an
    # independent record. Only their agreement earns writes/deletes.
    if [ -n "$pport" ] && [ "$pport" != "$FS_LOCAL_PORT" ]; then
      d_bad FILES_CONFIG "profile and service disagree on the local port ($pport vs $FS_LOCAL_PORT) — re-run the wizard"
      return 1
    fi
    if [ -z "$pfolder" ] || [ -z "$FS_FOLDER" ] || [ "$pfolder" != "$FS_FOLDER" ]; then
      d_bad FILES_CONFIG "profile and service disagree on the served folder — refusing direct-disk probes"
      d_say FILES_CONFIG "(re-run the wizard to rewrite both records, or use the CONDUCK_FILES_* overrides)"
      return 1
    fi
    # Loopback on purpose: the doctor grades THIS HOST's lane; contacting a
    # public URL the user never typed would widen the doctor's egress contract.
    DF_URL="http://127.0.0.1:$FS_LOCAL_PORT"
    DF_DIR="$pfolder"; DF_CRED="$FS_CRED"; DF_USER="conduck"
  fi
  if ! credential_value_safe "$DF_CRED"; then
    d_bad FILES_CONFIG "the recovered credential contains control characters — refusing"
    return 1
  fi
  out=$(python3 - "$DF_DIR" <<'PY' 2>/dev/null
import os, sys
p = sys.argv[1]
if not p or not os.path.isabs(p) or any(c in p for c in "\r\n"):
    print("BAD not an absolute clean path"); sys.exit(0)
rp = os.path.realpath(p)
home = os.path.realpath(os.path.expanduser("~"))
if rp == "/" or rp == home:
    print("BAD refusing / and the home directory itself"); sys.exit(0)
if not os.path.isdir(rp):
    print("BAD the folder does not exist"); sys.exit(0)
st = os.stat(rp)
print("OK %d:%d" % (st.st_dev, st.st_ino))
print(rp)
PY
)
  case "$out" in
    OK*) ;;
    BAD*) d_bad FILES_CONFIG "shared folder rejected — ${out#BAD }"; return 1 ;;
    *)    d_bad FILES_CONFIG "could not validate the shared folder (python3 failed)"; return 1 ;;
  esac
  DF_DEV_INO=$(printf '%s\n' "$out" | sed -n '1p'); DF_DEV_INO="${DF_DEV_INO#OK }"
  DF_DIR=$(printf '%s\n' "$out" | sed -n '2p')
  d_ok FILES_CONFIG "file lane resolved ($src) — server $DF_URL, folder verified (identity pinned)"
  return 0
}

# Tier 1 — transport. Sets DOCTOR_FILE_TRANSPORT.
doctor_files_transport() {
  local tfail=0 terr=0 disk_ok=true code out body tmpd tmp uprobe hdrs
  local wkey="conduck-check-$DF_RUN-wt.txt"
  local fkey="conduck-check-$DF_RUN-fresh.txt"
  local ukey1="conduck-check-$DF_RUN-unauth-none.txt"
  local ukey2="conduck-check-$DF_RUN-unauth-wrong.txt"
  local nkey="conduck-check-$DF_RUN-dir"
  local wt_nonce
  wt_nonce=$(python3 -c 'import secrets; print("conduck-check write-through " + secrets.token_hex(16))' 2>/dev/null)
  # ONE 0700 directory, three files inside it — not one mktemp file plus sibling
  # names built by string concatenation. mktemp publishes its random suffix the
  # moment it creates the file, and /tmp's sticky bit stops DELETION, not the
  # CREATION of "<that name>.u"; a local user who wins that race turns the plain
  # redirect below into a write through their symlink, at this script's
  # privileges — and `-D` lets the file server choose the bytes written.
  tmpd=$(mktemp -d "${TMPDIR:-/tmp}/conduck-check.XXXXXX" 2>/dev/null) || tmpd=""
  if [ -z "$wt_nonce" ] || [ -z "$tmpd" ]; then
    d_bad FILES_CONFIG "could not stage transport probes (python3/mktemp failed)"
    DOCTOR_FILE_TRANSPORT="ERROR"; return 0
  fi
  tmp="$tmpd/probe"; uprobe="$tmpd/unauth"; hdrs="$tmpd/headers"

  # write-through: PUT over WebDAV must land byte-identical in the folder.
  df_register T file "$wkey"
  printf '%s\n' "$wt_nonce" > "$tmp"
  code=$(doctor_fs_write real -T "$tmp" "$DF_URL/$wkey")
  local wt_ok=false
  case "$code" in
    2??)
      out=$(doctor_files_disk_verify "$wkey" "$tmp")
      case "$out" in
        OK) d_ok FILES_WRITE_THROUGH "write-through — PUT over WebDAV landed byte-identical in the configured folder"; wt_ok=true ;;
        MISSING)
          d_bad FILES_WRITE_THROUGH "PUT answered HTTP $code, but nothing appeared in the configured folder"
          d_say FILES_WRITE_THROUGH "(the server serves a DIFFERENT directory than the one on record — the app would upload"
          d_say FILES_WRITE_THROUGH " into one folder while the agent works in another. Re-run the wizard.)"
          tfail=$((tfail+1)) ;;
        MISMATCH|NOTREGULAR|TOOBIG)
          d_bad FILES_WRITE_THROUGH "PUT landed, but the on-disk file is wrong ($out)"; tfail=$((tfail+1)) ;;
        *)
          d_bad FILES_WRITE_THROUGH "could not verify the folder safely — direct-disk checks disabled this run"
          terr=$((terr+1)); disk_ok=false ;;
      esac ;;
    401|403) d_bad FILES_WRITE_THROUGH "authenticated PUT rejected (HTTP $code) — read-only folder or wrong credential"; tfail=$((tfail+1)) ;;
    000)     d_bad FILES_WRITE_THROUGH "no answer from $DF_URL — is the file server running?"; tfail=$((tfail+1)) ;;
    *)       d_bad FILES_WRITE_THROUGH "authenticated PUT answered HTTP $code"; tfail=$((tfail+1)) ;;
  esac

  # auth, on the routes that carry user bytes (a server protecting only
  # listings while GET/PUT stay open must fail here).
  if $wt_ok; then
    code=$(doctor_fs_code none "$DF_URL/$wkey")
    case "$code" in
      401|403) d_ok FILES_AUTH_READ_MISSING "GET without credentials is refused (HTTP $code)" ;;
      2??)     d_bad FILES_AUTH_READ_MISSING "GET with NO credentials answered HTTP $code — the lane is open"; tfail=$((tfail+1)) ;;
      *)       d_bad FILES_AUTH_READ_MISSING "GET without credentials answered HTTP $code (expected 401/403)"; tfail=$((tfail+1)) ;;
    esac
    code=$(doctor_fs_code wrong "$DF_URL/$wkey")
    case "$code" in
      401|403) d_ok FILES_AUTH_READ_WRONG "GET with a WRONG credential is refused (HTTP $code)" ;;
      2??)     d_bad FILES_AUTH_READ_WRONG "GET with a WRONG credential answered HTTP $code — any password works"; tfail=$((tfail+1)) ;;
      *)       d_bad FILES_AUTH_READ_WRONG "GET with a wrong credential answered HTTP $code (expected 401/403)"; tfail=$((tfail+1)) ;;
    esac
  else
    note "  [FILES_AUTH_READ_MISSING] [FILES_AUTH_READ_WRONG] skipped — need the write-through file to probe against."
  fi
  df_register T file "$ukey1"
  printf 'conduck-check unauth probe\n' > "$uprobe"
  code=$(doctor_fs_write none -T "$uprobe" "$DF_URL/$ukey1")
  case "$code" in
    401|403) d_ok FILES_AUTH_WRITE_MISSING "PUT without credentials is refused (HTTP $code)" ;;
    2??)     d_bad FILES_AUTH_WRITE_MISSING "PUT with NO credentials was ACCEPTED (HTTP $code) — anyone can write into this folder"; tfail=$((tfail+1)) ;;
    *)       d_bad FILES_AUTH_WRITE_MISSING "PUT without credentials answered HTTP $code (expected 401/403)"; tfail=$((tfail+1)) ;;
  esac
  df_register T file "$ukey2"
  code=$(doctor_fs_write wrong -T "$uprobe" "$DF_URL/$ukey2")
  case "$code" in
    401|403) d_ok FILES_AUTH_WRITE_WRONG "PUT with a WRONG credential is refused (HTTP $code)" ;;
    2??)     d_bad FILES_AUTH_WRITE_WRONG "PUT with a WRONG credential was ACCEPTED (HTTP $code)"; tfail=$((tfail+1)) ;;
    *)       d_bad FILES_AUTH_WRITE_WRONG "PUT with a wrong credential answered HTTP $code (expected 401/403)"; tfail=$((tfail+1)) ;;
  esac
  rm -f "$uprobe" 2>/dev/null

  # freshness: a file written DIRECTLY to disk (exactly how agents deliver
  # output) must become visible over WebDAV fast. Prime the directory cache
  # with a 404 for the future name FIRST — on a cold cache even the broken
  # 5-minute default answers instantly, and this check exists to catch it.
  if $disk_ok; then
    df_register T file "$fkey"
    code=$(doctor_fs_code real -r 0-0 "$DF_URL/$fkey")
    if [ "$code" = "404" ]; then
      # Revalidate the pinned folder identity IMMEDIATELY before the direct
      # write — the resolve-time check is several network round-trips old.
      if doctor_files_dir_ok; then
        # O_CREAT lands the name before the write can fail, so the create COUNTS
        # from here on whether or not it reports OK.
        DF_WROTE=true
        out=$(python3 - "$DF_DIR" "$fkey" <<'PY' 2>/dev/null
import os, secrets, sys
p = os.path.join(sys.argv[1], sys.argv[2])
fd = os.open(p, os.O_CREAT | os.O_EXCL | os.O_WRONLY | getattr(os, "O_NOFOLLOW", 0), 0o644)
os.write(fd, ("conduck-check freshness " + secrets.token_hex(16) + "\n").encode())
os.fsync(fd)
os.close(fd)
print("OK")
PY
)
      else
        out="UNSAFE"
      fi
      if [ "$out" = "UNSAFE" ]; then
        d_bad FILES_READ_FRESH "the folder failed its identity check right before the direct write — refusing"
        terr=$((terr+1))
      elif [ "$out" = "OK" ]; then
        local t0 now elapsed first=""
        t0=$(python3 -c 'import time; print("%.3f" % time.monotonic())')
        while :; do
          code=$(doctor_fs_code real -r 0-0 "$DF_URL/$fkey")
          now=$(python3 -c 'import time; print("%.3f" % time.monotonic())')
          elapsed=$(awk -v a="$t0" -v b="$now" 'BEGIN{printf "%.2f", b - a}')
          case "$code" in 2??) first="$elapsed"; break ;; esac
          if awk -v e="$elapsed" 'BEGIN{exit !(e > 5.0)}'; then break; fi
          sleep 0.25
        done
        if [ -n "$first" ] && awk -v e="$first" 'BEGIN{exit !(e <= 2.0)}'; then
          d_ok FILES_READ_FRESH "a file written directly to disk was visible over WebDAV in ${first}s"
        elif [ -n "$first" ]; then
          d_bad FILES_READ_FRESH "direct disk write reached WebDAV after ${first}s — over the 2.0s freshness limit"
          d_say FILES_READ_FRESH "(The file was already complete on disk; WebDAV directory caching delayed visibility."
          d_say FILES_READ_FRESH " Configure rclone serve webdav with --dir-cache-time 1s or lower.)"
          tfail=$((tfail+1))
        else
          d_bad FILES_READ_FRESH "direct disk write was still invisible through WebDAV after 5.0s"
          d_say FILES_READ_FRESH "(This is exactly how agent-written output files go missing in the app. Configure"
          d_say FILES_READ_FRESH " rclone serve webdav with --dir-cache-time 1s or lower, then re-run me.)"
          tfail=$((tfail+1))
        fi
      else
        d_bad FILES_READ_FRESH "could not create the freshness file directly on disk"; terr=$((terr+1))
      fi
    elif [ "$code" = "200" ] || [ "$code" = "206" ]; then
      d_bad FILES_READ_FRESH "a file with the check's random name already exists — collision, refusing"; terr=$((terr+1))
    else
      d_bad FILES_READ_FRESH "the priming request answered HTTP $code (expected 404 for a not-yet-created name)"; tfail=$((tfail+1))
    fi
  else
    note "  [FILES_READ_FRESH] skipped — direct-disk checks are disabled this run."
  fi

  # ranged-probe compatibility: the app's existence probe is Range: bytes=0-0.
  if $wt_ok; then
    code=$(doctor_fs_code real -D "$hdrs" -r 0-0 "$DF_URL/$wkey")
    case "$code" in
      206)
        if grep -qi '^content-range:' "$hdrs" 2>/dev/null; then
          d_ok FILES_PROBE_COMPAT "ranged probe honored (206 + Content-Range) — exactly what the app sends"
        else
          d_bad FILES_PROBE_COMPAT "206 without a Content-Range header"; tfail=$((tfail+1))
        fi ;;
      200)
        d_ok FILES_PROBE_COMPAT "ranged probe answered 200 (Range ignored) — compatible; the app treats 200 and 206 both as present"
        d_say FILES_PROBE_COMPAT "(degradation note: the whole file rides every probe — honoring Range: bytes=0-0 is cheaper)" ;;
      416) d_bad FILES_PROBE_COMPAT "Range: bytes=0-0 on a non-empty file answered 416 — the app's probe would see this as missing"; tfail=$((tfail+1)) ;;
      *)   d_bad FILES_PROBE_COMPAT "ranged probe answered HTTP $code"; tfail=$((tfail+1)) ;;
    esac
    rm -f "$hdrs" 2>/dev/null
  else
    note "  [FILES_PROBE_COMPAT] skipped — need the write-through file to probe against."
  fi

  # nested folders: capability, not a mandate — the app falls back to flat
  # keys on a conclusive rejection. Only an indeterminate answer is trouble.
  df_register T file "$nkey/n.txt"
  df_register T dir "$nkey"
  code=$(doctor_fs_write real -X MKCOL "$DF_URL/$nkey/")
  case "$code" in
    201)
      printf 'conduck-check nested probe\n' > "$tmp"
      code=$(doctor_fs_write real -T "$tmp" "$DF_URL/$nkey/n.txt")
      body=$(doctor_curl_fs real "$DF_URL/$nkey/n.txt" 2>/dev/null) || body=""
      # Three outcomes, three different repairs: the PUT inside the new folder
      # being refused, the file reading back empty, and it reading back wrong.
      # A single message carrying only the PUT's status prints "(HTTP 201)" next
      # to a failure, which reads as if the 201 is the problem — so the status
      # stays where it IS the finding, and the read-back failures name the read
      # instead.
      if [ "${code#2}" = "$code" ]; then
        d_bad FILES_NESTED "MKCOL created the folder, but a PUT inside it answered HTTP $code"; tfail=$((tfail+1))
      elif [ "$body" = "conduck-check nested probe" ]; then
        d_ok FILES_NESTED "nested folders SUPPORTED (MKCOL + PUT + GET round-trip)"
      elif [ -z "$body" ]; then
        d_bad FILES_NESTED "the nested PUT succeeded (HTTP $code), but reading the file back returned no bytes"; tfail=$((tfail+1))
      else
        d_bad FILES_NESTED "the nested PUT succeeded (HTTP $code), but the file reads back with different content"; tfail=$((tfail+1))
      fi ;;
    403|405|409|501)
      d_ok FILES_NESTED "nested folders REJECTED by the server (HTTP $code) — fine: the app falls back to flat keys" ;;
    000) d_bad FILES_NESTED "no answer to MKCOL — transport trouble, not a capability verdict"; tfail=$((tfail+1)) ;;
    *)   d_bad FILES_NESTED "MKCOL answered HTTP $code — neither support nor a clean rejection"; tfail=$((tfail+1)) ;;
  esac
  rm -rf "$tmpd" 2>/dev/null

  if   [ "$terr" -gt 0 ];  then DOCTOR_FILE_TRANSPORT="ERROR"
  elif [ "$tfail" -gt 0 ]; then DOCTOR_FILE_TRANSPORT="FAIL"
  else DOCTOR_FILE_TRANSPORT="PASS"; fi
  $disk_ok || DF_DEV_INO=""   # poison the pin: later tiers must not touch the disk either
  return 0
}

# Tier 2 + 3 — the agent sentinel and the app-shaped delivery probe.
# Sets DOCTOR_FILE_ACCESS + DOCTOR_FILE_E2E.
doctor_files_agent() {
  if ! doctor_files_dir_ok; then
    note "  [FILE_COPY_BYTES] [FILE_REPLY_REFERENCE] [FILE_E2E] skipped — the shared folder failed its identity check."
    return 0
  fi
  if [ -z "${MODELS_FIRST_ID:-}" ]; then
    note "  [FILE_COPY_BYTES] skipped — /v1/models offered no usable model id (already failed above)."
    return 0
  fi
  local ih okey ikey used_key content tmp code out
  ih=$(python3 -c 'import secrets; print(secrets.token_hex(4))' 2>/dev/null)
  content=$(python3 -c 'import secrets; print(secrets.token_hex(32))' 2>/dev/null)
  tmp=$(mktemp "${TMPDIR:-/tmp}/conduck-check.XXXXXX" 2>/dev/null) || tmp=""
  if [ -z "$ih" ] || [ -z "$content" ] || [ -z "$tmp" ]; then
    d_bad FILE_COPY_BYTES "could not stage the sentinel (python3/mktemp failed)"
    DOCTOR_FILE_ACCESS="ERROR"; return 0
  fi
  okey="output-$DF_RUN.txt"
  ikey="conduck-check-$DF_RUN/${ih}__input-$DF_RUN.txt"
  printf '%s\n' "$content" > "$tmp"

  # Input rides the REAL lane shape: a per-conversation folder + the
  # <8hex>__<name> stored-key form. MKCOL unsupported -> the app's flat
  # fallback, and the doctor follows it.
  df_register A dir "conduck-check-$DF_RUN"
  used_key="$ikey"
  code=$(doctor_fs_write real -X MKCOL "$DF_URL/conduck-check-$DF_RUN/")
  if [ "$code" = "201" ]; then
    df_register A file "$ikey"
    code=$(doctor_fs_write real -T "$tmp" "$DF_URL/$ikey")
  else
    used_key="conduck-check-$DF_RUN-${ih}__input-$DF_RUN.txt"
    df_register A file "$used_key"
    code=$(doctor_fs_write real -T "$tmp" "$DF_URL/$used_key")
  fi
  if [ "${code#2}" = "$code" ]; then
    # WebDAV upload failed — place the input directly on disk so the agent
    # tier can still produce evidence (independence from a broken transport).
    # Carry the upload's status into every message below: HTTP 403 (a read-only
    # folder or a rejected credential), a 5xx (out of space, a server fault) and
    # no answer at all (nothing listening) are three different repairs, and this
    # status is the only thing that separates them.
    local uwhy="HTTP $code"
    [ "$code" = "000" ] && uwhy="no answer"
    # Revalidate the pin immediately before this direct write, same as the
    # freshness create: the entry check is several probes old by now.
    doctor_files_dir_ok || {
      note "  [FILE_COPY_BYTES] skipped — the folder failed its identity check before the fallback write."
      rm -f "$tmp" 2>/dev/null
      return 0
    }
    # Same O_CREAT rule as the freshness write: the name can exist even when the
    # write below reports a failure.
    DF_WROTE=true
    out=$(python3 - "$DF_DIR" "$used_key" "$tmp" <<'PY' 2>/dev/null
import os, sys
p = os.path.join(sys.argv[1], sys.argv[2])
d = os.path.dirname(p)
if not os.path.isdir(d):
    os.makedirs(d, exist_ok=True)
data = open(sys.argv[3], "rb").read()
fd = os.open(p, os.O_CREAT | os.O_EXCL | os.O_WRONLY | getattr(os, "O_NOFOLLOW", 0), 0o644)
os.write(fd, data); os.fsync(fd); os.close(fd)
print("OK")
PY
)
    if [ "$out" != "OK" ]; then
      note "  [FILE_COPY_BYTES] skipped — the input sentinel's WebDAV upload failed ($uwhy) and the direct disk write failed too (transport already red above)."
      rm -f "$tmp" 2>/dev/null
      return 0
    fi
    note "  (input sentinel placed directly on disk — the WebDAV upload path failed ($uwhy), see tier 1.)"
  fi

  # The output name must not pre-exist — and the WebDAV 404 doubles as cache
  # priming (same rationale as FILES_READ_FRESH: a cold directory cache must
  # not hand the adapter a freshness pass it didn't earn).
  df_register A file "$okey"
  code=$(doctor_fs_code real -r 0-0 "$DF_URL/$okey")
  if [ "$code" != "404" ] && [ "$code" != "401" ] && [ "$code" != "403" ]; then
    if [ "$code" = "000" ]; then
      d_bad FILE_COPY_BYTES "no answer from the file server before the turn — cannot prove the output name is free"
    else
      d_bad FILE_COPY_BYTES "the output name already answers HTTP $code before the turn ran — collision, refusing"
    fi
    DOCTOR_FILE_ACCESS="ERROR"; rm -f "$tmp" 2>/dev/null; return 0
  fi

  local payload
  payload=$(DF_MODEL="$MODELS_FIRST_ID" DF_OKEY="$okey" DF_IKEY="$used_key" DF_INAME="input-$DF_RUN.txt" \
            python3 - <<'PY' 2>/dev/null
import json, os
e = os.environ
task = ("Copy the input file listed below to a new file named %s at the ROOT of your "
        "working directory, byte-for-byte. Then confirm in one short sentence that names "
        "the new file." % e["DF_OKEY"])
# GOLDEN WIRE TEXT — byte-identical to the app (ConverseRequest.swift:
# spliceServerFileRefs + fileDeliveryInstruction). The doctor must certify the
# prompt shape Conduck actually sends, not a paraphrase.
ref = ("The following file(s) are in your working directory — use them for this request. "
       "Each input lives under its conversation folder at the path shown:\n"
       "- %s (saved as %s)" % (e["DF_INAME"], e["DF_IKEY"]))
instr = ("[Conduck file transfer] To return a file, write it to the root of your working "
         "directory and state its exact filename in plain text in your reply. Attachment "
         "directives (MEDIA: lines or similar) do not reach this user — only files named "
         "in plain reply text are delivered.")
print(json.dumps({"model": e["DF_MODEL"],
                  "messages": [{"role": "user", "content": task + "\n\n" + ref + "\n\n" + instr}],
                  "stream": False}))
PY
)
  if [ -z "$payload" ]; then
    d_bad FILE_COPY_BYTES "could not build the sentinel request (python3 failed)"
    DOCTOR_FILE_ACCESS="ERROR"; rm -f "$tmp" 2>/dev/null; return 0
  fi

  say ""
  say "  The file sentinel — one real turn against model '$(safe_display "$MODELS_FIRST_ID" 60)': the agent must copy a"
  say "  small input file to the folder root and name the output in its reply. Agents can be slow;"
  say "  I wait up to 5 minutes…"
  DF_AGENT_RAN=true
  local turn_ok=false shape_reason=""
  if doctor_chat_eval "$payload"; then turn_ok=true; else shape_reason="$DCE_REASON"; fi

  # THE APP-SHAPED MOMENT: one ranged existence probe, immediately, no retry —
  # exactly what Conduck fires when the reply lands (headers only).
  local probe_code
  probe_code=$(doctor_fs_code real -r 0-0 "$DF_URL/$okey")
  out=$(doctor_files_disk_verify "$okey" "$tmp")
  local copy_ok=false
  [ "$out" = "OK" ] && copy_ok=true

  if ! $turn_ok && [ "${DCE_HINT:-}" = "transfer" ]; then
    d_bad FILE_COPY_BYTES "the file turn never completed ($shape_reason)"
    d_say FILE_COPY_BYTES "(the lane was not graded — file_access stays NOT_RUN; fix the transport first, then re-run)"
    rm -f "$tmp" 2>/dev/null
    return 0
  fi

  if $turn_ok && $copy_ok; then
    d_ok FILE_COPY_BYTES "model '$(safe_display "$MODELS_FIRST_ID" 60)' copied the sentinel byte-for-byte to the folder root (${DCC_TIME:-?}s)"
  elif $turn_ok; then
    case "$out" in
      MISSING)
        d_bad FILE_COPY_BYTES "agent reply arrived before a complete byte-identical output file existed"
        d_say FILE_COPY_BYTES "(Conduck probes as soon as the reply lands: wait for the agent's file tools to finish"
        d_say FILE_COPY_BYTES " before returning HTTP 200 — no grace period or retry was applied. If the engine has"
        d_say FILE_COPY_BYTES " no file tools or a different working folder, that is the real finding: this lane"
        d_say FILE_COPY_BYTES " cannot deliver files as configured.)"
        ;;
      MISMATCH)   d_bad FILE_COPY_BYTES "an output file exists but is NOT byte-identical to the input" ;;
      NOTREGULAR) d_bad FILE_COPY_BYTES "the output exists but is not a regular file — refusing it" ;;
      TOOBIG)     d_bad FILE_COPY_BYTES "the output is implausibly large — refusing to read it" ;;
      *)          d_bad FILE_COPY_BYTES "could not verify the output safely ($out)" ;;
    esac
  else
    d_bad FILE_COPY_BYTES "the file turn's HTTP reply is malformed — $shape_reason"
    $copy_ok && d_say FILE_COPY_BYTES "(the file DID land correctly — but a reply Conduck can't parse means it never finds out)"
  fi

  local ref_ok=false
  if $turn_ok; then
    out=$(printf '%s' "$DCC_BODY" | DF_OKEY="$okey" DF_IKEY="$used_key" python3 -c '
import json, os, re, sys
d = json.load(sys.stdin)
reply = d["choices"][0]["message"]["content"]
# Mirror of the app detector (FileTransferOutputDetector): filename-shaped
# tokens -> allowlisted extensions -> dedup by first appearance -> drop the
# echoed inbound stored key (full key AND its last path component) -> cap 5.
allow = {"pdf","csv","tsv","json","xml","yaml","yml","txt","md","log","zip","tar","gz",
         "png","jpg","jpeg","gif","svg","xlsx","xls","docx","doc","pptx","html",
         "py","js","ts","sh","sql","parquet"}
seen, ordered = set(), []
for tok in re.findall(r"[A-Za-z0-9._-]+\.[A-Za-z0-9]{1,8}", reply):
    ext = tok.rsplit(".", 1)[1].lower()
    if ext in allow and tok not in seen:
        seen.add(tok); ordered.append(tok)
ik = os.environ["DF_IKEY"]
inbound = {ik, ik.rsplit("/", 1)[-1]}
outputs = [t for t in ordered if t not in inbound][:5]
print("YES" if os.environ["DF_OKEY"] in outputs else "NO")' 2>/dev/null)
    if [ "$out" = "YES" ]; then
      d_ok FILE_REPLY_REFERENCE "the reply names the output file where Conduck's detector will find it"
      ref_ok=true
    else
      d_bad FILE_REPLY_REFERENCE "the reply does not name the output file detectably"
      d_say FILE_REPLY_REFERENCE "(Conduck scans reply text for allowlisted filenames — the first 5 candidates after"
      d_say FILE_REPLY_REFERENCE " dropping echoed input names — and probes only those. A correct file the app cannot"
      d_say FILE_REPLY_REFERENCE " DISCOVER is not a working lane: state the exact filename in plain reply text.)"
    fi
  fi

  if $copy_ok; then
    if [ "$probe_code" = "200" ] || [ "$probe_code" = "206" ]; then
      # Discoverable at the app's moment — now the byte-faithful download.
      # A separate step on purpose: the app's landing probe reads headers only,
      # so the full GET proves fidelity without claiming to BE landing behavior.
      local dl; dl=$(doctor_curl_fs real "$DF_URL/$okey" 2>/dev/null) || dl=""
      if [ "$dl" = "$content" ]; then
        d_ok FILE_E2E "output discoverable the instant the reply landed (HTTP $probe_code) and downloads byte-faithful"
        DOCTOR_FILE_E2E="PASS"
      else
        d_bad FILE_E2E "the probe saw the file, but the downloaded bytes differ from the on-disk output"
        DOCTOR_FILE_E2E="FAIL"
      fi
    else
      d_bad FILE_E2E "agent output existed on disk when the reply landed, but Conduck's immediate ranged WebDAV probe returned HTTP $probe_code"
      d_say FILE_E2E "(Agent file creation completed; the failure is disk-to-WebDAV visibility, not agent timing —"
      d_say FILE_E2E " see FILES_READ_FRESH and --dir-cache-time.)"
      DOCTOR_FILE_E2E="FAIL"
    fi
  else
    note "  [FILE_E2E] skipped — no verified output file to probe."
  fi

  if $turn_ok && $copy_ok && $ref_ok; then DOCTOR_FILE_ACCESS="PASS"; else DOCTOR_FILE_ACCESS="FAIL"; fi
  [ "${MODELS_ID_COUNT:-0}" -gt 1 ] 2>/dev/null \
    && note "  (file_access grades model '$(safe_display "$MODELS_FIRST_ID" 60)' only — other advertised models may differ.)"
  rm -f "$tmp" 2>/dev/null
  return 0
}

# Graded cleanup: WebDAV DELETE capability + proof that every registered
# artifact is gone. Unproven cleanup is ERROR on the owning meter — never
# silence. Exact names only, never a glob.
doctor_files_delete() {
  local entry kind rel code webdav_ok=true del_unsupported=""
  for entry in ${DF_ARTS[@]+"${DF_ARTS[@]}"}; do
    kind=$(printf '%s' "$entry" | cut -f2); rel=$(printf '%s' "$entry" | cut -f3)
    [ "$kind" = "file" ] || continue
    code=$(doctor_fs_code real -X DELETE "$DF_URL/$rel")
    case "$code" in 2??|404) ;; 403|405|501) webdav_ok=false; del_unsupported="$code" ;; *) webdav_ok=false ;; esac
  done
  for entry in ${DF_ARTS[@]+"${DF_ARTS[@]}"}; do
    kind=$(printf '%s' "$entry" | cut -f2); rel=$(printf '%s' "$entry" | cut -f3)
    [ "$kind" = "dir" ] || continue
    code=$(doctor_fs_code real -X DELETE "$DF_URL/$rel/")
    case "$code" in 2??|404) ;; 403|405|501) webdav_ok=false; del_unsupported="$code" ;; *) webdav_ok=false ;; esac
  done
  # Ground truth + guarded direct removal of anything that remains. Success
  # must be PROVEN: the checker prints a VERIFIED sentinel as its LAST line
  # only after the whole walk completed — a checker that dies mid-list can
  # never read as "clean" (empty output without the sentinel is a failure,
  # not a pass; the trailing-sentinel order is what makes a partial crash
  # unspoofable).
  local leftovers="" vout=""
  if doctor_files_dir_ok; then
    vout=$(for entry in ${DF_ARTS[@]+"${DF_ARTS[@]}"}; do printf '%s\n' "$entry"; done \
      | python3 -c '
import os, stat, sys
root = sys.argv[1]
left = []
dirs = []
for line in sys.stdin.read().splitlines():
    try:
        tier, kind, rel = line.split("\t", 2)
    except ValueError:
        continue
    if not rel.split("/", 1)[0].startswith(("conduck-check-", "output-")):
        left.append(tier + " " + rel); continue
    p = os.path.join(root, rel)
    rp = os.path.realpath(p)
    if not (rp == root or rp.startswith(root + os.sep)):
        left.append(tier + " " + rel); continue
    if kind == "dir":
        dirs.append((tier, p, rel)); continue
    try:
        st = os.lstat(p)
    except FileNotFoundError:
        continue
    except Exception:
        left.append(tier + " " + rel); continue
    try:
        if stat.S_ISREG(st.st_mode) or stat.S_ISLNK(st.st_mode):
            os.unlink(p)
        else:
            left.append(tier + " " + rel); continue
    except Exception:
        left.append(tier + " " + rel)
for tier, p, rel in dirs:
    if os.path.isdir(p):
        try:
            os.rmdir(p)
        except OSError:
            left.append(tier + " " + rel)
for x in left:
    print(x)
print("VERIFIED")' "$DF_DIR" 2>/dev/null)
    if [ "$vout" = "VERIFIED" ]; then leftovers=""
    elif [ "${vout%$'\n'VERIFIED}" != "$vout" ]; then leftovers="${vout%$'\n'VERIFIED}"
    else leftovers="? the cleanup checker itself failed — nothing proven"
    fi
  else
    leftovers="? folder identity changed mid-run — nothing removed directly"
  fi
  if [ -z "$leftovers" ]; then
    if $webdav_ok; then
      d_ok FILES_DELETE "WebDAV DELETE works — every check artifact removed and verified gone"
    elif [ -n "$del_unsupported" ]; then
      d_ok FILES_DELETE "DELETE unsupported (HTTP $del_unsupported) — artifacts removed directly on disk instead"
      d_say FILES_DELETE "(the app treats WebDAV deletion as best-effort, so this is a degradation, not a failure)"
    else
      d_ok FILES_DELETE "check artifacts removed (some DELETE requests failed; direct disk cleanup covered them)"
    fi
    DF_ARTS=()
  else
    d_bad FILES_DELETE "check artifacts could NOT all be removed"
    d_say FILES_DELETE "(remove anything starting with 'conduck-check-$DF_RUN' — and 'output-$DF_RUN.txt' — from the shared folder by hand)"
    case "$leftovers" in *"T "*|\?*) DOCTOR_FILE_TRANSPORT="ERROR" ;; esac
    case "$leftovers" in *"A "*|\?*)
      DOCTOR_FILE_ACCESS="ERROR"
      case "$DOCTOR_FILE_E2E" in PASS|FAIL) DOCTOR_FILE_E2E="ERROR" ;; esac ;;
    esac
  fi
  # Late-write backstop: a broken adapter can answer 200 and write the output
  # AFTER cleanup. One bounded second look — verdicts above stay unchanged.
  if $DF_AGENT_RAN && doctor_files_dir_ok; then
    sleep 2
    python3 -c '
import os, sys
p = os.path.join(sys.argv[1], sys.argv[2])
try:
    st = os.lstat(p)
    import stat
    if stat.S_ISREG(st.st_mode):
        os.unlink(p)
        print("LATE")
except FileNotFoundError:
    pass
except Exception:
    pass' "$DF_DIR" "output-$DF_RUN.txt" 2>/dev/null | grep -q LATE \
      && note "  (the output file appeared AFTER cleanup — removed; the adapter answered before its file tools finished)"
  fi
  return 0
}

# Best-effort backstop for early deaths and signals — the graded
# doctor_files_delete empties DF_ARTS on success, so this only fires mid-run.
doctor_files_cleanup_backstop() {
  [ "${#DF_ARTS[@]}" -gt 0 ] 2>/dev/null || return 0
  [ -n "$DF_URL" ] || return 0
  # Registration precedes creation, so a populated DF_ARTS proves only that the
  # run INTENDED those names. DF_WROTE still false means nothing ever answered a
  # mutating request and no direct disk create ran: there is nothing to remove,
  # and sending the operator to search their agent's working folder for a file
  # that cannot exist is a false alarm (a silent lane answers no DELETE either).
  $DF_WROTE || return 0
  local entry kind rel
  for entry in ${DF_ARTS[@]+"${DF_ARTS[@]}"}; do
    kind=$(printf '%s' "$entry" | cut -f2); rel=$(printf '%s' "$entry" | cut -f3)
    if [ "$kind" = "dir" ]; then doctor_curl_fs real -X DELETE "$DF_URL/$rel/" >/dev/null 2>&1 || true
    else doctor_curl_fs real -X DELETE "$DF_URL/$rel" >/dev/null 2>&1 || true; fi
  done
  warn "Adapter check exited mid-flight — attempted removal of its conduck-check-$DF_RUN files; check the shared folder if any remain."
}

run_doctor_files() {
  say ""
  say "  ${BOLD}--files — the file-lane probes.${RESET} Three meters: file_transport (this host's WebDAV <->"
  say "  disk lane), file_access (the selected agent copies a sentinel and names it), file_e2e"
  say "  (the app-shaped immediate delivery probe). This is the one adapter-check profile that MUTATES:"
  say "  small conduck-check-* files are written to and removed from the shared folder."
  DF_RUN=$(python3 -c 'import secrets; print(secrets.token_hex(4))' 2>/dev/null)
  if [ -z "$DF_RUN" ]; then
    d_bad FILES_CONFIG "could not generate a run nonce (python3 failed)"
    DOCTOR_FILE_TRANSPORT="ERROR"; return 0
  fi
  if ! doctor_files_resolve; then
    DOCTOR_FILE_TRANSPORT="ERROR"
    return 0
  fi
  doctor_files_transport
  doctor_files_agent
  doctor_files_delete
  return 0
}

# The frozen machine line (schema=3), and the published grammar for it.
#
# Printed as the LAST line of EVERY adapter-check exit — green, red, or an early
# die: fixed field order, ASCII enums, no ANSI. Any key added, removed, renamed or
# given a new value bumps schema=, so a consumer pins the number it parses and
# ignores a line carrying one it does not know. Renaming the prefix
# CONDUCK_DOCTOR -> CONDUCK_CHECK_ADAPTER was such a change, which is why schema
# went 2 -> 3. Exactly ONE summary line is emitted (consumers use `tail -1`), so
# the retired prefix is never dual-emitted.
#
# The domains are written HERE, in the one artifact a consumer is guaranteed to
# have: the adapter build brief tells an agent to curl this script and nothing
# else, so a grammar that lives only in the README is a grammar it cannot read.
#
#   schema=3            this grammar
#   contract=v1         the adapter contract family being graded
#   revision=<n.n>      the contract revision this harness implements
#   harness=<version>   conduck-connect's own version; informational, never a gate
#   profile=            basic | deep — deep adds the semantic image probe
#   core=               PASS | FAIL | NOT_RUN — the core wire contract's roll-up.
#                       IMAGE_INPUT and every file check are excluded from it by
#                       design: they grade optional capabilities
#   history_image=      PASS | FAIL | NOT_RUN
#   stream=             PASS | FAIL | NOT_RUN
#   image_input=        VERIFIED | DECLINED | UNVERIFIED | FAIL | NOT_RUN
#   file_transport=     NOT_REQUESTED | NOT_RUN | PASS | FAIL | ERROR
#   file_access=        same domain
#   file_e2e=           same domain
#   checks=<n>          counted verdict lines
#   failed=<n>          how many of them went red
#   exit=<n>            see below
#
# Never key on checks= or failed= as absolute numbers: they move whenever a check
# is added, and a loop pinned to "checks=10" breaks on a harness upgrade that
# fixed nothing about the adapter. Key on the meters and the exit status.
#
# NOT_RUN vs NOT_REQUESTED, because that is precisely what a retry loop branches
# on. NOT_RUN means "this run never got far enough to measure it" — a prerequisite
# stopped the tier, or the probe failed for a cause this run could not tell apart
# from another rule's failure. Fix what went red above and run again; it never
# means "fine". NOT_REQUESTED means "you did not ask for this profile", which is
# not a problem and must never be retried: only the three file meters emit it, and
# only when --files was absent. A capability the run could not measure is never
# reported as failing it — the run-level verdict lives in core=, failed= and
# exit=, and a red verdict line is what says the adapter is non-conformant.
#
# exit=<n> versus the process exit status:
#   * In a NON-INTERACTIVE run — the only kind a machine gets, including any run
#     under CI=1 — this line is the LAST line and exit= IS the process status.
#   * In an interactive run the summary prints BEFORE the optional setup handoff,
#     and it grades the CHECK: exit=0 says every check passed, while the process
#     walks on into setup and finally exits on setup's own result. Read exit=
#     there as this check's verdict, never as a prediction about the process.
# The statuses: 0 every check passed · 1 a check failed, or the run broke · 2 a
# usage error caught after the check began (a malformed URL — a bad FLAG is
# refused by the argument parser before any check exists, so it carries no summary
# at all) · 3 an operator stopped the run at a prompt · 128+signal for HUP/INT/TERM.
doctor_summary() { # doctor_summary <exit-code>
  local rc="${1:-1}" core="NOT_RUN"
  if $DOCTOR_CORE_RAN; then
    core="PASS"
    [ "$DOCTOR_CORE_FAILS" -gt 0 ] && core="FAIL"
  fi
  printf 'CONDUCK_CHECK_ADAPTER schema=3 contract=v1 revision=%s harness=%s profile=%s core=%s history_image=%s stream=%s image_input=%s file_transport=%s file_access=%s file_e2e=%s checks=%s failed=%s exit=%s\n' \
    "$DOCTOR_CONTRACT_REV" "$VERSION" "$DOCTOR_PROFILE" "$core" \
    "$DOCTOR_HISTORY_IMAGE" "$DOCTOR_STREAM" "$DOCTOR_IMAGE_INPUT" \
    "$DOCTOR_FILE_TRANSPORT" "$DOCTOR_FILE_ACCESS" "$DOCTOR_FILE_E2E" \
    "$DOCTOR_CHECKS" "$DOCTOR_FAILS" "$rc"
}

# EXIT dispatcher: chained onto the wizard's on_exit backstop (a no-op for the
# doctor, which never applies exposures — but replacing an armed trap silently
# is how cleanups get lost). $? must be captured FIRST. INT/TERM/HUP are
# routed through exit because macOS bash 3.2 skips the EXIT trap on an
# unhandled signal — the summary line must ride even a Ctrl-C.
doctor_on_exit() {
  local rc=$?
  on_exit
  $DOCTOR_FILES && doctor_files_cleanup_backstop
  doctor_summary "$rc"
}

run_doctor() {
  # The machine summary must ride EVERY exit (frozen schema=3 grammar) — arm
  # it before anything can die. Flag-combination errors happen before this
  # function and are non-runs by definition: no doctor started, no summary.
  DOCTOR_PROFILE="basic"; $DOCTOR_DEEP && DOCTOR_PROFILE="deep"
  # --files was REQUESTED: the meters flip NOT_REQUESTED -> NOT_RUN here, so
  # even an early die reports "asked for, never executed" — never "not asked".
  if $DOCTOR_FILES; then
    DOCTOR_FILE_TRANSPORT="NOT_RUN"; DOCTOR_FILE_ACCESS="NOT_RUN"; DOCTOR_FILE_E2E="NOT_RUN"
  fi
  trap doctor_on_exit EXIT
  trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM
  # Runtime dependencies are checked only AFTER the summary trap is armed.
  # A missing curl/python3 is exit 1 + a final NOT_RUN machine line, never a
  # silent pre-check exit and never an exit-2 CLI usage error.
  preflight

  say "${BOLD}conduck-connect $VERSION — --check-adapter${RESET}"
  # The opening block, printed on the machine path too. An adapter build loop is
  # exactly where nobody read a README first, and this is the only place the
  # command says out loud that its checks send real turns that can cost quota and
  # land in a server's own history. The lines under it are the facts the shared
  # block cannot carry: which contract revision this harness grades, and what
  # --files does to the shared folder in concrete terms.
  explain_check_adapter
  say "  Graded against contract revision $DOCTOR_CONTRACT_REV: ${BOLD}conduck.com/setup/adapter/v1/${RESET}"
  if $DOCTOR_FILES; then
    say "  --files writes and removes small conduck-check-* files in the configured shared folder,"
    say "  and asks the selected agent to copy one. I clean up after myself, but I can't promise a"
    say "  MISBEHAVING agent touches nothing else."
  fi
  note "Building your own adapter? Loop me from a shell — exit code 0 means every check passed."
  if interactive_terminal; then
    note "A CONDUCK_CHECK_ADAPTER machine summary prints before the optional setup handoff."
  else
    note "The last line is always a CONDUCK_CHECK_ADAPTER machine summary — scripts key on it."
    # Where the grammar is, said to the only reader who needs it. A machine is
    # told to download this script and nothing else, so "see the README" is a
    # pointer it cannot follow; the comment above doctor_summary in this very file
    # is one it can. The function name is the anchor because it is stable — prose
    # in a comment is not.
    note "Its key/value domains are in this script, in the comment above doctor_summary."
  fi

  # Target: the positional URL if one was given, else ask.
  if [ -n "$CHECK_URL" ]; then
    GW_URL=$(doctor_accept_url "$CHECK_URL") \
      || usage_die "Can't test '$CHECK_URL' — use https://… (or http://127.0.0.1:<port> for a local test)."
  else
    say ""
    # explain_check_adapter is the prompt's `i` copy, passed by FUNCTION NAME
    # rather than as an action id: explain_prompt resolves a function before it
    # consults the explanation catalogue, and the block that says what this
    # command wants an address for is the block that opened the command.
    # prompt_into, not $(…), so a `q` here stops the run in THIS shell — inside
    # the subshell it would kill the subshell and the check would walk on with an
    # empty address.
    prompt_into GW_URL doctor_ask_url explain_check_adapter
  fi
  apply_gateway_url_normalization

  # Token: $CONDUCK_TOKEN (scripted re-runs) or a hidden prompt. Never argv.
  # Set-but-empty is an EXPLICIT keyless declaration; unset means "ask". A
  # redirected run must never infer no-auth from a missing answer, or the adapter
  # gets graded keyless and every AUTH_* check reports a failure the operator
  # never chose.
  if [ -n "${CONDUCK_TOKEN+set}" ] && [ -z "$CONDUCK_TOKEN" ]; then
    GW_AUTH="none"; GW_TOKEN=""
    note "Keyless by explicit \$CONDUCK_TOKEN=."
  elif [ -n "${CONDUCK_TOKEN:-}" ]; then
    GW_AUTH="bearer"; GW_TOKEN="$CONDUCK_TOKEN"
    note "Using the bearer token from \$CONDUCK_TOKEN."
  else
    say ""
    note "Tip: export CONDUCK_TOKEN=<token> to skip this prompt on re-runs."
    # Two failures, two different meanings, and they must not share a message.
    # rc 11 is an operator who pressed q; the message below tells a SCRIPT how to
    # supply a token, so printing it to someone who deliberately stopped is both
    # wrong and alarming. quit_run runs HERE, in the parent shell — the EXIT trap
    # still emits the machine summary, with exit=3.
    local token_rc=0
    GW_TOKEN=$(ask_secret "Bearer token the server expects" "keyless — this server has no token" "gateway.token") \
      || token_rc=$?
    case "$token_rc" in
      0)  ;;
      11) quit_run ;;
      *)  die "No token given and no answer possible (the input ended). Set CONDUCK_TOKEN=<token> for a scripted run, or set CONDUCK_TOKEN= (empty) to declare keyless deliberately." ;;
    esac
    if [ -n "$GW_TOKEN" ]; then GW_AUTH="bearer"; else GW_AUTH="none"; fi
  fi
  # Plain TLS validation, the same rule the app applies. For a certificate this
  # machine doesn't trust, run it on the server itself against http://127.0.0.1.
  TRANSPORT=""

  head_ "Adapter check — $GW_URL"

  if ! doctor_models_check; then
    say ""
    bad "Adapter check: FAIL — /v1/models isn't answering correctly, so I stopped here."
    say "  Fix that first (every other check would only fail the same way), then re-run me."
    say "  The contract, with a copy-paste self-test: ${BOLD}https://conduck.com/setup/adapter/v1/${RESET}"
    # The same way out as the full FAIL below: this envelope rule is stricter than
    # the app's own Test Connection (Content-Type is graded, an empty "data" is a
    # failure), so third-party software can stop here and still work with the app.
    doctor_not_yours_hint
    exit 1
  fi

  doctor_auth_checks

  say ""
  say "  Now the chat checks — several real turns, each graded against the contract's response"
  say "  rules (strict JSON, one choice, string content, Content-Type application/json). The"
  say "  first goes deliberately WITHOUT a \"model\" field, WITH an unknown extra field, and"
  say "  \"stream\": false — all three must be tolerated. Agents can be slow; I wait up to 5"
  say "  minutes per turn…"
  local payload
  payload=$(python3 -c 'import json
print(json.dumps({"messages": [{"role": "user", "content": "Reply with exactly: pong"}],
                  "stream": False, "conduck_check_probe": True}))') \
    || die "Could not build the test request (python3 failed)."
  doctor_chat_check CHAT_BASIC "chat: absent model + unknown field + stream:false" "$payload" plain || true

  doctor_model_selection_check || true

  # The anti-poisoning probe, in the REAL failure shape this rule exists for:
  # a photo turn that got no assistant reply (two consecutive user messages),
  # then a text-only follow-up. The adapter must answer — forward the earlier
  # image, or swap in the contract's disclosure text; rejecting the request is
  # how one bad photo used to kill every later turn of a conversation.
  payload=$(python3 -c 'import json, zlib, struct, base64
def chunk(t, d):
    return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
ihdr = struct.pack(">IIBBBBB", 1, 1, 8, 0, 0, 0, 0)
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(b"\x00\xff")) + chunk(b"IEND", b"")
uri = "data:image/png;base64," + base64.b64encode(png).decode()
print(json.dumps({"messages": [
    {"role": "user", "content": [
        {"type": "text", "text": "What is in this photo?"},
        {"type": "image_url", "image_url": {"url": uri}}]},
    {"role": "user", "content": "Reply with exactly: pong"}], "stream": False}))') \
    || die "Could not build the history-image test request (python3 failed)."
  # The meter comes from doctor_capability_meter, never from the check's exit
  # status: that status answers "did this check go red", and the meter answers
  # "what did this run MEASURE". They differ on exactly one path — a probe that
  # failed for a cause this run could not tell apart from another rule's failure
  # — and there the honest meter is NOT_RUN. A red verdict line, failed= and
  # exit=1 still carry the run-level verdict, so nothing is softened.
  doctor_chat_check HISTORY_IMAGE "chat: image in an EARLIER message, newest turn text-only" "$payload" history
  DOCTOR_HISTORY_IMAGE=$(doctor_capability_meter)

  payload=$(python3 -c 'import json
print(json.dumps({"messages": [{"role": "user", "content": "Reply with exactly: pong"}],
                  "stream": True}))') \
    || die "Could not build the stream test request (python3 failed)."
  doctor_chat_check STREAM_SYNC "chat: \"stream\": true still answers one JSON object" "$payload" stream
  DOCTOR_STREAM=$(doctor_capability_meter)

  if $DOCTOR_DEEP; then
    say ""
    say "  --deep: the semantic image probe — a locally generated PNG showing six digits rides the"
    say "  newest message. A reply carrying those digits, allowing one misread glyph, proves the"
    say "  engine truly SAW it; an honest HTTP 400 decline with code \"image_unsupported\" also"
    say "  passes. Answering while silently ignoring the image is the one forbidden move."
    doctor_image_input_check || true
  fi

  $DOCTOR_FILES && run_doctor_files

  say ""
  if [ "$DOCTOR_FAILS" = "0" ]; then
    ok "Adapter check: PASS — $DOCTOR_CHECKS/$DOCTOR_CHECKS checks green. This adapter follows Conduck's rules."
    check_setup_next_step
    return 0
  fi
  bad "Adapter check: FAIL — $DOCTOR_FAILS of $DOCTOR_CHECKS checks failed."
  say "  Every rule above, with a copy-paste self-test:  ${BOLD}https://conduck.com/setup/adapter/v1/${RESET}"
  doctor_not_yours_hint
  exit 1
}
