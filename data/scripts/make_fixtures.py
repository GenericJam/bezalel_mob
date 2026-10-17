"""Cut the small test packs from the built packs.

  python3 data/scripts/make_fixtures.py [--packs data/out] [--out ../bezalel_core/test/fixtures/packs] [--pack core ...]

The fixtures live in bezalel_core (the study tools' tests), checked out
beside this repository. This repository's tests read them from the
bezalel_core dependency: the pinned deps/bezalel_core, or this sibling
checkout with BEZALEL_LOCAL_DEPS=bezalel_core, so fresh fixtures reach them
only that way or once bezalel_core is pushed and its pin bumped.

Each fixture is a pack file with the same tables, schemas and indexes as the
real pack (data/out/<pack>.sqlite), holding only the rows around a few
passages: Genesis 1-2, Exodus 31, Psalm 22, John 3 and Jude. Rows keep their
ids, so references between tables (similar_passages -> passages -> verses)
stay valid. What each table keeps:

core      the verses of those chapters and of EXTRA_VERSES, the BSB text of
          every kept verse, the
          lexicon entries the words of Exodus 31 cite plus the entries the
          tests read or search for, the morphology codes those chapters use
          plus the tests' codes, the names first mentioned there (and the
          tests' names) with their ACAI entities, the cross references from
          those verses, all thematic references, the Torah weave units over
          those chapters, and the nearest similar passages of a few anchor
          verses with the verses each passage's preview shows
graph     the verse mentions in those chapters; the people they name, with
          all their ancestors, two generations of descendants, and the
          spouses and siblings of those (likewise for GRAPH_PEOPLE), and the
          people born or died at GRAPH_PLACES, with the edges among them; all
          places, events and event-place edges; the GRAPH_PLACES' mentions
notes     the study notes and translator notes over Exodus 31 and John 3, the
          dictionary articles and key terms AQUIFER_QUERIES find, the ANE
          entries mapped to ANE_CHAPTERS, all theology themes and the theology
          content indexed to THEOLOGY_CHAPTERS or filed under THEOLOGY_THEMES,
          and all the textual-variant cases
          and LXX quotation hints (about 100 KB)
lxx       the Septuagint rows of those chapters and of EXTRA_VERSES, and the
          Greek-numbered rows of LXX_EXTRA
ancient   the ancient-source passages linked to those chapters and those
          overlapping ANCIENT_CITATIONS, with their links, notes and
          search-index rows

The lexicon (BDB and LSJ definitions run to several KB an entry) and the
notes are the large tables, hence the narrower cut there. Run this after a
pack rebuild changes the data the tests read. Reads data/out read-only;
needs only the Python standard library.
"""

from __future__ import annotations

import argparse
import re
import sqlite3
import sys
from pathlib import Path

FTS5_SHADOWS = ("_data", "_idx", "_content", "_docsize", "_config")

