# Pairing payload — wire contract v1

The script emits a pairing code that the Conduck app imports (scan or paste). The QR and the paste string carry identical content.

```
conduck-setup:v1:<base64(minified JSON)>
```

The base64 is standard and unwrapped (single line). The decoded JSON:

```json
{
  "v": 1,
  "gateway": {
    "kind": "openclaw | hermes | custom",
    "name": "<custom gateways only>",
    "url": "https://…",
    "auth": "bearer | none",
    "token": "<omitted when auth is none>",
    "model": "<omitted unless setup resolved a model name>"
  },
  "fileServer": {
    "url": "https://…",
    "credential": "<hex secret>",
    "folderCapable": false,
    "autoDeliver": false,
    "filenamePolicy": "preserve"
  },
  "transport": "tailscale | funnel | cloudflare | public"
}
```

## Rules

- **`v` gates parsing.** An unknown major version means "update the app, or update the script." Unknown keys are ignored (tolerant decode).
- **Conditional fields are omitted, not null.** `name` only for custom gateways; `token` only when `auth` is `bearer`; the whole `fileServer` object only when the file lane is configured; each of the three file-delivery fields below only when its minter has something to state. `model` is present whenever setup ended up with one — because you named it with `CONDUCK_CHECK_SERVER_MODEL` and continued from that check into setup, because a check proved the gateway requires it, because the server advertised exactly one and you accepted that default, or because you typed it — and omitted when you left model selection to the app.
- **No URL carries userinfo.** `conduck-connect` refuses a `user:password@` address at every prompt, so a code it mints never puts a credential inside a routing field.
- **The three file-delivery fields are stated only to deviate from the app's own default, and `conduck-connect` states none of them.** Every code this script mints carries a bare `{url, credential}` file-server block; the app's own "share this setup" export is the minter that fills the other three in. A missing key always means "unstated, keep the importing device's own default" — never an explicit `false` and never an empty policy — so a two-field block and a five-field block agreeing on the defaults describe the same lane.
  - **`folderCapable`** — whether the server accepts a `PUT` into a folder it has to create. A measurement of the server, not a permission, so the app applies whichever value a code states. The app's export states it only when that device itself ran a file-server test and that test said **`false`**; `true` is what an unmeasured lane already assumes, so stating it adds nothing. An importing device still ends up not-ready and must run its own test, which re-measures this from scratch.
  - **`autoDeliver`** — may this gateway put files on the device automatically. **Monotonic: a code may restrict, never grant.** The app honours a `false` and ignores a `true`, because a code is scannable input a stranger can craft and the import screen the user approves names the destination, not the permissions — so a `true` would quietly re-enable delivery on a gateway where it had been switched off, with nothing on screen having said so. Nothing is lost: `true` is already the default.
  - **`filenamePolicy`** — how a delivered file's name is treated. `preserve` is the only token in the vocabulary, so nothing states it today; the rule is written now so the day a second policy exists a code carries it without a wire revision. An unrecognised value resolves to the default rather than failing the import.
- **A device's own readiness never travels, and neither does its listing verdict.** `available` (this lane passed a test *here*) and the "this server can't list folders" verdict are both settled by the importing device's own test — the scanning device may sit on a different network and evaluates the server itself. An import therefore lands the lane not-ready and forgets whatever listing verdict the target ref used to hold, rather than inheriting either across the wire.
- **`transport` is informational.** It is your explicit path choice, and it drives display copy only — it is never load-bearing for trust.
- **The payload carries no certificate material.** Every endpoint in a code must present a certificate the receiving device already trusts on its own. A pin is an *additional* restriction on a connection the system already accepts; it can never rescue an untrusted chain, so there is no field through which a code could grant trust. `conduck-connect` refuses to mint a code for an endpoint whose certificate this machine does not trust.
- **The token and the file-lane credential are secrets.** The code is scannable by anyone who can see your screen; the script warns you when it emits it.
- **The app hard-rejects an invalid payload — whole, never partially** (mind this if you mint codes yourself): every URL must be `https://`, with a non-empty host and **no `user:password@` userinfo**; `auth: "bearer"` with a missing or empty `token` rejects (fail closed — never an unauthenticated import); `kind: "custom"` requires a nonempty `name`; a missing or non-integer `v` rejects. One admissibility rule covers every endpoint URL the app persists — gateway, file server, and custom voice endpoint alike — and it is applied on **read** as well as on import, so an endpoint stored by an older build, or synced in from a device on a different version, can never be requested either.

This contract is **locked at v1** — fields are added compatibly (tolerant decode), never repurposed.
