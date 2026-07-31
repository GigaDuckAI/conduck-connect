# --- Hermes agent-side readiness ---------------------------------------------
# Current Hermes API-server releases expose the full toolset by default. A
# user-supplied `platform_toolsets.api_server` narrows that default, though, and
# an explicit list without `file` removes read_file/write_file while chat stays
# perfectly green. `terminal.cwd` independently decides where those tools land.
# We inspect only these narrow YAML paths with a conservative stdlib parser.
# Anchors, flow maps, non-local backends, and global file-tool disables are
# deliberately "manual": guessing at them would broaden privileges silently.
#
# That same key decides something Conduck cares about even more than files: the
# default API-server toolset carries Hermes's `memory` and `session_search`
# tools, so an untouched Hermes answers a brand-new conversation from facts the
# app never sent. Conduck replays the whole conversation every turn and owns the
# history; a gateway that keeps its own contradicts that and pays for the hidden
# context on every turn. No request/response check can see it — a remembering
# gateway passes every wire check — so the scope is classified here, at the
# point where the configuration is chosen, and reported before anything is
# declared ready.
HERMES_CONFIG_CHANGED_THIS_RUN=false
HERMES_GUIDANCE_CHANGED_THIS_RUN=false
HERMES_GUIDANCE_TARGET_THIS_RUN=""
HERMES_RESIDUAL_REPORTED=false
HERMES_SCOPE_CHANGED_THIS_RUN=false
# Fail-safe defaults: a run that never manages to read the config must report
# "I cannot tell", never silence. Silence would read as an all-clear.
HERMES_RECALL_STATE="unknown"
HERMES_RECALL_FIX="none"
HERMES_RECALL_ITEMS=()
HERMES_RECALL_SCOPE=""
HERMES_RECALL_AFTER=""
HERMES_RECALL_REPORTED=false
# A no to the removal is a no for the whole run. Asking the same question again
# at the next Hermes step would read as nagging, not as consent.
HERMES_RECALL_DECLINED=false
HERMES_ANALYSIS_STATUS=""
HERMES_ANALYSIS_REASONS=()
HERMES_ANALYSIS_CHANGES=()
# The two lists the by-hand hint offers, JSON-quoted because that is the only
# inline form the scanner above reads back: a bare flow sequence is refused as
# "YAML syntax this connector will not guess at", and the refusal names the key,
# not the quoting. Advising `[web, file]` therefore sent an operator to write the
# exact line the next run would reject, with nothing on screen to explain it.
# Quoted is also what hermes_config_analysis's own rewrite emits, so the shape we
# tell people to type and the shape we type for them are now the same one.
# Every caller shares these — 20-gateway and 91-show-code pick which of the two
# to pass — so the form is defined once rather than re-spelled at each print.
HERMES_API_SERVER_ADVICE='["web"]'
HERMES_API_SERVER_ADVICE_FILE='["web", "file"]'

hermes_residual_state_note() {
  [ "${GW_KIND:-}" = "hermes" ] || return 0
  $HERMES_RESIDUAL_REPORTED && return 0
  local changed=false
  if $HERMES_CONFIG_CHANGED_THIS_RUN; then
    note "The narrow Hermes config.yaml edit approved earlier remains in place (terminal.cwd / the API-server toolset list only)."
    changed=true
  fi
  if $HERMES_GUIDANCE_CHANGED_THIS_RUN; then
    note "The marker-delimited Conduck guidance block remains in ${HERMES_GUIDANCE_TARGET_THIS_RUN:-the Hermes workspace}."
    changed=true
  fi
  if $HERMES_SCOPE_CHANGED_THIS_RUN; then
    note "The approved removal of Hermes's recall tools from its API-server scope also remains in place."
    changed=true
  fi
  if $changed; then
    note "Those independent host edits are not transactionally rolled back when a later optional file-lane step fails or is declined."
    HERMES_RESIDUAL_REPORTED=true
  fi
}

