# ----------------------------------------------------------- explanations --

# Small, reusable information panels for the interactive setup flow. The caller
# decides when to offer them (normally the visible `i` affordance) and redirects
# stdout to stderr when it is collecting an answer with command substitution.
#
# These panels explain ONE current decision. "Later" is deliberately about
# persistence or a concrete inverse action, never a promise that Back, Ctrl-C, a
# failed later step, or a re-run rolls the setup back. WHAT-IT-TOUCHES.md is the
# detailed authority; this catalog is its concise, in-flow counterpart.
explain_panel() { # explain_panel <about> <why> <does> [if-skipped] [later]
  local about="$1" why="$2" does="$3"
  local skipped="${4:-}" later="${5:-}"

  say ""
  say "  ${BOLD}About this step:${RESET} $about"
  [ -z "$why" ] || say "  ${BOLD}Why:${RESET} $why"
  [ -z "$does" ] || say "  ${BOLD}It does:${RESET} $does"
  [ -z "$skipped" ] || say "  ${BOLD}If skipped:${RESET} $skipped"
  [ -z "$later" ] || say "  ${BOLD}Later:${RESET} $later"
  say ""
}

# Copy catalog for the bounded choices and consent gates in setup. IDs are
# internal, stable spellings for prompt call sites; they are never user input.
explain_action() { # explain_action <action-id>
  local action_id="${1:-}"

  case "$action_id" in
    general)
      explain_panel \
        "Review the current setup question" \
        "This choice controls only the action described immediately above it." \
        "An explanation changes no answer and performs no action; the same question is shown again." \
        "Saying No leaves this action undone." \
        "No, Back, stop, and re-running do not undo actions you already approved."
      ;;

    nav.main|main-menu)
      explain_panel \
        "Choose what conduck-connect should do" \
        "Setup pairs a gateway; the two checks answer narrower compatibility questions; a saved code pairs another device." \
        "Only setup may offer host changes. Checks send live requests, and showing a saved code runs live verification." \
        "Nothing starts until you choose an option." \
        "Gateway, user-owned configuration, and network exposure changes still have their own preview or approval; connector bookkeeping stays inside the setup action you chose."
      ;;

    nav.gateway|gateway-selection)
      explain_panel \
        "Choose the gateway Conduck will talk to" \
        "The gateway supplies the chat or full agent turn behind the Conduck client." \
        "Reads the usual OpenClaw and Hermes locations, reports what it finds, and records only your explicit choice for this run." \
        "Setup cannot continue until a gateway is chosen." \
        "Returning here changes the wizard's route only; host changes you already approved stay in place."
      ;;

    nav.saved_profile)
      explain_panel \
        "Choose which saved gateway code to re-show" \
        "Each non-secret profile records routing facts for one earlier successful setup." \
        "Selects one profile for drift checks, secret re-derivation, live verification, and code output; this menu changes nothing." \
        "No saved gateway is selected and no code is shown." \
        "The profile is not rewritten, whichever one you choose."
      ;;

    nav.custom_gateway_pick)
      explain_panel \
        "Choose whether this is a gateway you already set up, or a new one" \
        "A gateway is filed under an id derived from its name, and that id also names its file-service and credential — so retyping a name inexactly would build a second gateway rather than change the first." \
        "Selecting a listed gateway keeps its existing id and asks for its current address and token; choosing the last option starts a new gateway with a name not already in use." \
        "No gateway is selected and setup cannot continue past this question." \
        "Nothing is changed by choosing: a selected gateway's saved setup is only rewritten once this run verifies successfully."
      ;;

    check.continue_setup|nav.continue_after_check|continue-after-check)
      explain_panel \
        "Continue from a passing check into setup and pairing" \
        "The check proved this address speaks the wire format Conduck needs; setup can now make it reachable over HTTPS and print a code." \
        "Reuses the checked URL and authentication in memory, then starts the normal consented setup flow." \
        "The passing check ends without making setup changes." \
        "The token is not saved by the check; setup still verifies the final app-facing address."
      ;;

    gateway.custom.has_https|gateway.custom.address|custom-address)
      explain_panel \
        "Tell setup whether this server already has HTTPS" \
        "Conduck accepts an HTTPS address; a loopback-only server still needs an exposure path." \
        "Chooses whether to ask for an existing HTTPS URL or the server's local listening port." \
        "Choosing No asks for the server's local port, then offers an HTTPS exposure path." \
        "This choice changes no server configuration by itself."
      ;;

    gateway.custom.has_auth|gateway.custom.auth|gateway-auth)
      explain_panel \
        "Describe how this gateway authenticates clients" \
        "Conduck must store an explicit bearer or keyless mode; a missing token is never silently treated as keyless." \
        "Takes the token at a hidden prompt that shows nothing as you type, so a paste is never echoed to the screen or left in scroll-back; an empty answer asks you to confirm keyless rather than assuming it." \
        "Choosing keyless means anyone who can reach the address can use what the gateway permits." \
        "Setup refuses to publish a keyless gateway unless the expert override was supplied."
      ;;

    gateway.custom.model|model-choice)
      explain_panel \
        "Choose the model name Conduck will send" \
        "Some OpenAI-compatible servers require a model on every request; others choose their own default." \
        "Stores the selected model in the pairing payload and sends it on later Conduck turns." \
        "A blank value leaves model selection to the server." \
        "This does not load, install, or change a model on the server."
      ;;

    gateway.custom.port)
      explain_panel \
        "Enter the local port where this server listens" \
        "Setup needs the loopback address before it can create or describe an HTTPS route to the server." \
        "Validates a whole port number from 1 to 65535 and keeps it in memory for this run; it does not open, close, or rebind the port." \
        "No local target is available for exposure or verification." \
        "The server keeps its existing port configuration."
      ;;

    gateway.custom.review)
      explain_panel \
        "Review the custom gateway details gathered so far" \
        "The next steps use this address, auth mode, and optional model to build the app-facing connection." \
        "Shows the resolved choices for review; it does not contact or reconfigure the server by itself." \
        "Setup does not proceed with details you have not accepted." \
        "Returning to an earlier choice changes the wizard route only; approved host changes remain."
      ;;

    gateway.openclaw.enable_chat|openclaw-chat-endpoint)
      explain_panel \
        "Enable OpenClaw's OpenAI-compatible chat endpoint" \
        "Without this endpoint the gateway can look healthy while Conduck has no chat route to call." \
        "Uses OpenClaw's own config command to set the chat-completions flag. A JSON5 config may be rewritten as plain JSON and lose comments." \
        "Conduck will not connect through this route." \
        "Set the flag back to false and restart OpenClaw to reverse this specific change."
      ;;

    gateway.openclaw.manual_enable_chat)
      explain_panel \
        "Enable OpenClaw's chat endpoint on a non-standard install" \
        "Without this endpoint the gateway can look healthy while Conduck has no chat route to call." \
        "Prints OpenClaw's exact config command for you to run, followed by a restart using the method appropriate for your install." \
        "The endpoint stays off and later verification is expected to fail." \
        "Enter only reports that you ran it. The setting persists until you set it back to false and restart."
      ;;

    gateway.hermes.accept_8645|hermes-proxy-port)
      explain_panel \
        "Continue with Hermes port 8645" \
        "Port 8645 is the tool-less Hermes proxy, not the full-agent API server normally found on 8642." \
        "Continues pairing a route that can chat but does not carry Hermes tools or skills." \
        "Setup stops so you can correct API_SERVER_PORT first." \
        "Changing to the full-agent port requires updating Hermes and re-running setup."
      ;;

    gateway.hermes.enable_api|hermes-api-server)
      explain_panel \
        "Enable the Hermes OpenAI API server" \
        "Conduck needs Hermes's API-server route for full agent turns." \
        "Appends the shown API_SERVER settings to ~/.hermes/.env, reuses an existing key or creates one if absent, then offers a restart." \
        "The API server stays off and later verification is expected to fail." \
        "Remove the dated conduck-connect block and restart Hermes to reverse this specific edit."
      ;;

    security.owned_file.chmod_0600|secret-file-mode)
      explain_panel \
        "Restrict a file that contains a gateway or file-lane secret" \
        "Its current permissions let other accounts on this machine read the secret." \
        "Runs the shown chmod 600 command; it changes file permissions, not file contents." \
        "The secret remains readable by those accounts, and setup warns again." \
        "The 0600 mode stays until you deliberately change it."
      ;;

    gateway.restart|gateway.openclaw.restart_chat|gateway.hermes.restart_api|file.openclaw.restart_tools|file.hermes.restart_config|service-restart)
      explain_panel \
        "Restart the gateway after an approved configuration change" \
        "The running service may keep its old settings until it reloads them." \
        "Restarts the named gateway service, which may be briefly unavailable while it comes back." \
        "The file edit stays, but the live gateway may still use the old setting." \
        "A restart does not undo or rewrite the configuration change."
      ;;

    gateway.hermes.manual_restart_api|file.hermes.manual_restart)
      explain_panel \
        "Restart Hermes using the service method for this machine" \
        "The approved file edit does not affect the running API server until Hermes reloads it." \
        "Prints a suggested restart command for you to run; conduck-connect does not run it on this path." \
        "The file stays changed, but live Hermes may still use the old setting." \
        "Enter only reports that you restarted it. A restart does not undo or rewrite the file edit."
      ;;

    file.openclaw.allow_tools|gateway.openclaw.file_policy|openclaw-file-policy)
      explain_panel \
        "Allow the OpenClaw agent to use Conduck's file lane" \
        "A working WebDAV lane is not enough if OpenClaw's tool policy still denies file reading, writing, or PDF handling." \
        "Shows the exact policy before and after, applies only the approved keys through OpenClaw's config command, then offers a restart." \
        "Chat still works, but the agent may not read uploads or return files." \
        "Restore the shown prior values and restart OpenClaw to reverse this policy edit."
      ;;

    file.openclaw.manual_tools)
      explain_panel \
        "Apply the OpenClaw file-tool policy on a non-standard install" \
        "The agent needs the approved read, write, and PDF tool policy before Conduck's file lane is useful." \
        "Prints the exact OpenClaw config commands for you to run, followed by a gateway restart using your install's method." \
        "Chat still works, but the agent may not read uploads or return files." \
        "Enter only reports that you completed the commands. Restore the shown prior values and restart to reverse the policy edit."
      ;;

    file.openclaw.keep_unready)
      explain_panel \
        "Continue with a file lane whose OpenClaw tool policy is not ready" \
        "The byte transport can exist even while the agent is unable to read uploads or write returned files." \
        "Keeps evaluating this lane without changing the OpenClaw policy; the later real agent test still has to pass before the lane reaches the code." \
        "The optional lane is left out now; chat is unaffected." \
        "Fix the policy and re-run setup. This choice does not undo earlier file-lane or gateway changes."
      ;;

    file.hermes.apply_config|gateway.hermes.file_alignment|hermes-file-alignment)
      explain_panel \
        "Align Hermes with Conduck's shared folder" \
        "The agent and the file server must use the same folder, and the API-server scope must include file tools." \
        "Applies the exact before and after for terminal.cwd and, only when needed, the API-server file toolset. If you staged recall removal in the preceding review, that same atomic edit removes only those shown recall entries too." \
        "The byte transport may work while Hermes cannot open uploads or return outputs." \
        "Restore the shown prior values and restart Hermes to reverse this edit."
      ;;

    gateway.hermes.remove_recall|gateway.hermes.recall|hermes-recall)
      explain_panel \
        "Remove Hermes recall from its API-server scope" \
        "Conduck sends the full conversation each turn; Hermes recall can add hidden or duplicate context that Conduck did not send." \
        "Removes only memory and session_search from the explicit list you were shown, then offers a restart." \
        "Pairing can continue, but the API server may keep its own cross-chat recall." \
        "Every client using this API server loses that recall; Hermes CLI and messaging memory stay. Put the shown entries back and restart to reverse it."
      ;;

    gateway.hermes.show_recall_manual)
      # Deliberately NOT shaped like the removal panel above it. This question
      # changes nothing at all — it only decides whether a long set of by-hand
      # YAML instructions is printed — and a panel that described it in the
      # language of an action would teach the operator to fear a `y` that is
      # free. What it prints depends on the shape of the config: an exact
      # replacement list where one can be proven safe, otherwise what to look for.
      explain_panel \
        "Print the by-hand instructions for narrowing Hermes's memory scope" \
        "Where this script cannot make the edit safely, the fix is yours to make, and the instructions run long enough to be worth asking about first." \
        "Prints text only: what to change in ~/.hermes/config.yaml, the exact replacement list where one can be proven not to drop toolsets you configured, and what the global alternative costs. It writes nothing, restarts nothing, and changes no file." \
        "Nothing happens and nothing changes; the finding above stays on screen and pairing continues either way." \
        "Nothing to reverse — no file is touched. Re-run this script whenever you want the instructions."
      ;;

    file.hermes.remove_recall)
      explain_panel \
        "Include Hermes recall removal in the combined file-readiness edit" \
        "Conduck sends the full conversation each turn; Hermes recall can add hidden or duplicate context that Conduck did not send." \
        "Stages removal of only memory and session_search in the combined Hermes review. It changes no file and restarts nothing at this step." \
        "The later review leaves the API-server scope unchanged unless you approve its exact combined edit." \
        "The next Apply question performs one atomic config edit and then offers the restart; every client using this API server is affected if you approve it."
      ;;

    file.openclaw.guidance|file.hermes.guidance|gateway.agent_guidance|agent-guidance)
      # Shared with OpenClaw, whose block carries no PDF rule, so nothing here
      # names a specific command: the accurate statement for both agents is that
      # the block is text and may point the agent at tools it already has.
      explain_panel \
        "Install Conduck file-transfer guidance for the agent" \
        "The agent needs to know that uploads are already on disk, how to read what it is handed, and how to return a finished file to Conduck." \
        "Adds or refreshes only the marked Conduck block in the selected agent context file; content outside the markers is untouched. The block is instructions only: it installs nothing and grants no new tool access, though it can direct the agent to use tools it already has, with the permissions it already has." \
        "The transport may pass while the agent mishandles uploads, answers from a filename it never read, or returns no downloadable file." \
        "New agent sessions read the block. Delete the block including both markers to remove it."
      ;;

    exposure.choose|exposure-choice)
      explain_panel \
        "Choose how Conduck reaches this gateway over HTTPS" \
        "The phone, tablet, Mac, and sometimes a standalone Watch must be able to reach the final address." \
        "Compares private Tailscale, public Funnel, Cloudflare, and an HTTPS address you already operate. The menu itself changes nothing." \
        "No reachable app-facing address is selected." \
        "Back returns to gateway selection; configuration changes already approved stay in place."
      ;;

    exposure.scope|scope-classification)
      explain_panel \
        "Classify an existing HTTPS address as public or private" \
        "The answer controls safety checks, especially the refusal to publish a keyless gateway." \
        "Records whether the address works from the open internet or only inside your network or VPN; it does not change the address." \
        "Setup cannot apply the correct keyless-access guard." \
        "If unsure, public is the stricter classification and does not weaken protection."
      ;;

    exposure.tailscale.make_private|exposure.tailscale.private|tailscale-private)
      explain_panel \
        "Create or switch to a private Tailscale Serve address" \
        "Conduck needs trusted HTTPS without exposing the gateway to the open internet." \
        "Continues to the exact Tailscale Serve command and its own approval. If approved there, it maps a tailnet-only HTTPS port to the gateway's loopback port. Each Conduck device needs Tailscale; a Watch relies on its nearby iPhone." \
        "The private address is not created or an existing public mapping is left as it is." \
        "The exact off or prior-mapping command is shown if this run later needs exposure cleanup; unrelated host edits remain."
      ;;

    exposure.tailscale.make_public|exposure.tailscale.public|tailscale-public)
      explain_panel \
        "Create or switch to a public Tailscale Funnel address" \
        "A public address lets Conduck connect without Tailscale on each device and lets a standalone Watch connect directly." \
        "Continues to the exact Tailscale Funnel command and its own approval. If approved there, it maps a public HTTPS port to the gateway's loopback port. Anyone who finds the URL can reach the gateway; its token is the lock." \
        "The gateway remains private or unreachable through this path." \
        "Turn that Funnel port off, or restore the prior mapping shown by setup, to reverse this exposure only."
      ;;

    exposure.cleanup.stale_public|exposure.stale_public.close|stale-public-exposure)
      explain_panel \
        "Close an older public Funnel that still targets this service" \
        "Choosing a private path is not private while another matching Funnel remains open on a different port." \
        "Turns off only the named public mapping after you approve it; mappings for other services are left alone." \
        "That older public address stays reachable." \
        "This is intentional cleanup and is not recreated by setup's exposure rollback. Recreating it later requires a new explicit Funnel command."
      ;;

    exposure.cleanup.orphaned)
      explain_panel \
        "Resolve an exposure left by an interrupted earlier run" \
        "The saved undo record says an earlier run may have left this exact Tailscale port mapped." \
        "Re-reads live Tailscale state and, with your approval, applies only the recorded cleanup or prior private mapping for that port." \
        "The mapping may stay reachable and the record remains for a later run." \
        "This repairs the named exposure only; it does not restore configuration files, restarts, commands you ran, or intentional stale-Funnel cleanup."
      ;;

    exposure.tailscale.privileged_retry)
      explain_panel \
        "Retry the shown Tailscale command with operator or elevated rights" \
        "Tailscale refused the first attempt, commonly because this account may not change Serve or Funnel mappings." \
        "Prints the exact sudo, doas, or root command for you to run; conduck-connect does not elevate silently." \
        "The requested mapping or cleanup remains unconfirmed." \
        "Enter only reports that you ran the command. It does not execute it or undo earlier changes."
      ;;

    exposure.tailscale.apply)
      explain_panel \
        "Apply the Tailscale Serve or Funnel command shown above" \
        "This is the step that turns the chosen HTTPS reachability into a live mapping." \
        "Runs the exact displayed Tailscale command, then re-reads Tailscale status instead of assuming it worked." \
        "No new mapping is confirmed; an existing mapping stays as reported above." \
        "Setup records this exposure's exact prior state for bounded cleanup. It does not record or undo unrelated host changes."
      ;;

    exposure.rollback.failed_run)
      explain_panel \
        "Clean up Tailscale exposure changes from this failed run" \
        "A setup code was not emitted, so a mapping opened or replaced during this run should not be left behind silently." \
        "Runs only the listed exposure undo commands and verifies each affected port against live Tailscale state." \
        "A public or private mapping from this run may remain live; the exact manual commands are printed again." \
        "This cleanup is limited to recorded exposure mappings. Configuration edits, restarts, guidance blocks, and commands you ran stay in place."
      ;;

    exposure.cloudflare.gateway|exposure.cloudflare.manual|cloudflare-manual)
      explain_panel \
        "Add a Cloudflare Tunnel route for this service" \
        "Cloudflare needs a hostname and ingress rule that forward to the local gateway or file-server port." \
        "Prints the DNS/tunnel command for you to run. conduck-connect does not change Cloudflare configuration itself." \
        "No Cloudflare hostname is connected to this service." \
        "Enter only means you ran the command; it does not execute it or undo earlier changes."
      ;;

    file.cloudflare.route)
      explain_panel \
        "Add a Cloudflare Tunnel route for the file lane" \
        "Attachments need their own hostname and ingress rule pointing to the local file-server port." \
        "Prints the DNS/tunnel command for you to run. conduck-connect does not change Cloudflare configuration itself." \
        "The file lane is omitted or remains unreachable through Cloudflare; chat can still work." \
        "Enter only means you ran the command. It does not execute it or undo earlier changes."
      ;;

    exposure.own_https|own-https)
      explain_panel \
        "Use an HTTPS address you already operate" \
        "Conduck requires encryption and a certificate the device already trusts." \
        "Validates the address and certificate, then records its reach for the pairing code. It does not reconfigure your proxy or certificate." \
        "Setup stops before pairing this address." \
        "A self-signed certificate cannot be accepted by an override; fix HTTPS or choose another exposure path."
      ;;

    file.setup.enable|files.setup|file-lane)
      explain_panel \
        "Set up optional file transfer between Conduck and the agent" \
        "The file lane carries uploads to a shared folder and makes completed agent files downloadable in Conduck." \
        "May create or reuse a shared folder, a loopback WebDAV service, credential files, and a separate HTTPS mapping." \
        "Chat still works, including content that fits inline, but the pairing code carries no file server." \
        "The folder may also be the agent's workspace. Stop the service and inspect the folder before deleting anything."
      ;;

    file.address.skip)
      explain_panel \
        "Deliberately leave a working file lane out of this setup code" \
        "A blank can mean you chose to omit file transfer, but it can also be a paste that did not land. This check prevents one stray Enter from silently discarding a lane that already passed its local tests." \
        "Yes omits file transfer from this code and saved profile. It does not stop the file service, remove its folder, or undo a route you created." \
        "No—or pressing Enter—returns to the address prompt so you can try again." \
        "Adding the lane later requires re-running setup. Pressing q stops the run but leaves earlier approved changes in place."
      ;;

    file.folder.override|files.folder|shared-folder)
      # This panel now answers TWO prompts, and they differ on the one thing an
      # operator reading it is about to do. OpenClaw and Hermes offer a default the
      # wizard knows and may create; every other gateway offers none and refuses a
      # path that is not already on this machine, because only the agent's own
      # folder can be the right answer there. A panel that promised creation would
      # be read by exactly the operator the refusal then bounces.
      explain_panel \
        "Choose the folder shared by Conduck and the agent" \
        "Every uploaded attachment lands here, and every file the agent returns must be written here, so it has to be the folder your agent itself reads and writes." \
        "Records an absolute folder for the lane. On OpenClaw and Hermes, whose working folder this wizard knows, a new lane may create it with private permissions. On any other gateway the path must already exist on this machine and is refused if it does not; an existing folder keeps its own mode either way." \
        "The default folder is used where one is shown. Where none is — any gateway other than OpenClaw and Hermes — there is nothing to fall back on, so a blank answer is refused and the question is asked again." \
        "This folder may contain your own or the agent's files. Back, Ctrl-C, and re-running do not delete it. At the no-default prompt, q stops the run and leaves earlier approved changes in place."
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
        "Include a file server the agent did not prove it can use" \
        "Bytes moved through the folder, but the sentinel that proves your agent can USE it did not pass — which is what a server with no file tools always does, and also what a wrong folder, a container, one failed turn, or a probe the file server itself refused looks like. The screen you came from names which step fell short." \
        "Yes puts the file server in this setup code; the code has no field for a caveat, so Conduck will show file transfer as enabled. No leaves it out of the code and closes an HTTPS route this run opened for the lane, so nothing stays reachable for a lane the code does not carry." \
        "Attachments stay inline-only in Conduck. The file service, its folder, and its contents keep running untouched; a route this run opened for the lane is switched off again, and a mapping it replaced is put back." \
        "Either answer leaves the running file server exactly as it is. Adding the lane to a code afterwards means re-running setup."
      ;;

    file.unit.repair_envfile|file.service.move_port|files.repair|file-lane-repair)
      explain_panel \
        "Repair a connector-owned file-server service" \
        "The saved service definition is incomplete, unsafe to reuse, or conflicts with another connector-owned lane." \
        "Rewrites only the named conduck-files service or moves it to the shown free loopback port, then verifies the live service." \
        "File transfer stays unavailable or continues using the broken definition." \
        "The connector-owned unit and credential remain until you stop and remove them explicitly."
      ;;

    file.exposure.make_public|files.expose_public|file-lane-public)
      explain_panel \
        "Expose the shared file lane to the public internet" \
        "A public gateway needs a similarly reachable file lane for attachments to work away from your private network." \
        "Continues to the exact public-exposure command and its own approval. If approved there, it publishes the file server's HTTPS route. Anyone who finds it can reach the login; the file credential is the lock." \
        "The lane stays private or is omitted from the pairing code, while chat can still work." \
        "This consent covers the file route only. Use the shown off or restore command to reverse that exposure."
      ;;

    file.exposure.keep_private)
      explain_panel \
        "Keep the file lane private when the gateway is public" \
        "No free Funnel port is available, but the existing Tailscale-only file lane can still serve your own tailnet devices." \
        "Keeps the current private mapping and includes that narrower file address in the pairing code; it creates no new public exposure." \
        "The file lane is omitted from the code; public chat still works." \
        "Attachments work only on Tailscale-connected devices. A standalone Watch away from its iPhone cannot reach this private lane."
      ;;

    file.service.enable_linger|files.systemd_linger|systemd-linger)
      explain_panel \
        "Keep the Linux file-server service running after logout and reboot" \
        "A user service without lingering stops after that user's last session, so attachments later fail while chat still works." \
        "Runs the shown loginctl enable-linger command; this is the setup flow's one sudo action it may run for you." \
        "The file lane works only while that user has an active session and may not return after reboot." \
        "Run loginctl disable-linger for that user to reverse this setting."
      ;;

    manual.command|manual-command)
      explain_panel \
        "Run a command that changes infrastructure you own" \
        "conduck-connect leaves this command to you because it touches your gateway, tunnel, proxy, or service outside the connector-owned boundary." \
        "Prints the exact command and waits. Pressing Enter only reports that you ran it; it does not execute or verify the command." \
        "The command is not run, and the dependent setup step may fail or remain incomplete." \
        "Skipping this command does not undo changes already approved."
      ;;

    check.server|check-server)
      explain_panel \
        "Check existing OpenAI-compatible software against the Conduck app" \
        "This answers whether the current app can use the server's model list and chat replies as-is." \
        "Changes no host configuration, but sends real model and chat requests that may use quota and appear in provider or server history." \
        "No compatibility result is produced." \
        "A pass is app compatibility, not the stricter adapter-contract grade."
      ;;

    check.adapter|check-adapter)
      explain_panel \
        "Grade software built specifically for Conduck" \
        "A purpose-built adapter must satisfy stricter auth, response, model, and stream rules than generic OpenAI software." \
        "Sends live positive and negative-auth requests. The optional files profile also writes and removes exact named probe artifacts." \
        "No adapter-contract result is produced." \
        "Use check-server instead for software not built for Conduck."
      ;;

    verify.live|live-verification)
      explain_panel \
        "Verify the final address before printing a setup code" \
        "The code should point only to a route the Conduck app can actually use." \
        "Sends a model-list request and a real chat turn, which may use provider quota or enter logs/history. A configured file lane also gets temporary authenticated probes and one real agent copy test." \
        "No setup code is printed until the required checks pass; approved configuration changes stay in place." \
        "Probe files are removed, or their exact names are printed when cleanup cannot be proved."
      ;;

    show_code.run|show-code)
      explain_panel \
        "Re-show a saved pairing code" \
        "This is the fast path for pairing another device without walking through setup choices again." \
        "Reads a non-secret saved profile, re-derives credentials from their real homes, checks for drift, and runs live verification." \
        "No code is shown." \
        "It changes no configuration and never rewrites the saved profile, but its live probes may use quota and temporary file artifacts."
      ;;

    verification.gateway_only|show_code.gateway_only|gateway-only-code)
      explain_panel \
        "Print a pairing code without the failing file lane" \
        "A healthy gateway can still provide chat when optional file transfer is unavailable." \
        "Drops the fileServer block from this code only; it does not delete the saved lane, its service, folder, or credential." \
        "No code is printed until the file lane is fixed or you make this choice." \
        "The saved profile keeps its file lane, so a later show-code run checks it again."
      ;;

    pairing.code|pairing-code)
      explain_panel \
        "Bring the verified gateway into the Conduck app" \
        "The app needs the gateway address, explicit auth mode, and optional file lane without asking you to retype them." \
        "Prints a QR and paste string containing the gateway token and, when present, the file credential. It also saves a 0600 routing-only profile with no secrets." \
        "The app is not paired from this run." \
        "Treat the code like a password. Anyone holding it has the access those credentials grant until you rotate them."
      ;;

    *)
      explain_panel \
        "Review the current setup action" \
        "This choice controls only the step described immediately above the prompt." \
        "Showing this explanation changes no answer and performs no action; the same prompt appears again." \
        "Declining or stopping leaves this action undone." \
        "No, Back, stop, and re-running do not undo actions you already approved."
      return 0
      ;;
  esac
}
