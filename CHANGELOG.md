# Changelog

Notable changes to `conduck-connect`. Format loosely follows [Keep a Changelog](https://keepachangelog.com/); versions track the script's own `VERSION`.

## [Unreleased]

- **Setup will no longer hand you a pairing code for a gateway that swallows
  photos.** Nothing stopped one before: `--check-server` printed *image input:
  IGNORED* and still returned PASS, `--check-adapter --deep` failed the same
  gateway and then offered *pair it; a failed grade here doesn't block that*, and
  setup itself never asked. So a gateway that dropped every picture paired
  cleanly and the owner found out the first time a photo vanished mid-conversation
  — the one failure the app cannot show, because a dropped picture comes back as
  an ordinary confident reply and the pairing code has no field to warn anything.
  Every verification now makes one more real chat turn carrying a small picture
  the script draws itself — four random digits, a couple of kilobytes — and asks
  for the digits back. It runs on every gateway kind and by every route to a code:
  `--setup`, both check-to-setup handoffs, and `--show-code`. It addresses the
  final app-facing URL with the model the code is about to name, so whatever HTTPS
  front, tunnel or proxy sits in the way is part of what gets tested.
  **What each answer costs you:** the digits read back, or a refusal the app
  recognizes (`400` + code `image_unsupported`), and the run passes with a line
  saying which — a text-only server that declines honestly is not a problem and is
  never treated as one. A body-size cap (`413`), an error nobody can classify, or
  a turn that never completed are reported and pass: a run that measured nothing
  may not convict, so a dropped tunnel is never reported as a gateway that loses
  photos. Only one answer withholds a code — a confident reply that quotes neither
  picture, asked twice with freshly drawn digits — and it asks rather than
  decides. **Enter means no.** The wizard cannot know what it is talking to: a
  purpose-built adapter that dropped the picture and a plain Ollama whose model
  simply cannot read four small digits answer identically from out here, and the
  second owner did nothing wrong. So the finding is reported for what it is —
  photos are *unverified*, not proven broken — and the same loud, default-No
  question is asked however you got here, including from `--check-adapter`. That
  route additionally gets pointed at `--check-adapter --deep`, which is where the
  wire is graded strictly and where this result is red and exits nonzero.
  Answering yes prints the code and says plainly that this screen is the only
  record; the pairing screen repeats it beside the code. A run with no terminal to
  ask on stops instead of printing a question into a log, and says why.

- Tracks adapter contract **revision 1.5**. The revision resolves a contradiction
  between the contract's prose and its own conformance checker over one image
  rule: a CURRENT-turn image has exactly two conforming outcomes, forward it to
  the engine or reject the request with `400` + code `image_unsupported`, and a
  `200` the engine produced without seeing the image fails whether it is silent
  or carries a substituted note. `--check-adapter --deep` has graded it that way
  since revision 1.3, so **no check changes behaviour here** — an adapter that
  passed before passes now, and the number this check reports is simply the
  revision whose text it has been enforcing.

- **A failed image probe stops naming a cause it cannot see.** `--check-adapter
  --deep` reported a reply without the probe's digits as *the engine never saw the
  image — it was silently dropped somewhere*, and `--check-server` said photos are
  *silently unseen*. From outside, that reply has two causes that look identical:
  the image never reached the engine, or it reached one that could not read the
  glyphs. Two adapters with different internals produced that same verdict on a
  live run, and the one that was forwarding correctly went auditing a delivery
  path that worked. Both messages now say what the probe actually establishes —
  this run could not verify the engine used the image — and name both causes so
  you check both. The verdicts are unchanged: `--check-adapter --deep` still fails
  closed on an unproven sighting, with the same two ways out (forward the image,
  or decline with `400` + code `image_unsupported`), and `--check-server`'s image
  result stays informational.

- **A tool-policy key written as the wrong type is reported instead of vanishing.**
  `{"tools": {"deny": "group:fs"}}` — the bare string where OpenClaw expects a
  list — was read as *no deny list at all*, and a config whose author had just
  switched their agent's file tools off came back as *OpenClaw's file-tool settings
  look ready (read/write allowed, profile: coding)*. `allow`, `alsoAllow`, `deny`,
  a `profile` that is not a name, and a whole `tools` block that is not an object
  all take the same route now: the wizard names the key, changes nothing, and
  leaves it with you — the same posture it already takes toward a list holding
  entries it cannot faithfully rewrite. A JSON `null` still means *unset* and is
  read exactly as before.

- **The unrecognised-profile verdict stops ending on the green verdict's line.**
  It says it cannot tell which file tools that profile grants and that nothing was
  changed, then closed on *The live file test later will confirm file access.* —
  the sentence the ready verdict ends on, which reads as a pass already granted.
  It now closes on one that matches what it just said: the live file test later is
  what settles it. The ready verdict keeps its own sentence, and `--dry-run` still
  promises neither.

- **Two policies this check used to rewrite are now left to you, because the only
  safe edit to either was none.** An empty `tools.allow` was read as an allowlist
  two entries short, and the offered repair wrote `["read", "write"]` into it —
  which turns an empty list into a real allowlist and revokes every tool the base
  profile had been granting, directly under a banner promising that everything
  else keeps its current policy. And a policy list holding anything that is not a
  tool name — a nested object, a number — had that entry silently dropped when the
  list was read, so the rewrite wrote it out of your config for good, while the
  before/after on screen, the one rollback you are offered, showed a "before" that
  did not match your file. Both now stop and say what they found, change nothing,
  and leave the decision with you.

- **A policy that allows every tool stops being reported as one that breaks file
  transfer.** OpenClaw matches the entries in `tools.allow` and `tools.alsoAllow`
  case-insensitively and with `*` wildcards, exactly as it does the entries in
  `tools.deny` — and this check honoured the wildcards on the deny side only. So
  `{"tools": {"allow": ["*"]}}`, a policy that permits every tool your gateway
  has, was read as one *omitting* the file tools: it printed *This tool policy
  would break agent file transfer: tools.allow omits read, write*, offered to
  append two tools that were already permitted, and would have restarted your
  gateway to apply a difference that was none. Decline that repair and the whole
  file lane left your setup code — the worst outcome of the three, and the one
  the wording pushed you toward. `["*"]`, `["re*", "wr*"]` and `["group:*"]` now
  all reach the green verdict with nothing proposed and nothing asked. An
  allowlist whose wildcards genuinely miss `read` and `write` still gains them.
- **`group:fs` means the same thing in `alsoAllow` as it does in `allow`.** It is
  OpenClaw's name for `read`, `write`, `edit` and `apply_patch` wherever it
  appears, and this check understood that in one list and not in the other.
  Someone who had written `{"tools": {"profile": "minimal", "alsoAllow":
  ["group:fs"]}}` — the documented way to add the file tools back on top of a
  locked-down profile — was told *the active profile lacks read, write* and
  offered a write that would have added what was already there. Both lists are
  read the same way now, a mixed-case `Group:FS` included. An `alsoAllow` that
  covers only one of the two tools still gains the other.
- **Profile names are read the way the rest of the policy is, and a name the
  wizard does not recognise is no longer graded at all.** `{"tools": {"profile":
  "Minimal"}}` was matched case-sensitively, missed the `minimal` test, and came
  out the far end as *OpenClaw's file-tool settings look ready (read/write
  allowed, profile: Minimal)* — a confident green for a profile that grants
  `session_status` and nothing else. `Minimal`, `MESSAGING`, `Coding` and `Full`
  now behave exactly as their lowercase spellings do. A profile name that is none
  of the four OpenClaw documents gets the only answer that is true: the wizard
  says it cannot tell which file tools that profile grants, changes nothing, asks
  nothing, and keeps your file lane — the live file test later in the run is what
  settles it. Calling such a config ready would certify tools nothing looked at;
  calling it broken would offer a repair for a policy that may be perfectly fine,
  and cost you the lane if you declined it. A `tools.deny` that really does block
  the lane is still found and still repaired, whatever the profile is called.
- **`--dry-run` stops promising a test it never runs.** A dry run prints the plan
  and exits before a single request is sent, but the green tool-policy verdict
  still ended on *The live file test later will confirm file access.* In that mode
  it now says the pass stops before that test instead. A real run points at it
  exactly as before.
- **`SECURITY.md` stops describing OpenClaw's PDF story as one a path hint
  solves.** The agent-guidance block it documents carries that hint and nothing
  else: the wizard never switches OpenClaw's `pdf` tool on, never grades it, and
  no longer mentions it anywhere in the tool-policy check. Native PDF reading on
  OpenClaw is your own call, and the README's file-lane troubleshooting lists
  what it takes.
- **The wizard stops switching OpenClaw's `pdf` tool on.** Its tool-policy check
  used to add `pdf` beside `read` and `write` and then report the result as
  *file-transfer-ready (read/write allowed, pdf on)*. Measured against a live
  box, that tool failed every call it was given. It does not use your chat model:
  it uses whatever `agents.defaults.pdfModel` names, and for the common
  bring-your-own shape — an OpenRouter-routed OpenAI model — the gateway answered
  `Unknown model:` and gave up. The correct answers to those same PDFs came from
  somewhere else entirely: a `clawpdf` binary that ships in the container whatever
  the tool policy says, plus the `image` tool, which lives in the base coding
  profile and was never ours to switch on. A scanned, image-only PDF scored eight
  of eight facts correct with the tool on and with it off, and invented nothing
  either way, including under pressure to guess. So the write bought two failing
  tool calls per PDF request and a visible *tool failed* line stapled to an
  otherwise correct reply. The check's concern is now exactly `read` and `write`,
  the two tools the file lane genuinely runs on, and it proposes, adds and claims
  nothing else. Nobody loses a tool they already have — this only stops the
  wizard adding one during pairing, and a gateway pinned to a provider with a
  real native PDF path keeps it, yours to configure. The two explanation panels
  behind `i` drop the same overclaim from the other end: the lane needs read and
  write, so they no longer describe PDF handling as a requirement of it. What to
  check when a PDF answers with generic content is written out instead, as an
  ordered three-step list in the README's file-lane troubleshooting — the denial,
  then `tools.alsoAllow`, then a `pdfModel` your gateway can actually resolve.
- **The tool policy is read the way OpenClaw reads it: ignoring case.** OpenClaw
  matches `allow` and `deny` entries case-insensitively, and this check did not.
  A `tools.deny` of `["Write"]` therefore looked like a policy with nothing wrong
  in it, and the file-lane repair would go on to add permissions *around* a
  denial still in force — then restart your gateway to apply a difference that
  was none. `Read`, `Group:FS`, a `WRI*` wildcard, and a tool your `allow` list
  already carries under another spelling now all behave exactly as their
  lowercase twins do. That last one matters most in daily use: a tool already
  permitted is not added a second time, so no config is written and no gateway is
  restarted for a change that would change nothing. Anything the wizard does
  write back keeps your own spelling.
- **A stock OpenClaw install stops being told its tool policy is broken.** The
  configuration a fresh gateway ships — `{"tools": {"profile": "coding"}}`, with
  the agent's file tools fully allowed — was reported as a policy that *would
  break agent file transfer*, offered a repair it did not need, and, if you
  declined that repair, took the entire file lane out of your setup code. That
  config now reaches the green verdict: nothing proposed, nothing asked, nothing
  restarted, lane kept. Declining a repair the lane genuinely does need is
  unchanged — the consequence is stated plainly and you choose whether to keep
  the lane anyway.
- **A green verdict says what it is, and points at what proves it.** The
  tool-policy line is read off your config file, while the live file test later in
  the same run is what actually proves your agent can use the lane — so the
  verdict now says so: *OpenClaw's file-tool settings look ready … The live file
  test later will confirm file access.* And when that test passes, every gateway
  kind is told the same thing about what it proved. The sentinel is a small text
  file, so a pass proves bytes make the round trip through your shared folder and
  nothing about reading any particular format. That sentence used to go only to
  operators of a custom gateway, the ones this wizard configures nothing for, and
  was withheld from OpenClaw and Hermes, where it had just written to the agent's
  tool policy — precisely where a proof about bytes is easiest to read as a proof
  about documents. Both paths print it now, out of one routine so the two cannot
  drift into saying different things about the same evidence, and it names three
  things rather than one: understanding a PDF or a spreadsheet depends on the
  gateway's tools, its model, and its provider. Holding the tool is not enough,
  which is exactly what the `pdf` measurements above showed.