# hermes_config_analysis <config> <workspace> [analyze|recall|apply|apply-recall] [approved-scope-json]
# `recall` classifies only the API-server recall scope (no workspace needed).
# `apply-recall` removes ONLY the approved recall entries — it never touches
# terminal.cwd or the file toolset. The 4th argument is the exact api_server
# list the operator was shown when approving; a mismatch refuses the write, so
# an edit made between the preview and the yes can never be silently overwritten.
hermes_config_analysis() {
  python3 - "$1" "$2" "${3:-analyze}" ${4+"$4"} <<'PY'
import json, os, re, stat, sys, tempfile

path, workspace, action = sys.argv[1:4]
scope_expect = sys.argv[4] if len(sys.argv) > 4 else None
recall_only = action in ("recall", "apply-recall")
workspace = os.path.realpath(os.path.expanduser(workspace))
if os.path.lexists(path) and os.path.islink(path):
    print("status\tmanual")
    print("reason\tconfig.yaml is a symlink; refusing to edit through it")
    sys.exit(0)
try:
    raw = open(path, encoding="utf-8").read() if os.path.exists(path) else ""
except Exception as exc:
    print("status\tmanual")
    print("reason\tcould not read config.yaml: %s" % type(exc).__name__)
    sys.exit(0)
lines = raw.splitlines(True)

KEY = re.compile(r"^([A-Za-z0-9_-]+):(?:[ \t]*(.*?))?[ \t]*(?:\n)?$")
CHILD = re.compile(r"^([ ]+)([A-Za-z0-9_-]+):(?:[ \t]*(.*?))?[ \t]*(?:\n)?$")
SPACED_KEY = re.compile(r"^([A-Za-z0-9_-]+)[ \t]+:")
PLAIN_STRING_ITEM = re.compile(
    r"^-[ ]+[A-Za-z0-9_][A-Za-z0-9_./-]*(?:[ \t]+#[^\r\n]*)?$")

def content(line):
    # Config keys/lists in the paths we edit must not rely on YAML comments,
    # anchors, tags, or multiline scalars. Values we write are JSON-quoted,
    # which is valid YAML and makes spaces/# unambiguous.
    #
    # A space-only line is BLANK, not content at indent N. Every caller guards
    # with `if not s`, so returning the raw spaces made each one read the line
    # as an indented child: enough to make a section AMBIG, to reject a whole
    # document in unsupported_root_form, and to refuse a block list in
    # sequence(). Trailing whitespace on otherwise-blank lines is near-universal
    # in hand-edited YAML, so this is ordinary input, not a corner case.
    #
    # Only ASCII spaces collapse. A tab-only or non-breaking-space-only line
    # must stay on the fail-closed path — tabs are invalid YAML indentation and
    # this scanner refuses them deliberately, so widening the strip would waive
    # a refusal rather than fix a false one.
    s = line.rstrip("\r\n")
    return "" if not s.strip(" ") else s

def quoted_mapping_key(s):
    """Decode a simple quoted YAML mapping key; None means not safely decoded."""
    if s.startswith('"'):
        try:
            key, end = json.JSONDecoder().raw_decode(s)
        except Exception:
            return None
        if isinstance(key, str) and s[end:].lstrip().startswith(":"):
            return key
        return None
    if s.startswith("'"):
        m = re.match(r"^'((?:[^']|'')*)'[ \t]*:", s)
        if m:
            return m.group(1).replace("''", "'")
    return None

def top_section(name, src=None):
    src = lines if src is None else src
    hit = None
    for i, line in enumerate(src):
        s = content(line)
        if not s or s.lstrip().startswith("#") or s[:1].isspace():
            continue
        # A top-level flow mapping can carry every authoritative section on one
        # line (valid YAML/JSON). This block editor intentionally does not
        # rewrite flow documents; seeing one makes every queried section
        # ambiguous so apply can never append duplicate block sections.
        if s.startswith(("{", "[")):
            return ("AMBIG", None, None)
        # Quoted YAML keys are semantically the same keys, but this deliberately
        # small editor never rewrites them. Treat a quoted authoritative section
        # as ambiguous rather than appending a duplicate plain-key section.
        alternative = quoted_mapping_key(s)
        spaced = SPACED_KEY.match(s)
        if alternative == name or (spaced and spaced.group(1) == name):
            return ("AMBIG", None, None)
        m = KEY.match(s)
        if m and m.group(1) == name:
            if hit is not None:
                return ("AMBIG", None, None)
            if (m.group(2) or "").strip():
                return ("FLOW", i, None)
            hit = i
    if hit is None:
        return ("MISSING", None, None)
    end = len(src)
    for j in range(hit + 1, len(src)):
        s = content(src[j])
        if not s or s.lstrip().startswith("#"):
            continue
        if not s[:1].isspace():
            # PyYAML emits a top-level scalar sequence without indenting its
            # items (for example `toolsets:\n- hermes-cli`). Such an item still
            # belongs to the preceding root key; it is not a new root section.
            if PLAIN_STRING_ITEM.match(s):
                continue
            end = j
            break
    return ("OK", hit, end)

def unsupported_root_form(src=None):
    """True when the document root is outside the block-map subset we edit."""
    src = lines if src is None else src
    saw_document_start = False
    saw_root_entry = False
    root_sequence_open = False
    root_has_indented_content = False
    after_root_scalar_item = False
    for line in src:
        s = content(line)
        if not s or s.lstrip().startswith("#"):
            continue
        if s[:1].isspace():
            # A simple root scalar item cannot subsequently open an indented
            # mapping/continuation. Supporting that would turn this into a
            # general YAML parser, so fail closed.
            if after_root_scalar_item:
                return True
            root_has_indented_content = True
            continue
        # One plain document-start marker before the mapping is harmless. Tags,
        # directives, explicit keys, document-end markers, quoted/spaced keys,
        # and whole-document flow collections remain deliberately unsupported.
        if s == "---" and not saw_document_start and not saw_root_entry:
            saw_document_start = True
            continue
        # PyYAML's default dumper uses indentless sequences at the document
        # root. Accept only a simple scalar item attached to a preceding empty
        # plain root key. List-of-map, tagged, flow, and standalone root
        # sequences remain outside the editable subset.
        if PLAIN_STRING_ITEM.match(s):
            if not saw_root_entry or not root_sequence_open \
               or root_has_indented_content:
                return True
            after_root_scalar_item = True
            continue
        saw_root_entry = True
        after_root_scalar_item = False
        m = KEY.match(s)
        if not m:
            return True
        root_sequence_open = not (m.group(2) or "").strip()
        root_has_indented_content = False
    return False

def child(section, name, src=None):
    src = lines if src is None else src
    st, start, end = top_section(section, src)
    if st != "OK":
        return (st, None, None, None, None)
    # YAML permits any positive direct-child indentation, not just two spaces.
    # The FIRST content line establishes that direct-map indentation. Validate
    # the section as a conservative map/list tree, with two narrow additions
    # for normal PyYAML output: scalar sequence items may be indentless beneath
    # an immediately preceding empty map key, and an unrelated quoted or
    # prose-like scalar may continue on deeper lines within narrow boundaries.
    entries = []
    quote_kind = None
    quote_indent = None
    quote_escaped = False
    plain_indent = None

    def scan_double_quote(text, opened=False, escaped=False):
        i = 0
        if not opened:
            if not text.startswith('"'):
                return ("none", False)
            i = 1
        while i < len(text):
            ch = text[i]
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                tail = text[i + 1:]
                if tail.strip() and not tail.lstrip().startswith("#"):
                    return ("invalid", False)
                return ("closed", False)
            i += 1
        return ("open", escaped)

    def scan_single_quote(text, opened=False):
        i = 0
        if not opened:
            if not text.startswith("'"):
                return "none"
            i = 1
        while i < len(text):
            if text[i] == "'":
                if i + 1 < len(text) and text[i + 1] == "'":
                    i += 2
                    continue
                tail = text[i + 1:]
                if tail.strip() and not tail.lstrip().startswith("#"):
                    return "invalid"
                return "closed"
            i += 1
        return "open"

    def plain_string_can_continue(value):
        # PyYAML wraps long plain strings onto more-indented continuation
        # lines. Limit this accommodation to an obvious prose-like scalar;
        # typed/symbolic values and all authoritative target values remain
        # structurally checked rather than treated as opaque prose.
        return (
            bool(value)
            and value[0].isalnum()
            and any(ch.isspace() for ch in value)
        )

    for i in range(start + 1, end):
        s = content(src[i])
        if not s:
            continue
        # Root-level comments can follow the final section all the way to EOF.
        # Skip ordinary comments before demanding child indentation. A comment
        # inside a proved multiline quote remains scalar content and is scanned
        # below; one arriving during a plain continuation is handled just past
        # the tab check, which it must not be allowed to jump.
        if quote_kind is None and plain_indent is None \
           and s.lstrip().startswith("#"):
            continue
        prefix = s[:len(s) - len(s.lstrip(" \t"))]
        if "\t" in prefix:
            return ("AMBIG", None, None, None, None)
        lead = len(prefix)
        # A comment can never continue a plain scalar (YAML 1.2 §7.3.3), so it
        # closes the continuation at ANY indent: keeping the state alive across
        # a deeper comment would let the next line hide inside the prose
        # accommodation instead of being structurally checked. Without this the
        # column-0 comment that follows an inline-commented value in the stock
        # Hermes config returned AMBIG at the guard below, costing the whole
        # file lane.
        #
        # Matched on `lstrip(" ")`, never `lstrip()`: a tab-prefixed comment has
        # already failed above, and any other Unicode whitespace prefix must
        # fall through to the indentation refusal rather than be waved past it
        # as a comment.
        if quote_kind is None and plain_indent is not None \
           and s.lstrip(" ").startswith("#"):
            plain_indent = None
            continue
        if lead <= 0:
            return ("AMBIG", None, None, None, None)
        if plain_indent is not None:
            if lead > plain_indent:
                # A colon followed by separation whitespace cannot continue a
                # YAML plain scalar. Treat it as structure instead of hiding a
                # target-looking mapping inside the prose accommodation.
                if re.search(r":(?:[ \t]|$)", s.lstrip(" ")):
                    return ("AMBIG", None, None, None, None)
                continue
            plain_indent = None
        if quote_kind is not None:
            if lead <= quote_indent:
                return ("AMBIG", None, None, None, None)
            if quote_kind == "double":
                qst, quote_escaped = scan_double_quote(
                    s.lstrip(" "), opened=True, escaped=quote_escaped)
            else:
                qst = scan_single_quote(s.lstrip(" "), opened=True)
            if qst == "invalid":
                return ("AMBIG", None, None, None, None)
            if qst == "closed":
                quote_kind = None
                quote_indent = None
                quote_escaped = False
            continue
        m = CHILD.match(s)
        if m:
            value = (m.group(3) or "").strip()
            if value.startswith('"'):
                qst, quote_escaped = scan_double_quote(value)
            elif value.startswith("'"):
                qst = scan_single_quote(value)
            else:
                qst = "none"
            if qst == "invalid":
                return ("AMBIG", None, None, None, None)
            if qst == "open":
                quote_kind = "double" if value.startswith('"') else "single"
                quote_indent = lead
            elif m.group(2) != name and plain_string_can_continue(value):
                plain_indent = lead
        entries.append((i, lead, s))
    if quote_kind is not None:
        return ("AMBIG", None, None, None, None)

    direct_indent = entries[0][1] if entries else None
    levels, level_kinds = [], {}
    indentless_open = {}
    previous_indent, previous_opens = None, False
    for _, lead, s in entries:
        m = CHILD.match(s)
        stripped = s.strip()
        if m:
            node_kind = "map"
            node_opens = not (m.group(3) or "").strip()
        elif stripped == "-" or stripped.startswith("- "):
            item = stripped[1:].strip()
            node_kind = "list"
            node_opens = not item
        else:
            return ("AMBIG", None, None, None, None)

        indentless_item = False
        if previous_indent is None:
            levels = [lead]
        elif lead > previous_indent:
            if not previous_opens:
                return ("AMBIG", None, None, None, None)
            # This opening key chose an ordinarily indented child, so it cannot
            # later also own an indentless sequence.
            indentless_open[previous_indent] = False
            levels.append(lead)
        elif lead < previous_indent:
            while levels and levels[-1] > lead:
                levels.pop()
            if not levels or levels[-1] != lead:
                return ("AMBIG", None, None, None, None)

        expected_kind = level_kinds.get(lead)
        if expected_kind is None:
            level_kinds[lead] = node_kind
        elif expected_kind != node_kind:
            if expected_kind == "map" and node_kind == "list" \
               and indentless_open.get(lead, False) \
               and PLAIN_STRING_ITEM.match(stripped):
                indentless_item = True
            else:
                return ("AMBIG", None, None, None, None)

        if lead == direct_indent and node_kind != "map" and not indentless_item:
            return ("AMBIG", None, None, None, None)
        if node_kind == "map":
            indentless_open[lead] = node_opens
        previous_indent, previous_opens = lead, node_opens

    found = None
    for i, indent, s in entries:
        m = CHILD.match(s)
        if not m:
            continue
        if m.group(2) == name and indent != direct_indent:
            return ("AMBIG", None, None, None, None)
        if indent != direct_indent:
            continue
        if m.group(2) == name:
            if found is not None:
                return ("AMBIG", None, None, None, None)
            found = (i, (m.group(3) or "").strip(), indent, end)
    if found is None:
        return ("MISSING", None, None, direct_indent, end)
    return ("OK",) + found

NON_STRING = re.compile(
    r"(?ix)^(?:~|null|true|false|yes|no|on|off|"
    r"[-+]?(?:0|[1-9][0-9_]*)(?:\.[0-9_]*)?(?:e[-+]?[0-9]+)?|"
    r"[-+]?\.[0-9_]+(?:e[-+]?[0-9]+)?|"
    r"[-+]?\.?(?:inf|nan)|0x[0-9a-f_]+|0o[0-7_]+|0b[01_]+|"
    r"[0-9]{4}-[0-9]{1,2}-[0-9]{1,2}(?:[tT ].*)?|[0-9]+:[0-9:]+)$")

def split_comment(value):
    """Strip a YAML plain comment, but never a # inside a JSON string."""
    quoted, escaped = False, False
    for i, ch in enumerate(value):
        if quoted:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                quoted = False
            continue
        if ch == '"':
            quoted = True
            continue
        if ch == "#" and (i == 0 or value[i - 1].isspace()):
            return value[:i].rstrip()
    if quoted or escaped:
        raise ValueError("unterminated JSON quote")
    return value.strip()

def unquoted_yaml_code(line):
    """Return only syntax outside YAML quote spans/comments for hazard scans."""
    out, double, single, escaped = [], False, False, False
    i = 0
    while i < len(line):
        ch = line[i]
        if double:
            out.append(" ")
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                double = False
            i += 1
            continue
        if single:
            out.append(" ")
            if ch == "'" and i + 1 < len(line) and line[i + 1] == "'":
                out.append(" "); i += 2; continue
            if ch == "'":
                single = False
            i += 1
            continue
        if ch == '"':
            double = True; out.append(" "); i += 1; continue
        if ch == "'":
            single = True; out.append(" "); i += 1; continue
        if ch == "#" and (i == 0 or line[i - 1].isspace()):
            break
        out.append(ch); i += 1
    return "".join(out)

ANCHOR_OR_ALIAS = re.compile(r"(?:^|[\s\[\]{},:?])(?:&|\*)[A-Za-z0-9_-]+")
MERGE_KEY = re.compile(r"(?:^|\s)<<[ \t]*:")

def string_value(value):
    try:
        value = split_comment(value)
    except ValueError:
        return "AMBIG", None
    if not value or not all(ch.isprintable() for ch in value):
        return "AMBIG", None
    # This subset deliberately accepts JSON double-quoted strings, not YAML
    # single-quoted strings. JSON decoding preserves commas, hashes, and
    # backslash escapes exactly instead of hand-stripping their delimiters.
    if value.startswith('"'):
        try:
            decoded = json.loads(value)
        except Exception:
            return "AMBIG", None
        if not isinstance(decoded, str) or not all(ch.isprintable() for ch in decoded):
            return "AMBIG", None
        return "OK", decoded
    if value.startswith("'") or value.endswith("'"):
        return "AMBIG", None
    if value[:1] in "|>&*!{[" or value.startswith("- ") \
       or ": " in value or NON_STRING.fullmatch(value):
        return "AMBIG", None
    return "OK", value

def scalar(section, name):
    st, i, value, indent, end = child(section, name)
    if st != "OK":
        return st, None
    return string_value(value)

def sequence(section, name, allow_null=False):
    st, i, value, indent, end = child(section, name)
    if st != "OK":
        return st, None, None
    if value:
        try:
            v = split_comment(value)
        except ValueError:
            return "AMBIG", None, None
        if allow_null and v == "null":
            return "OK", [], ("inline-null", i, indent, end)
        if v.startswith("[") and v.endswith("]"):
            try:
                vals = json.loads(v)
            except Exception:
                return "AMBIG", None, None
            if not isinstance(vals, list) or not all(
                    isinstance(item, str) and item and
                    all(ch.isprintable() for ch in item)
                    for item in vals):
                return "AMBIG", None, None
            return "OK", vals, ("inline", i, indent, end)
        vst, decoded = string_value(v)
        if vst != "OK":
            return "AMBIG", None, None
        return "OK", [decoded], ("inline", i, indent, end)
    # `items` carries each value with the exact line that holds it. Removing an
    # approved entry deletes that one line instead of re-serialising the list,
    # which would flatten indentation and drop the operator's own comments.
    vals, items, j, item_indent = [], [], i + 1, None
    while j < end:
        s = content(lines[j])
        if not s or s.lstrip().startswith("#"):
            j += 1; continue
        lead = len(s) - len(s.lstrip(" "))
        if lead < indent:
            break
        t = s.strip()
        # PyYAML emits a sequence value at the same indentation as its key:
        #   api_server:
        #   - web
        # A different mapping key at that level closes the sequence.
        if lead == indent and not t.startswith("- "):
            break
        if not t.startswith("- "):
            return "AMBIG", None, None
        if item_indent is None:
            item_indent = lead
        elif lead != item_indent:
            return "AMBIG", None, None
        ist, item = string_value(t[2:])
        if ist != "OK":
            return "AMBIG", None, None
        vals.append(item); items.append((j, item)); j += 1
    return "OK", vals, ("block", i, indent, j, item_indent, items)

# Hermes resolves an absent (or YAML-null) platform_toolsets.<platform> to that
# platform's own default bundle, and the API server's default bundle carries the
# `memory` and `session_search` tools. "No list" is therefore not "no recall" —
# it is the widest recall there is, which is why an unwritten key is reported
# rather than passed over.
RECALL_TOOLSETS = {"memory", "session_search"}
# Individually selectable Hermes toolsets in the releases this connector was
# built against. A name that is NOT one of these — a plugin toolset, or one a
# later release adds — is treated as unreadable rather than harmless: it may
# carry recall of its own, and assuming otherwise would print a false all-clear.
KNOWN_TOOLSETS = {
    "web", "browser", "terminal", "file", "code_execution", "vision", "video",
    "image_gen", "video_gen", "x_search", "tts", "stt", "skills", "todo",
    "memory", "context_engine", "session_search", "clarify", "delegation",
    "cronjob", "homeassistant", "spotify", "discord", "discord_admin",
    "yuanbao", "computer_use"}

def composite_bundle(name):
    """True for a name that expands to a whole platform's tools."""
    return name in ("all", "*") or name.startswith("hermes-")

def scope_line_plain(meta):
    """False when rewriting the api_server line would destroy a comment on it."""
    if not meta or meta[0] != "inline":
        return True
    m = CHILD.match(content(lines[meta[1]]))
    if not m:
        return False
    value = (m.group(3) or "").strip()
    try:
        return split_comment(value) == value
    except ValueError:
        return False

def classify_recall(readable, st, vals, meta, disabled):
    """(state, items, fixable) for recall reachable through the API server.

    state    in-scope | default-wide | clear | unknown
    fixable  literal  — plain entries this editor can delete by name
             none     — anything else; the operator edits it themselves
    """
    if not readable or st in ("AMBIG", "FLOW"):
        return ("unknown", [], "none")
    globally_off = RECALL_TOOLSETS <= disabled
    if st in ("MISSING", "NULL"):
        return ("clear", [], "none") if globally_off else ("default-wide", [], "none")
    if st != "OK":
        return ("unknown", [], "none")
    live = [v for v in vals if v not in disabled]
    composites = [v for v in live if composite_bundle(v)]
    hits = [v for v in live if v in RECALL_TOOLSETS]
    opaque = [v for v in live if v not in KNOWN_TOOLSETS and not composite_bundle(v)]
    if composites:
        # A bundle name cannot be edited down to "everything except memory";
        # deleting it would take the rest of that platform's tools with it.
        return ("clear", [], "none") if globally_off else ("in-scope", composites, "none")
    if hits:
        # Deleting the named entries only proves the scope clean when every
        # remaining name is one this connector actually knows.
        if opaque or not scope_line_plain(meta):
            return ("in-scope", hits, "none")
        return ("in-scope", hits, "literal")
    if opaque:
        return ("unknown", opaque, "none")
    return ("clear", [], "none")

manual = []
changes = []

if unsupported_root_form():
    manual.append("config.yaml uses a document-root YAML form outside this connector's conservative plain block-map subset")

if any(ANCHOR_OR_ALIAS.search(unquoted_yaml_code(content(line))) or
       MERGE_KEY.search(unquoted_yaml_code(content(line)))
       for line in lines):
    manual.append("YAML anchors, aliases, or merge keys can change the effective target paths; this connector will not edit through them")

# Whether the document itself is inside the editable subset. Captured before the
# path-specific reasons below so a workspace mismatch never makes the toolset
# look unreadable, or the other way round.
root_readable = not manual

pst, pvals, pmeta = sequence("platform_toolsets", "api_server")
# `api_server:` with nothing under it is YAML null, not an empty list. Hermes
# falls back to its wide default there, so treating it as "[]" would both
# mis-state the before→after and silently narrow the whole scope to whatever
# this connector appended.
if pst == "OK" and pmeta and pmeta[0] == "block" and not pvals:
    pst = "NULL"

dst, dvals, _dmeta = sequence("agent", "disabled_toolsets", allow_null=True)
disabled_toolsets = set(dvals) if dst == "OK" else set()

recall_state, recall_items, recall_fix = classify_recall(
    root_readable, pst, pvals, pmeta, disabled_toolsets)
print("recall\t" + recall_state)
print("recall_fix\t" + recall_fix)
for item in recall_items:
    print("recall_item\t" + item)
if recall_fix == "literal":
    # Both sides of the before→after, and the exact list the approval is bound
    # to. The caller hands `recall_scope` straight back on apply, so a config
    # edited between the preview and the yes refuses instead of overwriting.
    print("recall_scope\t" + json.dumps(pvals))
    print("recall_after\t" + json.dumps([v for v in pvals if v not in recall_items]))
if action == "recall":
    sys.exit(0)

# The approved removal, re-proved against the file as it is right now.
remove_targets = []
if scope_expect is not None:
    if recall_fix != "literal" or pst != "OK":
        manual.append("the API-server recall entries are not in the plain list form this connector edits")
    else:
        try:
            expected = json.loads(scope_expect)
        except Exception:
            expected = None
        if expected != pvals:
            manual.append("platform_toolsets.api_server changed after the exact edit was shown; re-run me")
        else:
            remove_targets = [v for v in pvals if v in recall_items]

if not recall_only:
    bst, backend = scalar("terminal", "backend")
    if bst == "OK" and backend not in ("", "local"):
        manual.append("terminal.backend is %r; a host WebDAV folder is not proven inside that backend" % backend)
    elif bst in ("AMBIG", "FLOW"):
        manual.append("terminal.backend uses YAML syntax this connector will not guess at")

    cst, cwd = scalar("terminal", "cwd")
    if cst == "OK":
        effective = os.path.realpath(os.path.expanduser(cwd))
        if not os.path.isabs(os.path.expanduser(cwd)) or effective != workspace:
            changes.append(("cwd", "terminal.cwd: %s -> %s" % (json.dumps(cwd), json.dumps(workspace))))
    elif cst in ("MISSING",):
        changes.append(("cwd", "terminal.cwd: (absent) -> %s" % json.dumps(workspace)))
    else:
        manual.append("terminal.cwd uses YAML syntax this connector will not guess at")

file_bundles = {"file", "all", "*", "hermes-api-server", "hermes-cli"}
if pst == "OK":
    # One projection, so an approved removal and the file toolset are shown and
    # written as a single before→after rather than two overlapping ones.
    want = [v for v in pvals if v not in remove_targets]
    if not recall_only and not file_bundles.intersection(want):
        want = want + ["file"]
    if want != pvals:
        changes.append(("toolset", "platform_toolsets.api_server: %s -> %s" %
                        (json.dumps(pvals), json.dumps(want))))
elif pst in ("AMBIG", "FLOW"):
    manual.append("platform_toolsets.api_server uses YAML syntax this connector will not guess at")
# Missing or null api_server means Hermes's own full API-server default remains
# authoritative, so its file tools are there. The live sentinel still proves the
# installed version rather than trusting that default on faith.

if not recall_only:
    for key, blocked in (("disabled_toolsets", {"file", "hermes-api-server"}),
                         ("disabled_tools", {"read_file", "write_file"})):
        st, vals, meta = sequence("agent", key, allow_null=True)
        if st == "OK" and blocked.intersection(vals):
            manual.append("agent.%s globally disables %s; removing it would broaden other Hermes platforms" %
                          (key, ", ".join(sorted(blocked.intersection(vals)))))
        elif st in ("AMBIG", "FLOW"):
            manual.append("agent.%s uses YAML syntax this connector will not guess at" % key)

if manual:
    print("status\tmanual")
    for reason in manual: print("reason\t" + reason)
    sys.exit(0)
if not changes:
    print("status\tready")
    if recall_only:
        print("reason\tthe API-server scope already carries no recall tools")
    else:
        print("reason\tfile toolset is not explicitly restricted and terminal.cwd matches the shared folder")
    sys.exit(0)
if action not in ("apply", "apply-recall"):
    print("status\tfix")
    for _, change in changes: print("change\t" + change)
    sys.exit(0)

def ensure_terminal(src):
    st, start, end = top_section("terminal", src)
    q = json.dumps(workspace)
    if st == "MISSING":
        if src and not src[-1].endswith(("\n", "\r")): src[-1] += "\n"
        if src and any(x.strip() for x in src): src.append("\n")
        src.extend(["terminal:\n", "  cwd: %s\n" % q])
        return src
    if st != "OK":
        raise ValueError("terminal section became ambiguous")
    cst, i, value, indent, cend = child("terminal", "cwd", src)
    if cst == "MISSING":
        child_indent = indent if indent is not None else 2
        src.insert(start + 1, " " * child_indent + "cwd: %s\n" % q)
    elif cst == "OK":
        src[i] = " " * indent + "cwd: %s\n" % q
    else:
        raise ValueError("terminal.cwd became ambiguous")
    return src

def remove_recall_entries(src, targets, expected):
    """Delete exactly the approved recall entries, or change nothing at all."""
    global lines
    lines = src
    st, vals, meta = sequence("platform_toolsets", "api_server")
    if st != "OK" or vals != expected:
        raise ValueError("api_server list changed before the edit")
    keep = [v for v in vals if v not in targets]
    kind, i, indent = meta[0], meta[1], meta[2]
    if kind == "inline":
        if not scope_line_plain(meta):
            raise ValueError("api_server line carries a comment")
        src[i] = " " * indent + "api_server: " + json.dumps(keep) + "\n"
        return src
    if kind != "block":
        raise ValueError("api_server is not in an editable list form")
    for line_no, value in sorted(meta[5], reverse=True):
        if value in targets:
            del src[line_no]
    if not keep:
        # An emptied block key is YAML null, which would hand the wide default —
        # memory included — straight back. Write the explicit empty list instead.
        src[i] = " " * indent + "api_server: []\n"
    return src

def ensure_api_file(src):
    global lines
    lines = src
    st, vals, meta = sequence("platform_toolsets", "api_server")
    if st != "OK" or file_bundles.intersection(vals):
        return src
    if meta[0] == "block" and not vals:
        return src   # bare key: YAML null, so Hermes's wide default still applies
    kind, i, indent, end = meta[:4]
    if kind == "inline":
        prefix = " " * indent + "api_server: "
        src[i] = prefix + json.dumps(vals + ["file"]) + "\n"
    else:
        item_indent = meta[4] if len(meta) > 4 and meta[4] is not None else indent + 2
        src.insert(end, " " * item_indent + "- file\n")
    return src

try:
    # Order matters: remove first, then add, then one atomic write. Each step
    # re-parses the buffer it is handed, so an insertion above the toolset key
    # cannot leave a later step editing a stale line number.
    if not recall_only:
        lines = ensure_terminal(lines)
    if remove_targets:
        lines = remove_recall_entries(lines, remove_targets, pvals)
    if not recall_only and any(kind == "toolset" for kind, _ in changes):
        lines = ensure_api_file(lines)
    data = "".join(lines)
    parent = os.path.dirname(path)
    os.makedirs(parent, exist_ok=True)
    mode = stat.S_IMODE(os.stat(path).st_mode) if os.path.exists(path) else 0o600
    fd, tmp = tempfile.mkstemp(prefix=".conduck-config.", dir=parent)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(data)
            f.flush(); os.fsync(f.fileno())
        os.replace(tmp, path)
    except Exception:
        try: os.unlink(tmp)
        except OSError: pass
        raise
except Exception as exc:
    print("status\tmanual")
    print("reason\tcould not apply the narrow config edit: %s" % type(exc).__name__)
    sys.exit(0)
print("status\tapplied")
PY
}

