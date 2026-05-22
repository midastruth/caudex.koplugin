local H         = require("spec.helpers")
local Highlight = require("caudex.highlight")

H.section("C. caudex/highlight.lua")

local ht, ctx

-- Plain string input
ht, ctx = Highlight.extract("hello world")
H.eq("string input: highlighted_text", ht,  "hello world")
H.eq("string input: context_text",     ctx, "hello world")

-- Empty string
ht, ctx = Highlight.extract("")
H.eq("empty string: highlighted_text", ht,  "")
H.eq("empty string: context_text",     ctx, "")

-- Table with .text field
ht, ctx = Highlight.extract({ text = "serendipity" })
H.eq("table.text: highlighted_text", ht, "serendipity")

-- Table with selected_text.text
ht, ctx = Highlight.extract({ selected_text = { text = "fortune" } })
H.eq("selected_text.text: highlighted_text", ht, "fortune")

-- Context extraction: selected_text.context provides context_text
ht, ctx = Highlight.extract({
  selected_text = {
    text    = "the word",
    context = "surrounding context for the word here",
  },
})
H.eq("context field: highlighted_text", ht,  "the word")
H.eq("context field: context_text",     ctx, "surrounding context for the word here")

-- Context extraction via snippet field
ht, ctx = Highlight.extract({
  selected_text = {
    text    = "snippet_word",
    snippet = "snippet context block",
  },
})
H.eq("snippet field: context_text", ctx, "snippet context block")

-- before/selection/after concatenation (no .text, no .context)
ht, ctx = Highlight.extract({
  before    = "before",
  selection = "TARGET",
  after     = "after",
})
-- .text is absent, so extract_string falls through to before/selection/after
-- But Highlight.extract uses selected_text = source.selected_text or source,
-- and highlighted_text = selected.text (nil), so ht = "" trimmed.
-- context_text comes from candidates starting at selected.context (nil),
-- then paragraph/sentence/snippet/… (all nil), so context falls back to ht="".
H.eq("no .text, no context candidates: ht is empty", ht, "")

-- Nested selected_text with before/selection/after but no .text
ht, ctx = Highlight.extract({
  selected_text = {
    before    = "Lead ",
    selection = "WORD",
    after     = " tail",
  },
})
-- selected.text = nil → highlighted_text = ""
-- candidates: context, paragraph, sentence, snippet, … all nil
-- context_text falls back to highlighted_text = ""
H.eq("nested before/selection/after, no .text: ht empty", ht, "")

-- Trimming: whitespace around text
ht, ctx = Highlight.extract({ text = "  trim me  " })
H.eq("trims whitespace from highlighted_text", ht, "trim me")

-- nil input
ht, ctx = Highlight.extract(nil)
H.eq("nil input: highlighted_text", ht, "")
H.eq("nil input: context_text",     ctx, "")
