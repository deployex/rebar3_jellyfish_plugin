# CHANGELOG (v0.1.x)

## 0.1.0 🚀 (Unreleased)

### Backwards incompatible changes
 * None (first release)

### Bug fixes
 * None

### Enhancements
 * Initial release: generates `.appup` files and a `jellyfish.json` sidecar for Erlang/rebar3 releases - the same contract [Jellyfish](https://github.com/deployex/jellyfish) writes for Elixir releases, covering single-app and umbrella projects and their production dependencies
 * [`PULL-1`](https://github.com/deployex/rebar3_jellyfish_plugin/pull/1) Hex publishing support
 * [`PULL-2`](https://github.com/deployex/rebar3_jellyfish_plugin/pull/2) Fixed the integration test under asdf setups with no global Erlang/rebar3 default, and added a `make clean` target