# (book code, Theographic book, chapter, book number)
CHAPTERS = [
    ("Gen", "Gen", 1, 1),
    ("Gen", "Gen", 2, 1),
    ("Exo", "Exod", 31, 2),
    ("Psa", "Ps", 22, 19),
    ("Jhn", "John", 3, 43),
    ("Jud", "Jude", 1, 65),
]
# The chapters whose notes are kept (the notes pack is mostly long articles).
NOTES_CHAPTERS = [c for c in CHAPTERS if c[0] in ("Exo", "Jhn")]
# The chapter whose words' lexicon entries are kept.
LEXICON_CHAPTER = ("Exo", 31)
# Verses whose similar passages are kept (the nearest SIMILAR_RANKS).
ANCHORS = ["Exo.31.3", "Psa.22.18(22.19)", "Jhn.3.16"]
SIMILAR_RANKS = 5
# Lexicon searches the tests run (search_lexicon, word_study by word): the
# first LEXICON_HITS entries the full lexicon ranks for each, in each
# language and in both, so the fixture returns what the real pack does for
# limits up to that.
LEXICON_QUERIES = ["wisdom", "love", "craftsman"]
LEXICON_HITS = 10
# Extra lexicon entries the tests read by number.
LEXICON_EXTRA = ["G0025", "G0026", "G4151", "H0157", "H7307"]
# Morphology codes the tests parse.
MORPHOLOGY_EXTRA = ["V-AAI-3S", "N-GSF", "V-PAI-3S", "HVqp3ms"]
# Names the tests look up besides those first mentioned in the chapters.
NAME_QUERIES = ["Bezalel", "Ai", "Judah", "David", "Uri"]
# A passage preview shows at most this many verses (PASSAGE_PREVIEW_VERSES).
PREVIEW_VERSES = 30
# Ancient-source passages the tests cite (corpus, work key, sort key): each
# passage whose sort range contains the key is kept.
ANCIENT_CITATIONS = [
    ("josephus", "antiquities", 18116), ("josephus", "antiquities", 18120),
    ("josephus", "life", 1), ("josephus", "jewish_war", 6316),
    ("qumran", "damascus_document", 6011), ("qumran", "community_rule", 6011),
    ("qumran", "pesher_habakkuk", 8008),
    ("rabbinic", "mishnah_shekalim", 1001), ("rabbinic", "mishnah_sukkah", 4009),
    ("pseudepigrapha", "4_ezra", 7028), ("pseudepigrapha", "4_ezra", 7035),
    ("pseudepigrapha", "4_ezra", 7106),
    ("philo", "opif", 26), ("targum", "onkelos_genesis", 49010),
]
# Verses beyond CHAPTERS (book, chapter, first, last) the tier 2 tests read:
# lookup_verse's textual-variant and quotation hints, and
# compare_biblical_versions' MT and LXX sides.
EXTRA_VERSES = [
    ("Psa", 40, 5, 8),
    ("Psa", 82, 1, 8),
    ("Heb", 10, 5, 7),
    ("Deu", 32, 43, 43),
    ("Dan", 3, 24, 25),
    ("Dan", 7, 13, 13),
    ("Job", 38, 6, 7),
    ("Mrk", 14, 62, 62),
    ("Mat", 26, 64, 64),
]
# Septuagint rows kept by their Greek edition position (book, chapter, first,
# last): LXX-only verses (the Prayer of Azariah) and an LXX-only book.
LXX_EXTRA = [("Dan", 3, 24, 25), ("Tob", 1, 1, 2)]
# People whose family the graph tests walk besides those the chapters
# mention (all their ancestors, two generations of descendants, spouses and
# siblings), and places whose history they read (with the people born or
# buried there, and the places' verse mentions, which rank namesakes).
GRAPH_PEOPLE = ["Abraham", "Melchisedec"]
GRAPH_PLACES = ["Hebron", "Ai"]
# Dictionary and key-term searches the tests run (get_bible_dictionary,
# get_key_terms): the articles the full pack returns for each (its exact
# title matches, else its first ten title or text matches).
AQUIFER_QUERIES = [
    ("dictionary", "abraham"), ("dictionary", "tabernacle"), ("dictionary", "jubilee"),
    ("key_terms", "atonement"), ("key_terms", "grace"),
]
# (book, chapter) whose ANE entries are kept: Genesis 15 has direct, broad and
# dropped whole-book entries; in Genesis 38 a whole-book entry citing it is
# promoted.
ANE_CHAPTERS = [("Exo", 31), ("Jhn", 3), ("Gen", 15), ("Gen", 38)]
# (book, chapter) whose theology content is kept: Psalm 82 has primary and
# supporting matches by several authors.
THEOLOGY_CHAPTERS = [("Exo", 31), ("Jhn", 3), ("Psa", 82)]
# Themes whose theology content is kept: atonement_models alternates authors.
THEOLOGY_THEMES = ["atonement_models"]


def verse_clause(book_col: str, chapter_col: str, verse_col: str, spans) -> str:
    return "(" + " OR ".join(
        f"({book_col} = '{b}' AND {chapter_col} = {c} AND {verse_col} BETWEEN {v1} AND {v2})"
        for b, c, v1, v2 in spans
    ) + ")"


def chapter_clause(book_col: str, chapter_col: str, books=lambda c: c[0], chapters=CHAPTERS) -> str:
    return "(" + " OR ".join(
        f"({book_col} = '{books(c)}' AND {chapter_col} = {c[2]})" for c in chapters
    ) + ")"


