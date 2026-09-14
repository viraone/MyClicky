# Peeky Code extensions

Extensions add languages, code themes, formatters, linters and reusable
**actions** to Peeky Code without touching the app. An extension is a folder
with a `manifest.json` plus the shell / AppleScript / JavaScript-for-Automation
scripts it points at — no native code, no build step. Peeky loads them at
launch and whenever you press ↻ on the **Extensions** tab.

```
~/Library/Application Support/MyClicky/Extensions/
└── hello-peeky/
    ├── manifest.json
    └── scripts/
        └── hello.sh
```

Install by dropping a folder on the Extensions tab, pasting a git URL into
**Install from git URL…**, or clicking **Install** on a marketplace entry.
The folder is renamed to the manifest `id`. Uninstall moves it to the Trash;
disabled extensions stay on disk but contribute nothing.

A working example lives in `examples/extensions/hello-peeky/`.

## manifest.json

```json
{
  "id": "hello-peeky",
  "name": "Hello Peeky",
  "version": "1.0.0",
  "description": "A minimal example extension.",
  "author": "you",
  "homepage": "https://github.com/you/hello-peeky",
  "apiVersion": 1,
  "contributes": {
    "languages":  [],
    "themes":     [],
    "formatters": [],
    "linters":    [],
    "actions":    []
  }
}
```

| Field | Required | Notes |
|---|---|---|
| `id` | yes | Letters, digits, `.`, `-`, `_` (max 64). Must be unique among installed extensions. |
| `name`, `version` | yes | Version is `x.y.z`; the marketplace compares it to offer **Update**. |
| `apiVersion` | no | Defaults to `1`, the only version this build supports; higher values are refused. |
| `description`, `author`, `homepage` | no | Shown in the Extensions tab. |
| `contributes` | yes | Any subset of the five sections below. Every referenced script path must exist inside the folder; regexes and colours are validated at load. |

### Languages

```json
{
  "id": "mylang",
  "name": "MyLang",
  "extensions": ["ml2", "mylang"],
  "base": "swift",
  "keywords": ["let", "var", "fn"],
  "control": ["if", "when", "else"],
  "lineComment": ";;",
  "blockComment": ["(*", "*)"],
  "rules": [
    { "pattern": "@[a-z_]+", "token": "variable" },
    { "pattern": "\\b(TODO|FIXME)\\b", "token": "keyword", "caseInsensitive": true }
  ]
}
```

- `extensions` — file extensions (no dot) this grammar owns. Listing an
  extension a built-in already handles overrides the built-in.
- `base` — optional built-in grammar applied first: `javascript`, `swift`,
  `python`, `css`, `html`, `json`, `shell`, `markdown`.
- `keywords`, `control`, `lineComment`, `blockComment` — generate the common
  rules for you (strings and numbers are always included).
- `rules` — extra regexes (NSRegularExpression syntax; `^`/`$` match per
  line) applied after the generated ones. `token` is one of `plain`,
  `comment`, `string`, `number`, `keyword`, `control`, `function`, `type`,
  `variable`, `tag`, `attribute`, `selector`, `punctuation`; `group`
  colours only that capture group.

### Themes

```json
{
  "id": "solar-dusk",
  "name": "Solar Dusk",
  "colors": {
    "background": "#1B1E24", "plain": "#E6E6E6",
    "keyword": "#C586C0", "control": "#C586C0", "type": "#4EC9B0",
    "function": "#DCDCAA", "variable": "#9CDCFE", "string": "#CE9178",
    "number": "#B5CEA8", "comment": "#6A9955", "punctuation": "#D4D4D4"
  }
}
```

Keys are the token names above plus `background`; values are `#RRGGBB` or
`#RRGGBBAA`. Missing keys fall back to the built-in Dark Modern palette. Pick
the active theme on the Extensions tab → **Code theme**; the choice persists
(`extensionsThemeID`) and the code viewer repaints live.

### Formatters

```json
{
  "id": "prettier",
  "name": "Prettier",
  "extensions": ["ts", "tsx", "js", "json", "md"],
  "command": "prettier",
  "args": ["--stdin-filepath", "${file}"],
  "stdin": true,
  "timeout": 20
}
```

`stdin: true` (default) pipes the buffer to the process and replaces it with
stdout; `stdin: false` runs the command against the file on disk and reloads
it. `command` is resolved on `PATH` plus the usual Homebrew and npm bin
folders. The **Format** button in the Code tab picks the first enabled
formatter whose `extensions` matches the open file.

### Linters

