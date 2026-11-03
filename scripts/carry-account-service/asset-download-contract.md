# Private native asset download

`GET /functions/v1/carry-assets/download/{assetUUID}`. A fresh current native Carry session bearer and publishable apikey are required. No query parameters, Range requests, client URLs, provider paths, cookies or OAuth AI sessions are accepted. Each request resolves its own account from the bearer, checks enrollment/session existence and rate limit, and resolves only that account's private ledger entry. Pending, missing, deleting or changed/unverified storage versions cannot be downloaded.

The broker requests the private provider object using the ledger UUID version (`versionId`) and repeats the current native-session/ledger check after provider headers arrive. No service credential, provider URL, provider response header or signed URL is returned. Redirects are forbidden. A successful response has status 200, application/octet-stream, attachment disposition, exact Content-Length, no-store, nosniff and these headers:

- X-Carry-Asset-ID: requested UUID
- X-Carry-Asset-SHA256: 64 lowercase hex characters
- X-Carry-Asset-Version: verified immutable provider UUID

At most 50 MiB stream through the broker with backpressure and a 60-second deadline. Actual count and SHA256 are checked incrementally; truncation, overflow, cancellation or mismatch fails the stream. HTTP headers may already have been sent when corruption is discovered; clients must treat body failure or checksum mismatch as a failed download and publish no cache file. A stream authorized before revocation may finish; revocation blocks every new download, including a retry. Revocation cannot recall bytes already delivered to a device.

401/403 mean no current native session; 404 means unavailable asset; 409 means not verified/version changed; 429 is rate limiting; 503 is temporary storage/service failure. Do not infer deletion or clear local edits from an unavailable response. No caller may assume 200 alone means verified bytes.

The native downloader uses an independent actor, ephemeral cookie-free URLSession, fresh token for each network request, redirect rejection, identity/header/byte/hash checks and private `downloads/{accountUUID}` directories (distinct from upload checkpoints even when the same root is supplied). It writes a bounded temporary file and atomically publishes only verified content. Close cancels and awaits all writers before optional cache removal. Offline cache access is explicit and revalidates bytes; signed-out/closed instances reject it. The workspace owner must close this downloader on sign-out/account switch, supply only graph-authorized descriptors, and keep AI grants separate. Existing local/iCloud files are never cache cleanup targets.

Current implementation is component-only. It is not wired to Carry workspace/graph projection or production UI. No deployed endpoint or real file claim follows from local tests. Provider versioned-download support and actual native bytes/session revocation remain hosted acceptance gates.

Provider contract: https://supabase.com/docs/reference/javascript/file-buckets-download (DownloadOptions.versionId).

## Native manifest

`GET /functions/v1/carry-assets/manifest/{assetUUID}` uses the same current native Carry session and rate limit as private download. It returns exactly `accountID`, `assetID`, `entityID`, `kind`, `slot`, `sha256`, `byteCount`, and `providerVersion`. It returns no object path, provider URL, signed URL, service key, original device filename or caller-controlled extra fields. Responses are private/no-store.

Both manifest and byte download now use `carry_asset_download_manifest`: the ledger must be verified, its verified provider version must still be current, and the exact live graph entity/kind/slot must reference that asset. A verified orphan reservation is unavailable for download until graph publication. An asset removed from the graph or belonging to a deleted entity is unavailable through these endpoints. Native upload inspection remains a separate prepublication operation. OAuth identities cannot use this native endpoint; AI must pass its independent grant/trip/file authorization.

The local fixture on port 8893 accepts optional `accountID`, `entityID`, `kind`, and `slot` in `POST /__fixture` and exposes a stable manifest/provider version for that fixture. It is explicitly synthetic-only, has no provider credentials, and is never deployed.