def range_clause(book_col: str, start_col: str, end_col: str, books=lambda c: c[0], chapters=CHAPTERS) -> str:
    """Rows whose chapter span [start, end] covers one of the chapters."""
    return "(" + " OR ".join(
        f"({book_col} = '{books(c)}' AND {start_col} <= {c[2]} AND {end_col} >= {c[2]})"
        for c in chapters
    ) + ")"


def sort_clause(book_col: str, start_col: str, end_col: str) -> str:
    """Rows whose chapter*1000+verse span overlaps one of the chapters."""
    return "(" + " OR ".join(
        f"({book_col} = '{c[0]}' AND {start_col} <= {c[2] * 1000 + 999} AND {end_col} >= {c[2] * 1000})"
        for c in CHAPTERS
    ) + ")"


def like_any(column: str, patterns: list[str]) -> str:
    return "(" + " OR ".join(f"{column} LIKE '{p}'" for p in patterns) + ")"


def ids(conn: sqlite3.Connection, sql: str) -> list:
    return [row[0] for row in conn.execute(sql)]


def in_list(values) -> str:
    quoted = []
    for value in sorted(set(values), key=str):
        quoted.append(str(value) if isinstance(value, int) else "'" + str(value).replace("'", "''") + "'")
    return "(" + (", ".join(quoted) or "NULL") + ")"


def lexicon_hits(src: sqlite3.Connection, query: str, language: str | None) -> list[str]:
    """The entries search_lexicon ranks first for ``query`` (Bezalel.Study.Lexicon.search/3)."""
    like = f"%{query.lower()}%"
    columns = ("short_definition", "full_definition", "transliteration", "word", "abbott_smith_def")
    sql = "SELECT strongs FROM lexicon WHERE (" + " OR ".join(f"LOWER({c}) LIKE ?" for c in columns) + ")"
    params = [like] * len(columns)
    if language:
        sql += " AND language = ?"
        params.append(language)
    sql += """ ORDER BY CASE WHEN LOWER(short_definition) LIKE ? OR LOWER(word) LIKE ?
                              OR LOWER(transliteration) LIKE ? THEN 0 ELSE 1 END,
                    usage_count DESC, strongs LIMIT ?"""
    params += [like, like, like, LEXICON_HITS]
    return [row[0] for row in src.execute(sql, params)]


