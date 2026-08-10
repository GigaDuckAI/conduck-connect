# ----------------------------------------------------------- explanations --

# Small, reusable information panels for the interactive setup flow. The caller
# decides when to offer them (normally the visible `i` affordance) and redirects
# stdout to stderr when it is collecting an answer with command substitution.
#
# These panels explain ONE current decision. "Afterwards" is deliberately about
# persistence or a concrete inverse action, never a promise that Back, Ctrl-C, a
# failed later step, or a re-run rolls the setup back. WHAT-IT-TOUCHES.md is the
# detailed authority; this catalog is its concise, in-flow counterpart.
#
# THE WRITING RULE, and it is the whole point of the file: `i` is what a person
# presses because a word on the screen defeated them. An explanation may
# therefore never lean on a term the prompt it explains was already unclear
# about — "port", "loopback", "exposure", "reverse proxy", "keyless", "WebDAV"
# each get glossed in the sentence that first uses them, or they do not appear.
# The bar to write to is `explain_exposure_paths` in 30-exposure.inc.sh: fixed
# human labels, plain words, honest about cost, and it ends by telling an unsure
# reader what to do. Every value prompt's panel ends the same way, with the
# `unsure` field — because a person who does not know the answer needs a
# direction more than they need a definition.
#
# TERMINOLOGY, fixed, because the app and this script have to agree:
#   setup code       the QR/paste string the app scans. Never "pairing code" —
#                    the app says "setup code" and has never said the other.
#   conduck-connect  this program. Never "the connector", never "the helper".
#   wizard           the `--setup` flow specifically, not the program.
#   gateway          the user's own AI server. Glossed on first use in any
#                    panel a first-time reader can reach.
#
# EVERY ARM HERE HAS A CALLER. Copy no prompt can reach is copy nobody
# maintains against the screen it claims to describe, and it makes the catalog
# look twice as covered as it is. When you add an arm, wire the call site in the
# same change; when you delete a call site, delete its arm. Panels that describe
# a whole COMMAND rather than one question live at the bottom of this file as
# named functions instead — `explain_prompt` resolves a function name before it
# tries the catalog, so those double as an opening block and as a prompt's `i`.

explain_panel() { # explain_panel <about> <why> <does> [if-skipped] [afterwards] [unsure]
  local about="$1" why="$2" does="$3"
  local skipped="${4:-}" afterwards="${5:-}" unsure="${6:-}"

  say ""
  say "  ${BOLD}About this step:${RESET} $about"
  [ -z "$why" ] || say "  ${BOLD}Why:${RESET} $why"
  [ -z "$does" ] || say "  ${BOLD}It does:${RESET} $does"
  [ -z "$skipped" ] || say "  ${BOLD}If skipped:${RESET} $skipped"
  # "Afterwards" rather than a shorter label, because the field answers "what is
  # still true once this is done, and how do I put it back" — a purpose no
  # reader could infer from a bare adverb, and the field is useless the moment
  # its heading has to be guessed at.
  [ -z "$afterwards" ] || say "  ${BOLD}Afterwards:${RESET} $afterwards"
  # Last on purpose: it is what a stuck reader is looking for, so it is the line
  # their eye lands on when the panel stops.
  [ -z "$unsure" ] || say "  ${BOLD}Honestly unsure?${RESET} $unsure"
  say ""
}

