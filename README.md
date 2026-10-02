<h1><img src="assets/claude-logo.svg" alt="Claude" width="40" align="absmiddle"> maki-claude</h1>

Use a Claude Pro or Max subscription in [maki](https://github.com/tontinton/maki).
The package adds a `claude` provider that logs in with the same OAuth flow as
Claude Code. A subscription token is accepted when the system prompt opens with
the Claude Code identity line as its own block, which maki sends as the
provider's system prefix; nothing else about the request has to change.

## Requirements

- A maki build with plugin providers (`maki.provider.register`), which landed
  after the 0.5.7 tag
- `openssl` on `PATH`, used once per login
- A Claude Pro or Max subscription
- Linux or macOS

## Install

Add the package in `~/.config/maki/init.lua`:

```lua
maki.pack.add({
  { src = "https://github.com/bzzimmy/maki-claude", version = "main" },
})
```

## Setup

```
maki auth login claude
```

Login opens the browser. Approve the request, copy the code the page shows,
and paste it into the terminal. maki stores the tokens in its state directory
with mode 0600 and the plugin refreshes them on its own.

Pick a model with `/model`; the catalog is under the `claude/` prefix, for
example `claude/claude-opus-5`.

- `maki auth logout claude` removes the stored tokens.
- maki's own usage display shows the subscription quota.

## Permissions

The package requests exactly what it calls: `net` for the API and the token
endpoint at `api.anthropic.com`, and `run` to call `openssl` for the login PKCE
pair.

## Development

Clone the repository and run the checks from its root. The Rust tests load
the package through the real maki Lua host and need `cargo-nextest`.

```sh
git clone https://github.com/bzzimmy/maki-claude.git
cd maki-claude
just check && just lint && just test
```
