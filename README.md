# macros-feeds

An [elfeed](https://github.com/skeeto/elfeed)-style RSS/Atom feed reader for
the [macros](https://github.com/kgwinnup/macros) editor, written entirely in
Steel.

- **Search buffer** listing entries from all feeds, newest first, filtered
  with elfeed's query language (`+tag -tag @2-weeks-ago #100 regex !regex`).
- **Show buffer** rendering one entry as text (block-aware HTML→text pass),
  with `b` to open the real link in your browser.
- **Persistent database** (`~/.macros-feeds-db`) — read/unread state, tags,
  and content survive restarts.
- **Async fetch** via the editor's `http-request` primitive: feeds download on
  a worker thread, one at a time off a queue; the UI never blocks.

## Install

In your `init.scm`:

```scheme
(package-install "https://github.com/kgwinnup/macros-feeds"
  'config (lambda ()
            (set-option "feeds"
                        (string-append
                         "https://lobste.rs/rss|dev "
                         "https://hnrss.org/frontpage|hn "
                         "https://xkcd.com/atom.xml"))))
```

(or `package-install-local` with a working-tree path.)

The `"feeds"` option is a whitespace-separated string of `url` or
`url|tag,tag` entries; the tags are auto-applied to new entries from that
feed. Feeds are configured through `set-option` because Steel compiles
init.scm as one unit — a config thunk can call core builtins but cannot
`set!` a package's globals. (When loading the file directly with `load`,
you can instead set the `*feeds-list*` list: URL strings or
`(url tag …)` lists.)

## Use

`M-x feeds` or `C-c f`, then `G` to fetch.

### *feeds-search*

| key            | action                                            |
|----------------|---------------------------------------------------|
| `enter`/click  | show the entry (marks it read)                    |
| `b`            | open the entry's link in the browser (marks read) |
| `y`            | copy the entry's link to the clipboard            |
| `r` / `u`      | mark read / unread (and move down)                |
| `A`            | mark every entry in the view read (asks first)    |
| `+` / `-`      | add / remove a tag on the entry at point          |
| `s`            | edit the filter                                   |
| `c`            | reset the filter to the default                   |
| `g`            | refresh the view from the database                |
| `G`            | fetch all feeds (progress shows in the header)    |
| `n` / `p`      | next / previous line                              |
| `?`            | menu of every command                             |
| `q`            | back to the buffer you opened `feeds` from        |

Emacs motion works throughout: `C-n`/`C-p`, `C-v`/`M-v`, `M-<`/`M->`,
`space` to page down.

Under evil/helix, `j`/`k`/`gg` move as usual; in the search buffer `G`
fetches (as in vanilla elfeed — use `end` or `C-d` for the bottom), while in
the show buffer `G` stays goto-bottom. Refresh is `g r` and fetch
is `R` (mirroring the magit convention, since `G` is goto-bottom).

Unread entries render **bold** in the theme's default text color (via the
editor's `set-face-bold` primitive and a colorless `feeds-unread` face);
read entries are dimmed.
Like elfeed, marking an entry read dims its line but does not evict it from
the view until the next refresh — even under the default `+unread` filter.

### *feeds-entry*

| key       | action                                |
|-----------|---------------------------------------|
| `n` / `p` | next / previous entry in the view     |
| `b`       | open this entry's link in the browser |
| `y`       | copy this entry's link                |
| `u`       | mark this entry unread again          |
| `+` / `-` | add / remove a tag                    |
| `?`       | menu of every command                 |
| `q`       | back to the search buffer             |

### Filter language

A space-separated list of terms, all of which must hold:

- `+tag` — entry must have `tag`
- `-tag` — entry must not have `tag`
- `@2-weeks-ago` — only entries newer than the age (`days`/`weeks`/`months`/`years`)
- `#50` — cap the list at 50 entries
- `regex` — title or feed title must match (case-insensitive)
- `!regex` — …must not match

The default is `@6-months-ago +unread` (the `"feeds-filter"` option, below).

## Configuration knobs

The first three are **options** — settable from an init.scm `'config` thunk
via `(set-option "name" "value")`, which is the only channel that works from
there (Steel compiles init.scm as one unit, so a thunk cannot `set!` a
package's globals). Each option falls back to a same-purpose global when
unset. The remaining knobs are plain globals: nobody sets those per-machine,
and they remain reachable via eval or by editing this file.

| knob                     | default                | meaning                        |
|--------------------------|------------------------|--------------------------------|
| `"feeds"` option         | unset (`*feeds-list*`, `'()`) | the feed list: `url\|tag,tag …` |
| `"feeds-db-file"` option | unset (`*feeds-db-file*`, `~/.macros-feeds-db`) | database path (`~/` ok) |
| `"feeds-filter"` option  | unset (`*feeds-search-filter*`, `@6-months-ago +unread`) | initial filter |
| `*feeds-feed-width*`     | `18`                   | feed column width (chars)      |
| `*feeds-title-width*`    | `90`                   | title truncation width         |
| `*feeds-show-width*`     | `80`                   | show-buffer wrap width         |
| `*feeds-user-agent*`     | Mozilla/5.0 …          | request User-Agent             |

## License

MIT