- **A run whose gateway has already failed stops spending a five-minute agent
  turn to learn nothing.** The last verification step asks your actual agent to
  read a randomized file and write it back — a real chat turn against your own
  paid model, budgeted at five minutes. Once any gateway check has failed, no
  setup code comes out of the run at all, so that turn buys an answer the run
  then discards, and the re-run you now owe has to spend it again. A custom
  gateway already checked first; OpenClaw and Hermes ran the turn anyway, and
  then pointed you at your file lane when the gateway was what died. All three
  kinds check first now, out of one shared routine so their wording cannot
  drift, and say plainly that the turn was skipped and why. The agent proof is
  left blank rather than marked unproved: unproved is a verdict a sentinel that
  ran and fell short earns, and this one never ran.
- **The Hermes memory question stops reading like a required file-transfer
  repair.** It is a separate concern that happens to share one config line with
  the file lane, so it is asked in the same place for the same reason — one edit,
  one restart, one question per run — but on screen it inherited the "Step 4 —
  agent file lane" heading and, on the stock config a fresh Hermes ships, dumped
  roughly 45 lines of by-hand YAML surgery nobody had asked for, on runs that had
  declined the file lane outright. The finding now carries its own heading that
  says it is not part of the file lane, states plainly that removing Hermes's
  recall is required for neither file transfer nor chat, and puts the by-hand
  instructions behind one question — *Show what to check or change by hand?* —
  asked once per run and answered `n` by default. `--dry-run`, `--reuse-only` and
  `--show-code` still print everything with no prompt, as those modes promise.
  Nothing about when or how often the question is asked, what gets edited, or how
  many times Hermes is restarted has changed.
- **"Toolset" is defined, once, before the Hermes path leans on it.** The word
  carries nearly every sentence in that path and appeared 28 times without ever
  being explained. The first Hermes screen of every run now glosses it in one
  parenthesis — a named group of tools Hermes hands an agent, `file` being the
  one that gives a surface its file read/write tools, `memory` and
  `session_search` being the recall this check is about — and it is deliberately
  modest: naming `file` grants the tools and proves nothing about reaching the
  shared folder, which is what the readiness check and the live sentinel are for.
- **You are told what `terminal.cwd` reaches before you approve writing it.** It
  is read from the root of `config.yaml`, not from the API server's own section,
  so it is the working folder for every Hermes surface that reads that key — not
  only the one Conduck talks to. The wizard already priced the reach of the
  recall keys it merely *suggests*; the key it actually *writes* had no such
  line. The toolset list beside it gets its own, narrower statement, and a change
  whose reach cannot be named falls through to the wider one rather than to
  silence.
- **A failed agent file turn points at what actually failed.** One hint —
  *fix Hermes file tools/terminal.cwd* — covered eight distinct outcomes,
  including the one where the agent read the sentinel, wrote a byte-identical
  copy, and only omitted the filename from its reply: keys this same run had
  applied and re-checked ninety seconds earlier. The probe now carries a failure
  *category* beside its message, and the diagnosis branches on that category
  rather than on matching its own prose. A reply-only failure says the file
  access passed and points at the answer; a transport or staging failure no
  longer claims the transport worked; and where one turn genuinely cannot tell
  the causes apart, the model answering is *listed* as one of them — it is named
  nowhere else on screen, and a model that never calls a tool produces exactly
  that result — never asserted as the observed cause.
- **The Hermes config line the wizard tells you to write by hand keeps your
  agent's tools.** Where it cannot make the `platform_toolsets.api_server` edit
  itself it prints a list to write instead, and that list was `["web"]` — or
  `["web", "file"]` in the file-lane step. Hermes has no exclusion syntax, so an
  explicit list really is the only per-surface way to drop two toolsets; but the
  api-server default resolves to 31 tools, and an operator who typed that advice
  exactly as given traded terminal, code execution, the browser, skills, vision
  and image generation for the removal of two. The list is now the reviewed
  api-server default minus the two recall toolsets — `["browser",
  "code_execution", "cronjob", "delegation", "file", "image_gen", "skills",
  "terminal", "todo", "vision", "web"]` — measured against Hermes's own resolver
  to keep everything that default resolves to *from configuration alone*, less
  `memory` and `session_search`. Two toolsets sit outside that: Hermes switches
  `homeassistant` and `x_search` on from `HASS_TOKEN` / `XAI_API_KEY` in its
  environment, and only while no explicit list exists, so writing one drops them.
  Rather than widen the list for every operator who holds no such key, or sample
  an environment printed advice has no business depending on, the hint names the
  omission in a sentence and tells you to add either one yourself. The freeze is
  stated as the deliberate thing it is, too: the list becomes yours to maintain,
  and a later Hermes that adds a toolset to its own bundle will not add it there.
  It is offered only where it provably preserves what your file resolves to on
  its own — no `api_server` key at all, or a list holding exactly
  `hermes-api-server` — and eligibility reads the *raw* configured list rather
  than the effective one, so an entry your `agent.disabled_toolsets` currently
  switches off disqualifies the canned list instead of being discarded along with
  it. Every other composite is described rather than replaced, and each now gets
  the reason that is true for it: a bundle the connector has not reviewed
  (`all`, `*`, `hermes-cli`) still gets "I do not know what this holds", while
  `hermes-api-server` standing beside other entries gets the honest one — that
  bundle is reviewed, and named on screen a line earlier, so claiming ignorance
  of it read as the connector distrusting its own report; what it will not do is
  decide the fate of the entries you put beside it. **Both printed snippets are
  child keys now, never root ones** — `api_server: [...]`, and
  `disabled_toolsets:` with its two items — each with its full dotted path named
  and its placement spelled out for a file that already has the parent section
  and for one that does not. A snippet led by `platform_toolsets:` or `agent:` is
  one a literal paste turns into a second section of that name, and two do not
  merge: one wins outright and everything the other set stops applying, which on
  the `platform_toolsets:` side means the very memory tools you were removing
  come back, and on the `agent:` side means the disables you made for other
  reasons vanish. The hint also names the one-line global alternative — **add**
  `memory` and `session_search` to `agent.disabled_toolsets`, as an addition to
  whatever that key already holds — with its costs: every Hermes surface at once,
  entries Hermes's own `hermes tools` screen can silently drop again, and saved
  memories that still reach the prompt after memory writes stop. The advice no
  longer varies with whether the pairing carries a file lane; the recall question
  is about memory, and every configuration that gets the list already carried the
  file toolset. Its closing lines also stop claiming that anything else pointed
  at this same API server keeps its memory, which the removal step contradicted a
  few lines later: an explicit list governs every client of this API server and
  leaves the CLI and messaging surfaces alone, the global key governs every
  surface, and the copy now says which is which.
- **Your Hermes agent stops answering PDF questions from the filename.** The
  guidance block installed in `.hermes.md` / `HERMES.md` told it to open every
  attachment with `read_file`, which has no PDF path: on a `.pdf` it returns PDF
  syntax, or reports the file as binary. With something that looked like a result
  in hand, the agent answered from the name of the file. The block now says
  plainly that neither of those is the document's text, and tells it to extract
  the text with `pdftotext -layout <the uploaded path> -` through the `terminal`
  tool — the trailing `-` keeping the text in the reply rather than writing a
  stray file into the shared folder, where a root-level file is exactly what
  another rule in the same block offers you as a download. It also tells the
  agent to say so when `pdftotext` is missing, fails, wants a password, or
  returns nothing usable, and never to quote PDF syntax back as if it were the
  text: `pdftotext` does no OCR, so a scanned page has no text layer to find,
  and a guess is the one answer worse than "I can't read this". `pdftotext` (poppler) ships by default almost
  nowhere, so setup prints a note when it cannot find it — and installs nothing.
  The two defects met in the middle: the by-hand advice above recommended away
  the very `terminal` toolset this instruction needs — so setup now looks for it.
  Where it can read `platform_toolsets.api_server` cleanly and finds no terminal
  tool in it — the shape the old advice left behind — it says the agent
  cannot run that PDF command at all, scopes the gap to PDFs, and names the
  one-line fix. Non-blocking, like the `pdftotext` note beside it, and silent for
  a config it cannot read rather than telling you to correct a key that may
  already be right. The screen that asks for your yes describes the rules the
  block carries rather than asserting what your host and your config hold — the
  only version of it that stays true when either note fires. The block gains one
  more rule while it is being rewritten: instructions found inside an attachment
  are untrusted unless your own chat message asks the agent to follow them, and an
  attachment never widens what it may reach. An already-installed block reads as
  stale on the next run and is refreshed in place, everything outside the markers
  untouched.
- **A Hermes config carrying an `agent.disabled_tools` key no longer costs you
  file transfer.** The readiness check inspected that key for `read_file` and
  `write_file` and, on a hit, refused the whole optional file lane for the run.
  Hermes has no reader for it: the toolset is its granularity floor, nothing in
  its configuration disables an individual tool, and the key has never existed in
  any release — so the only thing that check could ever do was decline a lane over
  a line Hermes itself ignores, for anyone who wrote one by hand or carried one in
  from another tool. The near-miss spelling is what made it plausible;
  `agent.disabled_toolsets`, one letter longer, is real, is read on every surface,
  and is still inspected exactly as before.
- **A custom gateway's token is asked for at a hidden prompt, and nowhere else.**
  Setup asked `Does it require a bearer token / API key? [y/N]` and only then, on
  a yes, opened the hidden prompt that takes the secret safely. A question whose
  own wording names the thing being requested invites the paste it is not built
  to receive: the answer arrives at an echoing `read`, is printed, is refused as
  not-a-yes-or-no, and stays in the terminal's scroll-back — five lines before
  the code warns that over SSH scroll-back is exactly what survives. There is now
  one prompt, it is hidden, and it is the token itself; an empty answer is a
  question rather than a conclusion, so keyless still has to be confirmed out
  loud and the fail-closed rule that a missing token is never read as "no token
  required" is unchanged. Input that ends without an answer still stops the run
  rather than inferring keyless from nobody being there. A dry run takes the mode
  as a numbered choice and never solicits a real secret.
- **A credential-shaped answer at any question that refuses it now says so.** The
  prompts that reject input and ask again — yes/no, numbered menus, addresses, and
  the press-Enter-when-done step — recognise an answer that looks pasted rather
  than typed and name the exposure once: it was shown, it is in scroll-back, and
  it should be rotated if it was real. The check is shape only, and the value is
  never repeated back; the whole defect is one copy of a secret on screen, and
  echoing it for clarity would make two.
- **A quick tunnel is no longer asked whether it is public.** Exposure asked the
  operator to classify an address the wizard can classify itself, and the answer
  is not cosmetic: `private` is what switches off the refusal to publish a gateway
  with no token. A `cloudflared tunnel --url` hostname has no private variant, so
  the question could only ever add a way to get it wrong. It is now stated instead
  of asked, exactly as a *named* Cloudflare tunnel already was. Reach that the
  wizard genuinely cannot derive still takes an explicit 1/2 with no Enter default.
  A keyless gateway on a quick tunnel now stops, and `--allow-keyless-public`
  remains the one deliberate override.
- **A quick-tunnel address carrying a query or fragment is recognised as one.**
  The host test ended the address at the first `/` only, so
  `https://x.trycloudflare.com?a=1` and `…#frag` fell through it — and the two
  callers that pass an address exactly as the operator typed it, the file lane and
  the pairing reminder, were the ones that lost the rotation warning. The
  authority now ends at the first `/`, `?` or `#`, the same cut the profile
  validator makes.
- **Setting up a custom gateway again changes it instead of duplicating it.** A
  gateway is filed under an id derived from its display name, and that id also
  names its file-service and the credential that service reads. Nothing ever
  looked a name up — a name that slugged differently by one character built a
  second gateway with its own port, unit, credential and saved setup while the
  first kept running, unmentioned; a name that slugged the *same* silently took
  over an existing gateway's file server and then overwrote its saved setup.
  Setup now lists the custom gateways already on the machine and asks which one
  this is, and picking one freezes its id — the name becomes display text, so
  correcting a typo corrects the name instead of creating the duplicate the list
  exists to prevent. A new gateway may not land on an id already in use: setup
  says which gateway holds it and offers the two ways forward. "In use" counts
  more than a readable saved setup — a run that failed before saving still leaves
  the service and credential behind, and a setup file a newer version wrote is not
  offered in the list but keeps its name reserved rather than being overwritten by
  the hiding. The address is always asked again rather than restored, because a
  quick tunnel's hostname is reassigned every time it restarts.
