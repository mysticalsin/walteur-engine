# Attack queue — a zero-dependency Node HTTP JSON API for a URL shortener: POST /shorte
> Read at every build-session start. Found-but-unfixed lives here; fixed graduates to Lessons.md. Ordered by blast radius (worst-consequence first).

| id | source | severity | blast radius | symptom | next action |
|----|--------|----------|--------------|---------|-------------|
| 1 | audit | major | security-exposure | Host-header reflection into shortUrl is undocumented. Live-verified: POST /shorten with `Host: evil.example.com` + `X-Forwarded-Proto: https` (and BASE_URL unset, which is bin/server.js's default) ret | fix, then re-run /goal |
| 2 | audit | minor | degraded-ux | Broken shortUrl on a genuinely-absent Host header. Live-verified via a raw HTTP/1.0 request with no Host header: buildShortUrl (src/server.js:120-128) does `${proto}://${req.headers.host}/${code}` wit | fix, then re-run /goal |
| 3 | audit | minor | degraded-ux | HEAD /:code returns 405 METHOD_NOT_ALLOWED (Allow: GET) instead of being handled like GET. RFC 9110 §9.3.2 expects a resource that supports GET to also support HEAD (headers only, no body). Live-verif | fix, then re-run /goal |
| 4 | audit | minor | degraded-ux | Stale build documentation. AGENTS.md §2 still reads 'No package.json exists yet (pre-build)' and '# TODO: fill in — package.json not yet created', but package.json now exists with the exact npm test/n | fix, then re-run /goal |
| 5 | audit | minor | cosmetic | blind-review.json nit still open: readBody() JSDoc (src/server.js:58-60) and the 'error' handler comment (lines ~100-103) say it rejects 'after destroying the socket'/'the destroy() above', but the ov | fix, then re-run /goal |
