maki-claude puts a Claude subscription behind a maki plugin provider. It loads
through the maki pack system, not as a builtin. One file does the work:

- `plugin/maki_claude.lua`: one `maki.provider.register` call with `auth`,
  `list_models`, `login` and `logout` hooks. It uses the `anthropic` codec, so
  the wire format is maki's. `list_models` reads the models the subscription
  serves from `/v1/models` and, like Claude Code, offers a model with a 1M
  window only under its `-1m` id, which makes maki send the long context beta. It declares the Claude Code identity line as
  the system prefix; that is the only thing the subscription token requires of
  a request, verified against Opus, Sonnet, and Fable with flat maki tool names
  and no extra headers.

Login is the Claude Code OAuth flow with the hosted callback page: the browser
shows a code and the user pastes it. A Lua hook cannot listen on a port, so
there is no loopback callback. maki stores the tokens through
`maki.provider.auth`. Keep the plugin to the provider: no commands, no files of
its own.

## Code guidelines

- No trivial comments, minimal bloat, no unnecessary state.
- Constants at the top of the file.
- Hooks fail the way maki expects: anything the user should read returns
  `nil, maki.provider.http_error(...)`, so it shows as its message alone and
  maki retries a 429 or 5xx. Never use 401, whose message maki replaces with
  its own. Raise only for bugs, which maki reports as a broken hook with a
  stack trace. `login` prints the user's mistakes with `ctx.print`.
- `plugin.toml` grants exactly what the Lua calls, and `net_hosts` lists every
  host it reaches. Keep it aligned by hand.

## Testing

Cheapest first:

- `just check` runs `cargo check --tests`.
- `just lint`
- `just test` needs `cargo-nextest`.

The Rust tests load the package through `PluginHost::load_package`, passing the
repo root, with the grants `plugin.toml` asks for. The provider registry and
the environment are global, so each test needs a process of its own, which
nextest gives it. The test points `HOME` and the XDG variables at a temporary
directory before creating the host. Assert effects maki sees: the registered
provider, what the `auth` hook resolves from stored credentials, and the
error it gives without them. `login` needs a browser and a terminal, so check it by hand.

Dev-dependencies pin a revision of maki. Move the pin when the host changes
what the plugin uses.

## Layout

- `plugin/`: the Lua entry file.
- `plugin.toml`: `min_maki_version` and the `[permissions]` request.
- `tests/plugin.rs`: host harness.
- `justfile`: check, lint, test, fmt-lua.

## Docs

The README is the canonical home for install and usage. Follow the maki docs
voice: plain words, no em-dashes, no contractions, state facts once.