- **A 5xx on a keyless gateway is no longer reported as a server fault when the
  server is really asking for a credential.** Some servers mishandle a *missing*
  credential inside their own error path and answer 5xx where they mean 401.
  LiteLLM without a database is the one this script meets most: its auth-error
  handler imports a module only database deployments install, so the handler
  itself raises before it can answer — measured, on a stock install, `no
  Authorization header → 500` while `wrong token → 400` and `correct token →
  200`. An operator who tells the wizard their LiteLLM is keyless was sent to
  read server logs over what is really "this gateway is not keyless". The wizard
  now settles it by experiment instead of guessing, in the same shape as the 403
  probe: repeat the failed request unchanged, and only if the same status
  reproduces, send it once more with a throwaway credential. A server that is
  simply broken answers both the same way; only one whose reply depends on the
  credential can differ. Both observed statuses are printed, so the operator
  reads the measurement rather than taking the verdict on faith, and the control
  running FIRST means a transient 5xx — a restarting gateway, a cold model load
  — stays silent instead of producing a confident wrong answer.
- **A 403 was reported as a rejected token — on gateways configured as keyless,
  where no token exists to reject.** `401` and `403` shared one arm, so the most
  common first-run failure of the most common local model server produced a
  sentence that was not merely unhelpful but false. Ollama refuses any request
  whose `Host` header is not a local name, and a tunnel forwards the public
  hostname unchanged, so the wizard's own suggestion — expose the port it names
  (`e.g. 11434 for Ollama`) with a quick tunnel — fails 100% of the time and then
  blames a credential the operator was never asked for. The two statuses are now
  separate, and each splits again on whether the gateway has a token: a keyless
  403 says there is nothing to reject and that the request itself was refused as
  it arrived. Where a local port is known the wizard sends the same request with
  the same credential to loopback and reports the split — green there and red
  over HTTPS proves the server and the credentials are fine and the route in
  front is at fault — and where it cannot prove that, it says so instead of
  implying it. The cure is named: make whatever fronts the gateway **rewrite**
  `Host` rather than forward it.
- **`OLLAMA_ORIGINS` is named as a dead end rather than prescribed as the fix.**
  It is the most-cited answer to an Ollama 403 and it cannot work: upstream reads
  it only into the browser CORS allow-list, never into the host check that
  produced the refusal, and neither Conduck nor this wizard sends an `Origin`
  header. Prescribing it would have cost the operator a restart and a re-run to
  arrive back at the identical 403 — the same dead end this change exists to
  close. Ollama's real second lever is that the host check is skipped when it
  listens beyond loopback (`OLLAMA_HOST=0.0.0.0`), stated with its cost.
- **The recovery a failed run recommends now exercises the route that failed.**
  Both checks offered at the end of a failed custom-gateway run substituted
  `http://127.0.0.1:<port>` whenever a local port was known — the one address
  where a `Host` mismatch cannot occur. The operator was told their token was
  rejected, ran the diagnostic the wizard itself recommended, watched it pass,
  and concluded their server was fine and the wizard was broken: a recovery path
  that actively confirmed the wrong theory. Both checks now target the address
  that failed, and the loopback run is offered separately, as a deliberate
  comparison, with one line on what the split between them proves. The same
  substitution on the success screen is fixed too.
- **`--check-server` and `--check-adapter` no longer tell a keyless run to invent
  a token.** Each carries its own copy of the status ladder, and each answered a
  keyless 401 *or* 403 with `set CONDUCK_TOKEN=<token>`. That was survivable while
  a failed setup pointed at loopback, where the check passed and the line never
  printed; it is not survivable now that a failed setup names `--check-server` as
  the first thing to run. A server that wants auth answers 401, so the token
  advice stays there and is gone from 403.
- **A blank at the file-lane address prompt threw away a working file server, and
  the setup code went out without it.** By the time that prompt appears the
  connector has found the operator's file server, recovered its credential and
  proved it answers a read and a write — and then read an empty line as "leave
  file transfer out", identical to a deliberate skip. A paste that did not land, a
  stray Enter and a considered no all arrived as the same empty string, and the
  outcome was announced in a dim one-line note. The operator scans the code and
  finds out on their phone; the only way back is a full re-run, because
  `--show-code` re-emits a lane the profile already holds and cannot invent one.
  Blank stays a valid answer — someone can accept the lane and then find they have
  no HTTPS route to give it — so it is now confirmed rather than assumed, and
  declining the skip returns to the address prompt, which makes a mis-paste cost
  one keystroke instead of the whole run. A confirmed skip says so as a warning
  rather than a note. This is the same failure the end-of-run residue report was
  added for; that report tells you afterwards, and this stops it happening.
  Step 6 now also states what the code **carries**, immediately before showing it:
  chat always, file transfer only when the lane really rides in the payload. It is
  decided by the same condition the payload builder uses, so the summary cannot
  disagree with the code it describes, and it covers every other route that drops
  a lane — a live probe that failed, an agent gate that could not be proved — not
  only this one.
- **The wizard told you to write a Hermes config line it would then refuse to
  read.** When it cannot make the `platform_toolsets.api_server` edit itself it
  prints the list to write by hand, and printed it as a bare YAML flow sequence:
  `api_server: [web, file]`. That is precisely the inline shape this connector's
  scanner will not guess at, so an operator who typed it exactly as instructed,
  restarted Hermes and re-ran was told `platform_toolsets.api_server uses YAML
  syntax this connector will not guess at` — a refusal that names the key and
  never the quoting, on a config they had just been handed verbatim. List length
  had nothing to do with it; `[web]` failed the same way. The advice is now
  JSON-quoted, `api_server: ["web", "file"]`, which is what this connector's own
  canonical rewrite already writes into that same line, so the shape it tells you
  to type and the shape it types for you are one shape. Both lists are defined
  once and shared by every module that prints them, rather than re-spelled at each
  of the twelve call sites, and a regression test now feeds each printed string
  back through the real analyzer: the old advice fails that test with exactly the
  status an affected user saw.
- **The block that teaches your agent to use the file lane was installed
  unreadable, and the run reported success.** Both file-server unit writers set
  `umask 077` as a bare statement instead of scoping it, so the mask survived for
  the rest of the process and every later write inherited it. `TOOLS.md` is
  written after the unit, so on the ordinary OpenClaw shape — script run as root
  on a VPS, agent running as uid 1000 inside the container — the guidance block
  landed readable by its owner alone. The file existed, the run printed the green
  line, and the agent never saw it; the live probe could not catch this because
  it repeats the same instructions inline in its own test message, so it passes
  whether or not the persistent copy is readable. The mask is now scoped to the
  writes that need it, and is applied to those files BEFORE their contents,
  because a mask governs creation only: a stale world-readable file from an
  earlier run would otherwise hold the credential for the window between the
  write and the `chmod`. A `TOOLS.md` this script creates is now explicitly
  `0644` and verified after the fact; an existing one that only its owner can
  read is left untouched and the block is not installed, with the exact
  `chmod 644` named — widening a file you already own is not the script's call,
  and writing into one your agent cannot read is the failure this closes.
- **A stock Hermes config was refused the file lane because of a trailing
  comment and some trailing whitespace.** The readiness gate that keeps the
  connector from broadening Hermes privileges or guessing at a mount was doing
  its job correctly; the YAML scanner feeding it was not. A value carrying an
  inline comment puts the scanner into plain-scalar continuation mode, and the
  column-0 `# ---` separator that follows in the shipped example config was then
  read as content rather than as the comment it is — a comment can never continue
  a plain scalar (YAML 1.2 §7.3.3). Separately, a "blank" line that actually held
  spaces was truthy, so it was scanned as a child at indent 2. Either one made
  the enclosing section ambiguous and the lane was dropped, which is the whole of
  "Hermes used to have a file server and now it does not". Both are fixed at the
  root: comments close a continuation at any indent, and a space-only line is
  treated as the blank line it is. The second fix lands in the shared line reader,
  because the same stray whitespace also rejected a block list and, after an
  indentless root sequence, declared the entire document outside the editable
  subset. Tabs and non-ASCII whitespace still fail closed exactly as before —
  they are not valid YAML indentation, and this scanner refuses them on purpose.
- **The only record of how to close an exposure lived in memory, so an
  interrupted run left one open with nothing on disk that named it.** `APPLIED`
  and `FS_APPLIED` are bash arrays and the undo recipe was only ever *printed*:
  on a SIGKILL or an OOM kill nothing printed at all, and on a dropped SSH
  session the exit trap ran and wrote into a terminal that no longer existed —
  practically identical outcomes, with a public Tailscale Funnel in front of a
  tool-capable agent gateway potentially still live. Each undo record is now
  written to `$STATE_DIR` (already 0700 for exactly this class of data) BEFORE
  the mutation that needs undoing, and a later run reports each leftover that is
  still live — naming its port, its backend, and whether it is PUBLIC — and
  offers to close it. Records are dropped only on proof: when the port no longer
  carries the verb and proxy we applied, or wholesale once a run emits a code.
  Declining the cleanup prompt now KEEPS the records, because printing hints is
  not evidence anyone read them, which is the dropped-SSH case exactly. Every
  field is re-validated on read, since the file is owner-editable and its values
  reach a `tailscale` command line. Reconcile runs after the setup lock, so two
  runs cannot both offer to close the same port, and before any new port is
  chosen.
- **A prompt titled "cleanup" would re-publish the gateway to the internet.**
  Under "here is how to put each affected port back the way it was", a port whose
  prior mapping was a Funnel got `tailscale funnel --bg …` — an unlabelled
  instruction to re-expose the machine — and accepting the block RAN it, possibly
  two prompts after the operator answered yes to turning the public URL off. One
  rule now governs every undo path: what this run applied is removed, and a prior
  mapping is restored only when it was private. A public prior leaves the port
  CLEARED, and the command that would re-publish it is printed OUTSIDE the
  accepted block, under its own heading, labelled as making the port public,
  alongside "I never re-publish a port on your behalf". The command survives as
  information because the operator may want that state back; it is no longer an
  action the script can take for them.
- **A `*.trycloudflare.com` address was accepted, and later emitted in a pairing
  code, with no word that it does not survive a restart.** Those hostnames are
  reassigned every time the tunnel restarts, so a reboot silently moves the
  address: the paired device points at a hostname that no longer exists, and the
  live one appears in no saved profile and in no output of this script, so
  neither the app nor this tool can look it up. The staleness is now named where
  the address is accepted AND again beside the emitted code, which is the
  artifact that goes stale, for the gateway URL and the file-lane URL
  independently.
- **A dropped file lane rolled back nothing and said nothing on two of three
  transports.** Rollback is Tailscale-only by construction, so on "my own HTTPS"
  and on Cloudflare a lane that failed its probe was quietly omitted from the
  code while the run ended GREEN — leaving an authenticated WebDAV server over
  the agent's working folder running, enabled at boot, with the HTTPS route the
  script told the operator to create still pointing at it. Any lane that is
  created but not shipped now reports itself before the terminal closes: the
  unit, that it restarts at boot, its credential files, and the exact
  copy-pasteable teardown commands (including `reset-failed`, without which a
  crash-looped unit stays `failed` after its file is gone). The report is latched
  to once per run. It now also fires on the three branches where making the lane
  public or private FAILS, which previously dropped the lane silently while the
  adjacent operator-declined branch reported correctly.
- **The shared folder was never resolved, so it could be the whole home
  directory — or quietly become it later.** The wizard accepted a symlink, wrote
  it into the service definition verbatim, certified it "byte-faithful", and
  offered to publish it, and the link's target could then be re-aimed under the
  running server with no restart and no re-check. Pointed at `$HOME`, the lane
  served `~/.ssh/authorized_keys` and this connector's own credential files over
  WebDAV. The folder is now resolved before any service definition records it,
  and `/`, the home directory itself, a non-absolute path and a plain file are
  all refused with the reason and what to do instead — matching what
  `--check-adapter --files` already refuses. The RESOLVED path is what gets
  served and recorded, so re-aiming a link afterwards cannot move the served
  folder, and the operator is told when resolution changed the path.
- **A stolen port wedged the lane permanently while every later run printed a
  checkmark for a dead service.** The port check is a bind probe seconds before
  rclone's own bind, so anything on the host can take it in the gap; the unit
  then crash-loops into systemd's start-rate limit and sits `failed` for good.
  Later runs printed "Found your existing file server", refused to expose it, and
  exited 0 with a green chat-only code, naming no unit and no way to look at it —
  leaving the operator with "attachments just never work" and nothing to search
  for. An inactive unit is now named, with the `systemctl --user status` and
  `journalctl --user -u <unit>` commands to inspect it.