restart_hermes_for_config() {
  local restarted=1
  if [ "$OS" = "Linux" ] && have systemctl \
     && systemctl --user is-enabled hermes-gateway.service >/dev/null 2>&1; then
    run_step "restart Hermes so the approved config change applies" \
      systemctl --user restart hermes-gateway.service && restarted=0
  else
    print_and_wait "Restart Hermes however it runs on this machine so the approved config change takes effect." \
      "systemctl --user restart hermes-gateway.service   # or your own restart method" && restarted=0
  fi
  # Hermes's API server is not listening the moment the restart command returns,
  # and BOTH callers walk straight into config and lane decisions about it. Same
  # defect class as the OpenClaw restarts, so the same bounded wait. HTTP-safe is
  # TRUE: what the operator approved here is agent-side config, nowhere near the
  # HTTP layer. On a --check-server handoff the gateway is paired as `custom` and
  # GW_HEALTH_PATH is empty, so the wait says it cannot tell rather than guessing.
  [ "$restarted" -eq 0 ] && gw_note_restart_and_wait "Hermes configuration change" true
  return "$restarted"
}

# --- API-server recall scope --------------------------------------------------
# The one reader for every analysis mode. It always re-arms the recall globals
# first: a config it cannot read must report "unknown", never keep a previous
# answer, because silence here would be read as an all-clear.
hermes_analysis_read() { # hermes_analysis_read <config> <workspace> <action> [approved-scope]
  local tab line
  tab=$(printf '\t')
  HERMES_ANALYSIS_STATUS=""; HERMES_ANALYSIS_REASONS=(); HERMES_ANALYSIS_CHANGES=()
  HERMES_RECALL_STATE="unknown"; HERMES_RECALL_FIX="none"
  HERMES_RECALL_ITEMS=(); HERMES_RECALL_SCOPE=""; HERMES_RECALL_AFTER=""
  while IFS= read -r line; do
    case "$line" in
      "status$tab"*)       HERMES_ANALYSIS_STATUS="${line#status$tab}" ;;
      "reason$tab"*)       HERMES_ANALYSIS_REASONS+=("${line#reason$tab}") ;;
      "change$tab"*)       HERMES_ANALYSIS_CHANGES+=("${line#change$tab}") ;;
      "recall$tab"*)       HERMES_RECALL_STATE="${line#recall$tab}" ;;
      "recall_fix$tab"*)   HERMES_RECALL_FIX="${line#recall_fix$tab}" ;;
      "recall_item$tab"*)  HERMES_RECALL_ITEMS+=("${line#recall_item$tab}") ;;
      "recall_scope$tab"*) HERMES_RECALL_SCOPE="${line#recall_scope$tab}" ;;
      "recall_after$tab"*) HERMES_RECALL_AFTER="${line#recall_after$tab}" ;;
    esac
  done < <(hermes_config_analysis "$1" "$2" "$3" ${4+"$4"})
}

