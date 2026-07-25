# Full prompt draft

This is a human-editable design specimen, not a runtime prompt resource.
Rewrite the first-person prose here freely. Once the wording feels right, move
each stable fragment into its corresponding file under
`Sources/CompletionCore/Resources/Prompts/`.

## Context currently available

| Context | Runtime status | Source |
| --- | --- | --- |
| Current application | Live, on by default | Frontmost macOS application |
| Current website | Not connected yet | Planned browser context |
| Input kind | Live, on by default | AX role, subrole, placeholder, title, and description |
| Snapshot text / OCR | Live, off by default | Focused app window through ScreenCaptureKit and local Vision OCR |
| Clipboard | Live, off by default | Current text clipboard contents |
| Input history | Not connected yet, off by default | Planned encrypted local history retrieval |
| Voice assessment | Not connected yet, off by default | Planned local periodic assessment |
| Custom voice | Live | Prompt Lab setting |
| Text before and after cursor | Live | Focused editor through Accessibility |
| Shipped seed examples | Live fallback | Bundled Markdown examples; replaced by real history |

## Full base-model sample

```text
I am typing the text at the end on my Mac. Additional context; some of it could be irrelevant:

I'm writing a comment on youtube.com in Safari.

Text visible on screen around where I am typing:

Alex: This shortcut stopped working after the latest macOS update. Has anyone found a fix?

Robin: Removing the old Accessibility entry and adding the newly signed app fixed it for me.

Clipboard contents:

The app needs a stable signing identity so macOS can preserve Accessibility consent between builds.

Recent examples of my writing:

My writing:
yeah, deleting the stale permission entry fixed it for me too

My writing:
I think the signature changed between those two builds.

What I have noticed about my writing:

I usually write concise, conversational replies. I use lowercase for casual messages, contractions, direct questions, and technical terminology when it is relevant.

My writing style:

Keep this friendly and direct. Avoid sounding like an assistant or explaining more than the conversation needs.

My writing:
oh nice, I didn't realise
```

## Seed fallback shape

When no real writing history is available, the `Recent examples of my writing`
section above is replaced by the individually editable files in
`Resources/Prompts/Seed/Examples`. Its composed shape is:

```text
Some examples of my writing:

My writing:
yo what's up with you?

My writing:
hey, are you around later?

My writing:
yeah that makes sense to me

…

My writing:
<LIVE TEXT BEFORE THE CURSOR>
```

For a mid-line completion, the final section instead contains the text before
the cursor, the text after it, and the current trailing part being completed.