- **Two setups running at once picked the same port, wrote the same unit and
  credential, and the loser erased the winner's live file lane from the saved
  profile.** Sequential re-runs were already properly idempotent; only the
  concurrent case broke, and nothing guarded it. Setup now takes a single-instance
  lock at the one choke point both entries pass through. Authority is the holder's
  LIVENESS, not the lock's existence — identity is the pid plus its command line,
  since after a reboot the same pid belongs to another program — so a lock
  stranded by a kill, a reboot or a power cut is reclaimed by the next run instead
  of blocking every future one. Unknowable liveness fails closed and never steals:
  no usable `ps`, or a `$HOME` shared with another machine, both refuse to judge.
  A dry run is exempt, since it changes nothing and must not be able to block a
  real setup.
- **A failed run, and `--reuse-only`, destroyed the saved record of a live file
  lane.** `--reuse-only`'s contract is that it refuses configuration changes, and
  the saved profile is configuration; a run whose checks failed had likewise
  proven nothing about the setup it was about to record. Either could turn one
  transient probe failure into the permanent deletion of a working lane, which is
  the outcome `--show-code`'s existing guard exists to prevent. Three guards now
  protect an EXISTING profile — reuse-only, a failed verification, and a lane
  dropped by a check rather than by the operator — each explaining what it kept
  and how to refresh it. Writing a FIRST profile is unguarded: there is nothing
  to destroy.
- **A moved address was reported as "the server errored".** On the Cloudflare and
  public transports the HTTP-code map filed 530 in the 5xx bucket, when 530 means
  precisely that nothing serves that hostname — its tunnel is gone — and the
  gateway never saw the request. Those two transports now get a real drift line:
  the gateway is probed on loopback, and answering locally while the address does
  not reach it IS the drift, so "reconcile the address" is separated from "start
  the gateway" instead of blaming the server for both. It fires only on failures
  where the request demonstrably never arrived; a rejected token or a login page
  proves it did, and calling those a moved address would send the operator after
  a fix that changes nothing.
- **A gateway-only code was offered when the gateway itself was what failed, and
  the file server was named as the thing to fix.** Once any gateway check fails
  no code is emitted at all, so the offer promised something the run would then
  refuse, over a fault the file lane cannot cause. Both paths now say the gateway
  failed too and to fix that first.
- **An unreadable saved profile was reported as "no saved profile — run setup
  once", and following that advice overwrote it.** The validator's real errors
  were discarded, so a profile a newer version wrote looked identical to no
  profile at all. Both entry points now surface the reason: the welcome menu says
  a saved code exists that this version cannot read, why, and that setting up
  again REPLACES the file; `--show-code` distinguishes "there is one and this
  version cannot use it" from "there is none". Option 4 is still offered only for
  a profile the loader will accept, so the menu cannot advertise an entry that
  dead-ends moments later.
- **A world-WRITABLE state directory was reported as a listing problem.**
  "Readable by other accounts" badly understates it: 0600 protects what is inside
  `fileserver-<id>.cred`, but in a writable directory any local account can
  replace the whole file, and rclone then reads its password out of somebody
  else's copy at the next start — likewise `profile-<id>.json`, which is what
  `--show-code` rebuilds a pairing code from. Write is now graded apart from read
  and worded for what it actually permits. `--show-code` checks the mode too: it
  parses the profile and re-derives both secrets, so it carries the same
  exposure, and the check runs before any secret is read.
- **`--check-adapter --files` sent the operator hunting for a probe file that
  could not exist, and made three different failures look identical.** The
  cleanup warning keyed off names registered BEFORE creation, so it fired even
  when nothing had ever answered a mutating request; it now keys off whether a
  write was genuinely attempted, counting a REJECTED write as possibly-created
  (an answering server may have written into a directory this host cannot see)
  and treating no answer at all as the only case where nothing can exist. Write
  failures now carry the HTTP status they already held, separating a read-only
  folder from a full disk from a server fault. The nested-folder verdict no longer
  prints "(HTTP 201)" beside a failure: a refused write, an empty read-back and a
  changed read-back are three findings, and the status appears only where it is
  the finding.
- **The logout caveat appeared only at the step that built the lane, which had
  scrolled away by the time the operator decided to trust it.** A `systemd --user`
  file server stops shortly after that user's last session ends and does not come
  back on reboot unless lingering is on. That is now re-stated beside the emitted
  code, gated on the one arrangement it is true for, with the `loginctl
  enable-linger` command.

- **Setup restarted the gateway to apply the tool-policy fix, then graded it
  while it was still booting.** On a stock OpenClaw Docker install `docker
  compose restart` returns in about a second and the health route first answers
  about five seconds later, so the verification that followed failed a gateway
  that was merely coming back — and the honest reading of that transcript is
  "the change I just approved broke my gateway", which gets a correct change
  undone. A restart this run asked for is now followed by a bounded wait on the
  gateway's own loopback health endpoint, on BOTH restart routes: the one the
  script runs, and the one the operator confirms by hand (the boot window is
  identical either way, and the confirmation is the only signal the second route
  has). Two answers a second apart are required, because one proves nothing — a
  container that starts, answers and dies, and an old process still listening on
  its way down, each answer once. The wait is bounded twice over, by a
  60-second budget and by a probe cap, since `date` is wall time and a clock
  stepped backwards mid-wait must not be able to extend the loop. It gates
  NOTHING: a gateway that is genuinely broken still reaches verification and
  still fails there, and the probe is verification's own health check rather
  than a private copy, so the wait and the check that follows it accept exactly
  the same answers by construction. All three restart sites now wait: the
  chat-endpoint flag in Step 2, OpenClaw's tool policy, and a Hermes config
  change — the last of which had two callers walking straight into config and
  lane decisions about an API server that was not listening yet. Each names its
  OWN change in the messages, because reassuring an operator about a change they
  never made is worse than saying nothing; and only the two that sit away from
  the HTTP layer claim they cannot affect it. The chat-endpoint flag IS that
  layer, so it makes no such promise. A Hermes gateway paired through a
  `--check-server` handoff has no known health route, and the wait says it cannot
  tell rather than guessing.
- **A declined or failed restart still printed "now file-transfer-ready".**
  Re-reading `openclaw.json` proves what is on disk and nothing about what the
  running gateway loaded, so a user who said no to the restart — or whose
  restart errored — was told the lane was ready while the live gateway was still
  denying the agent's file tools. The two facts are now separate: the success
  line claims the file (`openclaw.json` is file-transfer-ready), and when the
  gateway was not restarted it says so out loud, with what that costs until it
  is.
- **A missing `rclone` read as the end of the run, and then a pairing code
  arrived anyway.** "Install it and re-run me, or skip the file lane for now"
  was the last thing said before setup carried on to pair the gateway, so the
  sensible-looking reaction was to abandon a setup that was about to succeed.
  It now says what actually happens: the run continues without file transfer,
  chat including pasted images still works, a chat-only setup code still comes
  if the checks pass, and installing rclone later plus a re-run adds the lane.
  The `rclone` check also moved AHEAD of the OpenClaw tool-policy step — asking
  whether a binary exists costs nothing, and changing a foreign gateway's tool
  policy and restarting it for a lane that cannot be built is a change made for
  nothing.
- **`--check-adapter` blamed three separate rules for one missing `model`
  field.** The history-image, stream and image probes all deliberately omit
  `model`, because tolerating an absent one is a contract requirement — so on an
  adapter that REQUIRES the field, every one of them failed for that single
  reason and each was then explained as a fault of its own rule. A working
  anti-poisoning path was told it rejects images in conversation history; a
  working vision path was told it silently drops them. `CHAT_BASIC` now owns the
  absent-model rule alone and answers it once, by re-sending its identical
  request with the first advertised id — evidence for that exact payload, not a
  guess read out of prose, and cheap because only a fast rejection status buys
  the retry the right to run. Once the requirement is confirmed the later probes
  carry that id and grade the rule they exist to grade, the requirement is named
  once where it belongs, and every verdict reached on a borrowed model discloses
  it on itself, so a green line cannot quietly relax what it tested. When the
  confirming retry fails too the cause is unattributable, and the checker says
  it is not grading those probes instead of inventing a story for them. For
  script consumers: `history_image=`, `stream=` and `image_input=` can now
  report the existing `NOT_RUN` value for a probe that ran but measured nothing,
  as well as for a tier a prerequisite stopped. No field was added, renamed or
  reordered and no new enum value exists, so `schema=` stays 3; the run-level
  verdict still lives in `core=`, `failed=` and the exit code.
- **Two chat-failure explanations described a cause that was not there.** A
  `413` was folded into whichever per-rule story the probe happened to be — a
  request-size limit answering a few-hundred-byte probe PNG was reported as a
  judgement on the request's shape. The stated cause now pre-empts every
  per-kind story, the same way the front-end 5xx statuses already did, and names
  where the limit almost always sits (in front of the adapter, not in the
  engine). The stream hint also left what Conduck sends ambiguous; it now states
  plainly that Conduck always sends `"stream": false` and never accepts SSE, so
  an adapter should answer one JSON object even if some other client sets the
  flag.
- **A failing adapter grade stranded the reader who had not written the
  adapter.** This grade holds software built FOR Conduck to Conduck's own rules,
  and third-party OpenAI-compatible servers are EXPECTED to fail parts of it —
  answering `"stream": true` with SSE is correct OpenAI behaviour and keyless is
  a legitimate deployment choice, so neither is a defect in Ollama, LiteLLM or
  Open WebUI. The closing line pointed only at the contract docs, so a wall of
  red read as "this cannot be used" when the app pairs with it fine. Every
  failure exit now names the question the reader actually has, and the two
  commands that answer it — including the early `/v1/models` abort, where the
  reader is equally stranded.
- **The multi-model caveat was unreachable on exactly the servers it exists
  for.** `--check-server` grades one model path, and the line saying so was
  gated on a state the run only reaches when the server REJECTS a model-less
  request. Any server that ANSWERS one — the common case, and precisely what a
  fan-out gateway advertising hundreds of ids does — landed elsewhere and got no
  caveat at all, on either the history-image note or the closing FAIL line. The
  gate is now "this run picked the graded path rather than the operator", which
  is as true of the model-less default route as of the first advertised id, with
  wording for both.
- **A mistyped address ended the server check and threw the token away.** The
  credential is the expensive input to re-type — often a 300-character JWT — and
  the address is the cheap one, yet a failing address exited the run and asked
  for both again. A failed address now re-asks for the ADDRESS and keeps the
  credential already entered, under the same acceptance rule as the first prompt
  (https anywhere, plain http only toward this machine) so the retry cannot
  relax what the first ask enforced. Interactive runs only: a scripted run still
  exits 1 on the first failure. Each attempt re-arms its counters, so a first
  attempt's red can never bleed into a later attempt's PASS. The HTML diagnosis
  also names the real answer now — an OpenAI-compatible API living under a
  SUB-PATH of the address given, with Open WebUI's `<url>/api` as the concrete
  case.
- **The pairing success screen suggested a grade without naming its outcome.**
  Right after proving a working setup it offered `--check-adapter`, so users who
  had just paired stock third-party software ran the strict grade, got a FAIL,
  and concluded the setup they had just proved was broken. The suggestion stays
  — it is the only screen an adapter author reaches — and now carries its
  consequence: the grade only fits software built for Conduck, generic servers
  fail rules that are correct for them, and that does not undo the pairing
  above.
- **The exposure menu never named the `*.trycloudflare.com` quick tunnel.**
  `cloudflared tunnel --url` is by far the commonest casual way one of these
  gateways gets exposed, and with no row a user could recognise it sent its own
  users at option 3 — the single path that wants a Cloudflare domain they do not
  have, and the one whose "cloudflared found" line looked like recognition.
  Option 4 now names the quick tunnel in the annotation slot the rows already
  use, unconditionally (gating it on a local `cloudflared` would hide it
  whenever the tunnel runs from another terminal, host, or `PATH`), and the `?`
  comparison places it on 4 explicitly. Truthful either way: that address
  carries a certificate devices already trust and needs no domain of your own,
  so it passes option 4's trust gate on its own merits.
- **The body-drain rejection is now a counted conformance check, not just a
  diagnosis.** `AUTH_CHAT_REJECT_BODY` grades what the diagnostic could only
  describe: after an early `401`, the adapter must either drain the request body
  or close the connection, so the next request on a reused keep-alive connection
  is still parsed from its own first byte. It fails only on positive evidence — a
  proven desync, or completed answers that contradict each other — because a
  conformance check that reddens under load is one people learn to ignore; a
  throttled burst (`429`/`503`) and a probe that never completes both pass with a
  note instead. `Expect:` is pinned empty: left alone, a server that rejects
  immediately makes curl skip sending the body at all, and an adapter that never
  drains would have graded clean. Connection reuse is only provable
  client-to-proxy, so the check states what it saw and claims no cause through a
  proxy.
