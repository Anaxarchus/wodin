# wodin

A build tool for compiling [Odin](https://odin-lang.org) programs to WebAssembly. wodin parses your source files, extracts JavaScript bindings declared directly in your Odin code, and generates a ready-to-serve HTML page — no JavaScript knowledge required on the Odin side, and no Odin knowledge required on the HTML side.

## How it works

wodin walks your Odin source tree and looks for `foreign` blocks whose declarations are tagged with `@(tag = ...)` attributes. It uses Odin's own `core:odin/ast` and `core:odin/parser` packages to do this statically — no compilation needed for the scan.

From those tags it generates a JavaScript import object (`_wodin`) that the Odin WASM runtime uses to resolve your foreign function calls at load time. It then compiles your package to WASM, copies `odin.js` from your Odin installation, and injects everything into an HTML template at a marker you control.

The result is a self-contained `out/` directory you can serve anywhere.

## Installation

wodin is a single Odin source file. You can use it however is most convenient for your workflow.

**Add to PATH** — build once and use it anywhere:

```sh
odin build . -out:wodin
# move the binary somewhere on your PATH
```

**Vendor into your project** — copy `wodin.odin` into your repo and build it where you need it, no PATH changes required:

```sh
odin build wodin.odin -file -out:wodin
./wodin build myapp
```

This is handy for reproducible project setups or CI, since the tool lives alongside the code it builds.

## Usage

```
wodin <command> [directory] [flags] [-- <odin flags>]
```

### Commands

| Command | Description |
|---------|-------------|
| `build` | Compile and generate output files |
| `run`   | Build then serve locally over HTTP |
| `help`  | Print usage information |

### Flags

| Flag | Default | Description |
|------|---------|-------------|
| `-out:<dir>` | `out` | Output directory |
| `-template:<file>` | built-in | Path to a custom HTML template |
| `-port:<n>` | `8080` | Port for `wodin run` |
| `--` | | Everything after this is passed directly to `odin build` |

## Tagging your bindings

wodin recognises two tag prefixes inside `foreign` blocks.

### `wodin.function`

Declares a JavaScript function that Odin can call. The body of the function is written inline in the tag, in JavaScript:

```odin
foreign import canvas "canvas"

foreign canvas {
    @(tag = `wodin.function { return a + b }`)
    add :: proc "c" (a, b: i32) -> i32 ---

    @(tag = `wodin.function { document.getElementById("app").textContent = msg }`)
    set_text :: proc "c" (msg: i32) ---
}
```

Parameter names are taken from the Odin proc signature and forwarded to the JS arrow function automatically, so you can reference them by name in the body.

The generated JavaScript for the above looks like:

```js
var _wodin = {
  "canvas": {
    add: (a, b) => {return a + b},
    set_text: (msg) => {document.getElementById("app").textContent = msg},
  },
};
```

### `wodin.variable`

Declares a JavaScript `let` variable that your `wodin.function` bodies can close over. This is the idiomatic way to share mutable state between Odin and JS — the variable itself is not a WASM import; instead you write getter and setter functions that read and write it.

Note that Odin requires variable declarations in an anonymous `foreign` block (no import name):

```odin
foreign import canvas "canvas"

// Variables must be declared in an anonymous foreign block
foreign {
    @(tag = `wodin.variable`)
    score :: i32 ---

    @(tag = `wodin.variable = 0`)
    lives :: i32 ---
}

// Functions can then close over those variables
foreign canvas {
    @(tag = `wodin.function { return score }`)
    get_score :: proc "c" () -> i32 ---

    @(tag = `wodin.function { score = v }`)
    set_score :: proc "c" (v: i32) ---

    @(tag = `wodin.function { return lives }`)
    get_lives :: proc "c" () -> i32 ---
}
```

This generates:

```js
let score;
let lives = 0;
var _wodin = {
  "canvas": {
    get_score: () => {return score},
    set_score: (v) => {score = v},
    get_lives: () => {return lives},
  },
};
```

A foreign block containing only `wodin.variable` tags (no functions) will have its `let` declarations emitted but will not produce an entry in `_wodin`.

## HTML templates

By default wodin uses a minimal built-in template:

```html
<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <title><!-- WODIN_NAME --></title>
</head>
<body>
    <!-- WODIN_BINDINGS -->
</body>
</html>
```

You can supply your own template with `-template:<file>`. A valid template must contain the `<!-- WODIN_BINDINGS -->` marker. Everything Odin-related is injected there — the runtime script, the bindings, and the WASM bootstrap — so authors don't need to know anything about the Odin runtime.

### Injection markers

| Marker | Description |
|--------|-------------|
| `<!-- WODIN_BINDINGS -->` | Required. Replaced with `odin.js`, the bindings script, and — if `<!-- WODIN_LOADER -->` is absent — the WASM bootstrap. |
| `<!-- WODIN_LOADER -->` | Optional. When present, the WASM bootstrap is injected here instead of at `<!-- WODIN_BINDINGS -->`, letting you control loader placement independently. |
| `<!-- WODIN_NAME -->` | Optional. Replaced with the app name (the source directory's basename). Can appear any number of times. |

If only `<!-- WODIN_BINDINGS -->` is present, everything is injected there and the template needs no knowledge of wodin's internals. Adding `<!-- WODIN_LOADER -->` splits the injection so authors who need custom loader placement or want to interleave their own setup code between the bindings and the bootstrap can do so:

```html
<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <title><!-- WODIN_NAME --></title>
</head>
<body>
    <canvas id="canvas"></canvas>

    <!-- WODIN_BINDINGS -->

    <script>
        // custom setup that runs after bindings are defined
        // but before the wasm module is loaded
        _wodin["canvas"].init_canvas(document.getElementById("canvas"));
    </script>

    <!-- WODIN_LOADER -->
</body>
</html>
```

A minimal custom template using only `<!-- WODIN_BINDINGS -->`:

```html
    <link rel="stylesheet" href="style.css">
</head>
<body>
    <h1><!-- WODIN_NAME --></h1>
    <canvas id="canvas"></canvas>
    <!-- WODIN_BINDINGS -->
</body>
</html>
```

## Examples

### Basic build

```sh
wodin build myapp
```

Compiles `myapp/` to `out/myapp.wasm`, generates `out/index.html` and copies `out/odin.js`.

### Build with a custom output directory

```sh
wodin build myapp -out:dist
```

### Build and serve locally

```sh
wodin run myapp
# wodin: building myapp...
# wodin: serving on http://localhost:8080  (Ctrl-C to stop)
```

### Custom port

```sh
wodin run myapp -port:3000
```

### Custom HTML template

```sh
wodin build myapp -template:templates/index.html
```

### Passing flags through to the Odin compiler

Anything after `--` is forwarded verbatim to `odin build`:

```sh
wodin build myapp -- -debug -vet
wodin run myapp -- -o:speed -no-bounds-check
```

The fixed wodin flags (`-target:js_wasm32` and `-out:`) are always prepended; your extra flags come after.

## Output structure

```
out/
├── index.html   — generated from your template
├── odin.js      — Odin WASM runtime (copied from your Odin installation)
└── myapp.wasm   — compiled WebAssembly module
```

The `out/` directory (or whatever `-out:` points to) is deleted and recreated on every build.

## Notes

- wodin locates `odin.js` by running `odin root` and checking `vendor/wasm/js/odin.js` and `core/sys/wasm/js/odin.js`. If neither is found it falls back to the `ODIN_ROOT` environment variable.
- The built-in HTTP server (`wodin run`) is single-threaded and intended for local development only.
- WASM modules require certain HTTP headers to use `SharedArrayBuffer`. wodin's server sets `Cross-Origin-Opener-Policy: same-origin` and `Cross-Origin-Embedder-Policy: require-corp` on every response automatically.
