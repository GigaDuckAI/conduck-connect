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
    "model": "<omitted unless the gateway requires one>"
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
- **Conditional fields are omitted, not null.** `name` only for custom gateways; `token` only when `auth` is `bearer`; `certFP` only for a self-signed cert; `model` only when the gateway requires one; the whole `fileServer` object only when the file lane is configured.
- **`transport` is your explicit path choice** and supersedes any guess the app might make from the URL pattern.
- **The token and the file-lane credential are secrets.** The code is scannable by anyone who can see your screen; the script warns you when it emits it.

This contract is **locked at v1** — fields are added compatibly (tolerant decode), never repurposed.