- **The test fixture had the very bug the check exists to catch.** Driven down
  one connection it answered `401 400 0` — our own reference adapter left the
  body unread, which means every builder reading it for guidance was reading the
  defect. Draining is now structural rather than a per-call-site habit: one
  `reject_hygiene` routine behind every early rejection, bounded (64 KiB, 5 s)
  and closing instead on chunked, malformed, duplicate, or oversized
  `Content-Length`. A successful `GET` carrying a body desynced the connection
  too, and no longer does.
- **Hermes's own recall is settled once, after the file-lane step — and a
  `--check-server` handoff now reaches it at all.** A run that checked a local
  Hermes and continued into setup pairs it as a custom server, so the recall
  notice never fired for exactly the users most likely to hit it. The
  attribution is latched while the check is still passing (by the later step the
  checked URL no longer exists), and only on a real match: scheme, bare
  authority, bind address, port, API-server enabled, and the exact key the check
  authenticated with. A remote gateway, a base path, a different key, a keyless
  check, a disabled API server, or an unreadable port declaration all stay
  silent — a settings match is correlation, and the wording says "matches"
  rather than claiming identity. Both steps write the same `config.yaml` line, so
  a file-lane Hermes user is now asked once and restarted once instead of twice.
- **Copy no longer sells gateway-side memory as something you get.** Leaving
  Hermes's recall on means paying for the thread twice — the gateway replays
  history the app already sent, measured at 13.3k prompt tokens against 540 for
  the same turn. The `8645` proxy warning drops "recall" from what you give up
  there (it is a bare model relay: tools and skills are the loss, and conflating
  the two axes muddied both), and an unreadable API-server toolset is now
  distinguished from one that reads fine but names toolsets we do not recognise —
  a different problem with a different fix.
- The rclone integration script pinned `revision=1\.3` in its summary regex, so
  it was stale the moment the contract moved and no suite runs it to notice. It
  matches any revision now; the grammar is what is frozen per `schema=`, not the
  revision number.

- **`--check-server` no longer grades an arbitrary model and calls the result a
  verdict on the server.** It probed with whichever id `/v1/models` listed first,
  so an aggregator fronting hundreds of models could report FAIL or PASS purely
  on the order it listed them — the same server, nothing about it changed. New
  `CONDUCK_CHECK_SERVER_MODEL` names the model to grade; it is snapshotted once
  and drives the named-selection turn, the history-image probe and the image
  probe alike, so a run cannot silently switch targets midway. Both verdicts now
  say which model they graded and that the others are untested, and a mistyped
  override is caught against the advertised roster before it produces failures
  the server would be blamed for. The old wording — "the app would hit the same
  walls" — was the actual falsehood: the observation was right, the
  extrapolation was not. Deliberately NOT added: an automatic retry against a
  second model, which would convert a false FAIL into a false PASS and hide a
  genuinely broken first id.
- **The setup handoff pairs the model that was actually checked.** It re-derived
  the model from the first advertised id, so a run that graded one model could
  pair another; and when a server required a model but advertised none, it
  emitted a pairing with no model at all — which that server rejects. Both come
  from `COMPAT_MODEL_ID` now. An empty value keeps its old meaning (the check
  passed without a model field, so app-side selection stays open) rather than
  standing in for "unknown".
- **A rejection sent before the request body is read now has a name.** Three of
  five independent adapter builds answered `401` while leaving the body unread
  on a keep-alive connection, so the next request was parsed starting mid-body.
  The check reported it as `WRONG token → HTTP 400`, which is true and causally
  wrong — every builder then audited auth logic that was fine. A paired probe
  down one connection now separates a proven desync from an unstable answer from
  a genuine auth fault, and says which it saw rather than asserting a cause it
  cannot prove through a proxy. The comment that taught the bug is corrected:
  auth is checked before the body is *processed*, and the bytes must still be
  consumed or the connection closed.
- **"transfer failed (timed out or the connection dropped)" split into nine
  specific causes**, including the one that reads as a network fault and is not:
  an adapter started without a supervisor and reaped mid-turn.
- **Hermes's API-server recall scope is reported before pairing, and offered for
  removal.** `memory` and `session_search` give the gateway a memory of its own,
  which double-counts context because Conduck resends the full history every
  turn — and no wire check can see it: such a gateway passes every check with
  `failed=0`. This is not an edge case. With no explicit `platform_toolsets.
  api_server` list, Hermes falls back to a bundle that contains both, so a fresh
  install is affected by default. Only plainly listed entries are removed, and
  only with a separate yes bound to the exact list previewed; bundle names, an
  unwritten key, unfamiliar names, commented lines and ambiguous YAML are
  described for manual editing and never rewritten. Reported from the gateway
  path and from `--show-code`, so it reaches chat-only users and configs that
  drifted after pairing. It reports and offers — it never blocks pairing.
- **Fixed: a bare `api_server:` key silently narrowed the whole API-server
  scope.** YAML reads it as null, not an empty list; it parsed as `[]`, so the
  wizard previewed `[] -> ["file"]` and on a yes wrote a file-only list,
  discarding every tool the operator had. It is now treated as the wide default
  it is, and no toolset change is proposed.
- **Install advice matches the distribution.** Any Linux was told to run `apt`.
  The package manager is detected (apt-get, dnf, yum, zypper, pacman, apk,
  xbps, emerge) with per-manager package names, and falls back to naming the
  tool honestly rather than printing a command that cannot work. `pacman` is
  never told to `-Sy`: Arch forbids partial upgrades, and a pairing wizard has
  no business prescribing a system upgrade.
- **`sudo` is no longer assumed.** Root needs no prefix, `doas` systems have no
  `sudo`, and a retry offered to a root shell would reprint the command that
  just failed. Root is now told why no retry is offered instead.
- **Lingering is checked against the right user.** It read `$USER`, which
  survives `su` and `sudo -u`, so it could answer "durable" about an account
  that was not the one `systemctl --user` was driving — and the reused-lane path
  never checked at all, silently re-shipping a lane born in a session that will
  not outlive logout. Both paths now ask `id -un`, distinguish "cannot tell"
  from "off", and re-check after enabling.
- Tracks adapter contract **revision 1.4**.
- `--help` gained an `Environment` section documenting `CONDUCK_TOKEN` (already
  in the README, never in `--help` — where someone looks before typing a token
  into argv) and `CONDUCK_CHECK_SERVER_MODEL`.
- Added `tests/run-host-environment-suite.sh` (125 assertions: package-manager
  detection and naming per distribution, privilege prefixes, linger states) and
  grew the file-lane readiness suite from 148 to 265 assertions covering recall
  classification across inline, block, bundle, wildcard, comment, anchor, flow,
  null and globally-disabled forms. The summary regex no longer pins a literal
  contract revision — every other free-moving field in it was already
  shape-matched, and the pinned literal broke the suite on a revision bump while
  guarding nothing.
- **The exposure menu's option 4 ("I already run my own HTTPS") is a gate, not a
  fork.** It accepts a certificate this machine trusts, or it stops. Apple's App
  Transport Security rejects an untrusted chain before the app is consulted, and
  a fingerprint pin can only *narrow* trust a device already has — it can never
  grant it, so a self-signed gateway never worked on a real device no matter
  what the wizard put in the code. The refusal names why the certificate failed
  and the three free routes to one that works: Tailscale Serve, Let's Encrypt
  (including its IP-address certificates, GA since January 2026, so no domain is
  needed), or a reverse proxy such as Caddy that mints and renews automatically.
  Removed with it: `compute_spki_hex`, `hex_to_b64`, the `selfsigned` transport,
  the "pin THIS certificate anyway" override, file-lane SPKI mirroring, curl
  `--pinnedpubkey` plumbing, and `certFP` from both the emitted payload and the
  on-disk profile schema. The certificate *diagnosis* stays: `cert_verify_code`
  and `cert_leaf_date_problem` still explain expiry, a wrong clock, a wrong
  hostname, or an untrusted issuer. `--check-server` / `--check-adapter` are
  unchanged — they already required a certificate this machine would trust.
- Added the regression coverage this path never had: the shipped
  `classify_own_https` is driven through its accept arm and every refusal arm
  (untrusted issuer, untrusted-and-expired, wrong hostname), asserting it stops,
  offers no override, and names all three remedies; a saved profile on the
  retired `selfsigned` transport is refused by the menu, with a
  trusted-transport control proving the filter is the transport itself; and the
  released artifact is asserted free of every pinning symbol while keeping both
  diagnosis helpers.
- The state directory's `0700` is now enforced on every run, not just the one
  that created it. `( umask 077; mkdir -p )` is a no-op on an existing
  directory, mode included, so a `~/.config/conduck` left world-listable by an
  earlier version or a different umask kept that mode forever and setup said
  nothing. Credential files inside stay `0600`, but the filenames name every
  gateway paired. A single `ensure_state_dir` is now the only creator: fresh →
  `0700` silently; already-open → reported once per run with the exact
  `chmod 700`, and never silently re-chmodded, since the connector may not have
  created it (same rule as the agent workspace).
- The real-rclone integration harness now parses rclone's startup port whether
  or not the URL is bracketed. rclone 1.60 prints it unbracketed, so on those
  builds the port came back empty and both cases failed as "rclone serve failed
  to start" — a false red about a server that had started correctly. Its
  failure path also dumps the log it actually has rather than a `doctor.out`
  that does not exist yet.
- File-server loopback ports are now allocated per gateway from a bounded range,
  excluding both live listeners and every connector-owned unit (including
  stopped units). The selected port persists in that gateway's service/profile
  and is reused on later runs; an unreadable existing unit is refused rather
  than overwritten or exposed.
- Setup now proves the exact local file-server service is active,
  authenticated, rejects missing/wrong credentials, and carries byte-identical
  writes before creating an HTTPS exposure.
- OpenClaw and Hermes file readiness is now agent-side, not WebDAV/static-config
  only: both run a real randomized
  read→byte-identical-write→reply-discovery sentinel before the lane is
  included. Hermes additionally checks the exact `terminal.cwd`, preserves an
  explicit API-server toolset while adding only the missing `file` bundle, and
  installs guidance in a verified Hermes context file. Non-local backends,
  global tool disables, ambiguous YAML/context precedence, agent failures, and
  failed cleanup stay fail-closed.
- Added focused loopback regressions for port ownership/live collisions, stable
  reuse, unsafe-unit refusal, Hermes config/guidance policy, local auth, and
  agent sentinel false-green cases.
- Hardened those readiness gates before release: the live agent turn has its
  own five-minute budget; a guarded local-root snapshot must prove the regular
  output file already existed with exact bytes when the reply returned, while
  the one real five-second WebDAV deadline is cache-visibility-only. Reply
  discovery mirrors the app's exact allowlisted-token logic; cleanup requires
  post-delete 404 for files and GET/PROPFIND absence for the temporary
  directory, and is chained through EXIT/signals by exact nonce names.
  systemd/plist reuse now requires one structural
  `ExecStart`/`--addr` authority plus an absolute served root, and
  credentials/control characters plus systemd path expansion are refused
  before use. Activity checks remain tied to the exact selected unit when
  stale per-gateway definitions duplicate a loopback port.
- Hermes's editable YAML subset now JSON-decodes double-quoted strings/arrays
  (including commas, escapes, and `#` inside quotes) and fails closed on
  single-quoted, null, non-string, complex, or comment-ambiguous values instead
  of risking a lossy rewrite. Valid direct-child indentation is detected and
  preserved (including four-space configs); inconsistent/nested ambiguity is
  refused before mutation. Quoted/spaced authoritative section keys and
  unsupported document-root forms (including flow mappings, tags, and explicit
  mapping keys) are never mistaken for missing sections or duplicated with
  plain block keys; anchors, aliases, and merge keys are globally refused
  because they can change the effective target paths.
- Security-review hardening. An endpoint URL carrying `user:pass@` userinfo is
  now refused at every prompt and on both check commands, so a password can
  never be echoed to the terminal, saved into the pairing profile, or ride
  inside a pairing code. Gateway-supplied strings — model ids, `Content-Type`,
  wire error codes — are stripped of C0 control bytes and DEL where they leave
  their parser, so a hostile server cannot forge extra `[CHECK_ID]` transcript
  lines or repaint the screen with ANSI. Every loopback probe now passes
  `--noproxy '*'`: `-q` suppresses `~/.curlrc` but not `$http_proxy`/`$ALL_PROXY`,
  which could otherwise receive a bearer token or forge an "it's up" answer
  about a local service. `OPENCLAW_GATEWAY_PORT` and `API_SERVER_PORT` are
  validated as whole 1–65535 ports, so an ordinary dotenv trailing comment can
  no longer word-split into an exposure command.
