# Study database

Bezalel's study tools read a SQLite database built from
[studybible-mcp](https://github.com/djayatillake/studybible-mcp)'s own pipeline,
pinned to a commit, with the audited-out files removed, then split into packs
the app downloads separately. Licences and the attributions the app must show:
[SOURCES.md](SOURCES.md).

## Rebuild

```sh
data/build.sh
```

Needs git, [uv](https://docs.astral.sh/uv/), zstd and the network, and about 4 GB
of free disk while building (downloads, the full database, and the packs with
their compressed copies). It writes only to `data/work/` (the studybible-mcp checkout,
downloads, the full database) and `data/out/` (the packs), both gitignored. A
second run reuses the verified downloads; `rm -rf data/work data/out` for a cold
build.

What it does, in order:

1. Checks out studybible-mcp at `pins.json` → `studybible_mcp.commit`, cleans
   the tree (`git clean -ffdx`), and installs its locked environment
   (`uv sync --locked`) on uv-managed CPython `pins.json` → `python`.
2. Runs studybible-mcp's own downloaders, which pin and checksum their sources:
   `download_stepbible.py` (STEPBible, BDB, Abbott-Smith; without `--aquifer`),
   `download_bsb.py`, `download_biblical_versions.py` (LXX, Brenton) and
   `download_ancient_sources.py`.
3. `scripts/sources.py` fetches what those downloaders take from moving
   branches, pinned here instead: the five BibleAquifer resources, ACAI and
   Theographic as sparse git checkouts at fixed commits; the vendored
   OpenBible.info cross references; the embedding model by revision and sha256.
   It also re-checks the cached STEPBible files against their pinned sha256 and
   stages everything into the checkout's `data/`.
4. `scripts/prune.py` deletes the files listed in `exclusions.json` (the full
   texts of Heiser's papers and transcripts, `data/heiser/content/*.txt`, which
   the importer doesn't read) after recording fingerprints of them, and fails if
   they have moved.
5. Runs studybible-mcp's build scripts unchanged: `build_database.py --rebuild`,
   `import_theographic.py`, `import_cross_references.py` (TSK only),
   `import_torah_weave.py`, then the theological scholarship as their README
   applies it: `import_heiser_content.py` (summaries, themes, textual variants,
   LXX quotation hints), `import_bradley_content.py`,
   `ingest_atonement_synthesis.py`, `ingest_reformed_evangelical.py` (Owen,
   Stott, Lennox) and `ingest_lamb_of_free.py`. Not run:
   `ingest_burnett_gage.py` (its PDF and spreadsheet aren't in the repository),
   `generate_embeddings.py`, `upgrade_database.py`, the one-off migrations and the
   `repair_*` scripts (patches for their hosted database).
6. `scripts/embed_input.py` and `scripts/similar.py` precompute similar verses
   and passages (below).
7. `scripts/make_packs.py` splits the database by `packs.json`, writes
   `out/<pack>.sqlite`, `out/<pack>.sqlite.zst`, `out/sizes.tsv` and
   `out/tables.tsv`.
8. `scripts/check_packs.py` sanity-checks the packs, including that no deleted
   full text appears in them; the build fails if any check fails.

### Reproducibility

Every input is pinned: studybible-mcp by commit (and its downloads by its own
sha256 and git-blob pins), the rest in `pins.json`. The build sets
`PYTHONHASHSEED=0` and `TZ=UTC`, uses one uv-managed CPython (and so one SQLite
build) and locked dependencies (`uv.lock` here and in the checkout), and writes
packs in a fixed order and fixed page size, and computes the similarity vectors
single-threaded. Two consecutive builds on this Mac (M-series, macOS) produced
byte-identical packs; compare the sha256 column of `out/sizes.tsv`. Another CPU
architecture may round the embedding floats differently, which could move a
neighbour at a tied similarity score.

Inputs fetched from URLs that are not versioned (bsb.txt, eBible.org zips) are
checked against pinned checksums, so if a publisher changes a file the build stops
rather than producing a different database; the fix is a reviewed pin bump.

To move to a newer studybible-mcp: change `studybible_mcp.commit`, rebuild, and
read the failures. `make_packs.py` stops on any table that `packs.json` doesn't
place, and `prune.py` stops if excluded material moved; re-audit new data folders
in SOURCES.md before shipping.

### Why build, not reuse the hosted database

studybible-mcp serves a prebuilt `study_bible.db` (~815 MB). We don't derive from
it because:

- it holds material no script at the pin can rebuild (Burnett, the
  Harrison–Römhild cross references) and tables no script builds at all (`hlt_*`,
  a draft Heiser-derived translation; `verse_comparison_scores`, LLM output), so
  its provenance can't be reproduced or audited row by row;
- the file is replaced in place on their server (no version, changing ETag), so a
  build from it can't be pinned;
- its similarity data are OpenAI `text-embedding-3-small` vectors in sqlite-vec
  tables: rebuilding them needs an OpenAI key and a paid API, the output isn't
  deterministic, and the phone would need the vector extension.

## Packs

Each pack is a standalone SQLite file: open it alone, or ATTACH several to one
connection. Table names are unique across packs, so queries need no schema prefix
except for `pack_meta`, which every pack has (`pack`, `description`, `tables`,
`studybible_mcp_commit`, `similar_model`, `sqlite_version`). The ancient pack
uses FTS5 (exqlite builds SQLite with it).

The split (`packs.json`):

| Pack | Tables | Used by |
|---|---|---|
| `core` (first launch) | `verses` (TAHOT/TAGNT words, morphology, Strong's, glosses), `bsb_verses`, `passages`, `lexicon`, `morphology`, `names`, `acai_entities`, `cross_references`, `thematic_references`, `torah_weave_units`, `torah_weave_cells`, `similar_verses`, `similar_passages` | `lookup_verse`, `word_study`, `search_lexicon`, `search_by_strongs`, `get_cross_references`, `parse_morphology`, `lookup_name`, `find_similar_passages`, `get_torah_weave` |
| `notes` | `aquifer_content` (study notes, dictionary, UW and SIL translator notes, key terms), `ane_entries`, `ane_book_mappings`, `theology_content`, `theology_verse_index`, `theology_themes`, `theology_theme_index`, `textual_variant_cases`, `textual_variant_readings`, `textual_variant_witnesses`, `textual_critical_judgments`, `textual_theological_interpretations`, `textual_author_claims`, `textual_translation_decisions`, `nt_ot_lxx_quote_hints` | `get_study_notes`, `get_bible_dictionary`, `get_key_terms`, `get_ane_context`, `get_theology_context`, `get_textual_variant`, and `lookup_verse`'s textual-variant and LXX-quotation cues |
| `lxx` | `biblical_version_verses` | `compare_biblical_versions` (MT side comes from core `verses`) |
| `ancient` | `ancient_source_passages`, `ancient_source_passages_fts` (FTS5), `ancient_source_biblical_links`, `ancient_source_notes` | `search_ancient_sources`, `lookup_ancient_source` |
| `graph` | `graph_people`, `graph_places`, `graph_events`, `graph_people_groups`, `graph_family_edges`, `graph_person_event_edges`, `graph_event_place_edges`, `graph_person_group_edges`, `graph_verse_mentions` | `people_in_passage`, `explore_genealogy`, `explore_person_events`, `explore_place`, `find_connection`, `graph_enriched_search` |

Two more optional packs, `translations` (the NET Bible) and `scrolls` (the
Dead Sea Scrolls), are built by bezalel_core's `data/` (its `data/README.md`)
and published with these from the data version that adds them.

Left out: the `hlt_*` tables, which no script at the pin fills (`make_packs.py`
checks they are empty), and the `heiser_*` compatibility views.

Sizes from the build at the current pins (MB = 10^6 bytes; gzip -9, zstd -19).
Every build writes them, with row counts and sha256, to `out/sizes.tsv` and
`out/tables.tsv`.

| Pack | Rows | Raw | gzip | zstd |
|---|---:|---:|---:|---:|
| core | 1,696,932 | 181.9 MB | 40.6 MB | 26.1 MB |
| notes | 122,989 | 285.0 MB | 39.4 MB | 26.1 MB |
| lxx | 30,617 | 39.1 MB | 20.6 MB | 17.6 MB |
| ancient | 50,030 | 95.1 MB | 27.3 MB | 20.4 MB |
| graph | 64,703 | 6.0 MB | 1.7 MB | 1.3 MB |
| all | | 607.0 MB | 129.6 MB | 91.4 MB |

Most of core is `verses` (92 MB: the word-by-word JSON), `lexicon` (27 MB),
cross references with their indexes (26 MB) and the two similarity tables (9 MB
each). Most of notes is `aquifer_content` (262 MB), which studybible-mcp stores
twice, as HTML (`content`) and plain text (`content_plain`).

## Similar passages

`find_similar_passages` searched sqlite-vec tables of OpenAI vectors. The packs
instead carry the answers:

- `similar_verses(verse_id, rank, similar_verse_id, similarity_permille)`: each
  verse's 20 nearest verses.
- `similar_passages(verse_id, rank, passage_id, similarity_permille)`: each
  verse's 20 nearest passages, leaving out the passage that contains it, as
  `find_similar_passages` does.

Every one of the 31,272 verse rows has a vector and 20 neighbours of each kind
(31,205 embedded from the BSB, 67 from the gloss).

`verse_id` and the targets are `verses.id` / `passages.id` in the same build;
`similarity_permille` is the cosine similarity × 1000 (so `/ 10` is the percentage
the tool prints); rank 1 is the nearest, ties ordered by id.

Vectors: [BAAI/bge-small-en-v1.5](https://huggingface.co/BAAI/bge-small-en-v1.5)
(MIT, 384 dimensions, run with onnxruntime on the CPU; pinned by revision and
sha256) over the English text `lookup_verse` shows, the BSB, falling back to the
STEPBible gloss where a row has no BSB text (Psalm superscriptions, verses the BSB
omits, the second row of a split-numbered verse). A passage's vector is the
normalised mean of its verses'. On a spot check against studybible-mcp's OpenAI
vectors (which embed the word-gloss text), the BSB vectors find the quotation
parallels the gloss vectors miss: Psalm 22:18 → John 19:24 and Matthew 27:35,
Deuteronomy 6:5 → Mark 12:30 and Matthew 22:37, Isaiah 53:5 → 1 Peter 2:24.

## Publish

The app reads one URL: **https://bezalel.genericjam.com/packs/manifest.json**.
It is served from the Cloudflare R2 bucket `bezalel-packs` (custom domain, no
egress fees). After a rebuild, and after committing `data/`:

```sh
python3 data/scripts/publish.py --dry-run   # what would be uploaded
python3 data/scripts/publish.py
```

It uploads `out/<pack>.sqlite.zst` to `packs/v<N>/` with
`Cache-Control: public, max-age=31536000, immutable`, then the manifest to
`packs/manifest.json` with `Cache-Control: no-cache`, last, so a client never sees
a manifest naming packs that aren't there yet. N is one more than the published
manifest's `data_version`, or `--version N`. Pack objects are never replaced: one
already at `packs/v<N>/` is accepted only if byte-identical (an interrupted
publish resumes), and anything else stops the publish; if a publish was aborted
and `data/out` rebuilt since, rerun with a fresh `--version` (unreferenced
`v<N>` objects are harmless). Every upload is fetched back from
`https://bezalel.genericjam.com` and its size and sha256 compared; these reads
add a unique query string so they reach R2 rather than an edge copy (Cloudflare
caches 404s too). Uploads use
`npx wrangler@4 r2 object put … --remote`, so wrangler must be logged in to the
account that owns the bucket. Wrangler uploads files up to 315 MB; the largest
compressed pack is 26 MB.

The manifest (`schema` 1):

```json
{
  "schema": 1,
  "data_version": 1,
  "built": "2026-10-15T19:30:00Z",
  "bezalel_commit": "<commit of the data/ that built the packs>",
  "studybible_mcp": {"repo": "https://github.com/djayatillake/studybible-mcp", "commit": "38cef28d…"},
  "sources": "https://github.com/GenericJam/bezalel_mob/blob/master/data/SOURCES.md",
  "packs": [
    {
      "name": "core",
      "description": "…",
      "required": true,
      "licence": "CC BY 4.0 (STEPBible, …); …",
      "url": "https://bezalel.genericjam.com/packs/v1/core.sqlite.zst",
      "compression": "zstd",
      "size": 26110356, "sha256": "…",
      "raw_size": 181886976, "raw_sha256": "…",
      "tables": ["verses", "…"]
    }
  ]
}
```

`size`/`sha256` are of the download; `raw_size`/`raw_sha256` of the decompressed
SQLite file, which the app checks after decompressing. `required` packs (core) are
offered on first launch and can't be removed; the others are downloaded on demand.
On "Check for updates" the app compares the manifest's `data_version` with the one
each installed pack came from, fetching only packs whose `raw_sha256` changed and
keeping the old file until the new one verifies (`Bezalel.Packs` in the app).