hermes_recall_read() { # hermes_recall_read <config>
  hermes_analysis_read "$1" "" recall
}

# One report per run, wherever the run first reaches a Hermes decision.
hermes_recall_report() {
  $HERMES_RECALL_REPORTED && return 0
  HERMES_RECALL_REPORTED=true
  local items
  items=$(safe_display "$(printf '%s' "${HERMES_RECALL_ITEMS[*]-}")" 120)
  say ""
  say "  ${BOLD}Hermes memory scope${RESET} — will this gateway remember what Conduck never sent it?"
  case "$HERMES_RECALL_STATE" in
    clear)
      ok "Nothing in this API-server toolset gives Hermes a memory of its own — the conversation stays Conduck's."
      return 0 ;;
    in-scope)
      warn "This gateway's API-server scope carries Hermes's own recall: ${items// /, }." ;;
    default-wide)
      warn "This config names no API-server toolset, so Hermes uses its default bundle — memory and session search included." ;;
    *)
      # `classify_recall` leaves $items non-empty here only when it read the list
      # fine but recognised none of the names — a different problem, and a
      # different fix, from a list it could not read at all.
      if [ -n "$items" ]; then
        warn "I can read this API-server list, but I do not recognise ${items// /, } — so I cannot tell whether it carries Hermes's own memory."
      else
        warn "I cannot read this config's API-server toolset, so I cannot tell whether Hermes keeps its own memory."
      fi ;;
  esac
  say "  Conduck sends the whole conversation every turn and expects the gateway to keep"
  say "  nothing of its own. One that remembers answers from things you never sent it, and"
  say "  you pay for that hidden context on every turn."
  say "  No connection check can see this, here or in --check-server: a remembering gateway"
  say "  passes them all. Test it yourself — tell it something in one conversation, then ask"
  say "  for it in a brand-new one. If it answers, the gateway is keeping its own history."
  return 0
}

# What to change by hand, for every shape this connector will not rewrite.
hermes_recall_manual_hint() { # hermes_recall_manual_hint <suggested-list>
  local suggested="${1:-$HERMES_API_SERVER_ADVICE}"
  case "$HERMES_RECALL_STATE" in
    clear) return 0 ;;
    in-scope)
      local entry bundle=false
      for entry in ${HERMES_RECALL_ITEMS[@]+"${HERMES_RECALL_ITEMS[@]}"}; do
        case "$entry" in hermes-*|all|'*') bundle=true ;; esac
      done
      if $bundle; then
        say "  That name is a whole bundle, and Hermes's bundles carry its memory tools. In"
        say "  ${BOLD}~/.hermes/config.yaml${RESET}, replace it with the toolsets you actually want —"
        say "  for example ${BOLD}api_server: $suggested${RESET} — and restart Hermes."
      else
        say "  In ${BOLD}~/.hermes/config.yaml${RESET}, take memory and session_search out of the"
        say "  platform_toolsets.api_server list, leave everything else, and restart Hermes."
      fi ;;
    default-wide)
      say "  Name the toolsets yourself in ${BOLD}~/.hermes/config.yaml${RESET}, then restart Hermes:"
      say "    platform_toolsets:"
      say "      api_server: $suggested" ;;
    *)
      say "  Check platform_toolsets.api_server in ${BOLD}~/.hermes/config.yaml${RESET} yourself —"
      say "  memory and session_search belong to your other Hermes surfaces, not to this one." ;;
  esac
  say "  This key is per-surface: your Hermes CLI and messaging surfaces keep their memory,"
  say "  and so does anything else you point at this same API server."
  return 0
}