- Tighter permissions on everything the connector creates that can hold a
  secret. `${XDG_CONFIG_HOME:-$HOME/.config}/conduck/` is created `0700` — it
  holds the file-lane credential files and the saved profiles. A shared agent
  folder the connector creates is `0700`; one that already exists keeps its own
  mode and is reported rather than silently re-permissioned. An existing
  `~/.hermes/.env` that other accounts can read is reported — your gateway key is
  inside it — and `chmod 600` is offered as its own confirmed step; a file the
  connector did not create is never re-permissioned without a yes, so permissions
  hold to the same promise as contents. `--check-adapter --files` stages its
  transport probes inside one
  `0700` `mktemp -d` rather than a `mktemp` file plus sibling names built by
  string concatenation.
- Documentation corrected against the code rather than the intent.
  `WHAT-IT-TOUCHES.md` no longer claims connector temp files live in a private
  per-run directory (they do not); it gains the missing row for the shared agent
  folder — the directory that receives every attachment you send and every file
  the agent writes back; it names `$HOME/.openclaw/openclaw.json` as the fixed
  path it is (`OPENCLAW_CONFIG_PATH` was documented but never honoured); and it
  states the real OpenClaw precedence, where the compose `.env` port wins over
  the config while its token is only a fallback. `README.md` no longer says every
  `sudo` is merely printed for you: `loginctl enable-linger` is run by the script
  itself after a `y/N` approval, and that is now named as the one exception; its
  "sends nothing anywhere" line carves out the Tailscale and Cloudflare commands
  the script runs on your behalf, matching what `SECURITY.md` already said.
  `PAYLOAD.md` describes when `model` is actually present.
- Added a regression guard for the pairing profile's "never a token or
  credential" invariant (`profile-never-carries-secrets`): `write_profile` is
  driven with sentinel values in `GW_TOKEN`/`FS_CRED`, and neither may appear
  anywhere under the state directory. It runs a control against a deliberately
  leaking copy of the same function, so a guard that stopped biting fails the
  suite rather than passing quietly.
- Test fixtures no longer reverse-resolve their own bind address.
  `http.server`'s `server_bind()` calls `socket.getfqdn()` before a fixture can
  print `READY`, which blocks until the resolver gives up on a host with no
  reverse zone for `127.0.0.1` — every case needing a fixture then failed with
  nothing printed to say why. A structural guard
  (`fixtures-do-not-reverse-resolve-their-bind`) now keeps a stock
  `HTTPServer`/`ThreadingHTTPServer` out of the tree, and a fixture that fails
  to start reports its own stderr instead of the previous case's output.

## [0.13.0] — one command surface, and checks that hand off to setup

