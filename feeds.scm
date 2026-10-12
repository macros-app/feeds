;; macros-feeds — an elfeed-style RSS/Atom feed reader for the macros editor,
;; in Steel.
;;
;; A clone of Emacs `elfeed`: a search buffer listing entries from all your
;; feeds (newest first, filterable with elfeed's little query language), and a
;; show buffer that renders one entry. The database persists across restarts.
;;
;;   * fetch   — one-shot async `http-request` per feed (the editor's Rust core
;;               does the networking on a worker thread; the UI never blocks).
;;               Feeds are fetched one at a time off a queue, so the single
;;               named response callback is never ambiguous.
;;   * parse   — RSS 2.0 and Atom, via the same regex+char-walk approach as
;;               macros-web-reader: capture groups return STRINGS (safe), and
;;               anything positional walks chars, never mixing the engine's
;;               byte-offset matches with char-indexed substring.
;;   * store   — a flat file (~/.macros-feeds-db by default), one entry per
;;               line, fields separated by US (0x1f), newlines in content
;;               escaped as RS (0x1e). Loaded on first use, written after every
;;               fetch and read/unread/tag change.
;;   * search  — elfeed's filter language (subset): `+tag -tag @2-weeks-ago
;;               #100 regex !notregex`, entries sorted newest-first.
;;
;;   M-x feeds  /  C-c f      open the search buffer
;;
;;   in *feeds-search*:
;;     enter / click    show the entry on this line (marks it read)
;;     b                open the entry's link in the system browser (marks read)
;;     y                copy the entry's link
;;     r / u            mark read / unread (and move down)
;;     A                mark every entry in the view read (asks first)
;;     + / -            add / remove a tag on the entry at point
;;     s / c            edit the filter / reset it to the default
;;     g                refresh the view from the database
;;     G                fetch all feeds
;;     n / p            next / previous line
;;     ?                menu of every command
;;     q                back to the buffer `feeds` was opened from
;;
;;   in *feeds-entry*:
;;     n / p            next / previous entry in the current view
;;     b / y            open / copy this entry's link
;;     u                mark this entry unread again
;;     + / -            add / remove a tag
;;     ?                menu of every command
;;     q                back to the search buffer
;;
;; Everything here is self-contained — it only calls editor primitives, Steel
;; builtins, and core.scm (always loaded: `ymd->days`, `days->ymd`, `sort-by`,
;; `pad2`, `read-string`), so it loads as a package without depending on other
;; packages.

;; ── configuration ───────────────────────────────────────────────────────────
;; The feed list. From init.scm, set the "feeds" OPTION — a whitespace-
;; separated string of `url` or `url|tag,tag` entries — because Steel compiles
;; init.scm as one unit, so a `'config` thunk can `set-option` (a core builtin)
;; but can NOT `set!` this package's globals (the identifier doesn't resolve at
;; init compile time; same reason macros-k8s configures via options):
;;
;;   (package-install-local "~/workspace/macros-feeds"
;;     'config (lambda ()
;;               (set-option "feeds"
;;                           "https://lobste.rs/rss|dev https://xkcd.com/atom.xml")))
;;
;; `*feeds-list*` below is the fallback when the option is unset (useful when
;; loading this file directly with `load`/eval): each element is a URL string
;; or a list of URL + tags (symbols or strings) auto-applied to NEW entries.
(define *feeds-list* '())

;; Where the database file lives, and the filter the search buffer starts
;; with (elfeed's default). Both are ALSO settable from init.scm as the
;; "feeds-db-file" / "feeds-filter" options — the option, when set, wins over
;; the global (same init-reachability story as the feed list above: a config
;; thunk can `set-option` but cannot `set!` these globals). Options are read
;; lazily at use time because `set-option` is queued — a value set in the
;; config thunk isn't visible while the package is still loading.
(define *feeds-db-file* (string-append (getenv "HOME") "/.macros-feeds-db"))
(define *feeds-search-filter* "@6-months-ago +unread")

;; Search-buffer column widths (chars) and show-buffer wrap width.
(define *feeds-feed-width* 18)
(define *feeds-title-width* 90)
(define *feeds-show-width* 80)

;; Extra request headers. Some hosts refuse the default ureq agent string.
(define *feeds-user-agent*
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) macros-feeds")

;; ── state ───────────────────────────────────────────────────────────────────
;; ALL mutable runtime state lives in ONE global hash (the web-reader pattern),
;; so the package exposes a single collidable name. Slots are read with
;; `(ef--st 'key)`, written with `(ef--st! 'key v)`; every key is seeded so a
;; #f always means "the value is #f", never "missing".
;;
;; The database itself is two slots: 'db (hash id → entry-hash) plus 'ids (the
;; insertion-ordered id list) — Steel hash iteration is avoided entirely by
;; carrying the key list alongside.
(define *feeds-state*
  (hash
   'db          (hash)  ; id → entry hash
   'ids         '()     ; every id, insertion order (drives persistence)
   'loaded      #f      ; db file has been read this session
   'filter      #f      ; the ACTIVE filter; #f = not set yet → (ef--filter) default
   'view        '()     ; ids currently rendered, display order
   'view-offset 3       ; buffer line of the first entry row
   'current     #f      ; id shown in *feeds-entry*
   'queue       '()     ; (url . tags) still to fetch this update
   'fetching    #f      ; (url . tags) in flight, or #f
   'fetch-total 0       ; feeds queued by the running update (progress header)
   'origin      #f      ; buffer `feeds` was opened from (`q` returns there)
   'confirm     #f      ; pending y-or-n-p action (thunk), or #f
   'new-count   0       ; entries added by the running update
   'err-count   0))     ; feeds that failed in the running update

(define (ef--st key)    (hash-try-get *feeds-state* key))
(define (ef--st! key v) (set! *feeds-state* (hash-insert *feeds-state* key v)))

;; A config knob: the named option when it's set to a string, else the
;; global's value (the k8s pattern — options are init.scm's only channel).
(define (ef--knob opt fallback)
  (let ((v (get-option opt)))
    (if (string? v) v fallback)))

;; Expand a leading ~/ (an option value may use it; the Rust file primitives
;; want an absolute path).
(define (ef--expand-home p)
  (if (and (> (string-length p) 1) (equal? (substring p 0 2) "~/"))
      (string-append (getenv "HOME") (substring p 1 (string-length p)))
      p))

(define (ef--db-file) (ef--expand-home (ef--knob "feeds-db-file" *feeds-db-file*)))

;; The active search filter: the runtime value once the user has set one
;; (`s`), else the configured default.
(define (ef--filter) (or (ef--st 'filter) (ef--knob "feeds-filter" *feeds-search-filter*)))

;; ── tiny helpers (self-contained, byte/char-safe) ───────────────────────────
(define (ef--trim s) (replace-regexp-in-string "^\\s+|\\s+$" "" s))

;; Split `s` on every occurrence of the single character `ch` — one char-list
;; pass, so no byte/char index mixing (see macros-web-reader for the war story).
(define (ef--split-char s ch)
  (let loop ((cs (string->list s)) (cur '()) (acc '()))
    (cond ((null? cs) (reverse (cons (list->string (reverse cur)) acc)))
          ((char=? (car cs) ch)
           (loop (cdr cs) '() (cons (list->string (reverse cur)) acc)))
          (else (loop (cdr cs) (cons (car cs) cur) acc)))))

;; UTF-8 byte length of `s` — overlay spans and click columns are byte-based.
(define (ef--bytelen s)
  (let loop ((cs (string->list s)) (n 0))
    (if (null? cs)
        n
        (let ((cp (char->integer (car cs))))
          (loop (cdr cs)
                (+ n (cond ((< cp 128) 1) ((< cp 2048) 2) ((< cp 65536) 3) (else 4))))))))

;; First capture group of `pat` in `s`, or #f. Captures return STRINGS — the
;; only regex result that is safe to combine with char-indexed operations.
(define (ef--cap pat s)
  (let ((c (regexp-captures pat s)))
    (if (null? c) #f (nth c 1))))

(define (ef--matches? pat s) (not (null? (regexp-captures pat s))))

;; alist get with equal? keys, or #f.
(define (ef--aget amap key)
  (cond ((null? amap) #f)
        ((equal? (car (car amap)) key) (cdr (car amap)))
        (else (ef--aget (cdr amap) key))))

;; Pad/truncate `s` to exactly `w` display chars (char-indexed on purpose).
(define (ef--fit s w)
  (let ((n (string-length s)))
    (cond ((> n w) (substring s 0 w))
          ((= n w) s)
          (else (let loop ((s s) (n n))
                  (if (= n w) s (loop (string-append s " ") (+ n 1))))))))

(define (ef--truncate s w)
  (if (> (string-length s) w) (string-append (substring s 0 (- w 1)) "…") s))

;; Greedy word wrap at `width` chars; never breaks inside a word.
(define (ef--wrap s width)
  (let loop ((ws (filter (lambda (w) (not (equal? w ""))) (ef--split-char s #\space)))
             (cur "") (acc '()))
    (cond
      ((null? ws) (reverse (if (equal? cur "") acc (cons cur acc))))
      ((equal? cur "") (loop (cdr ws) (car ws) acc))
      ((<= (+ (string-length cur) 1 (string-length (car ws))) width)
       (loop (cdr ws) (string-append cur " " (car ws)) acc))
      (else (loop (cdr ws) (car ws) (cons cur acc))))))

;; Field/record separators for the db file, and the id joiner.
(define ef--us (list->string (list (integer->char 31))))   ; field sep
(define ef--rs (list->string (list (integer->char 30))))   ; escaped newline
(define ef--soh (integer->char 1))                          ; regex sentinel
(define ef--soh-str (list->string (list ef--soh)))

;; Strip control chars that would corrupt the db line format or the rendered
;; buffer; newlines become spaces (single-line fields only).
(define (ef--sanitize s)
  (list->string
   (map (lambda (c) (if (< (char->integer c) 32) #\space c))
        (string->list s))))

;; ── entities ────────────────────────────────────────────────────────────────
;; Decode numeric refs (`&#39;` and `&#x2F;`) then the common named ones. Each
;; numeric ref is fenced with the sentinel and converted in one char-walk.
(define (ef--hexval s)
  (let loop ((cs (string->list s)) (acc 0))
    (if (null? cs)
        acc
        (let* ((i (char->integer (car cs)))
               (v (cond ((and (>= i 48) (<= i 57)) (- i 48))
                        ((and (>= i 97) (<= i 102)) (- i 87))
                        ((and (>= i 65) (<= i 70)) (- i 55))
                        (else 0))))
          (loop (cdr cs) (+ (* acc 16) v))))))

(define (ef--numeric-entities s)
  (let* ((s (replace-regexp-in-string "&#[xX]([0-9a-fA-F]+);"
                                      (string-append ef--soh-str "x$1" ef--soh-str) s))
         (s (replace-regexp-in-string "&#([0-9]+);"
                                      (string-append ef--soh-str "d$1" ef--soh-str) s))
         (pieces (ef--split-char s ef--soh)))          ; text, code, text, code, …
    (let loop ((ps pieces) (i 0) (acc '()))
      (if (null? ps)
          (ef--concat (reverse acc))
          (loop (cdr ps) (+ i 1)
                (cons (if (= 0 (modulo i 2))
                          (car ps)
                          (let* ((tok (car ps))
                                 (kind (substring tok 0 1))
                                 (num (substring tok 1 (string-length tok)))
                                 (cp (if (equal? kind "x")
                                         (ef--hexval num)
                                         (or (string->number num) 32))))
                            (if (and (> cp 8) (< cp 1114112))
                                (list->string (list (integer->char cp)))
                                " ")))
                      acc))))))

(define (ef--concat xs)
  (let loop ((xs xs) (acc "")) (if (null? xs) acc (loop (cdr xs) (string-append acc (car xs))))))

(define (ef--join xs sep)
  (cond ((null? xs) "")
        ((null? (cdr xs)) (car xs))
        (else (string-append (car xs) sep (ef--join (cdr xs) sep)))))

(define (ef--entities s)
  (let* ((s (ef--numeric-entities s))
         (s (replace-regexp-in-string "&nbsp;" " " s))
         (s (replace-regexp-in-string "&lt;" "<" s))
         (s (replace-regexp-in-string "&gt;" ">" s))
         (s (replace-regexp-in-string "&quot;" "\"" s))
         (s (replace-regexp-in-string "&apos;" "'" s))
         (s (replace-regexp-in-string "&mdash;" "—" s))
         (s (replace-regexp-in-string "&ndash;" "–" s))
         (s (replace-regexp-in-string "&hellip;" "…" s))
         (s (replace-regexp-in-string "&amp;" "&" s)))   ; LAST, or &amp;lt; double-decodes
    s))

;; ── dates ───────────────────────────────────────────────────────────────────
;; Parse feed timestamps to unix epoch seconds via core.scm's `ymd->days`.
;; Timezone offsets are ignored (a feed reader sorts by day, not by minute).
(define ef--months
  '(("Jan" . 1) ("Feb" . 2) ("Mar" . 3) ("Apr" . 4) ("May" . 5) ("Jun" . 6)
    ("Jul" . 7) ("Aug" . 8) ("Sep" . 9) ("Oct" . 10) ("Nov" . 11) ("Dec" . 12)))

(define (ef--now) (or (string->number (current-time "%s")) 0))

(define (ef--epoch y mo d h mi)
  (+ (* 86400 (ymd->days y mo d)) (* 3600 h) (* 60 mi)))

;; RFC 822 ("Tue, 08 Jul 2025 07:33:00 +0000") or ISO 8601
;; ("2025-07-08T07:33:00Z" / "2025-07-08"); anything else → now.
(define (ef--parse-date s)
  (let ((s (if s (ef--trim s) "")))
    (cond
      ((equal? s "") (ef--now))
      ((ef--matches? "^[0-9]{4}-[0-9]{2}-[0-9]{2}" s)
       (let* ((c (regexp-captures
                  "^([0-9]{4})-([0-9]{2})-([0-9]{2})([T ]([0-9]{2}):([0-9]{2}))?" s))
              (y (string->number (nth c 1)))
              (mo (string->number (nth c 2)))
              (d (string->number (nth c 3)))
              (h (if (and (> (length c) 5) (nth c 5) (not (equal? (nth c 5) "")))
                     (string->number (nth c 5)) 0))
              (mi (if (and (> (length c) 6) (nth c 6) (not (equal? (nth c 6) "")))
                      (string->number (nth c 6)) 0)))
         (ef--epoch y mo d h mi)))
      ((ef--matches? "[0-9]{1,2}\\s+[A-Za-z]{3}[a-z]*\\s+[0-9]{2,4}" s)
       (let* ((c (regexp-captures
                  "([0-9]{1,2})\\s+([A-Za-z]{3})[a-z]*\\s+([0-9]{2,4})(\\s+([0-9]{2}):([0-9]{2}))?" s))
              (d (string->number (nth c 1)))
              (mo (or (ef--aget ef--months (nth c 2)) 1))
              (y0 (string->number (nth c 3)))
              (y (if (< y0 100) (+ y0 2000) y0))
              (h (if (and (> (length c) 5) (nth c 5) (not (equal? (nth c 5) "")))
                     (string->number (nth c 5)) 0))
              (mi (if (and (> (length c) 6) (nth c 6) (not (equal? (nth c 6) "")))
                      (string->number (nth c 6)) 0)))
         (ef--epoch y mo d h mi)))
      (else (ef--now)))))

(define (ef--date-string epoch)
  (let* ((ymd (days->ymd (quotient epoch 86400)))
         (y (car ymd)) (mo (car (cdr ymd))) (d (car (cdr (cdr ymd)))))
    (string-append (number->string y) "-" (pad2 mo) "-" (pad2 d))))

;; ── feed parsing (RSS 2.0 + Atom) ───────────────────────────────────────────
(define (ef--strip-cdata s)
  (replace-regexp-in-string "(?is)<!\\[CDATA\\[(.*?)\\]\\]>" "$1" s))

;; Clean a single-line text field: drop tags, decode entities, squeeze
;; whitespace, strip control chars.
(define (ef--clean-text s)
  (if (not s)
      ""
      (ef--sanitize
       (ef--trim
        (replace-regexp-in-string "\\s+" " "
                                  (ef--entities
                                   (replace-regexp-in-string "(?s)<[^>]*>" " " s)))))))

;; Split a feed document into (header . entry-blocks) by fencing each
;; <item>/<entry> open tag with the sentinel and splitting on it — byte-safe.
(define (ef--blocks xml)
  (let* ((marked (replace-regexp-in-string "(?i)<(item|entry)([\\s>])"
                                           (string-append ef--soh-str "<$1$2") xml))
         (pieces (ef--split-char marked ef--soh)))
    (cons (car pieces) (cdr pieces))))

;; The entry's link. Atom: prefer rel="alternate" href, then any href.
;; RSS: the text inside <link>…</link>.
(define (ef--block-link block)
  (or (ef--cap "(?is)<link[^>]*rel=[\"']alternate[\"'][^>]*href=[\"']([^\"']+)" block)
      (ef--cap "(?is)<link[^>]*>\\s*(https?://[^<\\s]+)\\s*</link>" block)
      (ef--cap "(?is)<link[^>]+href=[\"']([^\"']+)" block)
      ""))

(define (ef--block-content block)
  (or (ef--cap "(?is)<content:encoded[^>]*>(.*?)</content:encoded>" block)
      (ef--cap "(?is)<content[\\s>][^>]*>(.*?)</content>" block)
      (ef--cap "(?is)<description[^>]*>(.*?)</description>" block)
      (ef--cap "(?is)<summary[^>]*>(.*?)</summary>" block)
      ""))

(define (ef--block-date block)
  (or (ef--cap "(?is)<pubDate[^>]*>(.*?)</pubDate>" block)
      (ef--cap "(?is)<dc:date[^>]*>(.*?)</dc:date>" block)
      (ef--cap "(?is)<published[^>]*>(.*?)</published>" block)
      (ef--cap "(?is)<updated[^>]*>(.*?)</updated>" block)
      ""))

;; Parse one feed body → (feed-title . entries), each entry a hash WITHOUT id /
;; feed-url / tags (the merge step adds those). Malformed blocks are skipped.
(define (ef--parse-feed body)
  (let* ((body (ef--strip-cdata body))
         (hb (ef--blocks body))
         (feed-title (ef--clean-text (or (ef--cap "(?is)<title[^>]*>(.*?)</title>" (car hb)) "")))
         (entries
          (filter
           (lambda (e) (not (equal? (hash-try-get e 'title) "")))
           (map
            (lambda (block)
              (let* ((title (ef--clean-text (ef--cap "(?is)<title[^>]*>(.*?)</title>" block)))
                     (link (ef--sanitize (ef--trim (ef--entities (ef--block-link block)))))
                     (guid (ef--clean-text
                            (or (ef--cap "(?is)<guid[^>]*>(.*?)</guid>" block)
                                (ef--cap "(?is)<id[^>]*>(.*?)</id>" block)
                                "")))
                     (date (ef--parse-date (ef--block-date block)))
                     (content (replace-regexp-in-string ef--us " " (ef--block-content block))))
                (hash 'title title
                      'link link
                      'guid (if (equal? guid "") (if (equal? link "") title link) guid)
                      'date date
                      'content content)))
            (cdr hb)))))
    (cons feed-title entries)))

;; ── database ────────────────────────────────────────────────────────────────
;; One line per entry: id␟feed-url␟feed-title␟title␟link␟epoch␟tags␟content
;; (␟ = 0x1f; newlines inside content stored as 0x1e). Line 1 is a version tag.
(define (ef--entry-line e)
  (string-append
   (hash-try-get e 'id) ef--us
   (hash-try-get e 'feed-url) ef--us
   (hash-try-get e 'feed-title) ef--us
   (hash-try-get e 'title) ef--us
   (hash-try-get e 'link) ef--us
   (number->string (hash-try-get e 'date)) ef--us
   (ef--join (hash-try-get e 'tags) ",") ef--us
   (replace-regexp-in-string "\r" ""
    (replace-regexp-in-string "\n" ef--rs (hash-try-get e 'content)))))

(define (ef--db-save)
  (let loop ((ids (reverse (ef--st 'ids))) (lines '("macros-feeds-db 1")))
    (if (null? ids)
        (write-file (ef--db-file)
                    (string-append (ef--join (reverse lines) "\n") "\n"))
        (let ((e (hash-try-get (ef--st 'db) (car ids))))
          (loop (cdr ids) (if e (cons (ef--entry-line e) lines) lines))))))

(define (ef--db-load)
  (when (not (ef--st 'loaded))
    (ef--st! 'loaded #t)
    ;; Migration: this package used to be macros-elfeed; if the new db file
    ;; doesn't exist yet, read the old one (the next save writes the new path).
    (let ((path (if (file-exists? (ef--db-file))
                    (ef--db-file)
                    (string-append (getenv "HOME") "/.macros-elfeed-db"))))
     (when (file-exists? path)
      (let loop ((lines (ef--split-char (read-file path) #\newline)))
        (when (pair? lines)
          (let ((f (ef--split-char (car lines) (integer->char 31))))
            (when (= (length f) 8)
              (let* ((id (nth f 0))
                     (tags (filter (lambda (t) (not (equal? t "")))
                                   (ef--split-char (nth f 6) #\,)))
                     (e (hash 'id id
                              'feed-url (nth f 1)
                              'feed-title (nth f 2)
                              'title (nth f 3)
                              'link (nth f 4)
                              'date (or (string->number (nth f 5)) 0)
                              'tags tags
                              'content (replace-regexp-in-string ef--rs "\n" (nth f 7)))))
                (when (not (hash-try-get (ef--st 'db) id))
                  (ef--st! 'ids (cons id (ef--st 'ids))))
                (ef--st! 'db (hash-insert (ef--st 'db) id e)))))
          (loop (cdr lines))))))))

;; Merge freshly parsed entries into the db. Existing ids are left untouched
;; (their read/unread state and tags are the user's); new ids arrive tagged
;; `unread` plus the feed's configured auto-tags. Returns how many were new.
(define (ef--db-merge url feed-title auto-tags entries)
  (let loop ((es entries) (added 0))
    (if (null? es)
        added
        (let* ((e (car es))
               (id (string-append url (list->string (list (integer->char 2)))
                                  (hash-try-get e 'guid))))
          (if (hash-try-get (ef--st 'db) id)
              (loop (cdr es) added)
              (let ((full (hash 'id id
                                'feed-url url
                                'feed-title (if (equal? feed-title "") url feed-title)
                                'title (hash-try-get e 'title)
                                'link (hash-try-get e 'link)
                                'date (hash-try-get e 'date)
                                'tags (cons "unread" auto-tags)
                                'content (hash-try-get e 'content))))
                (ef--st! 'db (hash-insert (ef--st 'db) id full))
                (ef--st! 'ids (cons id (ef--st 'ids)))
                (loop (cdr es) (+ added 1))))))))

;; Mutate one entry's tags: `op` is 'add or 'remove. Saves the db.
(define (ef--retag id tag op)
  (let ((e (hash-try-get (ef--st 'db) id)))
    (when e
      (let* ((tags (hash-try-get e 'tags))
             (tags (cond ((equal? op 'add) (if (member tag tags) tags (cons tag tags)))
                         (else (filter (lambda (t) (not (equal? t tag))) tags)))))
        (ef--st! 'db (hash-insert (ef--st 'db) id (hash-insert e 'tags tags)))
        (ef--db-save)))))

;; ── filter language ─────────────────────────────────────────────────────────
;; "+tag -tag @2-weeks-ago #50 regex !regex" → hash of compiled predicates.
(define (ef--age->seconds spec)                     ; "6-months-ago" → seconds
  (let* ((c (regexp-captures "^([0-9]+)-?([a-z]+)" spec)))
    (if (null? c)
        #f
        (let* ((n (string->number (nth c 1)))
               (u (substring (nth c 2) 0 1))
               (secs (cond ((equal? u "d") 86400)
                           ((equal? u "w") 604800)
                           ((equal? u "m") 2626560)      ; 30.4 days
                           ((equal? u "y") 31557600)
                           (else 86400))))
          (if n (* n secs) #f)))))

(define (ef--parse-filter str)
  (let loop ((toks (filter (lambda (t) (not (equal? t "")))
                           (ef--split-char (ef--trim str) #\space)))
             (must '()) (mustnot '()) (since #f) (limit #f) (yes '()) (no '()))
    (if (null? toks)
        (hash 'must must 'mustnot mustnot 'since since 'limit limit
              'matches yes 'notmatches no)
        (let* ((tok (car toks))
               (head (substring tok 0 1))
               (rest (substring tok 1 (string-length tok))))
          (cond
            ((equal? head "+") (loop (cdr toks) (cons rest must) mustnot since limit yes no))
            ((equal? head "-") (loop (cdr toks) must (cons rest mustnot) since limit yes no))
            ((equal? head "#") (loop (cdr toks) must mustnot since (string->number rest) yes no))
            ((equal? head "@")
             (let ((secs (ef--age->seconds rest)))
               (loop (cdr toks) must mustnot
                     (if secs (- (ef--now) secs) since) limit yes no)))
            ((equal? head "!") (loop (cdr toks) must mustnot since limit yes (cons rest no)))
            (else (loop (cdr toks) must mustnot since limit (cons tok yes) no)))))))

(define (ef--entry-visible? e flt)
  (let ((tags (hash-try-get e 'tags))
        (text (string-append (hash-try-get e 'title) " " (hash-try-get e 'feed-title)))
        (since (hash-try-get flt 'since)))
    (and
     (let all ((ts (hash-try-get flt 'must)))
       (or (null? ts) (and (member (car ts) tags) (all (cdr ts)))))
     (let none ((ts (hash-try-get flt 'mustnot)))
       (or (null? ts) (and (not (member (car ts) tags)) (none (cdr ts)))))
     (or (not since) (>= (hash-try-get e 'date) since))
     (let all ((ps (hash-try-get flt 'matches)))
       (or (null? ps)
           (and (ef--matches? (string-append "(?i)" (car ps)) text) (all (cdr ps)))))
     (let none ((ps (hash-try-get flt 'notmatches)))
       (or (null? ps)
           (and (not (ef--matches? (string-append "(?i)" (car ps)) text)) (none (cdr ps))))))))

;; The filtered view: newest first, capped by #limit.
(define (ef--visible-ids)
  (let* ((flt (ef--parse-filter (ef--filter)))
         (db (ef--st 'db))
         (vis (filter (lambda (id)
                        (let ((e (hash-try-get db id)))
                          (and e (ef--entry-visible? e flt))))
                      (ef--st 'ids)))
         (sorted (sort-by (lambda (id) (hash-try-get (hash-try-get db id) 'date))
                          > vis))
         (limit (hash-try-get flt 'limit)))
    (if (and limit (> (length sorted) limit))
        (let take ((xs sorted) (n limit) (acc '()))
          (if (or (= n 0) (null? xs)) (reverse acc) (take (cdr xs) (- n 1) (cons (car xs) acc))))
        sorted)))

;; ── search buffer ───────────────────────────────────────────────────────────
(define ef--search-help
  "  enter show · b browser · y copy link · r/u read/unread · +/- tag · s/c filter · g refresh · G fetch · ? menu · q quit")

;; " — fetching 2/5" while an update runs, else "".
(define (ef--progress)
  (if (ef--st 'fetching)
      (string-append " — fetching "
                     (number->string (- (ef--st 'fetch-total) (length (ef--st 'queue))))
                     "/" (number->string (ef--st 'fetch-total)))
      ""))

(define (ef--tags-suffix tags)
  (let ((shown (filter (lambda (t) (not (equal? t "unread"))) tags)))
    (if (null? shown) "" (string-append "(" (ef--join shown ",") ")"))))

;; Render the search buffer.
;;
;; `recompute?` — #t re-runs the filter (open / `g` / `s` / after a fetch);
;; #f redraws the EXISTING view (elfeed's semantics: marking an entry read
;; dims its line but does not evict it until the next explicit refresh, even
;; when the filter says +unread).
;;
;; `where` — cursor placement: 'top (first entry), 'keep (stay on the same
;; line), or an integer line number.
;;
;; Overlays paint the date (comment), feed (function) and tag (keyword)
;; columns with BUILT-IN faces so a runtime theme switch can't wipe them;
;; read entries dim whole-line, unread entries render BOLD: `feeds-unread`
;; is a colorless face carrying only the bold attribute (`set-face-bold` —
;; added to the editor core alongside this package; with no color entry the
;; paint path falls back to the theme's default text color). Re-seeded on
;; every render because a runtime `load-theme` wipes all face attributes.
(define (ef--ensure-faces) (set-face-bold "feeds-unread" #t))

(define (ef--search-render recompute? where)
  (let* ((prev-line (buffer-line))
         (ids (if recompute?
                  (ef--visible-ids)
                  (filter (lambda (id) (hash-try-get (ef--st 'db) id)) (ef--st 'view))))
         (db (ef--st 'db))
         (total (length (ef--st 'ids)))
         (header (string-append "Feeds — " (number->string (length ids)) "/"
                                (number->string total) " entries — filter: "
                                (ef--filter) (ef--progress)))
         (already? (equal? (current-buffer) "*feeds-search*")))
    (ef--st! 'view ids)
    (let loop ((rest ids) (idx 3)
               (abs (+ (ef--bytelen header) 1 (ef--bytelen ef--search-help) 1 1))
               (texts (list "" ef--search-help header))
               (faces (list (list 0 "keyword") (list 1 "comment")))
               (ospans '()))
      (if (null? rest)
          (begin
            (ef--ensure-faces)
            ((if already? render-buffer-quiet render-buffer)
             "*feeds-search*" "feeds-search-mode"
             (ef--join (reverse texts) "\n") (reverse faces))
            (clear-overlays)
            (for-each (lambda (sp) (overlay-set-face (nth sp 0) (nth sp 1) (nth sp 2)))
                      (reverse ospans))
            (goto-line (cond ((and (equal? where 'keep) already? (>= prev-line 3)) prev-line)
                             ((number? where) where)
                             (else 3))))
          (let* ((e (hash-try-get db (car rest)))
                 (tags (hash-try-get e 'tags))
                 (unread? (member "unread" tags))
                 (datef (ef--date-string (hash-try-get e 'date)))
                 (feedf (ef--fit (hash-try-get e 'feed-title) *feeds-feed-width*))
                 (titlef (ef--truncate (hash-try-get e 'title) *feeds-title-width*))
                 (tagsf (ef--tags-suffix tags))
                 (line (string-append datef "  " feedf "  " titlef
                                      (if (equal? tagsf "") "" "  ") tagsf))
                 (faces (cons (list idx (if unread? "feeds-unread" "comment")) faces))
                 (feed-start (+ abs 12))                        ; date is ASCII: 10+2 bytes
                 (feed-end (+ feed-start (ef--bytelen feedf)))
                 (ospans (cons (list abs (+ abs 10) "comment")
                               (cons (list feed-start feed-end "function") ospans)))
                 (ospans (if (equal? tagsf "")
                             ospans
                             (let ((tstart (+ feed-end 2 (ef--bytelen titlef) 2)))
                               (cons (list tstart (+ tstart (ef--bytelen tagsf)) "keyword")
                                     ospans)))))
            (loop (cdr rest) (+ idx 1) (+ abs (ef--bytelen line) 1)
                  (cons line texts) faces ospans))))))

;; The entry on the cursor's line, or #f.
(define (ef--entry-at-point)
  (let* ((line (buffer-line))
         (idx (- line (ef--st 'view-offset)))
         (view (ef--st 'view)))
    (if (and (>= idx 0) (< idx (length view)))
        (nth view idx)
        #f)))

;; ── show buffer ─────────────────────────────────────────────────────────────
;; A light HTML→text pass for entry content: block tags become line breaks,
;; list items get bullets, everything else is stripped, entities decoded, and
;; paragraphs wrapped. (For full pages, `b` opens the real browser.)
(define (ef--html->lines html)
  (let* ((s (ef--strip-cdata html))
         (s (replace-regexp-in-string "(?is)<(script|style)[^>]*>.*?</(script|style)>" " " s))
         (s (replace-regexp-in-string "(?i)<br\\s*/?>" "\n" s))
         (s (replace-regexp-in-string "(?i)<li[^>]*>" "\n• " s))
         (s (replace-regexp-in-string "(?i)</(p|div|li|ul|ol|h1|h2|h3|h4|h5|h6|blockquote|tr|pre|table|figure)>" "\n\n" s))
         (s (replace-regexp-in-string "(?i)<(p|h1|h2|h3|h4|h5|h6|blockquote|pre)[^>]*>" "\n\n" s))
         (s (replace-regexp-in-string "(?s)<[^>]*>" " " s))
         (s (ef--entities s))
         (s (replace-regexp-in-string "\r" "" s)))
    ;; wrap each paragraph line; squeeze blank runs
    (let loop ((ls (ef--split-char s #\newline)) (prev-blank #t) (out '()))
      (if (null? ls)
          (reverse out)
          (let ((t (ef--trim (replace-regexp-in-string "[ \t]+" " " (car ls)))))
            (cond
              ((equal? t "")
               (if prev-blank (loop (cdr ls) #t out) (loop (cdr ls) #t (cons "" out))))
              (else
               (let w ((ws (ef--wrap t *feeds-show-width*)) (out out))
                 (if (null? ws)
                     (loop (cdr ls) #f out)
                     (w (cdr ws) (cons (car ws) out)))))))))))

(define ef--show-help
  "  n/p next/prev · b browser · y copy link · u unread · +/- tag · ? menu · q back")

;; Show `id` and mark it read.
(define (ef--show id)
  (when (hash-try-get (ef--st 'db) id)
    (ef--st! 'current id)
    (ef--retag id "unread" 'remove)
    (ef--show-render id 0)))

;; Draw *feeds-entry* for `id` with the cursor on `line` — no read-state
;; change, so retagging from inside the entry can redraw the meta line.
(define (ef--show-render id line)
  (let ((e (hash-try-get (ef--st 'db) id)))
    (when e
      (let* ((meta (string-append (hash-try-get e 'feed-title) " — "
                                  (ef--date-string (hash-try-get e 'date))
                                  (let ((ts (ef--tags-suffix (hash-try-get e 'tags))))
                                    (if (equal? ts "") "" (string-append "  " ts)))))
             (head (list (hash-try-get e 'title)
                         meta
                         (hash-try-get e 'link)
                         ef--show-help
                         ""))
             (body (ef--html->lines (hash-try-get e 'content)))
             (faces (list (list 0 "keyword") (list 1 "function")
                          (list 2 "string") (list 3 "comment"))))
        ((if (equal? (current-buffer) "*feeds-entry*") render-buffer-quiet render-buffer)
         "*feeds-entry*" "feeds-show-mode"
         (ef--join (append head body) "\n") faces)
        (clear-overlays)
        (goto-line line)))))

;; ── fetching ────────────────────────────────────────────────────────────────
;; Parse the "feeds" option string — whitespace-separated `url` or
;; `url|tag,tag` tokens — to a list of (url . tag-strings).
(define (ef--parse-feeds-option s)
  (map (lambda (tok)
         (let ((parts (ef--split-char tok #\|)))
           (cons (car parts)
                 (if (null? (cdr parts))
                     '()
                     (filter (lambda (t) (not (equal? t "")))
                             (ef--split-char (car (cdr parts)) #\,))))))
       (filter (lambda (t) (not (equal? t "")))
               (ef--split-char (replace-regexp-in-string "\\s+" " " s) #\space))))

;; The configured feeds, normalized to (url . tag-strings): the "feeds"
;; option when set (the init.scm channel), else the *feeds-list* global.
(define (ef--feeds)
  (let ((opt (get-option "feeds")))
    (if (and (string? opt) (not (equal? (ef--trim opt) "")))
        (ef--parse-feeds-option opt)
        (map (lambda (f)
               (if (list? f)
                   (cons (car f)
                         (map (lambda (t) (if (symbol? t) (symbol->string t) t)) (cdr f)))
                   (cons f '())))
             *feeds-list*))))

(define (ef--fetch-next)
  (let ((q (ef--st 'queue)))
    (if (null? q)
        (begin
          (ef--st! 'fetching #f)
          (ef--db-save)
          (when (equal? (current-buffer) "*feeds-search*")
            (ef--search-render #t 'keep))
          (message (string-append "feeds: update done — "
                                  (number->string (ef--st 'new-count)) " new"
                                  (let ((errs (ef--st 'err-count)))
                                    (if (> errs 0)
                                        (string-append ", " (number->string errs) " failed")
                                        "")))))
        (let ((feed (car q)))
          (ef--st! 'queue (cdr q))
          (ef--st! 'fetching feed)
          (when (equal? (current-buffer) "*feeds-search*")
            (ef--search-render #f 'keep))           ; progress in the header
          (message (string-append "feeds: fetching " (car feed) " …"))
          (http-request "GET" (car feed)
                        (list "User-Agent" *feeds-user-agent*
                              "Accept" "application/rss+xml, application/atom+xml, application/xml;q=0.9, */*;q=0.8")
                        ""
                        'feeds--on-response)))))

;; `http-request` delivers "<status>\n<body>" in one string; split at the
;; first newline only (the body has plenty of its own).
(define (ef--split-status payload)
  (let loop ((cs (string->list payload)) (acc '()))
    (cond ((null? cs) (cons (list->string (reverse acc)) ""))
          ((char=? (car cs) #\newline)
           (cons (list->string (reverse acc)) (list->string (cdr cs))))
          (else (loop (cdr cs) (cons (car cs) acc))))))

(define (feeds--on-response payload)
  (let ((feed (ef--st 'fetching)))
    (when feed                               ; a stray/late callback is dropped
      (let* ((sp (ef--split-status payload))
             (status (or (string->number (ef--trim (car sp))) 0))
             (body (cdr sp)))
        (if (or (< status 200) (>= status 300))
            (begin
              (ef--st! 'err-count (+ (ef--st 'err-count) 1))
              (message (string-append "feeds: " (car feed) " → HTTP "
                                      (number->string status))))
            (let* ((parsed (ef--parse-feed body))
                   (added (ef--db-merge (car feed) (car parsed) (cdr feed) (cdr parsed))))
              (ef--st! 'new-count (+ (ef--st 'new-count) added)))))
      (ef--fetch-next))))

;; ── commands ────────────────────────────────────────────────────────────────
(define (feeds)
  (ef--db-load)
  (unless (member (current-buffer) '("*feeds-search*" "*feeds-entry*"))
    (ef--st! 'origin (current-buffer)))
  (ef--search-render #t 'top)
  (when (null? (ef--st 'ids))
    (message (if (null? (ef--feeds))
                 "feeds: no feeds configured — set the \"feeds\" option"
                 "feeds: database empty — press G to fetch"))))

(define (feeds-update)
  (ef--db-load)
  (cond
    ((ef--st 'fetching) (message "feeds: an update is already running"))
    ((null? (ef--feeds)) (message "feeds: no feeds configured — set the \"feeds\" option"))
    (else
     (ef--st! 'queue (ef--feeds))
     (ef--st! 'fetch-total (length (ef--feeds)))
     (ef--st! 'new-count 0)
     (ef--st! 'err-count 0)
     (ef--fetch-next))))

(define (feeds-search-show)
  (let ((id (ef--entry-at-point)))
    (if id (ef--show id) (message "feeds: no entry on this line"))))

(define (ef--link id)
  (let ((e (and id (hash-try-get (ef--st 'db) id))))
    (if e (hash-try-get e 'link) "")))

(define (ef--browse id)
  (let ((link (ef--link id)))
    (if (equal? link "")
        (message "feeds: entry has no link")
        (begin (open-url link) (message (string-append "feeds: opened " link))))))

(define (ef--yank id)
  (let ((link (ef--link id)))
    (if (equal? link "")
        (message "feeds: entry has no link")
        (begin (clipboard-set link) (message (string-append "feeds: copied " link))))))

(define (feeds-search-browse)
  (let ((id (ef--entry-at-point)))
    (if (not id)
        (message "feeds: no entry on this line")
        (begin
          (ef--retag id "unread" 'remove)
          (ef--search-render #f 'keep)
          (ef--browse id)))))

(define (feeds-search-yank)
  (let ((id (ef--entry-at-point)))
    (if id (ef--yank id) (message "feeds: no entry on this line"))))

(define (ef--search-retag tag op advance?)
  (let ((id (ef--entry-at-point)))
    (if (not id)
        (message "feeds: no entry on this line")
        (let ((line (buffer-line)))
          (ef--retag id tag op)
          (ef--search-render #f 'keep)
          (when advance? (goto-line (+ line 1)))))))

(define (feeds-search-untag-unread) (ef--search-retag "unread" 'remove #t))
(define (feeds-search-tag-unread)   (ef--search-retag "unread" 'add #t))

(define (feeds-search-tag-all)
  (if (ef--entry-at-point)
      (read-string "Add tag: "
                   (lambda (input)
                     (let ((tag (ef--trim input)))
                       (when (not (equal? tag "")) (ef--search-retag tag 'add #f)))))
      (message "feeds: no entry on this line")))

(define (feeds-search-untag-all)
  (if (ef--entry-at-point)
      (read-string "Remove tag: "
                   (lambda (input)
                     (let ((tag (ef--trim input)))
                       (when (not (equal? tag "")) (ef--search-retag tag 'remove #f)))))
      (message "feeds: no entry on this line")))

(define (feeds-search-set-filter)
  (read-string "Filter: "
                (lambda (input)
                  (ef--st! 'filter (ef--trim input))
                  (ef--search-render #t 'top))
                (ef--filter)))

(define (feeds-search-clear-filter)
  (ef--st! 'filter #f)
  (ef--search-render #t 'top)
  (message (string-append "feeds: filter reset to " (ef--filter))))

;; Mark every entry in the current view read — one db save, after a confirm.
(define (feeds-search-mark-all-read)
  (let ((ids (filter (lambda (id)
                       (let ((e (hash-try-get (ef--st 'db) id)))
                         (and e (member "unread" (hash-try-get e 'tags)))))
                     (ef--st 'view))))
    (if (null? ids)
        (message "feeds: nothing unread in this view")
        (begin
          (ef--st! 'confirm
                   (lambda ()
                     (for-each
                      (lambda (id)
                        (let ((e (hash-try-get (ef--st 'db) id)))
                          (ef--st! 'db (hash-insert (ef--st 'db) id
                                                    (hash-insert e 'tags
                                                                 (filter (lambda (t) (not (equal? t "unread")))
                                                                         (hash-try-get e 'tags)))))))
                      ids)
                     (ef--db-save)
                     (ef--search-render #f 'keep)
                     (message (string-append "feeds: marked " (number->string (length ids)) " read"))))
          (y-or-n-p (string-append "Mark " (number->string (length ids)) " entries read? ")
                    'feeds--confirm-yes)))))

(define (feeds--confirm-yes ans)
  (let ((t (ef--st 'confirm)))
    (ef--st! 'confirm #f)
    (when (and t (equal? ans "yes")) (t))))

(define (feeds-search-refresh) (ef--search-render #t 'keep))

;; Back to where `feeds` was opened from, if that buffer is still around.
(define (feeds-search-quit)
  (let ((o (ef--st 'origin)))
    (switch-to-buffer (if (and o (member o (buffer-names))) o "*scratch*"))))

(define (feeds-menu)
  (transient "Feeds"
             (list (list "Entry"
                         (list "o" "Show"            'feeds-search-show)
                         (list "b" "Open in browser" 'feeds-search-browse)
                         (list "y" "Copy link"       'feeds-search-yank))
                   (list "Mark"
                         (list "r" "Read"            'feeds-search-untag-unread)
                         (list "u" "Unread"          'feeds-search-tag-unread)
                         (list "A" "All in view read" 'feeds-search-mark-all-read)
                         (list "+" "Add tag…"        'feeds-search-tag-all)
                         (list "-" "Remove tag…"     'feeds-search-untag-all))
                   (list "View"
                         (list "s" "Edit filter…"    'feeds-search-set-filter)
                         (list "c" "Reset filter"    'feeds-search-clear-filter)
                         (list "g" "Refresh"         'feeds-search-refresh)
                         (list "G" "Fetch all feeds" 'feeds-update)
                         (list "q" "Quit"            'feeds-search-quit)))))

;; show-buffer commands
;; Back to the search buffer, cursor parked on the entry we were reading (the
;; view is NOT recomputed, so the just-read entry is still on its line even
;; under a +unread filter — press `g` to sweep it away).
(define (feeds-show-quit)
  (let* ((cur (ef--st 'current))
         (view (ef--st 'view))
         (line (let loop ((xs view) (i 0))
                 (cond ((null? xs) 'top)
                       ((equal? (car xs) cur) (+ i (ef--st 'view-offset)))
                       (else (loop (cdr xs) (+ i 1)))))))
    (ef--st! 'current #f)
    (ef--search-render #f line)))

(define (feeds-show-browse) (ef--browse (ef--st 'current)))
(define (feeds-show-yank)   (ef--yank (ef--st 'current)))

;; Retag the entry being read and redraw it in place (meta line shows tags).
(define (ef--show-retag tag op)
  (let ((id (ef--st 'current)))
    (when id
      (ef--retag id tag op)
      (ef--show-render id (buffer-line)))))

(define (feeds-show-tag-unread)
  (ef--show-retag "unread" 'add)
  (message "feeds: marked unread"))

(define (ef--show-read-tag prompt op)
  (read-string prompt
               (lambda (input)
                 (let ((tag (ef--trim input)))
                   (when (not (equal? tag "")) (ef--show-retag tag op))))))

(define (feeds-show-tag)   (ef--show-read-tag "Add tag: " 'add))
(define (feeds-show-untag) (ef--show-read-tag "Remove tag: " 'remove))

(define (feeds-show-menu)
  (transient "Feeds entry"
             (list (list "Entry"
                         (list "n" "Next"            'feeds-show-next)
                         (list "p" "Previous"        'feeds-show-prev)
                         (list "b" "Open in browser" 'feeds-show-browse)
                         (list "y" "Copy link"       'feeds-show-yank))
                   (list "Mark"
                         (list "u" "Unread"          'feeds-show-tag-unread)
                         (list "+" "Add tag…"        'feeds-show-tag)
                         (list "-" "Remove tag…"     'feeds-show-untag)
                         (list "q" "Back to list"    'feeds-show-quit)))))

(define (ef--show-step dir)
  (let* ((view (ef--st 'view))
         (cur (ef--st 'current)))
    (let loop ((xs view) (i 0))
      (cond
        ((null? xs) (message "feeds: entry not in view"))
        ((equal? (car xs) cur)
         (let ((j (+ i dir)))
           (if (and (>= j 0) (< j (length view)))
               (ef--show (nth view j))
               (message "feeds: no more entries"))))
        (else (loop (cdr xs) (+ i 1)))))))

(define (feeds-show-next) (ef--show-step 1))
(define (feeds-show-prev) (ef--show-step -1))

;; ── keymaps + registration ──────────────────────────────────────────────────
(define-key "feeds-search-mode" "enter"   'feeds-search-show)
(define-key "feeds-search-mode" "mouse-1" 'feeds-search-show)
(define-key "feeds-search-mode" "b"       'feeds-search-browse)
(define-key "feeds-search-mode" "r"       'feeds-search-untag-unread)
(define-key "feeds-search-mode" "u"       'feeds-search-tag-unread)
(define-key "feeds-search-mode" "+"       'feeds-search-tag-all)
(define-key "feeds-search-mode" "-"       'feeds-search-untag-all)
(define-key "feeds-search-mode" "shift-a" 'feeds-search-mark-all-read)
(define-key "feeds-search-mode" "y"       'feeds-search-yank)
(define-key "feeds-search-mode" "s"       'feeds-search-set-filter)
(define-key "feeds-search-mode" "c"       'feeds-search-clear-filter)
(define-key "feeds-search-mode" "g"       'feeds-search-refresh)
(define-key "feeds-search-mode" "shift-g" 'feeds-update)
(define-key "feeds-search-mode" "n"       'next-line)
(define-key "feeds-search-mode" "p"       'previous-line)
(define-key "feeds-search-mode" "?"       'feeds-menu)
(define-key "feeds-search-mode" "q"       'feeds-search-quit)

(define-key "feeds-show-mode" "q"       'feeds-show-quit)
(define-key "feeds-show-mode" "b"       'feeds-show-browse)
(define-key "feeds-show-mode" "y"       'feeds-show-yank)
(define-key "feeds-show-mode" "u"       'feeds-show-tag-unread)
(define-key "feeds-show-mode" "+"       'feeds-show-tag)
(define-key "feeds-show-mode" "-"       'feeds-show-untag)
(define-key "feeds-show-mode" "n"       'feeds-show-next)
(define-key "feeds-show-mode" "p"       'feeds-show-prev)
(define-key "feeds-show-mode" "?"       'feeds-show-menu)

;; Motion + scrolling: a "special" read-only buffer bypasses the global evil
;; keymaps, so movement must be bound per-mode (Emacs defaults here, modal
;; overlays below — the exact web-reader arrangement).
(for-each
 (lambda (mode)
   (define-key mode "down"   'next-line)
   (define-key mode "up"     'previous-line)
   (define-key mode "left"   'backward-char)
   (define-key mode "right"  'forward-char)
   (define-key mode "ctrl-n" 'next-line)
   (define-key mode "ctrl-p" 'previous-line)
   (define-key mode "ctrl-v" 'evil-scroll-down)
   ;; The editor spells Meta "alt-" — "meta-v" never matched a keystroke.
   (define-key mode "alt-v"  'evil-scroll-up)
   (define-key mode "ctrl-d" 'evil-scroll-down)
   (define-key mode "ctrl-u" 'evil-scroll-up)
   (define-key mode "space"  'evil-scroll-down)
   (define-key mode "home"   'beginning-of-buffer)
   (define-key mode "end"    'end-of-buffer)
   (define-key mode "alt-<"  'beginning-of-buffer)
   (define-key mode "alt->"  'end-of-buffer))
 (list "feeds-search-mode" "feeds-show-mode"))

;; Modal (evil + helix) overlays: vim motion plus the mode's own keys. In the
;; SEARCH buffer `G` fetches (matching the help line and elfeed muscle memory)
;; rather than jumping to the bottom — `end`/`ctrl-d` still get you there —
;; with magit-style `g r` refresh and `R` as a fetch alias.
(for-each
 (lambda (prefix)
   (let ((km (string-append prefix "feeds-search-mode")))
     (define-key km "j"       'next-line)
     (define-key km "k"       'previous-line)
     (define-key km "ctrl-d"  'evil-scroll-down)
     (define-key km "ctrl-u"  'evil-scroll-up)
     (define-key km "g g"     'evil-goto-first-line)
     (define-key km "shift-g" 'feeds-update)
     (define-key km "g r"     'feeds-search-refresh)
     (define-key km "shift-r" 'feeds-update))
   (let ((km (string-append prefix "feeds-show-mode")))
     (define-key km "j"       'next-line)
     (define-key km "k"       'previous-line)
     (define-key km "ctrl-d"  'evil-scroll-down)
     (define-key km "ctrl-u"  'evil-scroll-up)
     (define-key km "g g"     'evil-goto-first-line)
     (define-key km "shift-g" 'evil-goto-last-line)))
 (list "evil-normal:" "helix-normal:"))

;; No line-number gutter: these are list/reading views, not code (the same
;; per-mode option core's `define-list-mode-keys` sets).
(set-option "line-numbers:feeds-search-mode" "false")
(set-option "line-numbers:feeds-show-mode" "false")

(define-key "fundamental" "ctrl-c f" 'feeds)

(register-command "feeds")
(register-command "feeds-update")
(register-command "feeds-search-show")
(register-command "feeds-search-browse")
(register-command "feeds-search-untag-unread")
(register-command "feeds-search-tag-unread")
(register-command "feeds-search-tag-all")
(register-command "feeds-search-untag-all")
(register-command "feeds-search-set-filter")
(register-command "feeds-search-refresh")
(register-command "feeds-search-quit")
(register-command "feeds-search-yank")
(register-command "feeds-search-clear-filter")
(register-command "feeds-search-mark-all-read")
(register-command "feeds-menu")
(register-command "feeds-show-quit")
(register-command "feeds-show-browse")
(register-command "feeds-show-yank")
(register-command "feeds-show-tag-unread")
(register-command "feeds-show-tag")
(register-command "feeds-show-untag")
(register-command "feeds-show-menu")
(register-command "feeds-show-next")
(register-command "feeds-show-prev")