# Copy catalog for the bounded choices, value prompts, and consent gates in
# setup. IDs are internal, stable spellings for prompt call sites; they are
# never user input.
explain_action() { # explain_action <action-id>
  local action_id="${1:-}"

  case "$action_id" in
    general)
      explain_panel \
        "Review the question printed just above this" \
        "Your answer controls only the one action described directly above the prompt — nothing else in the run, and nothing you already approved." \
        "Reading an explanation changes no answer and does nothing to this machine; the same question comes back afterwards." \
        "Saying No leaves that one action undone. The run carries on and tells you what it could not do." \
        "No, Back, stopping, and re-running me do not undo changes you already approved."
      ;;

    nav.main)
      # The entry point is not a step inside a wizard, and the
      # About/Why/It does/If skipped template is the wrong shape for it: nobody
      # standing at the front door has asked "what does this one question do".
      # They have asked what the program is, what they are left holding, what it
      # will touch, and how to look without committing — four questions, four
      # labelled answers, in the order a stranger asks them.
      say ""
      say "  ${BOLD}What this is${RESET}"
      say "  conduck-connect is a setup script. It takes an AI gateway that is already"
      say "  running on this machine and connects it to the Conduck app on your phone,"
      say "  tablet, or Mac. \"Gateway\" is just the program your AI actually runs in —"
      say "  OpenClaw and Hermes are two of them, and so is anything that speaks the"
      say "  OpenAI API (Ollama, LM Studio, LiteLLM, vLLM, something you wrote"
      say "  yourself). If somebody installed one of those here for you, that is your"
      say "  gateway, and option 1 is yours."
      say ""
      say "  ${BOLD}What you end up with${RESET}"
      say "  Two things. An encrypted web address (one starting https://) that reaches"
      say "  your gateway from outside this machine, and a setup code — printed as a"
      say "  QR square you point your phone's camera at. One scan and the app is"
      say "  connected: address, key, and file settings all imported, nothing to"
      say "  retype. So keep the phone next to you, with Conduck already installed."
      say ""
      say "  ${BOLD}How long${RESET}"
      say "  Usually ten to twenty minutes the first time, and most of that is reading"
      say "  and deciding rather than waiting. Adding a second device afterwards takes"
      say "  under a minute."
      say ""
      say "  ${BOLD}What changes on this machine${RESET}"
      say "  At most four things: one setting switched on inside your gateway's own"
      say "  config file, an encrypted front door for it (Tailscale or Cloudflare do"
      say "  this for free), and — only if you ask for file transfer — one shared"
      say "  folder plus one small file server. You are shown the exact command, or"
      say "  the exact before-and-after text, and asked before each one."
      say ""
      # "No accounts, no telemetry" is absolute and stays unqualified. "Nothing goes
      # anywhere except your own gateway" is NOT true and must never be said here:
      # the sentence two lines up names Tailscale and Cloudflare, and choosing either
      # runs the operator's own client against that vendor. Claiming otherwise in the
      # same paragraph that names them is the kind of contradiction a skeptical reader
      # finds first, and it costs more trust than the reassurance buys. So this says
      # the part that is true absolutely, then names the one exception plainly.
      say "  No accounts, and no telemetry ever — there is no collection endpoint"
      say "  anywhere in this file. The only thing it talks to besides your own"
      say "  gateway is the front-door tool you pick, and it asks first."
      say ""
      # The menu is a hub — every action ends by OFFERING the list again, on `m` —
      # and a stranger cannot see that from three lines and a prompt. Without it,
      # "which of these three am I" reads as a one-shot commitment, which is
      # exactly the pressure that makes somebody guess. It says "offers", not
      # "returns": the default at that last question is to finish, and a panel
      # that promised an automatic return would be describing a keystroke the
      # reader has to press.
      say "  ${BOLD}If you pick the wrong one${RESET}"
      say "  It costs you the time and nothing else. Options 2 and 3 only ask"
      say "  questions and report — they change nothing at all — and every option"
      say "  ends by offering you this list again, so one wrong turn costs one"
      say "  action rather than the whole session. Setting up and pairing is the"
      say "  only option that changes anything, and it asks before each change."
      say ""
      say "  ${BOLD}To look without committing${RESET}"
      say "  Press q to stop, then run:"
      say "    ${BOLD}bash conduck-connect.sh --setup --dry-run${RESET}"
      say "  It asks the same questions, never asks for a password, and prints the"
      say "  list of things a real run would do — without doing any of them."
      say ""
      ;;

    nav.gateway)
      explain_panel \
        "Pick which AI gateway on this machine Conduck should talk to" \
        "A gateway is the program your AI actually runs in; the Conduck app is only the phone, tablet, or Mac front end for it. OpenClaw and Hermes are two such programs this script knows by name and can configure for you. Anything else that speaks the OpenAI API — Ollama, LM Studio, LiteLLM, vLLM, an adapter you wrote — is the third option." \
        "Looks in the usual install locations for OpenClaw and Hermes and reports what it found. Picking a name reads that gateway's own config file to learn its address and settings; it changes nothing yet." \
        "Setup cannot go on without knowing which program to point the app at." \
        "Coming back to this question changes only the route through the remaining questions. Anything you already approved stays applied." \
        "If somebody set this machine up for you, the name they used is the answer. If you installed something yourself and it is not called OpenClaw or Hermes, take the third option — it covers everything else."
      ;;

    nav.saved_profile)
      explain_panel \
        "Pick which already-paired gateway to show the setup code for again" \
        "Every finished setup leaves behind a small record of where that gateway lives and how to reach it — no passwords, just the routing. This is how you pair a second device without walking the whole setup again." \
        "Takes the one you pick, re-reads its password from wherever that password really lives, checks that the address still answers, and prints the setup code. This menu itself does nothing." \
        "No gateway is picked and no setup code is shown." \
        "The saved record is not rewritten, whichever one you pick." \
        "Pick the one whose name you recognise from the app. Picking the wrong one costs nothing — you can run this again."
      ;;

    nav.custom_gateway_pick)
      explain_panel \
        "Say whether this is a server you set up here before, or a brand new one" \
        "Each server is filed under a short internal name made from the name you typed, and that same internal name is used for its file service and its stored password. Retyping the name even slightly differently would build a SECOND server here rather than updating the first." \
        "Picking one from the list keeps its existing internal name and just asks for its current address and password. Picking the last option starts a new one, under a name not already in use." \
        "Nothing is picked and setup cannot continue past this question." \
        "Choosing changes nothing by itself: a server you picked is only rewritten once this run has verified it end to end." \
        "If you have paired this same machine's server before — even if its address has changed since — pick it from the list. Start a new one only for a server you have genuinely never paired."
      ;;

    check.continue_setup)
      explain_panel \
        "Go straight from a passing check into setup and pairing" \
        "The check just proved this address answers in the format the Conduck app needs. Setup is the next part: giving it an encrypted web address and printing the code your phone scans." \
        "Reuses the address and password already in memory from the check, then starts the normal setup questions — each change still asks first." \
        "The check ends here and nothing on this machine is set up or changed." \
        "The check did not store the password; setup will still verify the final address the app is actually given." \
        "Say yes. The check cost you the typing already, and setup asks before every change it makes."
      ;;

    gateway.custom.has_https)
      explain_panel \
        "Say whether your server already answers on an address starting with https://" \
        "The Conduck app talks only to encrypted addresses — that is what the s on the end of https means — and the encryption certificate has to be one your phone already trusts on its own. A server started at home normally answers only on the machine it runs on, which is not that." \
        "Yes asks you for that address next. No asks instead for the port number your server listens on locally, and then helps you put an encrypted address in front of it — Tailscale and Cloudflare both do that part for free." \
        "" \
        "Either answer by itself changes nothing about your server." \
        "Answer No, which is what Enter does. Unless you deliberately set up a domain name and a certificate for this server, or somebody handed you an https:// address for it, you do not have one — and No is the path that builds you one."
      ;;

    # For the https:// address prompt itself (20-gateway.inc.sh, the ask_url that
    # follows a Yes at gateway.custom.has_https). Its whole difficulty is that
    # people paste the address of a chat page, or an address with /v1 on the end.
    gateway.custom.address)
      explain_panel \
        "Type the https:// address that already reaches this server from outside" \
        "This is the address the app itself will call, from a phone that may be nowhere near this machine, so it has to work from the open internet or from your VPN — not just from this desk." \
        "Give the BASE address only, with no /v1 and no other path on the end: this script and the app add the rest themselves (a pasted /v1 tail is trimmed off for you). A trailing slash is trimmed too." \
        "" \
        "Nothing about your server or your proxy is reconfigured; the address is checked and then used." \
        "If you cannot name an https:// address you set up on purpose, you probably do not have one. Press b if it is offered, or stop with q and start again answering No at the previous question — setup will build you an encrypted address for free."
      ;;

    # For the "A short name for it (shown in the app)" prompts. The answer is a
    # label and nothing more — but a lossy short form of it becomes the permanent
    # id, so the derivation is stated in full rather than sketched. The cut at 32
    # characters is the half that actually surprises people: two descriptive names
    # that differ only in their tail land on ONE id, and a reader told merely that
    # spaces become hyphens has no way to predict it. Stating the whole rule here
    # is what makes it possible to pick a second name that will not collide; the
    # refusal screen says the same thing, but only after the collision.
    gateway.display_name)
      explain_panel \
        "Give this gateway a short name for your own benefit" \
        "It is a label, nothing else. It appears in the Conduck app's gateway list so you can tell this one apart from another, and it is what this script calls it the next time you run setup." \
        "Records the name for the setup code and for the saved record. It contacts nothing and configures nothing. A short form of the name — lowercased, with every character that is not a letter or a digit turned into a hyphen, and then cut to the first 32 characters — is put after \"custom-\" to make the id this machine files the gateway's settings, its file service and its stored password under. That id is the \"Filed under\" line on the review screen a few questions from now." \
        "" \
        "That cut is worth one moment's thought: two names that read as obviously different can produce the same id if they match for their first 32 characters, and this machine can only hold one gateway per id. Setup refuses the second one rather than overwriting the first, and names which gateway it collided with. You can change the display name later by re-running setup and picking this gateway; the id it was first given stays as it is, so its settings, service, and stored password all keep matching." \
        "Press Enter and take the suggested name. Nothing depends on it, and \"Mac mini\" or \"work agent\" beats a name you will not recognise in a month — or a long sentence whose first 32 characters are the same as the last gateway's."
      ;;

    gateway.custom.has_auth)
      explain_panel \
        "Say whether this server checks for a secret key before it answers" \
        "Most servers want a key — a long random string, sometimes called an API key or a bearer token — sent with every request, and refuse anyone who cannot produce it. Some are set up with no key at all, which means anyone who can reach the address can use it." \
        "Takes the key at a hidden prompt: nothing at all appears as you type, so a paste never lands on screen or in your scroll-back. The key rides inside the setup code your phone scans and is never written to this machine's saved record. Pressing Enter with nothing typed does not quietly mean \"no key\" — it opens a separate question that makes you say so." \
        "" \
        "No key means anyone who reaches the address can use whatever your gateway allows. Setup refuses to put a no-key server on a public address unless you explicitly override it." \
        "Look at how the server was started, or at the config file your gateway was given. If you were handed a long random string when it was installed, that is the key. If you never saw one, and the server only answers on this machine, it is probably keyless."
      ;;

    # For the hidden token prompts themselves (the custom-gateway key, OpenClaw's
    # and Hermes's, the two check commands' bearer prompt, and --show-code's
    # re-entry). It answers the one question the hidden prompt cannot: where does
    # this string come from.
    #
    # It must NOT promise one behaviour for Enter. Six prompts share this panel and
    # they part company on exactly that keystroke: three stop the run because the
    # gateway they are asking for cannot be keyless, one offers keyless behind a
    # separate confirmation, and the two check commands grade the server keyless
    # straight away. Naming one of the three would be false at four call sites and
    # read as authoritative at all six, so the panel points at the Enter clause the
    # prompt itself is already printing — the one statement that is right wherever
    # the reader is standing.
    gateway.token)
      explain_panel \
        "Paste the secret key your server checks on every request" \
        "Without it the server answers every request with a refusal, and the app would be paired to an address it can never use." \
        "Nothing appears on screen while you type or paste — that is deliberate, not a frozen prompt. The key travels inside the setup code your phone scans and is never written into the record this script saves, which is why --show-code has to ask you for it again." \
        "" \
        "Nothing on the server changes. If you later rotate the key, re-run setup or --show-code and pair the devices again with the new one." \
        "It is wherever your gateway was configured: the line in its config file or its start-up command that names a key or token, or the string whoever installed it wrote down for you. If your server genuinely has no key, Enter is safe to try — an empty answer is never read as a quiet yes here. The prompt line above says what it does: stop, offer keyless and make you confirm it, or grade the server keyless and say so."
      ;;

    # Three prompts share this panel and they do NOT share an Enter: the
    # three-way menu for a gateway being changed, a plain blank-means-blank prompt,
    # and — where the server reported exactly one model — a prompt with that name
    # already filled in. A flat "leave it blank" would be advice to delete the
    # single correct answer at the third, so the panel sends the reader to the
    # prompt's own Enter clause instead of naming one keystroke for all three.
    gateway.custom.model)
      explain_panel \
        "Choose which model name the app should send with every message" \
        "Some servers hold several models and insist that each request names the one to use; others have a single default and ignore what you name. A model name is a plain string like \"llama3.1\" or \"gpt-4o-mini\" — it is a label the server recognises, not a file you have to install." \
        "Records the name and sends it in the app's later requests. It does not download, install, or switch a model on the server." \
        "Where the prompt offers nothing, leaving it blank hands the choice to the server, which is right whenever the server has a default of its own." \
        "This is stored with the gateway, so changing it later means re-running setup for this gateway." \
        "Take whatever the prompt above says Enter does. Where your server reported exactly one model, that name is already filled in and is the answer; where nothing is offered, leave it blank — if the server needs a name it says so on the very first message, and re-running setup to add one takes a minute."
      ;;

    gateway.custom.port)
      # The one question in the wizard whose reader most often does not know what
      # the word in it means, so the panel starts from zero rather than from the
      # program's own point of view. What the number IS and where to look come
      # first; what setup then does with it is last, because nobody presses `i`
      # here to learn about the script.
      say ""
      say "  ${BOLD}What a port number is${RESET}"
      say "  One machine can run many programs that answer web requests at once. The"
      say "  port number is how it keeps them apart — think of one street address"
      say "  with numbered doors. Your AI server knocked on one of those doors when"
      say "  it started, and I need to know which one so I can send requests to it"
      say "  and to nothing else on this machine."
      say ""
      say "  ${BOLD}Where to find yours${RESET}"
      say "  It is the number after the last colon in the address your server prints"
      say "  when it starts up: listening on http://localhost:8080 means 8080. Look"
      say "  in the terminal window where you started it, or in the notes of whoever"
      say "  set it up."
      say ""
      say "  If the server names no address, these are the usual defaults:"
      say "    Ollama      11434        LiteLLM   4000"
      say "    LM Studio    1234        vLLM      8000"
      say "  (Hermes's own agent server is 8642 — but if you run Hermes, stop and"
      say "  start again choosing Hermes by name in Step 1, and I read its port"
      say "  out of its config for you.)"
      say ""
      # The detected-ports picker in front of this reader is a shortlist, not an
      # inventory, and both of its limits are invisible from the screen: it caps
      # its rows, and it only offers the port range people normally start servers
      # on. A reader whose server is missing concludes the machine is not running
      # it — the one wrong conclusion this panel exists to prevent — so this
      # section stays, and says WHY a real server can be absent from a list that
      # looks complete. It is worded for both call sites: the picker, and the
      # typed prompt reached by pressing `t` or by there being nothing to list.
      # No count and no port range are quoted, because both live in
      # 20-gateway.inc.sh and a number repeated here is a number that can drift.
      say "  ${BOLD}If a list of listening programs did not have yours${RESET}"
      say "  Where this machine has something obvious to offer, the question above"
      say "  shows a shortlist of it and a ${BOLD}t${RESET} row for typing a number it did not"
      say "  offer. The list is capped, and it skips the ports nobody starts an AI"
      say "  server on, so a server can be missing from it and still be running"
      say "  perfectly. To see everything this machine is listening on:"
      if [ "${OS:-}" = "Darwin" ]; then
        say "    ${BOLD}lsof -nP -iTCP -sTCP:LISTEN${RESET}"
      else
        say "    ${BOLD}ss -ltnp${RESET}   (or, if that is missing: ${BOLD}lsof -nP -iTCP -sTCP:LISTEN${RESET})"
      fi
      say "  Every listening program on this machine is printed with its port at the"
      say "  end of the address column. Yours is the line naming your AI server."
      say ""
      say "  ${BOLD}What I do with it${RESET}"
      say "  Only build the local address http://127.0.0.1:<your number>, which means"
      say "  \"this machine, that door\", and use it to check the server answers and to"
      say "  put an encrypted web address in front of it in the next step. Your server"
      say "  is not restarted, moved, or reconfigured, and the number is not saved"
      say "  anywhere until the whole setup succeeds."
      say ""
      say "  ${BOLD}Honestly unsure?${RESET}"
      say "  Run the command above and try the likeliest number. Guessing wrong is"
      say "  harmless: the next check simply reports that nothing answered there, and"
      say "  you come straight back to this question."
      say ""
      ;;

    gateway.custom.review)
      explain_panel \
        "Check the answers you have given before anything is applied" \
        "This is the last point before setup starts using these details, and the cheapest place to catch a typed-in mistake — a mistyped model name or the wrong address costs a whole run to discover later." \
        "Shows the answers back to you and waits. It does not contact your server or change anything at this point. \"Filed under\" is the one line you did not type: it is the id derived from the name, and it is what this machine's saved settings, file service and stored password are all named after — shown here because it is otherwise invisible until two gateways quietly share one." \
        "" \
        "Pressing b re-asks this short group of questions from the top and throws the draft away. Changes you approved earlier in the run stay applied." \
        "Read the address line. If it names a machine and a number you recognise, press Enter; if anything on the screen surprises you, press b — re-answering costs a minute."
      ;;

    gateway.openclaw.enable_chat)
      explain_panel \
        "Switch on OpenClaw's OpenAI-compatible chat endpoint" \
        "OpenClaw ships with this switched off. Without it the gateway looks perfectly healthy while the Conduck app has no route to send a message to — the single most common reason a setup that looked fine does not work." \
        "Runs OpenClaw's own config command to flip that one setting. If your config file is written in the JSON5 style, OpenClaw may rewrite it as plain JSON and drop any comments in it." \
        "The app will not be able to connect through this gateway." \
        "Set the same flag back to false and restart OpenClaw to reverse this one change."
      ;;

    gateway.openclaw.manual_enable_chat)
      explain_panel \
        "Switch on OpenClaw's chat endpoint yourself, on an install I cannot drive" \
        "Without that endpoint the gateway looks healthy while the Conduck app has no route to send a message to. Your OpenClaw is installed somewhere this script will not run commands against on your behalf." \
        "Prints OpenClaw's exact config command for you to copy and run, then the restart appropriate to how yours was installed. This script runs neither of them." \
        "Enter skips this step — the endpoint stays off, and the verification later in this run is expected to fail." \
        "Answering y only tells me you ran it — I cannot see whether you did. Neither answer undoes anything already applied. Once the command has run, the setting stays on until you set it back to false and restart."
      ;;

    gateway.hermes.accept_8645)
      explain_panel \
        "Carry on using Hermes port 8645 anyway" \
        "Hermes answers on two different doors, and they are not equivalent. 8645 is the plain proxy: it can chat, but it carries none of the agent's tools or skills. 8642 is the full agent server, which is normally what you want Conduck talking to." \
        "Pairs the chat-only route. Everything will appear to work; the agent simply will not be able to use its tools." \
        "Setup stops here so you can point API_SERVER_PORT at the full agent server first." \
        "Switching to the full agent server later means changing that setting in Hermes and re-running setup." \
        "Say no and fix the port. Chat-only is a real limitation you will run into within a day, and it is much easier to correct now than to diagnose later."
      ;;

    gateway.hermes.enable_api)
      explain_panel \
        "Switch on Hermes's OpenAI-compatible API server" \
        "That server is the route Conduck needs for full agent replies — the ones where the agent uses its tools rather than only chatting." \
        "Adds exactly the settings shown above to ~/.hermes/.env. If a key already exists there it is reused; if none exists one is created. A restart is offered afterwards, separately." \
        "The API server stays off and the verification later in this run is expected to fail." \
        "Delete the dated conduck-connect block from that file and restart Hermes to reverse this edit."
      ;;

    security.owned_file.chmod_0600)
      explain_panel \
        "Lock down a file that holds one of your secrets" \
        "As it stands, other accounts on this machine can open that file and read the key inside it." \
        "Runs the chmod 600 command shown above, which changes who may open the file. It does not read, move, or alter what is in it." \
        "The secret stays readable by those accounts, and setup warns you about it again." \
        "The restriction stays until you deliberately change it back."
      ;;

    gateway.openclaw.restart_chat|gateway.hermes.restart_api|file.openclaw.restart_tools|file.hermes.restart_config)
      explain_panel \
        "Restart the gateway now that its configuration has changed" \
        "A running program keeps using the settings it read at start-up, so the edit you just approved has no effect until it reads them again." \
        "Restarts that one gateway service. It is briefly unavailable while it comes back — a few seconds on a normal install." \
        "The edit stays on disk, but the running gateway keeps its old behaviour until something restarts it." \
        "A restart does not undo or rewrite the configuration change; it only makes it take effect."
      ;;

    gateway.hermes.manual_restart_api|file.hermes.manual_restart)
      explain_panel \
        "Restart Hermes yourself, the way this machine starts it" \
        "The edit you approved does not reach the running Hermes until it reloads its settings, and there is no single restart command that is correct on every machine." \
        "Prints a suggested restart command for you to copy and run. This script does not run it on this path." \
        "Enter skips this step — the file stays changed, but the live Hermes keeps its old behaviour." \
        "Answering y only tells me you restarted it — I cannot see whether you did. Neither answer undoes anything already applied, and a restart does not undo or rewrite the edit either; it only makes it take effect."
      ;;

    file.openclaw.allow_tools)
      explain_panel \
        "Let the OpenClaw agent read and write files in the shared folder" \
        "Moving files into a folder is not enough on its own: OpenClaw keeps a separate list of what its agent is allowed to do, and if reading and writing files is not on that list, uploads simply sit there unopened." \
        "Shows the exact policy before and after, then applies only the keys you approved, through OpenClaw's own config command. A restart is offered afterwards, separately." \
        "Chat still works. The agent may not be able to open what you send it or hand a finished file back." \
        "Put the shown earlier values back and restart OpenClaw to reverse this policy edit."
      ;;

    file.openclaw.manual_tools)
      explain_panel \
        "Set OpenClaw's file permissions yourself, on an install I cannot drive" \
        "The agent needs reading and writing on its allowed list before a shared folder is of any use to it, and your OpenClaw is installed somewhere this script will not run commands against on your behalf." \
        "Prints the exact OpenClaw config commands for you to copy and run, then the restart appropriate to your install. This script runs neither." \
        "Enter skips this step — chat still works, but the agent may not be able to open uploads or return files." \
        "Answering y only tells me you ran them — I cannot see whether you did. Neither answer undoes anything already applied. To reverse the policy edit once it is in, put the shown earlier values back and restart."
      ;;

    file.openclaw.keep_unready)
      explain_panel \
        "Carry on with file transfer even though OpenClaw is not allowed to use it" \
        "The plumbing that moves the bytes can be perfectly healthy while the agent on the other end is still forbidden from opening what arrives." \
        "Keeps building the file lane without touching OpenClaw's permissions. A real end-to-end test later in this run still has to pass before file transfer reaches your setup code." \
        "File transfer is left out of this run. Chat is unaffected either way." \
        "Fix the permissions and re-run setup. This choice does not undo anything already applied." \
        "Say no and let setup fix the permissions — it shows you the exact change first, and file transfer is the whole reason to run this step."
      ;;

    file.hermes.apply_config)
      explain_panel \
        "Point Hermes at the same folder Conduck will use" \
        "The agent and the file server have to be looking at one folder, not two — and the agent's own permissions have to include file tools, or it will never open what you send." \
        "Applies exactly the before-and-after shown above for terminal.cwd and, only where it is needed, the file toolset. If you asked for recall removal at the previous question, that same single edit removes only the entries you were shown." \
        "The bytes may move while Hermes cannot open uploads or return finished files." \
        "Put the shown earlier values back and restart Hermes to reverse this edit."
      ;;

    gateway.hermes.remove_recall)
      explain_panel \
        "Take Hermes's own memory tools out of the API server's allowed list" \
        "Conduck sends the whole conversation with every message, so the thread is already complete. Hermes's recall can then add older or duplicate material the app never sent, which shows up as the agent answering something you did not ask." \
        "Removes only memory and session_search from the exact list shown above, then offers a restart separately." \
        "Pairing still works; the API server keeps its own cross-conversation recall." \
        "Every client using this same API server loses that recall — Hermes on the command line and its messaging memory are untouched. Put the shown entries back and restart to reverse it."
      ;;

    gateway.hermes.show_recall_manual)
      # Deliberately NOT shaped like the removal panel above it. This question
      # changes nothing at all — it only decides whether a long set of by-hand
      # YAML instructions is printed — and a panel that described it in the
      # language of an action would teach the operator to fear a `y` that is
      # free. What it prints depends on the shape of the config: an exact
      # replacement list where one can be proven safe, otherwise what to look for.
      explain_panel \
        "Print by-hand instructions for narrowing what Hermes remembers" \
        "Where this script cannot make the edit and be sure it is safe, the change is yours to make — and the instructions run long enough to be worth asking before filling the screen with them." \
        "Prints text and nothing else: what to change in ~/.hermes/config.yaml, the exact replacement list wherever one can be proven not to drop toolsets you configured, and what the simpler global alternative costs you. It writes nothing, restarts nothing, changes no file." \
        "Nothing happens and nothing changes. What is already on screen stays, and pairing continues either way." \
        "Nothing to reverse — no file is touched. Re-run this script whenever you want the instructions again." \
        "Say yes. It only prints; you can read it and ignore it."
      ;;

    file.hermes.remove_recall)
      explain_panel \
        "Include the memory-tool removal in the one combined Hermes edit" \
        "Conduck sends the whole conversation with every message, so Hermes's own recall can add older or duplicate material the app never sent." \
        "Stages the removal of only memory and session_search, to be shown in the combined review coming next. It changes no file and restarts nothing here." \
        "The review coming next leaves the allowed list alone unless you approve its exact combined edit." \
        "The next Apply question makes one single edit and then offers the restart. Every client using this same API server is affected once you approve it."
      ;;

    file.openclaw.guidance|file.hermes.guidance)
      # Shared with OpenClaw, whose block carries no PDF rule, so nothing here
      # names a specific command: the accurate statement for both agents is that
      # the block is text and may point the agent at tools it already has.
      explain_panel \
        "Add a short set of file-handling instructions for your agent to read" \
        "An agent that is handed a file it cannot see the point of tends to answer from the filename instead of opening it. This block tells it that uploads are already sitting on its own disk, how to read them, and where to write a finished file so Conduck can offer it back to you." \
        "Adds or refreshes only the marked Conduck section of the agent's instruction file; everything outside those two markers is left exactly as it was. The block is instructions, not permissions: it installs nothing and grants nothing, though it can point the agent at tools it already has, with the access it already has." \
        "Files may move perfectly while the agent mishandles them — answering from a filename it never opened, or producing nothing you can download." \
        "New agent conversations pick the block up. Delete the block, including both marker lines, to remove it."
      ;;

    exposure.tailscale.make_private)
      explain_panel \
        "Give the gateway an encrypted address only your own devices can reach" \
        "Conduck needs an https:// address with a certificate your phone already trusts. Tailscale hands you one for free, and keeps the gateway invisible to everyone outside your own network of devices. Tailscale's own name for this is \"Serve\"." \
        "Goes on to show you the exact Tailscale command and ask about it separately. If you approve it there, an encrypted address on your own private network is pointed at your gateway's local door. Every device running Conduck then needs to be signed in to that same Tailscale network; an Apple Watch rides along on its nearby iPhone." \
        "The private address is not created, or an existing public one is left exactly as it is." \
        "If this run later has to undo its network changes, the exact command to switch it off (or to put back what was there before) is printed for you. Nothing else on this machine is touched." \
        "This is the safer of the two Tailscale choices, and you can re-run this script and switch later. Pick it unless you specifically need a standalone Apple Watch, or need to connect from a device you cannot install Tailscale on."
      ;;

    exposure.tailscale.make_public)
      explain_panel \
        "Give the gateway an encrypted address anyone on the internet can reach" \
        "A public address means no Tailscale app on your phone, and it means an Apple Watch works on its own with no iPhone nearby. Tailscale's own name for this is \"Funnel\"." \
        "Goes on to show you the exact Tailscale command and ask about it separately. If you approve it there, a public encrypted address is pointed at your gateway's local door. Anyone who finds that address can knock on it; your gateway's secret key is the only lock, which is why setup refuses to do this for a gateway that has no key." \
        "The gateway stays private, or unreachable by this route." \
        "Switch that public address off, or put back the mapping setup shows you, to reverse this one change. Nothing else is affected." \
        "Choose the private option instead unless you need a standalone Apple Watch or a device that cannot run Tailscale. You can re-run this script and change your mind."
      ;;

    exposure.cleanup.stale_public)
      explain_panel \
        "Close an older public address that still points at this same service" \
        "Choosing a private address is not actually private while a public one from an earlier run is still open on a different door pointing at the same place." \
        "Switches off only the one public address named above, once you approve it. Addresses belonging to other services are left alone." \
        "That older public address stays reachable from the internet." \
        "This is deliberate tidying-up, and setup will not recreate it if this run later undoes its own changes. Bringing it back means running a new public command on purpose." \
        "Say yes. If you had wanted that address you would not be choosing a private one now."
      ;;

    exposure.cleanup.orphaned)
      explain_panel \
        "Deal with a network change an interrupted earlier run left behind" \
        "This script keeps a note of network changes it makes, so that a run stopped halfway does not quietly leave your gateway reachable in a way you did not choose. That note says an earlier run may have left this exact door open." \
        "Re-reads what Tailscale reports right now and, with your approval, applies only the recorded cleanup — or puts back the private mapping that was there before — for that one door." \
        "The door may stay open and the note is kept for a later run to deal with." \
        "This repairs the one named address only. It does not restore config files, restarts, commands you ran, or tidy-ups you asked for on purpose." \
        "Say yes. It closes something an interrupted run opened, and nothing you set up deliberately depends on it."
      ;;

    exposure.tailscale.privileged_retry)
      explain_panel \
        "Run the shown Tailscale command again with administrator rights" \
        "Tailscale refused the first attempt. The usual reason is that this account is not permitted to change which addresses Tailscale publishes." \
        "Prints the exact command with sudo, doas, or root in front for you to copy and run. This script never raises its own privileges silently." \
        "Enter skips the retry — the change Tailscale refused stays unmade." \
        "Answering y only tells me you ran it — I cannot see whether you did. Neither answer undoes anything already applied."
      ;;

    exposure.tailscale.apply)
      explain_panel \
        "Run the Tailscale command shown above" \
        "This is the step that actually turns the reachability you chose into a live address. Everything before it was preparation." \
        "Runs exactly the command printed above, then asks Tailscale what its state is now rather than assuming the command worked." \
        "No new address is created; anything already in place stays as reported above." \
        "Setup records exactly what this address looked like beforehand, so it can be put back if the run has to undo itself. It records nothing about unrelated changes to this machine."
      ;;

    exposure.rollback.failed_run)
      explain_panel \
        "Undo the network changes this failed run made" \
        "This run never got as far as printing a setup code, so an address it opened or replaced along the way should not be left behind without you knowing." \
        "Runs only the undo commands listed above, and then checks each affected door against what Tailscale actually reports." \
        "An address this run opened may stay live. The exact commands to close it by hand are printed again so you can do it yourself." \
        "This cleanup covers recorded network addresses only. Config edits, restarts, instruction blocks, and commands you ran yourself stay in place." \
        "Say yes. These are changes this run made and then could not finish using."
      ;;

    # The hostname QUESTION, which is not the route COMMAND below it and shares
    # nothing with it but the word Cloudflare. Its reader is being asked to invent
    # a name; the route panel's reader is being asked whether they ran something.
    # They part company on Enter most of all: here Enter abandons Cloudflare and
    # returns to the four ways of getting an encrypted address, which is the right
    # answer for the commonest reader of this prompt — somebody who picked option 3
    # without a domain in a Cloudflare account, for whom two of the other three
    # options cost nothing and need no domain at all.
    exposure.cloudflare.hostname)
      explain_panel \
        "Invent the hostname you want this gateway to answer on" \
        "Cloudflare routes by name, so before anything can be pointed at your gateway it needs a name to point. It is yours to choose — a subdomain of a domain that is already in your Cloudflare account, shaped like gateway.yourdomain.com — and it does NOT have to exist yet. The step straight after this is the command that creates it." \
        "Records the name and nothing else. Nothing is contacted, nothing in your Cloudflare account changes, and no DNS record is created by typing it here. A pasted https:// address is trimmed back to just the host part for you." \
        "Enter — a blank answer — leaves this path and puts the four ways of getting an encrypted address back on screen, with nothing changed by having looked at this one." \
        "Nothing to reverse: no route exists until you run the command on the next screen, and the certificate for this hostname stays Cloudflare's business, renewals included." \
        "This path only works if you already manage a domain inside a Cloudflare account. If you do not — or you are not sure what that would mean — press Enter and take Tailscale from the menu instead: it gives you a trusted encrypted address for free and needs no domain of your own."
      ;;

    exposure.cloudflare.gateway)
      explain_panel \
        "Add a Cloudflare route that points a hostname at this gateway" \
        "Cloudflare needs to be told which of your hostnames belongs to this service and where on this machine to forward it. Only you can make that change — it lives in your Cloudflare account, not on this machine." \
        "Prints the command for you to copy and run. This script never changes Cloudflare configuration itself." \
        "Enter skips this step — no Cloudflare hostname is connected to this gateway, and setup cannot verify an address that does not exist yet." \
        "Answering y only tells me you ran it — I cannot see whether you did. Neither answer undoes anything already applied."
      ;;

    file.cloudflare.route)
      explain_panel \
        "Add a Cloudflare route for file transfer" \
        "File transfer runs as its own small server on a separate door, so it needs its own hostname pointed at it — the gateway's hostname will not carry it." \
        "Prints the command for you to copy and run. This script never changes Cloudflare configuration itself." \
        "Enter skips this step — file transfer is left out, or stays unreachable through Cloudflare. Chat is unaffected." \
        "Answering y only tells me you ran it — I cannot see whether you did. Neither answer undoes anything already applied."
      ;;

    exposure.own_https)
      # Reachable as the `i` of the own-HTTPS address prompt. It carries three
      # separate facts — what qualifies as an address, what that address has to
      # REACH, and the one failure that looks like a broken gateway but is not —
      # and the five-field template flattens them into one paragraph nobody
      # finishes. The thing this path has never said anywhere is the middle one.
      say ""
      say "  ${BOLD}When this is your option${RESET}"
      say "  Your gateway already sits behind a reverse proxy you configured, or on"
      say "  a rented server with a domain name of your own. The certificate has to"
      say "  be one your phone already trusts by itself — a free Let's Encrypt one"
      say "  qualifies, a certificate you signed yourself does not, and there is no"
      say "  way for the app to make an exception for it."
      say ""
      say "  ${BOLD}What the address has to reach${RESET}"
      say "  Give the BASE address, with no /v1 and no other path on the end: the"
      say "  script and the app add the rest themselves. Whatever sits in front has"
      say "  to pass requests through to the gateway unchanged, so that"
      say "    <your address>/v1/models"
      say "  answers with the gateway's own list of models. If that one address"
      say "  works in a browser, the rest of this will work."
      say ""
      say "  ${BOLD}The trap worth knowing about${RESET}"
      say "  Some servers — Ollama is the common one — look at which hostname a"
      say "  request was addressed to and refuse anything they do not recognise."
      say "  The tell is that the server answers perfectly on this machine and"
      say "  refuses the identical request through your public address. Fix it at"
      say "  the proxy by rewriting that line; in nginx that is"
      say "    ${BOLD}proxy_set_header Host 127.0.0.1:<the gateway's port>;${RESET}"
      say ""
      say "  ${BOLD}What setup does with it${RESET}"
      say "  Checks the certificate, records how far the address reaches, and uses"
      say "  it in the setup code. It never reconfigures your proxy or your"
      say "  certificate — those stay entirely yours, renewals included."
      say ""
      say "  ${BOLD}Honestly unsure?${RESET}"
      say "  If you did not deliberately set up a domain name, a certificate, and a"
      say "  proxy for this server, this is not your option. Go back and let setup"
      say "  build you an encrypted address instead — Tailscale and Cloudflare both"
      say "  do it for free."
      say ""
      ;;

    file.setup.enable)
      explain_panel \
        "Set up optional file transfer between Conduck and your agent" \
        "Without it, chat still works and pasted images still work — but anything you attach reaches the agent as text inside the conversation rather than as a real file its tools can open, so a PDF, a spreadsheet, or a zip is of no use to it. It is also what lets the agent hand a finished file back for you to download." \
        "May create or reuse one shared folder, a small password-protected file server that only answers on this machine, a couple of files holding its password, and a separate encrypted address for it. Each of those asks first." \
        "Chat works exactly as before, including content that fits inside the message. Your setup code simply carries no file server." \
        "The shared folder is often the agent's own working folder, with its own files in it. Stop the file service and look inside the folder before deleting anything." \
        "Say yes if you ever plan to hand the agent a document. It is the part of setup people come back to add later, and adding it later means walking the whole wizard again."
      ;;

    # For the file lane's own https:// address prompt (40-file-lane.inc.sh). It
    # is a DIFFERENT address from the gateway's, and that is the mistake it
    # exists to prevent.
    file.address.url)
      explain_panel \
        "Type the https:// address that reaches the file server" \
        "File transfer runs as its own small server on its own door, so it needs its own address. The gateway's address will not reach it, and pasting the gateway's address here produces a setup code that fails on the first attachment." \
        "Records the address, checks that the file server actually answers on it, and puts it in the setup code alongside the gateway's. Give the base address with no path on the end." \
        "Pressing Enter with nothing typed goes on to a question about leaving file transfer out of this setup code entirely." \
        "Nothing is reconfigured; the file server keeps running either way." \
        "If you just created a Cloudflare route or a tunnel for the file server, this is that hostname. If you cannot name one, press Enter: the next question asks whether to leave file transfer out, and answering y there does it. Chat is unaffected either way and you can add it later."
      ;;

    file.address.skip)
      explain_panel \
        "Deliberately leave a working file lane out of this setup code" \
        "A blank answer can mean you chose to leave file transfer out — but it can just as easily be a paste that did not land. This question exists so that one stray Enter cannot silently throw away a file lane that already passed its tests." \
        "Yes leaves file transfer out of this setup code and out of the saved record. It does not stop the file service, remove its folder, or undo a route you created." \
        "No — which is what Enter does — takes you back to the address question so you can try again. After three blank answers in a row it stops asking and leaves file transfer out, saying so on screen." \
        "Adding file transfer to a setup code afterwards means re-running setup. Pressing q stops the run and leaves everything already approved in place." \
        "Press Enter and try the address again. Leaving out a lane that already works is almost never what someone means to do."
      ;;

    file.folder.override)
      # This panel answers TWO prompts, and they differ on the one thing an
      # operator reading it is about to do. OpenClaw and Hermes offer a default the
      # wizard knows and may create; every other gateway offers none and refuses a
      # path that is not already on this machine, because only the agent's own
      # folder can be the right answer there. A panel that promised creation would
      # be read by exactly the operator the refusal then bounces.
      explain_panel \
        "Name the one folder that Conduck and your agent both use" \
        "Everything you attach lands in this folder, and everything the agent finishes has to be written into it to come back to you. So it has to be a folder the agent itself already reads and writes — not a new folder chosen for tidiness, which the agent would never look in." \
        "Records one absolute path (a path starting with /). On OpenClaw and Hermes, whose working folder this script knows, a brand new lane may create that folder with private permissions. On any other gateway the folder has to exist on this machine already and is refused if it does not; an existing folder keeps whatever permissions it has either way." \
        "Where a default is shown, that default is used. Where none is shown — every gateway other than OpenClaw and Hermes — there is nothing to fall back on, so a blank answer is refused and the question comes round again." \
        "This folder may hold your own files or the agent's. Going back, stopping, and re-running never delete it. At the prompt with no default, q stops the run and leaves everything already approved in place." \
        "Take the suggested folder where one is offered. Where none is, it is the folder your agent already works in — the one it saves things into when you ask it to write a file."
      ;;

    file.agent.unproved)
      # The panel is one string for seven failure categories, so it names none of
      # them and points at the screen that does. Asserting "the agent did not read
      # the test file" here would be false for the categories where no agent was
      # ever contacted — a file server that refused the probe, a chat request that
      # never returned, a temp file this script could not stage.
      # "No" is described as what it actually runs: drop_file_lane rolls back the
      # HTTPS exposure this run applied for the lane. A blanket "nothing you
      # approved is touched" is read one line before the rollback prints.
      explain_panel \
        "Include a file server the agent never proved it can actually use" \
        "The bytes moved through the folder, but the test that proves your agent can USE what lands there did not pass. That is what a server with no file tools always looks like — and it is also what a wrong folder, an agent in a container, one failed turn, or a file server that refused the test looks like. The screen you came from names which step fell short." \
        "Yes puts the file server in this setup code. The code has no way to carry a caveat, so the Conduck app will show file transfer as working. No leaves it out and switches off an address this run opened for it, so nothing stays reachable that the code does not use." \
        "Attachments stay inside the message in Conduck. The file service, its folder, and its contents keep running untouched; an address this run opened for it is switched off again, and anything it replaced is put back." \
        "Either answer leaves the running file server exactly as it is. Adding it to a setup code afterwards means re-running setup." \
        "Say no. A setup code that promises file transfer the agent cannot use fails later, in the app, where the reason is much harder to see than it is here."
      ;;

    file.unit.repair_envfile|file.service.move_port)
      explain_panel \
        "Repair a file server that this script set up earlier" \
        "Its saved definition is incomplete, unsafe to start again, or is fighting with another file server this script created. Reusing it as it stands would fail in a way that looks like a gateway fault." \
        "Rewrites only the one named conduck-files service, or moves it to the free door shown above, and then checks that the live service came back." \
        "File transfer stays unavailable, or keeps running from the broken definition." \
        "The service and its password file stay on this machine until you stop and remove them deliberately." \
        "Say yes. This service was created by this script and is only used by it, so repairing it affects nothing else you run."
      ;;

    file.exposure.make_public)
      explain_panel \
        "Let the file server be reached from the open internet" \
        "Your gateway is on a public address, so a file server that only your private network can reach would leave attachments broken everywhere except at home." \
        "Goes on to show you the exact command and ask about it separately. If you approve it there, the file server gets its own public encrypted address. Anyone who finds it reaches a login prompt; the file password is the only lock." \
        "File transfer stays private, or is left out of the setup code. Chat is unaffected." \
        "This approval covers the file server's address only. Use the switch-off command shown to reverse it."
      ;;

    file.exposure.keep_private)
      explain_panel \
        "Keep file transfer private even though the gateway is public" \
        "There is no free public door left for it, but the existing private address still works perfectly for devices signed in to your own Tailscale network." \
        "Keeps the current private address and puts that narrower one in the setup code. It creates no new public address." \
        "File transfer is left out of the setup code entirely; public chat still works." \
        "Attachments will work only on devices connected to your Tailscale network. An Apple Watch away from its iPhone cannot reach a private address." \
        "Say yes if the devices you actually use are on your Tailscale network. Say no only if you need attachments from a device that is not."
      ;;

    file.service.enable_linger)
      explain_panel \
        "Keep the file server running after you log out and after a reboot" \
        "On Linux, a service started under your account normally stops the moment your last session ends. The result is file transfer that works today and quietly fails next week, while chat keeps working — which makes it very hard to connect to a cause." \
        "Runs the loginctl enable-linger command shown above. This is the one command in setup that may ask for your administrator password." \
        "File transfer works only while that account has an active session, and may not come back after a reboot." \
        "Run loginctl disable-linger for that account to reverse this setting."
      ;;

    verification.gateway_only)
      explain_panel \
        "Print a setup code for chat only, leaving out the file transfer that failed" \
        "A healthy gateway can still give you everything except attachments, and a working chat today is usually worth more than a perfect setup tomorrow." \
        "Leaves the file server out of this one setup code. It does not delete the saved lane, its service, its folder, or its password." \
        "No setup code is printed at all until either the file transfer is fixed or you make this choice." \
        "The saved record keeps its file lane, so the next --show-code run checks it again — fix the cause and it comes back on its own." \
        "Say yes. You get a working app now, and nothing about the file lane is thrown away."
      ;;

    verification.image_ignored)
      explain_panel \
        "Pair a gateway whose reply did not reflect the test picture" \
        "This is the one failure the app cannot show you later: a photo comes back as an ordinary, confident reply that does not reflect it, and the setup code carries no field that could warn the app about it — so this screen is the only place it can be said. What was measured is that two freshly drawn pictures were not read back; whether they never reached an engine or reached one that could not read them is not visible from here." \
        "Yes prints the code and pairs the gateway exactly as it is; nothing about this finding is recorded in the code, in the app, or in the saved profile. No ends this run without a code — which is a failed verification like any other, so a file lane is left out of this run and any network exposure this run applied for it is rolled back, and you are offered the commands to undo the rest." \
        "Enter means No. Your gateway is not reconfigured either way: this question is about whether a code is printed, not about changing the server." \
        "Re-running verifies again from scratch, so fixing the gateway — sending pictures to an engine that can see them, or refusing them with HTTP 400 and code \"image_unsupported\" — clears this without any further undo." \
        "Say no. Nothing is lost by stopping here: pair once the pictures come back, and until then you have not built a habit of sending photos to something that quietly drops them."
      ;;

    *)
      explain_panel \
        "Review the action described just above this prompt" \
        "Your answer controls only that one action — nothing else in the run." \
        "Reading this explanation changes no answer and does nothing to this machine; the same prompt comes back." \
        "Declining or stopping leaves that one action undone." \
        "No, Back, stopping, and re-running me do not undo changes you already approved."
      return 0
      ;;
  esac
}