# The one edit offered here, and only in its plainest form: named entries in an
# explicit list. A bundle name, an unwritten key, or anything this parser cannot
# read is described instead of rewritten — deleting a bundle would take a whole
# platform's tools with it, and inventing a list where the user wrote none would
# narrow far more than memory.
hermes_recall_remove_step() { # hermes_recall_remove_step <config> -> 0 when the scope is proven clear
  local cfg="$1" status
  [ "$HERMES_RECALL_FIX" = "literal" ] || return 1
  [ -n "$HERMES_RECALL_SCOPE" ] || return 1
  say ""
  say "  ${BOLD}platform_toolsets.api_server: $HERMES_RECALL_SCOPE -> $HERMES_RECALL_AFTER${RESET}"
  say "  Only that one list changes. Every other toolset in it stays, and Hermes's other"
  say "  surfaces are untouched — but anything else talking to this same API server loses"
  say "  its memory too."
  if ! confirm "  Remove Hermes's recall tools from its API-server scope?"; then
    note "Leaving it as it is."
    HERMES_RECALL_DECLINED=true
    return 1
  fi
  mutate_guard "remove only the recall entries from platform_toolsets.api_server in $cfg" || return 1
  status=$(hermes_config_analysis "$cfg" "" apply-recall "$HERMES_RECALL_SCOPE" \
    | awk -F '\t' '$1=="status"{print $2; exit}')
  if [ "$status" != "applied" ]; then
    warn "That edit could not be applied safely, so nothing was changed."
    return 1
  fi
  HERMES_SCOPE_CHANGED_THIS_RUN=true
  hermes_recall_read "$cfg"
  if [ "$HERMES_RECALL_STATE" != "clear" ]; then
    warn "The edit landed but the scope still does not read as memory-free."
    return 1
  fi
  ok "Hermes's API-server scope re-checked — no memory or session-search tools left in it."
  restart_hermes_for_config || {
    warn "Hermes was not restarted, so it is still running with its old scope."
    return 1
  }
  return 0
}

# The gate a caller can act on. Returns 0 only when this Hermes API server is
# provably free of its own recall. Deciding what a nonzero result MEANS — stop
# before pairing, or carry on with the warning — stays with the caller: refusing
# to pair a gateway that chats fine is a product call, not a parser's.
# --dry-run and --reuse-only report and return 0 by design; neither may block a
# run whose whole promise is that it changes nothing.
hermes_recall_scope_step() { # hermes_recall_scope_step [suggested-list]
  [ "${GW_KIND:-}" = "hermes" ] || return 0
  local cfg="$HOME/.hermes/config.yaml"
  hermes_recall_read "$cfg"
  hermes_recall_report
  [ "$HERMES_RECALL_STATE" = "clear" ] && return 0
  if $DRY_RUN; then
    note "(dry-run: a real run offers to remove those entries, or shows you the exact edit)"
    hermes_recall_manual_hint "${1:-$HERMES_API_SERVER_ADVICE}"
    return 0
  fi
  if $REUSE_ONLY; then
    warn "(reuse-only: not changing Hermes config)"
    hermes_recall_manual_hint "${1:-$HERMES_API_SERVER_ADVICE}"
    return 0
  fi
  if [ "$HERMES_RECALL_FIX" = "literal" ] && ! $HERMES_RECALL_DECLINED \
     && hermes_recall_remove_step "$cfg"; then
    return 0
  fi
  hermes_recall_manual_hint "${1:-$HERMES_API_SERVER_ADVICE}"
  return 1
}

hermes_file_readiness_step() { # hermes_file_readiness_step <workspace>
  local workspace="$1" cfg="$HOME/.hermes/config.yaml"
  local status approved_scope=""
  hermes_analysis_read "$cfg" "$workspace" analyze
  status="$HERMES_ANALYSIS_STATUS"

  # The memory question comes before the file question, and gets its own answer:
  # it decides what this file's single edit contains, and it matters just as much
  # to a user who ends up declining the optional file lane.
  hermes_recall_report
  if [ "$HERMES_RECALL_STATE" != "clear" ]; then
    if [ "$HERMES_RECALL_FIX" != "literal" ] || $DRY_RUN || $REUSE_ONLY \
       || $HERMES_RECALL_DECLINED; then
      hermes_recall_manual_hint "$HERMES_API_SERVER_ADVICE_FILE"
    elif [ "$status" = "fix" ] || [ "$status" = "ready" ]; then
      say ""
      say "  ${BOLD}platform_toolsets.api_server: $HERMES_RECALL_SCOPE -> $HERMES_RECALL_AFTER${RESET}"
      say "  Only that one list changes. Every other toolset in it stays, and Hermes's other"
      say "  surfaces are untouched — but anything else talking to this same API server loses"
      say "  its memory too."
      if confirm "  Remove Hermes's recall tools from its API-server scope?"; then
        approved_scope="$HERMES_RECALL_SCOPE"
        # Re-read with the approval folded in, so the operator sees ONE
        # before→after for this file rather than two overlapping ones.
        hermes_analysis_read "$cfg" "$workspace" analyze "$approved_scope"
        status="$HERMES_ANALYSIS_STATUS"
      else
        note "Leaving the API-server scope as it is."
        HERMES_RECALL_DECLINED=true
        hermes_recall_manual_hint "$HERMES_API_SERVER_ADVICE_FILE"
      fi
    else
      # File readiness is already unprovable here, but the memory scope is a
      # different question about the same one line, and it decides how chat
      # behaves whether or not file transfer goes ahead. Offer it on its own.
      if hermes_recall_remove_step "$cfg"; then
        hermes_analysis_read "$cfg" "$workspace" analyze
        status="$HERMES_ANALYSIS_STATUS"
      else
        hermes_recall_manual_hint "$HERMES_API_SERVER_ADVICE_FILE"
      fi
    fi
  fi

  say ""
  say "  ${BOLD}Hermes file readiness${RESET} — can the API-server agent use this exact folder?"
  case "$status" in
    ready)
      ok "Hermes config is file-lane-ready (${HERMES_ANALYSIS_REASONS[0]:-working root and file tools})."
      return 0 ;;
    manual|"")
      warn "I cannot prove a safe Hermes file configuration:"
      local r; for r in ${HERMES_ANALYSIS_REASONS[@]+"${HERMES_ANALYSIS_REASONS[@]}"}; do say "    $r"; done
      warn "I will leave file transfer out rather than broaden Hermes privileges or guess at a remote/sandbox mount."
      return 1 ;;
    fix) ;;
    *)
      warn "Unexpected Hermes readiness result '$status' — leaving file transfer out."
      return 1 ;;
  esac

  if [ -n "$approved_scope" ]; then
    warn "So here is the whole edit to Hermes's config, in one place:"
  else
    warn "Hermes needs these narrow changes before its API-server agent can use the lane:"
  fi
  local c; for c in "${HERMES_ANALYSIS_CHANGES[@]}"; do say "    ${BOLD}$c${RESET}"; done
  say "  Only the API-server's toolset list and this working-folder path are in scope;"
  say "  no terminal, web, or messaging-platform permissions are added, and nothing but"
  say "  the entries shown above is taken away."
  if $DRY_RUN; then
    for c in "${HERMES_ANALYSIS_CHANGES[@]}"; do plan_add "EDIT $cfg — $c"; done
    note "(dry-run: a real run asks before editing Hermes config)"
    return 0
  fi
  if $REUSE_ONLY; then
    warn "(reuse-only: not changing Hermes config; leaving the file lane out)"
    return 1
  fi
  if ! confirm "  Apply exactly these Hermes changes?"; then
    note "Leaving the file lane out — chat is unaffected."
    if [ -n "$approved_scope" ]; then
      note "The API-server scope is unchanged too; nothing in this file was touched."
    fi
    return 1
  fi
  mutate_guard "edit only terminal.cwd / platform_toolsets.api_server in $cfg" || return 1
  status=$(hermes_config_analysis "$cfg" "$workspace" apply ${approved_scope:+"$approved_scope"} \
    | awk -F '\t' '$1=="status"{print $2; exit}')
  if [ "$status" != "applied" ]; then
    warn "The Hermes config edit could not be applied safely — leaving the file lane out."
    return 1
  fi
  HERMES_CONFIG_CHANGED_THIS_RUN=true
  if [ -n "$approved_scope" ]; then HERMES_SCOPE_CHANGED_THIS_RUN=true; fi
  hermes_analysis_read "$cfg" "$workspace" analyze
  status="$HERMES_ANALYSIS_STATUS"
  if [ "$status" != "ready" ]; then
    warn "Hermes config did not re-check as file-ready — leaving the file lane out."
    return 1
  fi
  if [ -n "$approved_scope" ] && [ "$HERMES_RECALL_STATE" != "clear" ]; then
    warn "The recall entries were removed but the scope still does not read as memory-free."
    hermes_recall_manual_hint "$HERMES_API_SERVER_ADVICE_FILE"
  fi
  ok "Hermes config re-checked — file toolset + working folder are aligned."
  if ! restart_hermes_for_config; then
    warn "Hermes was not restarted, so the file change is not active — leaving the lane out."
    return 1
  fi
  return 0
}

