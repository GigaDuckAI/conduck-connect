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
    "certFP": "<SPKI SHA-256, lowercase hex; omitted unless self-signed>",
    "model": "<omitted unless setup resolved a model name>"
  },
  "fileServer": {
    "url": "https://…",
    "credential": "<hex secret>",
    "certFP": "<optional; omitted unless the file lane is self-signed>"
  },
  "transport": "tailscale | funnel | cloudflare | public | selfsigned"
}
```

## Rules

- **`v` gates parsing.** An unknown major version means "update the app, or update the script." Unknown keys are ignored (tolerant decode).
- **Conditional fields are omitted, not null.** `name` only for custom gateways; `token` only when `auth` is `bearer`; `certFP` only for a self-signed cert; the whole `fileServer` object only when the file lane is configured. `model` is present whenever setup ended up with one — because a check proved the gateway requires it, because the server advertised exactly one and you accepted that default, or because you typed it — and omitted when you left model selection to the app.
- **No URL carries userinfo.** `conduck-connect` refuses a `user:password@` address at every prompt, so a code it mints never puts a credential inside a routing field.
- **`transport` is your explicit path choice** and supersedes any guess the app might make from the URL pattern.
- **The token and the file-lane credential are secrets.** The code is scannable by anyone who can see your screen; the script warns you when it emits it.
- **The app hard-rejects an invalid payload — whole, never partially** (mind this if you mint codes yourself): every URL must be `https://`, with a non-empty host and **no `user:password@` userinfo**; `auth: "bearer"` with a missing or empty `token` rejects (fail closed — never an unauthenticated import); `kind: "custom"` requires a nonempty `name`; a present `certFP` must normalize to exactly 64 hex characters; a missing or non-integer `v` rejects. One admissibility rule covers every endpoint URL the app persists — gateway, file server, and custom voice endpoint alike — and it is applied on **read** as well as on import, so an endpoint stored by an older build, or synced in from a device on a different version, can never be requested either.

This contract is **locked at v1** — fields are added compatibly (tolerant decode), never repurposed.