# --------------------------------------------------------- opening blocks --
#
# Panels that describe a whole COMMAND rather than one question. They read as
# introductions, so they belong at the top of the command they describe, before
# it asks anything — not behind an `i` at a prompt that has not happened yet.
# Each is a plain function, which means `explain_prompt` will also accept its
# name wherever a prompt inside that command wants it as its `i` copy.

# Print at the top of --check-server, before the first question.
explain_check_server() {
  say ""
  say "  ${BOLD}What this check answers${RESET}"
  say "  Whether the Conduck app, as it ships today, can talk to the server you"
  say "  point me at — can it read the server's list of models, and does a real"
  say "  reply come back in the shape the app expects."
  say ""
  say "  ${BOLD}What it changes${RESET}"
  say "  Nothing, on this machine or on the server. But it is not silent: it sends"
  say "  real requests, including one real chat message. On a paid model that"
  say "  costs a little quota, and the message may appear in your provider's or"
  say "  your server's own history."
  say ""
  say "  ${BOLD}What a pass means${RESET}"
  say "  That the app can use this server. It is not the stricter grade that"
  say "  software written specifically for Conduck has to meet — that is what"
  say "  --check-adapter is for."
  say ""
}

# Print at the top of --check-adapter, before the first question.
explain_check_adapter() {
  say ""
  say "  ${BOLD}What this check answers${RESET}"
  say "  Whether software built specifically for Conduck meets the adapter rules:"
  say "  stricter requirements on how it handles keys, replies, model lists, and"
  say "  streaming than generic OpenAI-compatible software has to meet."
  say ""
  say "  ${BOLD}What it changes${RESET}"
  say "  Nothing on this machine. It sends real requests, including deliberately"
  say "  wrong-key ones to check they are refused. With the file profile enabled"
  say "  it also writes and then removes a few clearly named test files."
  say ""
  say "  ${BOLD}Not the right check?${RESET}"
  say "  If the software was NOT written for Conduck — OpenClaw, Hermes, Ollama,"
  say "  LiteLLM, vLLM — use ${BOLD}--check-server${RESET} instead. Those legitimately do"
  say "  things the adapter rules forbid, so failures here would mean nothing."
  say ""
}

