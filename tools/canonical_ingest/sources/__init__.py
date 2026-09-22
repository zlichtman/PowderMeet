"""Per-source fetchers for canonical resort data.

Each source module exposes a single `fetch(resort_id, hints)` function
that returns a `SourceResult`. Modules are independent — adding a
source means dropping a new module here and registering it in
`canonical_ingest.cli.SOURCES`.
"""