```json
{
  "id": "eslint",
  "name": "ESLint",
  "extensions": ["ts", "tsx", "js"],
  "command": "eslint",
  "args": ["--format", "unix", "${file}"],
  "pattern": "^[^:]+:(?<line>\\d+):(?<col>\\d+): (?<message>.*?) \\[(?<severity>Error|Warning)",
  "stdin": false,
  "timeout": 30
}
```

`pattern` is applied line-by-line to the output with the named groups `line`
(required), `col`, `severity` (`error`/`e`/`fatal` → error, `info`/`note`/
`hint` → info, anything else → warning) and `message`. A non-zero exit that
yields findings is normal; it's only an error when nothing parses and stderr
is non-empty. Findings show as underlines in the code viewer and a count in
the tools row under the file.

Placeholders in `args`: `${file}` (full path), `${name}` (file name), `${dir}`
(file's folder), `${project}`, `${ext}`. Scripts also get `PEEKY_FILE`,
`PEEKY_PROJECT` and `PEEKY_EXTENSION_DIR` in the environment.

### Actions

```json
{
  "verb": "deploy_preview",
  "description": "Push the current branch and open its preview URL.",
  "note": "Deploying preview…",
  "runner": "shell",
  "script": "scripts/deploy.sh",
  "irreversible": false,
  "timeout": 120,
  "params": [
    { "name": "branch", "description": "Branch to deploy (defaults to current)", "required": false }
  ],
  "example": "{\"verb\":\"deploy_preview\",\"params\":{\"branch\":\"main\"}}"
}
```

- `verb` — snake_case identifier. Built-in Peeky Actions verbs always win on a
  collision; between extensions the first loaded (alphabetical folder) wins.
- `runner` — `shell` (default, `/bin/zsh script`), `applescript`
  (`osascript script`), or `javascript` (`osascript -l JavaScript script`).
- `irreversible: true` makes Peeky ask for confirmation before running, even
  when the planner didn't flag the step.
- `note` is the progress line shown while it runs; `example` is a complete
  JSON step shown to the model verbatim.
- `params` arrive as positional args (`$1 $2 …`, manifest order), as
  `PEEKY_PARAM_<NAME>` variables, and as a JSON object on stdin.

Actions run from three places:

1. **Extensions tab** → ▶ next to the action, with fields for its params.
2. **Peeky Actions** (TALK / "do it"): every enabled action is offered to the
   planner as a verb with its description, so "deploy a preview of this
   branch" can plan `deploy_preview`.
3. **Peeky Remote**: `EXT deploy_preview\tbranch=main` (params tab-separated
   `key=value`). The Mac replies `EXT_STATUS OK\t<last stdout line>` or
   `EXT_STATUS FAIL\t<reason>`.

Environment for action scripts:

| Variable | Meaning |
|---|---|
| `PEEKY_EXTENSION_ID`, `PEEKY_EXTENSION_DIR` | Which extension, and its folder |
| `PEEKY_VERB` | The action verb being run |
| `PEEKY_PROJECT` | The folder dropped on Peeky Code (also the cwd), if any |
| `PEEKY_FILE` | The file open in the Code tab, if any |
| `PEEKY_FRONT_APP`, `PEEKY_FRONT_BUNDLE` | Frontmost app name and bundle id |
| `PEEKY_COPIED` | Text Peeky last copied for you, if any |
| `PEEKY_PARAM_<NAME>` | One per declared param |

The last stdout line is the result toast; on non-zero exit the first line of
stderr (or stdout) is the failure reason.

## Marketplace catalog

The Extensions tab fetches
`https://raw.githubusercontent.com/viraone/peeky-extensions/main/catalog.json`
(override with `defaults write com.local.MyClicky extensionsCatalogURL <url>`).

```json
{
  "catalogVersion": 1,
  "extensions": [
    {
      "id": "hello-peeky",
      "name": "Hello Peeky",
      "version": "1.0.0",
      "description": "A minimal example extension.",
      "author": "viraone",
      "repo": "https://github.com/viraone/hello-peeky.git",
      "ref": "v1.0.0",
      "homepage": "https://github.com/viraone/hello-peeky",
      "tags": ["example"]
    }
  ]
}
```

Each entry is one git repository whose root is the extension folder.
**Install** runs `git clone --depth 1 [--branch <ref>] <repo>` into a
temporary folder, validates its manifest, and moves it under the Extensions
folder as `<id>`. **Update** appears when the catalog version is newer than
the installed one. Search matches id, name, description, author and tags.