# Print before live verification starts, in setup and in --show-code. It is the
# only place the tool warns that verification is not free.
explain_live_verification() {
  say ""
  say "  ${BOLD}Why I verify before printing anything${RESET}"
  say "  A setup code should only ever point at a route the app can genuinely use."
  say "  Finding out in the app, on a phone, is much harder to diagnose than"
  say "  finding out here."
  say ""
  say "  ${BOLD}What that costs${RESET}"
  say "  I ask the gateway for its model list and then send one real chat message."
  say "  On a paid model that uses a little quota, and the message can appear in"
  say "  your provider's or your server's logs and history. If file transfer is"
  say "  set up, I also make a few authenticated test requests and have the agent"
  say "  copy one small test file."
  say ""
  say "  ${BOLD}Afterwards${RESET}"
  say "  Test files are deleted. If I cannot prove a deletion worked, I print the"
  say "  exact filenames so you can check yourself. Nothing you already approved"
  say "  is undone by a verification failure."
  say ""
}

# Print at the top of --show-code, before the profile picker.
explain_show_code() {
  say ""
  say "  ${BOLD}What this does${RESET}"
  say "  Re-shows the setup code for a gateway you already paired, so you can add"
  say "  another phone, tablet, or Mac without answering the setup questions"
  say "  again. This is the way to pair a second device."
  say ""
  say "  ${BOLD}What it changes${RESET}"
  say "  No configuration, anywhere, and it never rewrites what it reads. It does"
  say "  send live requests to check the address still works before handing you a"
  say "  code — see the note about quota when it gets there."
  say ""
  say "  ${BOLD}Why it may still ask you something${RESET}"
  say "  Secrets are deliberately not stored on this machine, so a gateway with a"
  say "  secret key asks you to paste it again. That is the price of not keeping"
  say "  your key in a file here."
  say ""
}

# Print alongside the setup code itself, at the moment it appears on screen.
# It is the only place the tool says what the code actually is.
explain_setup_code_secrecy() {
  say ""
  say "  ${BOLD}Treat this code like a password.${RESET} It carries your gateway's secret key,"
  say "  and the file password when file transfer is set up. Anyone who photographs"
  say "  the QR square, or copies the text, has exactly the access those credentials"
  say "  give — until you change them at the gateway. Do not paste it into a chat,"
  say "  an issue, or a screenshot."
  say ""
  say "  What is saved on this machine is only the routing — the address, the"
  say "  transport, the model name. No secret is written to disk by this script,"
  say "  which is why re-showing the code later asks you for the key again."
  say ""
}