An intentional public CLI simplification, Apple-client parity,
diagnostics hardening, and repository governance. The pairing payload is
unchanged. **Two breaking changes for scripts** — both machine-summary schemas
bump; see [Migrating](#migrating) below.

- **One clear command surface:** no arguments opens a welcome action menu.
  `--setup`, `--check-server [url]`, `--check-adapter [url]`, and
  `--show-code` go directly to those actions. `--doctor`, `--compat`,
  `--show-qr`, `--openclaw`, `--hermes`, and the temporary subcommand forms are
  removed and now fail with a named error pointing at the replacement.
  `--generic` is the single exception: it stays **functional** as a
  compatibility alias for custom-server setup, because shipped Conduck app
  builds emit it (see [Migrating](#migrating)).
- **The menu asks the decisive provenance question:** option 2 is existing
  OpenAI-compatible software **not built for Conduck**; option 3 is an adapter
  built specifically for Conduck. This keeps generic servers out of the
  intentionally stricter adapter grader.
- **Stable exit-status split:** `0` is success/PASS, `1` is a setup/runtime
  failure or completed-check FAIL, and `2` is command-line misuse. Unknown or
  retired spellings, incompatible flags, extra positional arguments, and an
  invalid direct URL now identify themselves as usage errors and exit `2`.
  Both checks arm their machine-summary trap before runtime preflight, so a
  missing `curl` or `python3` exits `1` and still emits a final `NOT_RUN`
  summary instead of disappearing before the machine contract starts.
- **Detection informs; the user decides:** setup reports any OpenClaw or Hermes
  install it finds, then always requires an explicit OpenClaw, Hermes, or
  another-server choice. Pressing Enter never silently selects a detected tool.
- **Checks hand off to setup:** after an interactive PASS, both checks offer to
  continue directly into setup and pairing. The checked URL, authentication,
  token, and any proven required model remain in memory; the gateway menu is
  skipped. Setup still verifies the final app-facing HTTPS route before it
  emits a pairing code. Noninteractive and CI runs never prompt and retain a
  final machine summary plus process exit code.
- **Long required model IDs stay exact:** server-owned model identifiers are
  opaque. A required ID longer than 100 characters now survives the
  check-to-setup handoff and pairing JSON byte-for-byte; the obsolete
  100-character warning is gone.
- **Fresh machine vocabulary:** summaries are
  `CONDUCK_CHECK_SERVER schema=2 …` and
  `CONDUCK_CHECK_ADAPTER schema=3 …`. Probe artifacts use
  `conduck-check-*`; test/module filenames use check-server/check-adapter terms.
- **One Apple-compatible response evaluator:** normal setup and `--check-server`
  now share the same current-Apple-app request/body rules at the directly
  addressed endpoint—any 2xx status, strict JSON, eager decoding of every
  choice, string content with an empty string allowed, unknown fields
  tolerated, and `Accept: application/json`. Diagnostics deliberately do not
  follow redirects or forward credentials to `Location` targets; 3xx failures
  point to the final URL. The strict adapter check remains exactly-200 and
  contract-specific. Android is still work in progress and is not yet the
  compatibility authority.
- **One versioned reply corpus across implementations:** the Apple app owns the
  canonical public cases; the connector and Android WIP client consume
  byte-identical vendored snapshots. Standalone CI runs locally without a
  network fetch, while embedded URL/revision metadata keeps provenance visible.
- **More precise compatibility verdict:** PASS means core text-chat wire
  compatibility. Image capability remains separately reported and
  informational; setup separately verifies HTTPS, certificate trust/pinning,
  and reachability.
- **Transport hardening:** every connector curl call ignores curl config files,
  so an unrelated include/proxy/output/redirect directive cannot reroute a
  secret or add undeclared file access. `--check-server` and
  `--check-adapter` additionally refuse proxy environment variables so
  credentials go directly to the explicitly supplied address.
- **Honest effects wording:** plain checks change no host configuration but do
  send live requests that may consume compute or enter server-side history;
  `--check-adapter --files` remains explicitly mutating. `--show-code` changes no
  configuration but its live verification can briefly write/delete a small
  file-lane probe.
- **Release/portability safeguards:** CI exercises the regression suite on both
  Ubuntu and macOS, and the release workflow refuses a tag that does not match
  the script's `VERSION`.
- **Modular source, single release artifact:** maintainers edit responsibility-
  scoped files under `src/`; a Bash 3.2-compatible deterministic builder
  assembles the same plain `conduck-connect.sh` users download. CI and release
  gates reject source/artifact byte drift.

- **License change:** Conduck-authored code moves from MIT to the **Apache License 2.0**. Existing releases and tags (through 0.12.0) remain MIT — history is not rewritten; the first Apache-licensed release will carry a new version. The vendored Project Nayuki QR block stays MIT and is unchanged.
- **License paperwork added:** `NOTICE`, `THIRD_PARTY_NOTICES.md` (the full Nayuki MIT notice), and `TRADEMARKS.md` (name/branding policy, separate from and adding no restrictions to Apache-2.0). The script now carries an `SPDX-License-Identifier: Apache-2.0 AND MIT` header.
- **Contribution files added:** `CONTRIBUTING.md`, plus issue and pull-request templates.
- **Security policy aligned** with the Conduck project's disclosure terms in `SECURITY.md`.
- **CI runs `tests/run-checks-suite.sh`** — the adapter/server/menu/command regression matrix — on both Ubuntu and macOS, after proving `src/` still assembles byte-for-byte into the checked-in `conduck-connect.sh`. Releases ship the license files (`LICENSE`, `NOTICE`, `THIRD_PARTY_NOTICES.md`) alongside the script and checksum.

### Migrating

**Both machine-summary schemas bump.** Renaming the line prefix is a grammar
change, and the script's own contract bumps `schema=` on any grammar change —
so a parser that keyed on the prefix alone cannot silently misread the new
line.

| Before (≤ 0.12.0) | Now (0.13.0) |
|---|---|
| `CONDUCK_DOCTOR schema=2 …` | `CONDUCK_CHECK_ADAPTER schema=3 …` |
| `CONDUCK_COMPAT schema=1 …` | `CONDUCK_CHECK_SERVER schema=2 …` |

**Key on the new prefix + `schema=` + the process exit code.** The retired
prefixes are **not** dual-emitted — there is no transition window, and a script
grepping for `CONDUCK_DOCTOR` now matches nothing. Exactly **one** summary line
is still printed, as the last line of every noninteractive run, so a `tail -1`
consumer keeps working unchanged.

**`--generic` survives as a functional compatibility alias.** It maps to
custom-server setup and keeps its original meaning: it skips gateway detection,
so an unrelated OpenClaw or Hermes install on the same host can never become
the default for someone who never asked for it. It is deliberately absent from
`--help` and the welcome menu — use `--setup`. It cannot be dropped in a later
release either: Conduck app builds already on the App Store emit `--generic`
verbatim, and every client resolves `releases/latest`, so an old install always
downloads the *newest* script.

**Flags that now fail with a named error**, each naming its replacement —
`--doctor` → `--check-adapter`, `--compat` → `--check-server`, `--show-qr` →
`--show-code`, `--openclaw` / `--hermes` → `--setup` and pick the gateway from
the list. These were only ever typed by a person reading docs, so no behavior
is preserved for them.

**`CONDUCK_TOKEN` is now explicit for both checks.** Set-but-empty
(`CONDUCK_TOKEN=`) is a deliberate keyless declaration. Unset with no answer
possible — piped or closed stdin — now fails fast with that instruction
instead of quietly grading the target as keyless, which graded the wrong thing
and reported it as a pass.

## [0.12.0] — `--compat`: the question for servers you didn't build

**New mode: `bash conduck-connect.sh --compat [url]`** — read-only, like the plain doctor, but answering the OTHER question: does the Conduck **app** work with this existing OpenAI-compatible server (Ollama, LiteLLM, vLLM, LM Studio, a framework endpoint) as-is?

The doctor grades the adapter contract — the forward promise for software **built for Conduck** — and generic servers rightly fail it on rules the app itself never exercises (honoring `stream: true` with SSE is *correct* OpenAI behavior; the doctor's negative-auth probes test enforcement the app never checks). That made a doctor FAIL on your existing stack look like "Conduck won't work here" when the app would run fine. `--compat` closes that trap by mirroring the app's own validation exactly:

- **Four wire checks:** the `/v1/models` probe (JSON object with a top-level `data` array; empty is valid; ids never required; 15-second limit), the chat decode (strict JSON; the whole `choices` array must decode; `content` must be a string — an **empty** string is a valid reply; `tool_calls`/unknown fields tolerated; response `Content-Type` never read), advertised-model selection, and history-image tolerance (one earlier photo must never break later turns).
- **`model=required` servers pass** — the probe retries with the first advertised id, exactly the request the app sends once a model is configured, and threads it through every later probe.
- **Explicit keyless** (empty token at the prompt) mirrors the app's no-auth scheme; no negative-auth requests are ever sent.
- **Informational image-capability probe** (`VERIFIED` / `DECLINED` / `IGNORED` / `OPAQUE`) that never flips the verdict — the app can't detect a silently dropped image either.
- **Own machine summary, own grammar:** the last line is `CONDUCK_COMPAT schema=1 … wire=PASS|FAIL … exit=…`. Exit `0` = the app can use this server at the wire level. It never claims adapter conformance, and it can't see statefulness (Conduck resends full history each turn; a server keeping its own history double-counts context).

Also in this release:

- The manual file-lane recipe in this README now carries `--dir-cache-time 1s` on the `rclone serve webdav` line. It is **load-bearing**: rclone's default 5-minute directory cache makes agent-written files invisible to the app's instant pickup probe (`--doctor --files` catches this as `FILES_READ_FRESH`). The wizard's own units always set it; hand-rolled setups copied from older docs should add it.
- `--compat` (like `--doctor`) no longer requires `openssl` in its preflight — it never uses it.
- The doctor's machine summary is unchanged (`CONDUCK_DOCTOR schema=2`, same grammar); `--compat` adds a new line, it does not touch the existing one.

## [0.11.0] — the doctor grades the file lane (`--doctor --files`)

The file lane — how files travel between you, your agent, and the app — was the one part of a setup the doctor could not check: every transport probe could be green while agent-written files silently never reached your phone (exactly the 0.10.0 cache bug). `--files` closes that blind spot. **One breaking change for scripts:** the machine summary line is now `schema=2`.

### Added

- **`--doctor --files` — the file-lane probes, graded as three independent meters.** `file_transport` checks this host's WebDAV↔disk lane itself: authentication on the routes that actually carry your bytes (GET and PUT — missing and wrong credentials must both be refused), write-through fidelity (a PUT must land byte-identical in the configured folder — catching a server that silently serves a *different* directory), **direct-write freshness** (a file written straight to disk, exactly how agents deliver output, must become visible over WebDAV within 2 seconds — the check is primed so a cold cache can't fake a pass; this is the 0.10.0 bug as a permanent, named regression), ranged-probe compatibility (the app's existence probe is `Range: bytes=0-0`; honoring it earns full marks, answering 200 is tolerated with a note), nested folders (a clean rejection is fine — the app falls back to flat names), and DELETE (with cleanup *verified*, not assumed). `file_access` runs one real chat turn: the selected model must copy a small input file — referenced with the app's exact wire text — byte-for-byte to the folder root, *finish before replying* (the app probes the instant the reply lands; no grace period), and name the output in plain reply text where the app's detector will find it. `file_e2e` then proves the combined delivery path with the app-shaped immediate probe plus a byte-faithful download.
- **`--files` is the one doctor profile that changes anything**, and it says so up front: it writes and removes small `conduck-doctor-*` files in the configured shared folder. Artifact names carry a per-run random tag, targets are registered before creation and removed by exact name (never a pattern), the folder's identity is pinned before any direct-disk step, and cleanup that cannot be *proven* is reported as an error — never silence.
- **Lane configuration, two ways:** on the machine where the wizard ran, `--files` finds the lane through the saved pairing profile matching the doctor's URL (and cross-checks it against the live service before trusting it). Anywhere else — CI, a hand-built setup — set `CONDUCK_FILES_URL` + `CONDUCK_FILES_DIR` + `CONDUCK_FILES_PASS` (all three; optional `CONDUCK_FILES_USER`, default `conduck`).

### Changed

- **Machine summary is now `schema=2`** (breaking for summary-parsing scripts): `file_access=NOT_RUN` is replaced by three fields — `file_transport=` / `file_access=` / `file_e2e=`, each `NOT_REQUESTED|NOT_RUN|PASS|FAIL|ERROR`. `NOT_REQUESTED` means you didn't pass `--files`; `NOT_RUN` means you asked but a prerequisite stopped that tier — the distinction scripts previously could not see. File checks never flip `core=` (the file lane is an optional profile, not part of the adapter wire contract) but do count in `failed=` and force exit 1.
- The regression suite gains hermetic file-lane fault fixtures, and a separate rclone integration suite proves the freshness check catches the real-world default-cache bug and passes the fixed configuration.

## [0.10.0] — the doctor grades contract 1.3, and agent-written files appear on time

Two independent things: the `--doctor` now grades adapters against the current contract revision (1.3, published at [conduck.com/setup/adapter/v1/](https://conduck.com/setup/adapter/v1/)) with machine-readable output you can wire into a build loop — and a file-server default that silently hid your agent's output files is fixed. No breaking changes — pairing codes, flags, and profiles from 0.9.0 keep working.

### Fixed

- **The file lane now shows agent-written files immediately.** The file server (rclone WebDAV) caches folder listings for 5 minutes by default. Files *uploaded* through it appeared instantly — but a file your **agent writes directly into the folder** (which is exactly how agents return files to you) stayed invisible to the server until that cache expired. Conduck checks for the file seconds after the agent's reply, found nothing, and the download chip silently never appeared — whether it worked was a coin flip on cache timing. New file servers are now created with `--dir-cache-time 1s`, so agent-written files appear within a second. **Existing setups:** the wizard only fixes servers it creates — for a file server you already have, add `--dir-cache-time 1s` to its rclone command (the LaunchAgent plist on macOS, the systemd unit on Linux) and restart it, or recreate the lane by re-running the wizard.
- **The `--deep` image probe no longer fails honest vision models on rendering grounds.** The probe's digits were drawn too close together; a real vision model read the code reliably only when the glyphs got breathing room. Spacing widened — verified 10/10 against a live vision engine.

### Changed

- **`--doctor` grades adapter-contract revision 1.3.** New checks, all named: a **historical-image continuity** probe (a photo turn with no reply followed by a text turn must still answer — the "poisoned conversation" shape), `"stream": true` must get a synchronous JSON reply (not SSE, not a hang), the advertised model `id` must actually select (and a bogus id must get `400` with code `model_not_found`), `Content-Type` is checked on both routes, and error bodies must carry a non-empty `type`. The `--deep` image probe is now **semantic**: it renders a 4-digit code as a PNG and requires the answer to contain those digits (proving the image was *seen*, not just tolerated) — declining honestly with `400` + code `image_unsupported` still passes; silently ignoring the image now fails.
- **Every doctor verdict line carries a stable `[CHECK_ID]`**, and the last line of every doctor run — including early exits and Ctrl-C — is a one-line machine summary (`CONDUCK_DOCTOR schema=1 ...`, unrun probes reported as `NOT_RUN`). Grep the id, or parse the summary from a build script; the human text above it can keep improving without breaking your tooling.

## [0.9.0] — the agent side of the file lane

The file lane's blind spot, closed at setup time: a green file-server test proves Conduck can *store* bytes — it has never proven the **agent** may read or return them. Three gateway-side traps (all hit live, all silent — every transport check stays green) now get checked and fixed where they live. No breaking changes — pairing codes, flags, and profiles from 0.8.0 keep working.

### Added

- **OpenClaw tool-policy check in the file-lane step (runs first, before any unit or exposure work).** The wizard reads `tools.{profile,allow,alsoAllow,deny}` from `openclaw.json` (comments and trailing commas fine) and grades it. A policy that denies the agent's file tools — most commonly `tools.deny` containing `group:fs`, which makes every uploaded file invisible to the agent — gets the exact per-key before→after fix, applied only with your yes through OpenClaw's own `config set`, then re-read from the file rather than trusted. The fix is the *minimum* relaxation: `group:fs` in the deny list is replaced by `edit` + `apply_patch`, so `read`/`write` come free while the mutating members stay denied; `exec` and everything else keep their current policy. It also enables the `pdf` tool (not part of the `coding` profile — without it PDFs get read as raw bytes and answered with plausible nonsense). Wildcard deny entries and an `allow`+`alsoAllow` conflict are flagged for you, never auto-rewritten. Declining the fix never silently drops the lane — the consequence is stated plainly and you choose.
- **Agent guidance installed into the workspace `TOOLS.md`** (marker-delimited, refreshed in place on re-runs, everything else in the file untouched; symlinks and malformed markers refused). It teaches the agent three things it otherwise learns by failing: attached files are already on disk (open them — never web-search for them); media/PDF tools want the file's **absolute** workspace path when a bare name is rejected; and to *return* a file, write it to the working-directory root and **name it in plain reply text** — attachment directives like `MEDIA:` are stripped by the chat endpoint and never reach the app. The whole block is scoped to Conduck turns (they carry a `[Conduck file transfer]` marker), so the same agent's messaging channels — where `MEDIA:` is exactly right — behave as before. Guidance loads at session start; the wizard says so, and new conversations pick it up.
- **README:** the file-lane contract gains the agent-tool-policy requirement, and troubleshooting gains the three matching symptoms (agent can't see uploaded files; PDF answered with generic content; "saved" file that never arrives).

## [0.8.0] — a doctor for adapters you built yourself

New `--doctor` mode: a read-only check-up for adapters built for Conduck, graded against the rules at [conduck.com/setup/adapter/v1/](https://conduck.com/setup/adapter/v1/). No breaking changes — pairing codes, flags, and profiles from 0.7.0 keep working.

### Added

- **`--doctor [url]`.** Run it on the machine where your adapter listens and it sends a handful of real requests, grades the answers strictly, and names the first thing to fix — changing nothing anywhere. It proves what the wizard's verify step can't: that your token check is actually **enforced** — a missing token and a wrong token must each get `401`, on `/v1/models` *and* `/v1/chat/completions` (an adapter that forgot its token check passes normal verification while sitting wide open). Also graded: the `/v1/models` answer shape (with at least one usable model `id`, inside the app's 15-second patience), and one real chat turn sent the way Conduck sends it — no `model` field, an unknown extra field, `"stream": false` — whose reply must be strict JSON with exactly one choice and plain-text content. Exit code `0` means every check passed; loop it from a build script while you iterate. Plain `http://` is accepted toward `127.0.0.1`/`localhost` only, so you can test before exposing; the token comes from `$CONDUCK_TOKEN` or a hidden prompt, never the command line, and the doctor's requests ignore proxies and curl config files so they go only to the address you gave it.
- **`--deep`.** With `--doctor`: one more chat turn with an image riding along, the shape Conduck sends when a photo is attached. Answering it works; declining it honestly with HTTP `400` and a clear error also passes.
- **Pointers where you'd look for them.** When verification of a custom (`--generic`) target fails — and once at the end of a successful custom pairing — the wizard prints the exact `--doctor` command for your adapter, so you can tell an adapter problem from a connection problem. Other gateway kinds see nothing new.

## [0.7.0] — press `?` when unsure, and quieter sharp edges

Every decision prompt now explains itself in plain words on request, and a cross-surface audit (checked against current Tailscale, Cloudflare, OpenClaw, Hermes, and rclone documentation) landed a batch of correctness fixes. No breaking changes — pairing codes, flags, and profiles from 0.6.0 keep working.

> **Same-day asset refresh (2026-07-14).** The `v0.7.0` script and checksum were re-published later the same day with three small fixes; `VERSION` stays `0.7.0` and nothing about pairing changes. If a checksum you saved from the morning no longer matches, this is why. What changed: the single-model pre-fill probe now sends the token you just entered (a server that correctly rejects anonymous requests used to silently kill the pre-fill); a machine without Tailscale gets a calm "only matters if you'd pick the Tailscale path" note instead of a refusing-to-guess warning; and the `--help` text now tells `--reuse-only` apart from `--show-qr` (advanced read-only walk of a live or hand-built setup vs. re-showing a saved code), with a pointer to `--reuse-only` from `--show-qr`'s no-saved-profile message.

### Added

- **`?` help at every decision prompt.** The exposure choice, the public/private question, and the file-lane mismatch menus all take `?` and compare the options in plain words — who can reach the address, what to install, who can see traffic, and what an Apple Watch needs. Purely additive: type the answer directly and nothing changed.
- **Profiles remember the file lane's own reach.** Fixes `--show-qr` refusing with a false "your setup changed" for a public gateway paired with a private file lane (or the reverse). Old profiles keep working.

### Changed

- **OpenClaw discovery handles modern configs.** Reads JSON5 configs (comments and trailing commas no longer break detection — with a heads-up that OpenClaw's own `config set` rewrites the file as plain JSON and drops comments); honors `gateway.auth.mode` (token *and* password); never embeds a `${ENV}` placeholder or secret reference as the token — the wizard asks for the real value instead, and `--show-qr` now resolves secrets the exact same way; finds the port wherever it lives (`OPENCLAW_GATEWAY_PORT` > `gateway.port` > default, validated).
- **TLS failures name the right side.** curl exit 60 — this machine refused the *server's* certificate — is no longer reported as "the HTTPS front rejected the connection" (exit 35 keeps that wording). The Troubleshooting row's explanation covers both directions now.
- **Tailscale refusals show Tailscale's own words.** A failed `serve`/`funnel` no longer blames missing sudo rights while hiding the real error; when your tailnet still needs Funnel or HTTPS enabled, you now see Tailscale's instructions.

### Fixed

- The macOS sleep warning no longer fires on every Mac (it also matched `disksleep`/`displaysleep`).
- Bracketed IPv6 gateway URLs pin correctly (portless `https://[::1]` defaults to `:443`; no SNI is sent for IP literals), and `--show-qr` accepts IPv6 profiles.
- The advanced rclone one-liner now names `RCLONE_PASS` — run bare, it served with an *empty* password.
- Piped or exhausted input can no longer mark a press-Enter step as done; failed file-lane probes clean up their test file; `--dry-run` stopped promising a verification it never runs; a model name over 100 characters got a warning. **Historical correction:** that warning really shipped, but its premise was wrong — the pairing/app wire does not cap model IDs at 100 characters. Version 0.13.0 removes it and preserves the exact ID.

## [0.6.0] — failures that name themselves, and a README that decodes them

Better diagnosis end to end: the wizard now says *what* failed instead of making you guess, and this README gained a [Troubleshooting](README.md#troubleshooting) section keyed to the exact messages it prints. No breaking changes — pairing codes, flags, and file locations from 0.5.0 keep working.

### Added

- **A Troubleshooting section in this README** — every verification message, what it means, and the fix, plus the silent gotchas no check can catch (wrong Hermes port, wrong WebDAV root, a lane on a narrower rail than the gateway). The Conduck setup page links straight to it.
- **Empty-model-list warning.** A server whose `/v1/models` answers the canonical envelope with zero models now verifies green *with a warning* — the endpoint is real, but with no models it can't answer a chat (matches the app's own "connected — no models yet" verdict).
- **Hermes proxy-port guard.** A Hermes config whose `API_SERVER_PORT` is 8645 — the tool-less `hermes proxy`, not the full-agent API server — gets a warning and an explicit confirm. It chats fine, so nothing downstream would ever catch the silent loss of tools, skills, and memory. (`--dry-run` notes it; `--reuse-only` warns and continues.)
- **Parity + probe test suites in CI** (`scripts/test-url-normalization.sh`, `scripts/test-models-probe.sh`) — the URL normalizer is pinned to the app's fixtures, and the `/v1/models` classifier is exercised against a live local mock server, on every push and before every release.

### Changed

- **Verification failures now name the concrete cause.** The old catch-all `unreachable or rejected (URL? token? HTTPS front?)` is gone; the wizard distinguishes DNS failure, connection refused, timeout, TLS/certificate rejection, pinned-key mismatch, `401` token rejection, `404` wrong path, `5xx` server error, and an OK reply that isn't JSON — each with its own one-line fix.
- **The HTML diagnosis stopped asserting.** `/v1/models` answering a web page used to be reported flatly as "the chat endpoint is still OFF". A reverse-proxy login or access page produces the identical symptom, so the message is now hedged and kind-aware: on OpenClaw/Hermes it names the endpoint flag as the *likely* cause with the interstitial as the alternative; on a custom server it points at the proxy/base-address family instead — and it shows the HTTP status either way.

### Fixed

- **Pasting a base URL that ends in `/v1` no longer breaks every request.** Ollama/LiteLLM docs write the endpoint as `…/v1`, but the script and the app both append `/v1/…` themselves — so the pasted form probed `/v1/v1/models` and failed. User-entered gateway URLs are now normalized exactly the way the Conduck app normalizes them (strip one terminal `/v1`, `/v1/models`, or `/v1/chat/completions` — segment-wise, percent-encoding-aware, port and path prefix preserved, query/fragment dropped), and the wizard says so when it rewrites.
- The Cloudflare hostname prompt now tolerates a pasted full URL (the scheme is stripped instead of producing `https://https://…`).

## [0.5.0] — pair a second device in seconds, and verification that matches the app exactly

Two features and a stricter verify step. No breaking changes — pairing codes, flags, and file locations from 0.4.0 keep working.

### Added

- **`--show-qr` — re-show your pairing code without redoing setup.** A successful wizard run now saves a **non-secret profile** at `~/.config/conduck/profile-<gateway>.json` (routing facts only — never tokens or credentials; see `WHAT-IT-TOUCHES.md`). `--show-qr` re-emits the same QR from it with no setup questions and zero configuration changes — the fast path for pairing a second device. It validates the saved profile before trusting it (a hand-edited or corrupted file stops with a clear message instead of emitting a code the apps reject), re-derives secrets from their canonical homes (a profile whose token can't be read stops rather than emit a keyless code), and refuses with a secret-free diff if your live setup has drifted — including a profile that names a different machine on your tailnet. It never rewrites the profile: a transient verification failure can drop the file lane from one emission, never from your saved setup. It may still ask you to pick a profile, re-enter a custom gateway's token, or confirm a gateway-only code.
- **Built your own AI? The wizard now meets you halfway.** The gateway menu names "your own adapter" alongside Ollama/LiteLLM/vLLM, and a server that answers with the wrong response shape gets its own diagnosis pointing at the published adapter contract — https://conduck.com/setup/adapter/v1/ — instead of a generic failure.

### Changed — verification now matches the Conduck app exactly

The verify step previously accepted some responses the app would go on to reject, so a green pairing code could still produce a broken first connection. Every check now mirrors the app's own parser:

- `/v1/models` must answer `200` with the canonical envelope — a JSON **object** whose top-level `data` is an **array**. Valid JSON in any other shape gets the new wrong-envelope diagnosis (see the adapter contract above) instead of passing.
- The live pong must be a clean transfer (a response that times out mid-body no longer counts), HTTP `200`, and a **non-empty text** `content` — a `tool_calls` reply carrying `content: null`, an error body, or an empty answer no longer passes.
- `NaN`/`Infinity` anywhere in a response now fail: Python's parser accepts them by default, Apple's rejects them, and the wizard must never be more lenient than the app it green-lights for.
- The pong wait now matches the app's own request timeout (300 s, up from 180 s) — slow self-hosted agents no longer fail verification the app itself would have survived.

### Fixed

- JSON responses with leading whitespace were misclassified as non-JSON by a shell-level first-byte check; the real parser now decides.

## [0.4.0] — first stable release: exposure, certificate, and secret-handling fixes

A quality-control pass over the whole wizard found four paths that did not behave the way the script documented, plus one introduced while fixing them. **If you are on `0.4.0-rc.4` or earlier, upgrade** — the exposure bug below can leave your gateway publicly reachable after you asked for a private setup.

### Fixed — exposure

- **Choosing a private path could leave an old public Funnel serving your gateway.** When a port already carried a Tailscale mapping for the same gateway with the opposite verb, the wizard allocated a *different* port instead of switching that one, so an existing public Funnel kept running untouched. Worse, the run then recorded itself as private and skipped the keyless-public refusal. The mapping is now switched **in place** (confirmed in both directions), and `funnel → serve` drops the `AllowFunnel` flag explicitly, because `serve off` alone leaves a port public.
- **Stale public Funnels are now surfaced.** On a private choice, the wizard finds Funnels on *other* ports still pointing at the same gateway or file lane from an earlier setup and offers to switch them off. It never removes one without an explicit yes — see `WHAT-IT-TOUCHES.md`.
- **Rollback is genuinely fail-closed.** Undoing a file-lane exposure now proves the port is restored by re-reading Tailscale's status before claiming success; a rollback that cannot be confirmed keeps its undo record, prints the exact commands, and refuses to end the run quietly behind a green pairing code. Undo records are written only after you confirm a change, and replayed newest-first.

### Fixed — certificates

- **The certificate diagnosis never ran.** An exit code was read after the wrong statement, so every "couldn't resolve the host / connection refused / timed out" message was unreachable, and real network failures fell through to a confusing classification error.
- Broken-certificate detection now catches **not-yet-valid** certificates (a wrong clock), not just expired ones, and the **file-lane** certificate goes through the same safety gate as the gateway's before it is pinned.

### Fixed — secrets

- **The gateway token and file-lane credential no longer appear in the process list.** They were passed to `curl` as command-line arguments, which any user on the host can read via `ps`; they now ride a private stdin config. This matches the posture the script already applied to the rclone service.
- `~/.hermes/.env` is created `0600` when it does not exist (the generated key lands inside it), and an existing `API_SERVER_KEY` is reused rather than silently rotated out from under other clients.

### Fixed — prompts (found while reviewing the fixes above)

- **A typo could silently answer a safety question.** The retry warning on a no-default prompt was written to standard output, so it was captured as part of your answer. The new public-vs-private question would then read as "private" — the one value that skips the refusal to publish a keyless gateway. All prompt output now goes to standard error, and a closed input stream stops the run instead of looping forever.

### Changed

- Verification is stricter: `/v1/models` must answer **HTTP 200** with JSON (an authentication error that happens to be JSON is no longer green), the local health check accepts any answer below 500 (an auth-gated health route is still proof the gateway is up), and the test request body is built by a real JSON encoder.
- `--help` prints the whole header (it was cut off mid-sentence). Typos re-prompt rather than aborting. `--reuse-only` no longer exits when an optional step *would* have changed something — it skips it and says so. A missing systemd user session is detected **before** a credential is minted. Trailing slashes are stripped from URLs. A file lane on a non-default port is now read correctly from a macOS LaunchAgent.

### Verification

Parse + `shellcheck --severity=warning` clean, vendored QR encoder checksum verified, and the prompt, guard, and port-validation paths exercised on macOS `bash` 3.2. The companion app's pairing-payload suite is green.

> Unlike `0.4.0-rc.1`–`rc.4`, this release has **not yet been re-run end-to-end against the live OpenClaw / Hermes rigs**; the changes are covered by static analysis and targeted regression tests. It ships now because the exposure bug it fixes is worse than the risk it carries. If you hit anything, please open an issue.

## [0.4.0-rc.3] — pairing-hint accuracy fix

Same script behavior as rc.2 — still `VERSION=0.4.0`, same flags, same exposure paths, same `conduck-setup:v1` payload. A one-line accuracy fix to the closing in-app instruction; no functional or security change.

### Changed
- **Final in-app pairing hint reworded to be label-agnostic.** The closing "In Conduck:" instruction no longer names a single button label or its on-screen position — the app's setup-code entry point now lives in a top-level **Connect** section, and its label varies by state (a first-time user sees "I have a setup code"; a returning user sees "Scan or paste setup code"). The hint now points at "the setup-code option" and spells out scan-or-paste on iPhone/iPad vs paste on Mac, so it stays accurate as the app's UI evolves.

## [0.4.0-rc.2] — clarity pass

Same script behavior as rc.1 — still `VERSION=0.4.0`, same flags, same exposure paths, re-verified against the live rigs. This is a copy-and-accuracy refinement plus a friendlier dry-run summary; no functional or security change.

### Changed
- **Clarity + accuracy pass for non-engineer operators:** plainer wording throughout — a "could you open this from your phone on cellular?" rule of thumb for public-vs-private, clearer explanations of the gateway bearer token and self-signed certificate pinning, and warmer prompts. No behavior change.
- **`--dry-run` now prints a "Decisions gathered" summary** (gateway, reachability, transport, resolved URL, any self-signed pin) just before the ordered list of actions a real run would take.

### Docs
- README leads with a single **download → verify → run** Quick start command — checksum-gated (a tampered download is refused before anything runs), and the wizard still asks before every change. Read-first and `--dry-run` variants are kept alongside.

## [0.4.0-rc.1] — first public pre-release

First public, auditable release. The script itself is `VERSION=0.4.0`, live-rig verified against OpenClaw, Hermes, and a keyless OpenAI-compatible (`--generic`) gateway, across the exposure paths (Tailscale, Funnel, Cloudflare Tunnel, and own-HTTPS including self-signed pinning).

> The Conduck app is not yet public; this pre-release exists so the script can be read and audited ahead of launch.

### Script 0.4.0 — highlights
- **File-lane scope alignment:** when an existing agent file lane is reachable on a different scope than the gateway, the wizard offers to *align* it (promote private→public behind an explicit publication confirm, or demote public→private), *omit* it, or *include as-is*. File-lane exposure changes are fail-closed: rolled back if the lane is dropped.
- **`--dry-run`** is a baseline-and-plan — shows current state and the exact actions a real run would take, then stops. No secrets, no mutation, no QR.
- **`--reuse-only`** reuses existing config and refuses any mutation — safe to point at a live box.
- **Local terminal QR** via a vendored, stdlib-only Python encoder — no `qrencode`, no install.

[0.4.0-rc.3]: https://github.com/gigaduckai/conduck-connect/releases/tag/v0.4.0-rc.3
[0.4.0-rc.2]: https://github.com/gigaduckai/conduck-connect/releases/tag/v0.4.0-rc.2
[0.4.0-rc.1]: https://github.com/gigaduckai/conduck-connect/releases/tag/v0.4.0-rc.1
