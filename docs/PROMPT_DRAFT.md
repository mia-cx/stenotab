# Full prompt draft

This is a human-editable design specimen, not a runtime prompt resource.
Rewrite the first-person prose here freely. Once the wording feels right, move
each stable fragment into its corresponding file under
`Sources/CompletionCore/Resources/Prompts/`.

The canonical runtime fragments live in `Prompts/Base/` and are filename-
prefixed in composition order (`00`, `01`, `01a`, …, `10d`). Files sharing a
number are alternatives or subparts of the same composed section. The only
separate Chat resource is `Chat/00-system-instruction.md`; chat providers use
the same canonical user prompt as local base models.

## Context currently available

| Context | Runtime status | Source |
| --- | --- | --- |
| Current application | Live, on by default | Frontmost macOS application |
| Current website | Not connected yet | Planned browser context |
| Input kind | Live, on by default | AX role, subrole, placeholder, title, and description |
| Snapshot text / OCR | Live, off by default | Focused app window through ScreenCaptureKit and local Vision OCR |
| Clipboard | Live, off by default | Current text clipboard contents |
| Frecent input history | Live, on by default | Encrypted accepted and directly typed examples |
| Semantically relevant history | Live, off by default | Apple Natural Language embeddings stored encrypted |
| Voice assessment | Live, off by default | Periodic local deterministic assessment |
| Custom personalization | Live | Prompt Lab setting |
| Text before and after cursor | Live | Focused editor through Accessibility |
| Shipped seed examples | Live fallback | Bundled Markdown examples; replaced by real history |

## Full base-model sample

```text
I am typing the text at the end of this document on my computer.

Some additional context that may or may not be relevant to my writing:

I am writing a comment on youtube.com in Safari.

I have recently written text like:

Text:
§yeah, deleting the stale permission entry
Insertion:
§ fixed it for me too

Text:
§I think the signature changed
Insertion:
§ between those two builds.

Other relevant examples of my writing are:

Text:
§yeah, re-adding the signed build fixed
Insertion:
§ Accessibility permissions here too

I have noticed that my writing typically looks like this:

I usually write concise, conversational replies. I use lowercase for casual messages, contractions, direct questions, and technical terminology when it is relevant.

I describe myself like this:

My name is Mia. I usually type in English or Dutch. I keep my writing short and direct.

I am not an assistant and won't explain more than what the conversation requires.

Some text that is visible on the screen around where I am typing:

Alex: This shortcut stopped working after the latest macOS update. Has anyone found a fix?

Robin: Removing the old Accessibility entry and adding the newly signed app fixed it for me.

I have this saved to my clipboard:

The app needs a stable signing identity so macOS can preserve Accessibility consent between builds.

From this point forward I will only write real text.

My writing:
§oh nice, I didn't realise
```

## Decomposed prompt

Static first instruction:

```md
I am typing the text at the end of this document on my computer.
```

### Focused app context

```md
Some additional context that may or may not be relevant to my writing:

I am <activity /> [on <website />] in <app />
<!-- Example: I am writing a comment on youtube.com in Google Chrome -->
<!-- Example: I am writing a message in Discord -->
<!-- Example: I am writing a document in Microsoft Word -->
```

### Statically frecent examples

```md
I have recently written text like:

Text:
§<example.input frecency-order=0 />
Insertion:
§<example.insertion frecency-order=0 />

Text:
§<example.input frecency-order=1 />
Insertion:
§<example.insertion frecency-order=1 />

<!-- Up to five paired records. -->
```

### Semantically relevant examples

```md
Other relevant examples of my writing are:

Text:
§<example.input embedding-proximity=0 />
Insertion:
§<example.insertion embedding-proximity=0 />

Text:
§<example.input embedding-proximity=1 />
Insertion:
§<example.insertion embedding-proximity=1 />

<!-- Up to five paired records. -->
```

### Periodic automatic re-assessment

```md
I have noticed that my writing typically looks like this:

<assessment>
<!-- Example: I usually write concise, conversational replies. I use lowercase for casual messages, contractions, direct questions, and technical terminology when it is relevant. -->
```

### Custom personalisation

```md
I describe myself like this:

<custom>
<!-- Example: My name is Mia. I usually type in English or Dutch. I write in a friendly, professional and empathetic voice. I keep my writing short, concise, to the point, and value readability and skimmability. I talk about a lot of technical concepts and will use jargon. -->
```

### Static perspective fix

```md
I am not an assistant and won't explain more than what the conversation requires.
```

### OCR

```md
Some text that is visible on the screen around where I am typing:

<ocr-content>
```

### Clipboard

```md
I have this saved to my clipboard:

<clipboard>
```

### Final prompt

```md
From this point forward I will only write real text.

My writing:
§<input>
```

## Seed fallback shape

When no real writing history is available, the `Frecent examples`
section above is replaced by the individually editable files in
`Resources/Prompts/Seed/Examples`. Its composed shape is:

```text
Some examples of my writing:

§yo what's up with you?

§hey, are you around later?

§yeah that makes sense to me

…

My writing:
§<LIVE TEXT BEFORE THE CURSOR>
```

For a mid-line completion, the final section instead contains the text before
the cursor, the text after it, and the current trailing part being completed.