hermes_guidance_target() { # hermes_guidance_target <workspace>
  local ws="$1"
  [ -e "$ws/.hermes.md" ] && { printf '%s' "$ws/.hermes.md"; return 0; }
  [ -e "$ws/HERMES.md" ] && { printf '%s' "$ws/HERMES.md"; return 0; }
  # Hermes gives .hermes.md/HERMES.md priority over other project context.
  # Creating one beside an existing AGENTS.md/CLAUDE.md/.cursorrules would
  # silently stop that lower-priority file from loading, so refuse rather than
  # change unrelated agent behavior.
  if [ -e "$ws/AGENTS.md" ] || [ -e "$ws/CLAUDE.md" ] || [ -e "$ws/.cursorrules" ]; then
    return 1
  fi
  printf '%s' "$ws/HERMES.md"
}

hermes_guidance_edit() { # hermes_guidance_edit <target> <check|apply>
  python3 - "$1" "$2" <<'PY'
import os, sys
target, action = sys.argv[1:3]
BEGIN = "<!-- conduck-connect:begin -->"
END = "<!-- conduck-connect:end -->"
block = BEGIN + """
## Conduck chat attachments (managed by conduck-connect)

These rules apply only when a user message contains `[Conduck file transfer]`.

- The exact uploaded path named in the message is already under this working directory. Use `read_file` on that path; never search the web for an attached file.
- To return a file, finish writing it at the working-directory root before replying, then state its exact filename in plain reply text.
- Do not use `MEDIA:` or another channel attachment directive for a Conduck turn; the OpenAI-compatible response does not deliver those directives to Conduck.
""" + END
if os.path.islink(target):
    print("symlink"); sys.exit(0)
try:
    old = open(target, encoding="utf-8").read() if os.path.exists(target) else ""
except Exception:
    print("unreadable"); sys.exit(0)
nb, ne = old.count(BEGIN), old.count(END)
if nb == 1 and ne == 1 and old.index(BEGIN) < old.index(END):
    managed = old[old.index(BEGIN):old.index(END)+len(END)]
    if managed == block:
        print("ready"); sys.exit(0)
    state = "stale"
elif nb == 0 and ne == 0:
    state = "missing"
else:
    print("malformed"); sys.exit(0)
if action == "check":
    print(state); sys.exit(0)
if state == "missing":
    new = old.rstrip("\n") + ("\n\n" if old.strip() else "") + block + "\n"
else:
    new = old[:old.index(BEGIN)] + block + old[old.index(END)+len(END):]
try:
    os.makedirs(os.path.dirname(target), exist_ok=True)
    mode = os.stat(target).st_mode & 0o777 if os.path.exists(target) else 0o644
    tmp = target + ".conduck-tmp-%d" % os.getpid()
    fd = os.open(tmp, os.O_CREAT | os.O_EXCL | os.O_WRONLY, mode)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(new); f.flush(); os.fsync(f.fileno())
    os.replace(tmp, target)
except Exception:
    try: os.unlink(tmp)
    except Exception: pass
    print("failed"); sys.exit(0)
print("applied")
PY
}

install_conduck_hermes_block() { # install_conduck_hermes_block <workspace>
  local ws="$1" target state
  [ -n "$ws" ] || { warn "Hermes shared folder is unknown — cannot install or prove its file guidance."; return 1; }
  if ! target=$(hermes_guidance_target "$ws"); then
    warn "This folder already has AGENTS.md, CLAUDE.md, or .cursorrules but no Hermes-specific context file."
    warn "Creating HERMES.md would override that context in Hermes, so I will not guess; leaving the file lane out."
    return 1
  fi
  state=$(hermes_guidance_edit "$target" check)
  case "$state" in
    ready)
      ok "Hermes's Conduck file guidance is present in $target."
      return 0 ;;
    missing|stale) ;;
    symlink|malformed|unreadable)
      warn "$target is $state — refusing to edit or replace it; leaving the file lane out."
      return 1 ;;
    *)
      warn "Could not inspect Hermes file guidance safely — leaving the file lane out."
      return 1 ;;
  esac
  say ""
  say "  Hermes loads project instructions from ${BOLD}${target##*/}${RESET}. I can install a"
  say "  marker-delimited Conduck block: open the exact uploaded path with read_file;"
  say "  finish output writes before replying; name returned files in plain reply text."
  if $DRY_RUN; then
    plan_add "INSTALL/refresh the Conduck agent-guidance block in $target (marker-delimited)"
    note "(dry-run: a real run asks before editing the guidance file)"
    return 0
  fi
  if $REUSE_ONLY; then
    warn "(reuse-only: guidance is absent/stale and cannot be changed; leaving the file lane out)"
    return 1
  fi
  if ! confirm "  Install/refresh that Hermes guidance block?"; then
    note "Leaving the file lane out — chat is unaffected."
    return 1
  fi
  mutate_guard "install the marker-delimited Conduck block in $target" || return 1
  state=$(hermes_guidance_edit "$target" apply)
  if [ "$state" = "applied" ]; then
    HERMES_GUIDANCE_CHANGED_THIS_RUN=true
    HERMES_GUIDANCE_TARGET_THIS_RUN="$target"
  fi
  if [ "$state" != "applied" ] || [ "$(hermes_guidance_edit "$target" check)" != "ready" ]; then
    warn "Could not install and re-check Hermes's guidance — leaving the file lane out."
    return 1
  fi
  ok "Conduck agent-guidance block installed in $target."
  return 0
}

AGENT_FILE_PROBE_REASON=""
AGENT_PROBE_ACTIVE=false
AGENT_PROBE_TAG=""
AGENT_PROBE_DIRKEY=""
AGENT_PROBE_INPUTKEY=""
AGENT_PROBE_OUTPUTKEY=""
AGENT_PROBE_TMP=""
AGENT_PROBE_OUTTMP=""
AGENT_PROBE_FS_URL=""
AGENT_PROBE_FS_CRED=""
AGENT_PROBE_FS_FOLDER=""
AGENT_PROBE_DIR_ARMED=false
AGENT_PROBE_INPUT_ARMED=false
AGENT_PROBE_OUTPUT_ARMED=false
AGENT_PROBE_DIR_VERIFY_METHOD=""
AGENT_PROBE_LATE_RISK=false

agent_probe_now_ms() {
  python3 -c 'import time; print(int(time.monotonic() * 1000))' 2>/dev/null
}

agent_probe_ms_seconds() { # agent_probe_ms_seconds <milliseconds>
  case "$1" in 0|[1-9][0-9]*) ;; *) return 1 ;; esac
  printf '%d.%03d' "$(($1 / 1000))" "$(($1 % 1000))"
}

agent_file_chat_eval() { # dedicated five-minute sentinel turn
  local max_time="${CONDUCK_AGENT_CHAT_TIMEOUT_SECONDS:-300}"
  case "$max_time" in 0|[1-9][0-9]*) ;; *) max_time=300 ;; esac
  [ "$max_time" -ge 31 ] 2>/dev/null && [ "$max_time" -le 1800 ] 2>/dev/null \
    || max_time=300
  CCE_REASON=""; CCE_LEN=""; CCE_TOKEN=""; CCE_WIRE_CODE=""
  if ! doctor_chat_request "$1" "$max_time"; then
    CCE_REASON="transfer failed (timed out or the connection dropped)"; return 1
  fi
  app_chat_loaded_eval "-"
}

# Mirror FileTransferOutputDetector.extractCandidates: safe filename token,
# extension allowlist, first-occurrence dedupe, inbound-name exclusion, then
# the app's five-candidate cap. The sentinel output must be one exact candidate;
# merely containing its bytes inside a longer token is not discoverable.
agent_reply_names_output() { # agent_reply_names_output <reply> <outputkey> <inputkey>
  printf '%s' "$1" | python3 -c '
import re, sys
target, inbound_key = sys.argv[1:3]
reply = sys.stdin.read()
allow = {"pdf","csv","tsv","json","xml","yaml","yml","txt","md","log","zip","tar","gz",
         "png","jpg","jpeg","gif","svg","xlsx","xls","docx","doc","pptx","html",
         "py","js","ts","sh","sql","parquet"}
seen, ordered = set(), []
for token in re.findall(r"[A-Za-z0-9._-]+\.[A-Za-z0-9]{1,8}", reply):
    ext = token.rsplit(".", 1)[1].lower()
    if ext in allow and token not in seen:
        seen.add(token)
        ordered.append(token)
inbound = {inbound_key, inbound_key.rsplit("/", 1)[-1]}
candidates = [token for token in ordered if token not in inbound][:5]
sys.exit(0 if target in candidates else 1)' "$2" "$3" >/dev/null 2>&1
}

agent_output_local_snapshot() { # <known-root> <exact-output-key> <expected-file>
  python3 - "$1" "$2" "$3" <<'PY' >/dev/null 2>&1
import os, re, stat, sys
root, key, expected = sys.argv[1:4]
if not os.path.isabs(root) or not re.fullmatch(r"output-[0-9a-f]{16}\.txt", key):
    sys.exit(1)
root = os.path.realpath(root)
if not os.path.isdir(root):
    sys.exit(1)
path = os.path.join(root, key)
if os.path.dirname(os.path.realpath(path)) != root:
    sys.exit(1)
try:
    with open(expected, "rb") as fh:
        want = fh.read()
    before = os.lstat(path)
    if not stat.S_ISREG(before.st_mode) or stat.S_ISLNK(before.st_mode):
        sys.exit(1)
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(path, flags)
    try:
        opened = os.fstat(fd)
        if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
            sys.exit(1)
        # The expected sentinel is connector-owned and tiny. Reject a
        # wrong-sized agent file before reading it, then perform one bounded
        # read so an exact-name giant file cannot consume connector memory.
        if not stat.S_ISREG(opened.st_mode) or opened.st_size != len(want):
            sys.exit(1)
        got = os.read(fd, len(want) + 1)
        after = os.fstat(fd)
    finally:
        os.close(fd)
    final_path = os.lstat(path)
except Exception:
    sys.exit(1)
stable = (
    (after.st_dev, after.st_ino) == (opened.st_dev, opened.st_ino) ==
    (final_path.st_dev, final_path.st_ino) and
    stat.S_ISREG(final_path.st_mode) and not stat.S_ISLNK(final_path.st_mode) and
    after.st_size == final_path.st_size == len(want)
)
sys.exit(0 if stable and got == want else 1)
PY
}

