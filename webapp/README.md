# autoreviewer webapp

Rails app that browses and searches a patch review workspace:
it indexes review findings, metadata, and PR discussion into sqlite and serves them over a small web UI behind Google login.
It never writes back to the reviewed repos -- read-only over the workspace checkout.

`REVIEWS_ROOT` points at the workspace root, which holds one directory per project (each with a `project.yaml` and a `findings/` tree) directly at its top level -- no extra path prefix.

## Dev setup

1. Needs the `sqlite3` CLI on `PATH` (not just the `sqlite3` gem) -- Rails loads `db/structure.sql` by shelling out to it.
2. `cp .env.example .env` and fill in `SECRET_KEY_BASE` (`bin/rails secret`) and `REVIEWS_ROOT` (point it at a workspace checkout, i.e. a directory holding one subdir per project, e.g. `/home/you/workspace`).
3. Create a Google OAuth client (Google Cloud console -> Credentials) with BOTH redirect URIs registered, since dev and prod share one client:
   - `http://localhost:3939/auth/google_oauth2/callback`
   - `https://<host>/auth/google_oauth2/callback`

   Put the client id/secret in `.env`, then copy `config/access.yaml.example` to `config/access.yaml` and fill in your allowed domains/emails (baked into the image at build time in prod).
4. `bin/rails server`, or `task dev`.
5. `task test` runs the suite; `task reindex-dev` forces a full reindex.

## Auth modes

By default every request goes through Google login, checked against `config/access.yaml`.
Set `AUTH_MODE=none` in `.env` to skip login entirely -- meant for localhost or other trusted networks only (the top-level compose binds the webapp port to 127.0.0.1 by default).
No Google client id/secret or `access.yaml` is needed in this mode.

## Prod setup

Prod is no longer a standalone container:
it's driven by the top-level repo's compose file, service `webapp`, under the `web` profile.
That compose file mounts the workspace checkout read-only at `/workspace` and sets `REVIEWS_ROOT=/workspace` for the container.

See the top-level repo's compose docs for build/start/stop.
From inside this dir, the running container is reached as:

```
docker compose exec webapp bin/rails reindex:full   # force a full reindex
docker compose exec webapp bin/rails console
```

The `dbdata` volume (sqlite db at `/data/production.sqlite3`) is safe to delete any time -- it's fully rebuilt from the mounted checkout by a reindex.

## Operational notes

- `config/access.yaml` (the login allowlist) is baked into the image at build time.
  Changing it requires a rebuild and restart of the `webapp` service -- a restart alone won't pick it up.
- A background thread reindexes automatically every `REINDEX_INTERVAL` seconds (60 default) whenever the mounted checkout's git HEAD has moved.
- `docker compose exec webapp bin/rails reindex:full` forces a full reindex immediately, instead of waiting for the interval / HEAD check.
