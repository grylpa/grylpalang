# Building a sentence bank

A **sentence bank** is a plain-text `.yaml` (or `.yml`) file listing sentences,
grouped into subjects. The app translates each sentence into your target
language on the fly and plays it back. You can also load a simple `.txt` file
(one sentence per line) — but YAML gives you subjects and the extras below.

The quickest start: **⋮ → "Email starter template"** sends you a ready-to-edit
file. Edit it, then **⋮ → "Load file from device"**.

---

## The basic shape

```yaml
language: English      # the language your sentences are written in

subjects:
  Greetings:
    sentences:
      - Hello, how are you?
      - Good morning!
  At the cafe:
    sentences:
      - Could I have the bill?
```

- **`language`** — the source language of your sentences.
- **`subjects`** — a named group is either a **leaf** (has `sentences:`) or a
  **meta** (has `includes:` — see below).
- Indentation matters (two spaces per level). Everything after `#` is a comment.

---

## Meta subjects (groups)

A **meta** subject bundles several leaf subjects so they play together. Under
`includes:` it lists subject **names**, not sentences. Nesting is one level deep
— a meta can't contain another meta.

```yaml
subjects:
  Everyday basics:
    includes:
      - Greetings
      - At the cafe
```

---

## Sentence extras

These optional markers go inside a source sentence:

| Marker | Meaning | Example |
|---|---|---|
| `N,` at the start | Play this sentence **N times** (emphasis) | `3, I am tired.` |
| `( … )` | On-screen **hint** — shown, never spoken/translated | `Could I have the bill (the check)?` |
| `a/b` | **Alternatives** — the first is spoken/translated, both are shown | `I'll have tea/coffee.` |
| `[[ … ]]` | The **focus word** for the fill-in-the-blank display | `The [[waiter]] is here.` |

**Slash abbreviations** such as `A/C`, `w/o`, `c/o`, `24/7`, `km/h` and `TCP/IP`
are recognised and spoken whole — they are *not* treated as `a/b` alternatives.

---

## Tips

- **Study only some sentences?** In the subject picker, expand a subject and
  un-check the ones you've mastered — they stop playing but stay there to
  restore later.
- **Drill a subject more?** Long-press it in the picker to set its importance
  (2–5×).
- **Optional playback defaults** can be set at the top of the file:
  `auto_source_pause`, `tts_repeat_count`, `tts_repeat_delay`,
  `auto_post_tts_delay` (all in seconds / counts). The in-app Settings can
  override them per device.

---

## Loading it

1. **From your device:** ⋮ → **Load file from device** → pick your `.yml`.
   Re-loading a file with the same name replaces the previous version.
2. **From a URL:** host the file somewhere public (a GitHub Gist "raw" link,
   Dropbox direct link, …) and set ⋮ → **Sentence bank URL**.