agent_probe_registered_names_safe() {
  local nested="conduck-connect-agent-$AGENT_PROBE_TAG/input-$AGENT_PROBE_TAG.txt"
  local flat="conduck-connect-agent-$AGENT_PROBE_TAG-input.txt"
  case "$AGENT_PROBE_TAG" in ''|*[!a-f0-9]*) return 1 ;; esac
  [ "${#AGENT_PROBE_TAG}" -eq 16 ] || return 1
  [ "$AGENT_PROBE_OUTPUTKEY" = "output-$AGENT_PROBE_TAG.txt" ] || return 1
  [ "$AGENT_PROBE_DIRKEY" = "conduck-connect-agent-$AGENT_PROBE_TAG" ] || return 1
  case "$AGENT_PROBE_DIR_VERIFY_METHOD" in ""|propfind|get) ;; *) return 1 ;; esac
  [ "$AGENT_PROBE_INPUTKEY" = "$nested" ] || [ "$AGENT_PROBE_INPUTKEY" = "$flat" ]
}

agent_probe_cleanup_file() { # agent_probe_cleanup_file <exact-key>
  local key="$1" code verify
  code=$(curl_fs_with_timeout 1 -X DELETE -o /dev/null -w '%{http_code}' \
    "$FS_URL/$key" 2>/dev/null || true)
  case "$code" in 2??|404) ;; *) return 1 ;; esac
  verify=$(curl_fs_with_timeout 1 -o /dev/null -w '%{http_code}' \
    "$FS_URL/$key" 2>/dev/null || true)
  [ "$verify" = "404" ]
}

agent_probe_directory_absent() {
  local code
  case "$AGENT_PROBE_DIR_VERIFY_METHOD" in
    propfind)
      code=$(curl_fs_with_timeout 1 -X PROPFIND -H 'Depth: 0' \
        -o /dev/null -w '%{http_code}' "$FS_URL/$AGENT_PROBE_DIRKEY/" \
        2>/dev/null || true)
      ;;
    get)
      code=$(curl_fs_with_timeout 1 -o /dev/null -w '%{http_code}' \
        "$FS_URL/$AGENT_PROBE_DIRKEY/" 2>/dev/null || true)
      ;;
    *)
      # An interrupt can arrive between MKCOL and capability discovery. Try the
      # WebDAV authority first, then the exact directory GET fallback; only an
      # explicit 404 is absence.
      code=$(curl_fs_with_timeout 1 -X PROPFIND -H 'Depth: 0' \
        -o /dev/null -w '%{http_code}' "$FS_URL/$AGENT_PROBE_DIRKEY/" \
        2>/dev/null || true)
      [ "$code" = "404" ] || {
        code=$(curl_fs_with_timeout 1 -o /dev/null -w '%{http_code}' \
          "$FS_URL/$AGENT_PROBE_DIRKEY/" 2>/dev/null || true)
      }
      ;;
  esac
  [ "$code" = "404" ]
}

# Exact-name cleanup for normal completion and EXIT/signal interruption. It
# snapshots the lane URL and credential at registration time, so a later
# fail-closed drop cannot turn cleanup into an unauthenticated no-op.
agent_file_probe_cleanup_backstop() { # [final:true]
  $AGENT_PROBE_ACTIVE || return 0
  local final="${1:-false}"
  local FS_URL="$AGENT_PROBE_FS_URL" FS_CRED="$AGENT_PROBE_FS_CRED"
  local clean=true code
  rm -f "$AGENT_PROBE_TMP" "$AGENT_PROBE_OUTTMP" 2>/dev/null || true
  if ! agent_probe_registered_names_safe; then
    warn "Agent sentinel cleanup registry was invalid; refusing any delete."
    return 1
  fi
  if $AGENT_PROBE_INPUT_ARMED; then
    agent_probe_cleanup_file "$AGENT_PROBE_INPUTKEY" || clean=false
  fi
  if $AGENT_PROBE_OUTPUT_ARMED; then
    agent_probe_cleanup_file "$AGENT_PROBE_OUTPUTKEY" || clean=false
  fi
  if $AGENT_PROBE_DIR_ARMED; then
    code=$(curl_fs_with_timeout 1 -X DELETE -o /dev/null -w '%{http_code}' \
      "$FS_URL/$AGENT_PROBE_DIRKEY/" 2>/dev/null || true)
    case "$code" in 2??|404) ;; *) clean=false ;; esac
    agent_probe_directory_absent || clean=false
  fi
  if $clean; then
    # A failed/timed-out chat can still have work running behind its returned
    # response. Normal cleanup proves the exact key absent now, but retains the
    # output-only registry so EXIT checks it once more. The final trap call
    # clears the registry after its last exact DELETE + 404 proof.
    if $AGENT_PROBE_LATE_RISK && [ "$final" != "true" ]; then
      AGENT_PROBE_DIR_ARMED=false
      AGENT_PROBE_INPUT_ARMED=false
      AGENT_PROBE_DIR_VERIFY_METHOD=""
      AGENT_PROBE_TMP=""; AGENT_PROBE_OUTTMP=""
      return 0
    fi
    if $AGENT_PROBE_LATE_RISK; then
      warn "Sentinel cleanup proves absence only at this moment; the failed, timed-out, cancelled, or reply-first agent turn may still have background work."
      warn "Recheck and remove this exact file later if it appears: ${AGENT_PROBE_FS_FOLDER:-<shared-root>}/$AGENT_PROBE_OUTPUTKEY"
    fi
    AGENT_PROBE_ACTIVE=false
    AGENT_PROBE_TAG=""; AGENT_PROBE_DIRKEY=""; AGENT_PROBE_INPUTKEY=""
    AGENT_PROBE_OUTPUTKEY=""; AGENT_PROBE_TMP=""; AGENT_PROBE_OUTTMP=""
    AGENT_PROBE_FS_URL=""; AGENT_PROBE_FS_CRED=""; AGENT_PROBE_FS_FOLDER=""
    AGENT_PROBE_DIR_ARMED=false; AGENT_PROBE_INPUT_ARMED=false
    AGENT_PROBE_OUTPUT_ARMED=false
    AGENT_PROBE_DIR_VERIFY_METHOD=""; AGENT_PROBE_LATE_RISK=false
    return 0
  fi
  warn "Sentinel cleanup was not proven; remove only these exact paths if present:"
  warn "$AGENT_PROBE_INPUTKEY and $AGENT_PROBE_OUTPUTKEY"
  $AGENT_PROBE_DIR_ARMED && warn "$AGENT_PROBE_DIRKEY/ (only after confirming it contains no unrelated files)"
  return 1
}

agent_probe_abandon_registry() { # no registered remote target was created
  rm -f "$AGENT_PROBE_TMP" "$AGENT_PROBE_OUTTMP" 2>/dev/null || true
  AGENT_PROBE_ACTIVE=false
  AGENT_PROBE_TAG=""; AGENT_PROBE_DIRKEY=""; AGENT_PROBE_INPUTKEY=""
  AGENT_PROBE_OUTPUTKEY=""; AGENT_PROBE_TMP=""; AGENT_PROBE_OUTTMP=""
  AGENT_PROBE_FS_URL=""; AGENT_PROBE_FS_CRED=""; AGENT_PROBE_FS_FOLDER=""
  AGENT_PROBE_DIR_ARMED=false; AGENT_PROBE_INPUT_ARMED=false
  AGENT_PROBE_OUTPUT_ARMED=false
  AGENT_PROBE_DIR_VERIFY_METHOD=""; AGENT_PROBE_LATE_RISK=false
}

agent_file_wait_for_output() { # agent_file_wait_for_output <expected> <download>
  local expected="$1" download="$2"
  local window="${CONDUCK_AGENT_OUTPUT_DEADLINE_MS:-5000}"
  local request_ms="${CONDUCK_AGENT_OUTPUT_REQUEST_TIMEOUT_MS:-750}"
  local start deadline now remaining call_ms max_time code sleep_ms
  case "$window" in 0|[1-9][0-9]*) ;; *) window=5000 ;; esac
  case "$request_ms" in 0|[1-9][0-9]*) ;; *) request_ms=750 ;; esac
  [ "$window" -ge 1 ] 2>/dev/null && [ "$window" -le 30000 ] 2>/dev/null || window=5000
  [ "$request_ms" -ge 50 ] 2>/dev/null && [ "$request_ms" -le 2000 ] 2>/dev/null || request_ms=750
  start=$(agent_probe_now_ms) || return 1
  deadline=$((start + window))
  while :; do
    now=$(agent_probe_now_ms) || return 1
    remaining=$((deadline - now))
    [ "$remaining" -gt 0 ] || return 1
    call_ms="$request_ms"; [ "$remaining" -lt "$call_ms" ] && call_ms="$remaining"
    max_time=$(agent_probe_ms_seconds "$call_ms")
    : > "$download"
    code=$(curl_fs_with_timeout "$max_time" -o "$download" -w '%{http_code}' \
      "$FS_URL/$AGENT_PROBE_OUTPUTKEY" 2>/dev/null || true)
    if [[ "$code" == 2?? ]] && cmp -s "$expected" "$download"; then
      return 0
    fi
    now=$(agent_probe_now_ms) || return 1
    remaining=$((deadline - now))
    [ "$remaining" -gt 0 ] || return 1
    sleep_ms=250; [ "$remaining" -lt "$sleep_ms" ] && sleep_ms="$remaining"
    sleep "$(agent_probe_ms_seconds "$sleep_ms")"
  done
}