def core_filters(src: sqlite3.Connection) -> dict[str, str]:
    main = ids(src, f"SELECT id FROM verses WHERE {chapter_clause('book', 'chapter')}")
    extra = ids(src, f"SELECT id FROM verses WHERE {verse_clause('book', 'chapter', 'verse', EXTRA_VERSES)}")
    anchors = ids(src, f"SELECT id FROM verses WHERE reference IN {in_list(ANCHORS)}")
    if len(anchors) != len(ANCHORS):
        sys.exit(f"anchor verses missing: {ANCHORS}")
    passages = ids(
        src,
        f"SELECT passage_id FROM similar_passages WHERE verse_id IN {in_list(anchors)} AND rank <= {SIMILAR_RANKS}",
    )
    preview = []
    for start, end in src.execute(
        f"SELECT start_verse_id, end_verse_id FROM passages WHERE id IN {in_list(passages)}"
    ):
        preview += ids(src, f"SELECT id FROM verses WHERE id BETWEEN {start} AND {end} ORDER BY id LIMIT {PREVIEW_VERSES}")
    verses = sorted(set(main) | set(extra) | set(preview))

    # Entries the words of one chapter cite (lookup_verse needs none: the
    # words carry their glosses), and the ones the tests read or search for.
    numbers = set(LEXICON_EXTRA)
    morphs = set(MORPHOLOGY_EXTRA)
    for book, chapter, word_data in src.execute(
        f"SELECT book, chapter, word_data FROM verses WHERE id IN {in_list(main)}"
    ):
        if (book, chapter) == LEXICON_CHAPTER:
            numbers.update(f"{m[0]}{int(m[1]):04d}" for m in re.findall(r"([GH])(\d{1,4})", word_data or ""))
        morphs.update(m for m in re.findall(r'"morph": "([^"]+)"', word_data or ""))
    for query in LEXICON_QUERIES:
        for language in (None, "greek", "hebrew"):
            numbers.update(lexicon_hits(src, query, language))

    refs_in_chapters = like_any("j.value", [f"{c[0]}.{c[2]}.%" for c in CHAPTERS])
    names = ids(
        src,
        f"""SELECT DISTINCT n.id FROM names n, json_each(n.refs) j WHERE {refs_in_chapters}
            UNION SELECT id FROM names WHERE {like_any('name', [f'%{q}%' for q in NAME_QUERIES])}""",
    )
    tipnr_keys = [
        f"{name}@{first}"
        for name, first in src.execute(
            f"SELECT name, json_extract(refs, '$[0]') FROM names WHERE id IN {in_list(names)}"
        )
        if first
    ]
    xref_sources = like_any("source", [f"{c[0]}.{c[2]}.%" for c in CHAPTERS])
    units = ids(
        src,
        f"SELECT DISTINCT unit_id FROM torah_weave_cells WHERE "
        + range_clause("book", "chapter_start", "chapter_end"),
    )
    return {
        "verses": f"id IN {in_list(verses)}",
        "bsb_verses": f"EXISTS (SELECT 1 FROM src.verses v WHERE v.id IN {in_list(verses)} "
        "AND v.book = bsb_verses.book AND v.chapter = bsb_verses.chapter AND v.verse = bsb_verses.verse)",
        "passages": f"id IN {in_list(passages)}",
        "lexicon": f"strongs IN {in_list(numbers)}",
        "morphology": f"code IN {in_list(morphs)}",
        "names": f"id IN {in_list(names)}",
        "acai_entities": f"EXISTS (SELECT 1 FROM json_each(acai_entities.tipnr_keys) k WHERE k.value IN {in_list(tipnr_keys)})",
        "cross_references": xref_sources,
        "thematic_references": "1",
        "torah_weave_units": f"id IN {in_list(units)}",
        "torah_weave_cells": f"unit_id IN {in_list(units)}",
        "similar_verses": "0",
        "similar_passages": f"verse_id IN {in_list(anchors)} AND rank <= {SIMILAR_RANKS}",
    }


def graph_filters(src: sqlite3.Connection) -> dict[str, str]:
    mentions = like_any("verse_ref", [f"{c[1]}.{c[2]}.%" for c in CHAPTERS])
    rows = src.execute(f"SELECT DISTINCT entity_type, entity_id FROM graph_verse_mentions WHERE {mentions}").fetchall()
    roots = {i for t, i in rows if t == "person"}
    roots |= set(ids(src, f"SELECT id FROM graph_people WHERE name IN {in_list(GRAPH_PEOPLE)}"))
    parents: dict[str, set] = {}
    children: dict[str, set] = {}
    others: dict[str, set] = {}
    for a, b, rel in src.execute("SELECT from_person_id, to_person_id, relationship_type FROM graph_family_edges"):
        if rel in ("father_of", "mother_of"):
            parents.setdefault(b, set()).add(a)
            children.setdefault(a, set()).add(b)
        else:
            others.setdefault(a, set()).add(b)
            others.setdefault(b, set()).add(a)
    # Every ancestor of the roots, their descendants two generations down,
    # then the spouses and siblings of all of those.
    people = set(roots)
    todo = list(roots)
    while todo:
        for parent in parents.get(todo.pop(), ()):
            if parent not in people:
                people.add(parent)
                todo.append(parent)
    generation = set(roots)
    for _ in range(2):
        generation = {c for p in generation for c in children.get(p, ())}
        people |= generation
    people |= {o for p in list(people) for o in others.get(p, ())}
    places = ids(src, f"SELECT id FROM graph_places WHERE name IN {in_list(GRAPH_PLACES)}")
    people |= set(ids(src, f"SELECT id FROM graph_people WHERE birth_place_id IN {in_list(places)} OR death_place_id IN {in_list(places)}"))
    people = in_list(people)
    place_mentions = f"entity_type = 'place' AND entity_id IN {in_list(places)}"
    return {
        "graph_people": f"id IN {people}",
        "graph_places": "1",
        "graph_events": "1",
        "graph_people_groups": f"name IN (SELECT group_name FROM src.graph_person_group_edges WHERE person_id IN {people})",
        "graph_family_edges": f"from_person_id IN {people} AND to_person_id IN {people}",
        "graph_person_event_edges": f"person_id IN {people}",
        "graph_event_place_edges": "1",
        "graph_person_group_edges": f"person_id IN {people}",
        "graph_verse_mentions": f"{mentions} OR ({place_mentions})",
    }