agent_file_probe() {
  AGENT_FILE_PROBE_REASON=""
  if $AGENT_PROBE_ACTIVE && ! agent_file_probe_cleanup_backstop true; then
    AGENT_FILE_PROBE_REASON="a prior sentinel's exact cleanup is still unproven"
    return 1
  fi
  local tag secret dirkey inputkey outputkey tmp outtmp code content payload model reply
  local bytes_ok=false request_ms request_timeout
  local agent_name read_tool write_tool
  case "$GW_KIND" in
    openclaw)
      agent_name="OpenClaw"; read_tool="read"; write_tool="write" ;;
    hermes)
      agent_name="Hermes"; read_tool="read_file"; write_tool="write_file" ;;
    *)
      AGENT_FILE_PROBE_REASON="this gateway has no verified agent file-tool probe"
      return 1 ;;
  esac
  tag=$(python3 -c 'import secrets; print(secrets.token_hex(8))' 2>/dev/null) || {
    AGENT_FILE_PROBE_REASON="could not generate a sentinel nonce"; return 1; }
  secret=$(python3 -c 'import secrets; print(secrets.token_hex(24))' 2>/dev/null) || {
    AGENT_FILE_PROBE_REASON="could not generate sentinel content"; return 1; }
  dirkey="conduck-connect-agent-$tag"
  inputkey="$dirkey/input-$tag.txt"
  outputkey="output-$tag.txt"
  # The content nonce is independent of every name carried in the prompt. A
  # tool-less model can see the randomized path, but cannot derive these bytes
  # from it and synthesize a passing output without reading the input file.
  content="CONDUCK-AGENT-FILE-SENTINEL-$secret"
  tmp=$(mktemp "${TMPDIR:-/tmp}/conduck-agent-probe.XXXXXX" 2>/dev/null) || {
    AGENT_FILE_PROBE_REASON="could not stage the sentinel"; return 1; }
  outtmp=$(mktemp "${TMPDIR:-/tmp}/conduck-agent-output.XXXXXX" 2>/dev/null) || {
    rm -f "$tmp"
    AGENT_FILE_PROBE_REASON="could not stage the sentinel download"; return 1; }
  printf '%s\n' "$content" > "$tmp"

  # Register every exact remote/local target before the first request can
  # create it. The EXIT trap uses this snapshot even if later code drops the
  # optional file lane from the pairing state.
  AGENT_PROBE_TAG="$tag"
  AGENT_PROBE_DIRKEY="$dirkey"
  AGENT_PROBE_INPUTKEY="$inputkey"
  AGENT_PROBE_OUTPUTKEY="$outputkey"
  AGENT_PROBE_TMP="$tmp"
  AGENT_PROBE_OUTTMP="$outtmp"
  AGENT_PROBE_FS_URL="$FS_URL"
  AGENT_PROBE_FS_CRED="$FS_CRED"
  AGENT_PROBE_FS_FOLDER="$FS_FOLDER"
  AGENT_PROBE_DIR_ARMED=false
  AGENT_PROBE_INPUT_ARMED=false
  AGENT_PROBE_OUTPUT_ARMED=false
  AGENT_PROBE_DIR_VERIFY_METHOD=""
  AGENT_PROBE_LATE_RISK=false
  AGENT_PROBE_ACTIVE=true

  # Prove the randomized output name is free before the agent turn. A stale
  # output must never let a tool-less model earn a pass.
  request_ms="${CONDUCK_AGENT_OUTPUT_REQUEST_TIMEOUT_MS:-750}"
  case "$request_ms" in 0|[1-9][0-9]*) ;; *) request_ms=750 ;; esac
  [ "$request_ms" -ge 50 ] 2>/dev/null && [ "$request_ms" -le 2000 ] 2>/dev/null \
    || request_ms=750
  request_timeout=$(agent_probe_ms_seconds "$request_ms")
  code=$(curl_fs_with_timeout "$request_timeout" -o /dev/null -w '%{http_code}' \
    "$FS_URL/$outputkey" 2>/dev/null || true)
  case "$code" in 404) ;; *)
    AGENT_FILE_PROBE_REASON="the randomized output name was not provably free (HTTP ${code:-000})"
    agent_probe_abandon_registry
    return 1 ;;
  esac
  AGENT_PROBE_OUTPUT_ARMED=true

  # Match the app's nested-folder shape when MKCOL is available; rclone supports
  # it. A flat fallback preserves compatibility with manually supplied WebDAV.
  code=$(curl_fs -X MKCOL -o /dev/null -w '%{http_code}' "$FS_URL/$dirkey/" 2>/dev/null || true)
  case "$code" in 2??)
    AGENT_PROBE_DIR_ARMED=true
    code=$(curl_fs_with_timeout 1 -X PROPFIND -H 'Depth: 0' \
      -o /dev/null -w '%{http_code}' "$FS_URL/$dirkey/" 2>/dev/null || true)
    case "$code" in
      2??) AGENT_PROBE_DIR_VERIFY_METHOD="propfind" ;;
      *)
        code=$(curl_fs_with_timeout 1 -o /dev/null -w '%{http_code}' \
          "$FS_URL/$dirkey/" 2>/dev/null || true)
        case "$code" in
          2??) AGENT_PROBE_DIR_VERIFY_METHOD="get" ;;
          *)
            AGENT_FILE_PROBE_REASON="the temporary WebDAV directory could not be observed for cleanup proof"
            agent_file_probe_cleanup_backstop || true
            return 1 ;;
        esac ;;
    esac
    ;;
    *)
      inputkey="conduck-connect-agent-$tag-input.txt"
      AGENT_PROBE_INPUTKEY="$inputkey"
      dirkey="" ;;
  esac
  AGENT_PROBE_INPUT_ARMED=true
  code=$(curl_fs -T "$tmp" -o /dev/null -w '%{http_code}' "$FS_URL/$inputkey" 2>/dev/null || true)
  case "$code" in 2??) ;;
    *)
      AGENT_FILE_PROBE_REASON="could not place the agent sentinel through WebDAV (HTTP ${code:-000})"
      agent_file_probe_cleanup_backstop || true
      return 1 ;;
  esac

  # Match the app/setup request exactly: Hermes normally chooses its configured
  # default when no custom model was entered. Do not substitute the first
  # advertised model here; it could be a non-agent/tool-less model and would
  # manufacture a file-lane failure the app itself would never encounter.
  model="${GW_MODEL:-}"
  payload=$(AF_MODEL="$model" AF_INPUT="$inputkey" AF_OUTPUT="$outputkey" \
    AF_READ="$read_tool" AF_WRITE="$write_tool" python3 - <<'PY' 2>/dev/null
import json, os
e = os.environ
task = (
    "Use %s to read the exact uploaded file path listed below. Use %s "
    "to copy its bytes unchanged into a new file named %s at the ROOT of your working "
    "directory. Finish the write before replying. Do not reconstruct or guess the "
    "file contents. Then reply with one short sentence containing the exact output "
    "filename." % (e["AF_READ"], e["AF_WRITE"], e["AF_OUTPUT"]))
ref = (
    "The following file(s) are in your working directory — use them for this request. "
    "Each input lives under its conversation folder at the path shown:\n"
    "- input.txt (saved as %s)" % e["AF_INPUT"])
instr = (
    "[Conduck file transfer] To return a file, write it to the root of your working "
    "directory and state its exact filename in plain text in your reply. Attachment "
    "directives (MEDIA: lines or similar) do not reach this user — only files named "
    "in plain reply text are delivered.")
p = {"messages": [{"role": "user", "content": task + "\n\n" + ref + "\n\n" + instr}],
     "stream": False}
if e["AF_MODEL"]:
    p["model"] = e["AF_MODEL"]
print(json.dumps(p))
PY
  )
  if [ -z "$payload" ]; then
    AGENT_FILE_PROBE_REASON="could not build the agent sentinel request"
  else
    AGENT_PROBE_LATE_RISK=true
    if ! agent_file_chat_eval "$payload"; then
      AGENT_FILE_PROBE_REASON="the $agent_name file turn failed: $CCE_REASON"
    elif ! agent_output_local_snapshot "$FS_FOLDER" "$outputkey" "$tmp"; then
      AGENT_FILE_PROBE_REASON="$agent_name replied before a byte-identical regular output file existed in the guarded shared root"
      # This is cleanup-only. A later file can never turn the result green, but
      # watching the exact key for the existing five-second window lets us remove
      # common reply-first/background writes before returning.
      agent_file_wait_for_output "$tmp" "$outtmp" || true
    else
      AGENT_PROBE_LATE_RISK=false
      reply=$(printf '%s' "$DCC_BODY" | python3 -c '
import json, sys
try: print(json.load(sys.stdin)["choices"][0]["message"]["content"])
except Exception: pass' 2>/dev/null)
      # rclone's 1-second directory cache may still hold the deliberate pre-turn
      # 404 when the agent writes directly to disk. Creation is already proven
      # at the reply boundary above; these retries can prove visibility only.
      agent_file_wait_for_output "$tmp" "$outtmp" && bytes_ok=true
      if ! $bytes_ok; then
        AGENT_FILE_PROBE_REASON="$agent_name created the output before replying, but it did not become byte-identically visible through WebDAV within five seconds"
      elif ! agent_reply_names_output "$reply" "$outputkey" "$inputkey"; then
        AGENT_FILE_PROBE_REASON="the output bytes were correct, but the reply did not name the randomized output file for Conduck to discover"
      fi
    fi
  fi

  # Exact nonce names only. A successful DELETE is not proof: follow each file
  # delete with an authenticated GET that must answer 404.
  if ! agent_file_probe_cleanup_backstop; then
    [ -n "$AGENT_FILE_PROBE_REASON" ] || AGENT_FILE_PROBE_REASON="sentinel cleanup could not be proven"
    return 1
  fi
  [ -z "$AGENT_FILE_PROBE_REASON" ]
}