def notes_filters(src: sqlite3.Connection) -> dict[str, str]:
    entries = ids(
        src,
        "SELECT DISTINCT entry_id FROM ane_book_mappings WHERE "
        + " OR ".join(
            f"(book = '{book}' AND (chapter_start IS NULL OR (chapter_start <= {chapter} "
            f"AND (chapter_end IS NULL OR chapter_end >= {chapter}))))"
            for book, chapter in ANE_CHAPTERS
        ),
    )
    content = ids(
        src,
        "SELECT DISTINCT content_id FROM theology_verse_index WHERE "
        + " OR ".join(f"(book = '{b}' AND chapter = {c})" for b, c in THEOLOGY_CHAPTERS)
        + f" UNION SELECT content_id FROM theology_theme_index WHERE theme_key IN {in_list(THEOLOGY_THEMES)}",
    )
    # Bezalel.Study.Aquifer.search/2: exact titles, else the first ten matches.
    articles = []
    for resource_type, query in AQUIFER_QUERIES:
        hits = ids(
            src,
            f"SELECT id FROM aquifer_content WHERE resource_type = '{resource_type}' "
            f"AND LOWER(title) = LOWER('{query}')",
        )
        if not hits:
            like = f"'%{query}%'"
            hits = ids(
                src,
                f"SELECT id FROM aquifer_content WHERE resource_type = '{resource_type}' "
                f"AND (LOWER(title) LIKE LOWER({like}) OR LOWER(content_plain) LIKE LOWER({like})) "
                f"ORDER BY CASE WHEN LOWER(title) LIKE LOWER({like}) THEN 0 ELSE 1 END, LENGTH(title) "
                f"LIMIT 10",
            )
        articles += hits
    return {
        "aquifer_content": range_clause(
            "book_num", "chapter_start", "chapter_end", books=lambda c: c[3], chapters=NOTES_CHAPTERS
        )
        + f" OR id IN {in_list(articles)}",
        "ane_entries": f"id IN {in_list(entries)}",
        "ane_book_mappings": f"entry_id IN {in_list(entries)}",
        "theology_content": f"id IN {in_list(content)}",
        "theology_verse_index": f"content_id IN {in_list(content)}",
        "theology_themes": "1",
        "theology_theme_index": f"content_id IN {in_list(content)}",
        # All of them: 30 cases and 22 quotation hints, about 100 KB.
        "textual_variant_cases": "1",
        "textual_variant_readings": "1",
        "textual_variant_witnesses": "1",
        "textual_critical_judgments": "1",
        "textual_theological_interpretations": "1",
        "textual_author_claims": "1",
        "textual_translation_decisions": "1",
        "nt_ot_lxx_quote_hints": "1",
    }


def lxx_filters(_src: sqlite3.Connection) -> dict[str, str]:
    canonical = chapter_clause("canonical_book", "canonical_chapter")
    extra = verse_clause("canonical_book", "canonical_chapter", "canonical_verse", EXTRA_VERSES)
    greek = verse_clause("edition_book", "edition_chapter", "edition_verse", LXX_EXTRA)
    return {"biblical_version_verses": f"{canonical} OR {extra} OR {greek}"}


def ancient_filters(src: sqlite3.Connection) -> dict[str, str]:
    cited = " OR ".join(
        f"(corpus = '{corpus}' AND work_key = '{work}' AND sort_start <= {key} AND sort_end >= {key})"
        for corpus, work, key in ANCIENT_CITATIONS
    )
    passages = ids(
        src,
        "SELECT DISTINCT passage_id FROM ancient_source_biblical_links WHERE "
        + sort_clause("biblical_book", "sort_start", "sort_end")
        + f" UNION SELECT id FROM ancient_source_passages WHERE {cited}",
    )
    return {
        "ancient_source_passages": f"id IN {in_list(passages)}",
        "ancient_source_passages_fts": f"rowid IN {in_list(passages)}",
        "ancient_source_biblical_links": f"passage_id IN {in_list(passages)}",
        "ancient_source_notes": f"passage_id IN {in_list(passages)}",
    }


PACKS = {
    "core": core_filters,
    "graph": graph_filters,
    "notes": notes_filters,
    "lxx": lxx_filters,
    "ancient": ancient_filters,
}


def schema(conn: sqlite3.Connection):
    rows = conn.execute("SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY type, name").fetchall()
    virtual = {n for t, n, _, sql in rows if t == "table" and sql and sql.startswith("CREATE VIRTUAL TABLE")}
    shadows = {f"{v}{s}" for v in virtual for s in FTS5_SHADOWS}
    tables = {n: sql for t, n, _, sql in rows if t == "table" and not n.startswith("sqlite_") and n not in shadows}
    indexes = [(tbl, sql) for t, _, tbl, sql in rows if t == "index" and sql]
    return tables, virtual, indexes


def cut(src_path: Path, out: Path, filters_for) -> None:
    src = sqlite3.connect(f"file:{src_path}?mode=ro", uri=True)
    tables, virtual, indexes = schema(src)
    filters = filters_for(src)
    src.close()
    unplaced = sorted(set(tables) - set(filters) - {"pack_meta"})
    if unplaced:
        sys.exit(f"{src_path.name}: no fixture filter for {unplaced}")

    if out.exists():
        out.unlink()
    dst = sqlite3.connect(f"file:{out}", uri=True, isolation_level=None)
    dst.execute("PRAGMA page_size = 4096")
    dst.execute("PRAGMA journal_mode = OFF")
    dst.execute("ATTACH DATABASE ? AS src", (f"file:{src_path}?mode=ro",))
    dst.execute("BEGIN")
    for table, sql in tables.items():
        dst.execute(sql)
        where = filters.get(table, "1")
        if table in virtual:
            columns = ", ".join(f'"{r[1]}"' for r in dst.execute(f'PRAGMA src.table_info("{table}")'))
            dst.execute(
                f'INSERT INTO main."{table}"(rowid, {columns}) '
                f'SELECT rowid, {columns} FROM src."{table}" WHERE {where} ORDER BY rowid'
            )
        else:
            order = "" if "WITHOUT ROWID" in sql.upper() else " ORDER BY rowid"
            dst.execute(f'INSERT INTO main."{table}" SELECT * FROM src."{table}" WHERE {where}{order}')
        for tbl, index_sql in indexes:
            if tbl == table:
                dst.execute(index_sql)
    if dst.execute("SELECT 1 FROM main.sqlite_master WHERE name = 'sqlite_sequence'").fetchone():
        dst.execute("DELETE FROM main.sqlite_sequence")
        dst.execute("INSERT INTO main.sqlite_sequence SELECT name, seq FROM src.sqlite_sequence")
    dst.execute("INSERT INTO main.pack_meta VALUES ('fixture', 'cut by data/scripts/make_fixtures.py')")
    dst.execute("COMMIT")
    dst.execute("DETACH DATABASE src")
    dst.execute("VACUUM")
    integrity = dst.execute("PRAGMA integrity_check").fetchone()[0]
    counts = {t: dst.execute(f'SELECT COUNT(*) FROM "{t}"').fetchone()[0] for t in tables}
    dst.close()
    if integrity != "ok":
        sys.exit(f"{out}: integrity_check {integrity}")
    rows = ", ".join(f"{t} {n}" for t, n in counts.items())
    print(f"  {out.name}: {out.stat().st_size / 1e6:.2f} MB ({rows})")


def main() -> None:
    root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser()
    parser.add_argument("--packs", type=Path, default=root / "data" / "out")
    parser.add_argument(
        "--out", type=Path, default=root.parent / "bezalel_core" / "test" / "fixtures" / "packs"
    )
    parser.add_argument("--pack", action="append", choices=sorted(PACKS), help="only these packs (repeatable)")
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    for name, filters in PACKS.items():
        if args.pack is None or name in args.pack:
            cut(args.packs / f"{name}.sqlite", args.out / f"{name}.sqlite", filters)


if __name__ == "__main__":
    main()
