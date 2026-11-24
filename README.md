# rebar3_jellyfish_plugin

> Simplifying Hot-Upgrades for Erlang Applications

`rebar3_jellyfish_plugin` is a rebar3 plugin that generates appup files for hot-upgrades in Erlang applications, single-app or umbrella, without requiring an Elixir toolchain.
It's a native-Erlang counterpart to [Jellyfish](https://github.com/deployex/jellyfish): the same beam-diffing and topological-sort approach, reimplemented in Erlang, producing the same `jellyfish.json` sidecar file alongside each generated `.appup`.
That shared contract lets tools like [DeployEx](https://github.com/deployex/deployex) recognize and validate hot-upgrade packages the same way regardless of whether the release was built with `mix` or `rebar3`.

## What are Appup Files?

Appup files describe how to upgrade and downgrade an application from one version to another.
They contain:

 * The application name
 * Instructions to upgrade to a newer version
 * Instructions to downgrade to the original version

For detailed information about the appup format, see the [Erlang appup manual](https://www.erlang.org/doc/man/appup.html).

## Important Upgrade Ordering

When upgrading processes, order matters:

 * Processes are suspended during upgrades
 * In-flight requests are handled by the old version until the upgrade completes
 * Dependencies are upgraded before their dependents (e.g. if `proc_a` depends on `proc_b`, `proc_b` is upgraded first)
 * The plugin automatically performs topological sorting when generating appups

## Installation

Add the plugin to `rebar.config`, hook it after `compile`, and add one static overlay rule to the project's `relx` config:

```erlang
{project_plugins, [
    {rebar3_jellyfish_plugin, "0.1.0"}
]}.

{provider_hooks, [
    {post, [{compile, {jellyfish, appup}}]}
]}.

{relx, [
    {release, {my_app, "0.1.0"}, [my_app]},
    ...,
    {overlay, [{copy, "rel/appups/lib", "lib"}]}
]}.
```

Once a previous version is found on disk, every subsequent `rebar3 release`, `rebar3 tar` or `rebar3 relup` generates the appup file right after compiling and copies it into the release.

The hook runs on `compile` rather than on `release`/`tar` directly, for two reasons:

 * `rebar3 tar` assembles its release internally without ever dispatching through the `release` provider, so a `{post, [{release, ...}]}` hook never fires for it.
 * Writing files straight into an already-assembled release's `lib/` directory doesn't survive a second `rebar3 tar`, since it also re-assembles from scratch and overwrites that directory.

Hooking `compile` and delivering the generated files through a static `overlay` rule - rather than writing them into the release tree directly - is what actually survives both commands, since relx applies overlays as one of the last steps of assembling a release no matter which top-level command triggered that assembly.
The overlay rule is written once and never needs to change between releases: the plugin always stages files under the versioned path the overlay already points at.

### Hot-Upgrading Dependencies (Optional)

The plugin generates appup files for both your application code and your dependencies, so third-party libraries can be upgraded at runtime alongside your own code changes.
Only dependencies that are part of the current profile (and therefore the release) are considered - there's no separate configuration for this, it follows rebar3's own profile system.
That includes the dependencies your own dependencies bring in: `systools:make_relup/4` needs an appup for every application whose version changes, so a library the project never declares still gets one when an update moves it.

> [!WARNING]
> Not all code changes are safe for hot-upgrades.
> Before performing a hot-upgrade, check whether the dependency supports hot-upgrades between versions, review the changelog for structural changes (e.g. process state modifications, API changes), and check stateful processes like `gen_server`s that may require special handling.
> You can do this analysis yourself, or ask an LLM-based coding assistant to review the diff and changelog between the two versions and flag anything that looks unsafe for a hot-upgrade - but either way, someone should look before you ship it.

### Which previous version is used

An appup upgrades from one previous version, the highest one found in the release directory that an earlier build left on disk, other than the version being built.
"Highest" follows the same order as Jellyfish, so both tools pick the same one:

 * The numeric parts decide first, as numbers: `0.10.0` is higher than `0.9.0`. Any number of parts is accepted, and `1.2` is the same as `1.2.0`.
 * A pre-release is lower than its release, `1.0.0-rc1` below `1.0.0`, and pre-releases are ordered as [Semantic Versioning](https://semver.org/#spec-item-11) says.
 * Build metadata, `1.0.0+abc`, is ignored.
 * A `git describe` version, `1.0.0-4-gabc1234`, is higher than `1.0.0`, and more commits is higher.
 * A version that is none of these is lower than every one that is.

> [!NOTE]
> A build identifier after the version, such as `0.1.0-9cad9cd`, is ordered as text.
> Two builds of the same version are therefore not ordered by when they were built.
> When versions are named this way, keep a single previous version in the release directory: build the version that is deployed, then the new one.

## Appup file

If for any reason you need to change the order of the modules or add new instructions to the generated appup file, set the `EDIT_APPUP` environment variable before building the release:

```bash
EDIT_APPUP=true rebar3 tar
```

The build will pause right after generating each appup, with its path printed, so you can edit it before it's copied into the release.
Since the hook runs on every `compile`, only set `EDIT_APPUP` for the specific command that builds the release you're about to edit - leaving it set would pause every ordinary `rebar3 compile` or `rebar3 eunit` run too, not just packaging ones.

## Relup file

The plugin focuses on generating appup files and copying them into the release.
It doesn't create relup files directly.
The relup file is typically created during a hot upgrade with the [DeployEx](https://github.com/deployex/deployex) application.

## The jellyfish.json file

Alongside every `.appup` file, the plugin writes a `jellyfish.json` file into the same `ebin` directory.
This is the signal a tool like DeployEx should check before trusting an `.appup` file, rather than the mere presence of the `.appup` itself - a dependency can legitimately ship its own `.appup` for unrelated reasons, and treating that as a hot-upgrade instruction would be a mistake.

It contains:

```json
{
  "name": "my_app",
  "type": "project",
  "from": "0.1.0",
  "to": "0.1.1",
  "format_version": 1,
  "generator": "rebar3_jellyfish_plugin/0.1.0"
}
```

See [Jellyfish's own documentation of this format](https://github.com/deployex/jellyfish#the-jellyfishjson-file) for the full field reference - it's the same contract, shared by both tools.

## Erlang Umbrella applications

Umbrella (multi-app) rebar3 projects work the same way as single-app ones: the plugin processes every app returned by `rebar3`'s own project-apps discovery, so no extra umbrella-specific configuration is needed.
Unlike Elixir umbrella apps, rebar3 apps already each carry their own independent version, so there's no equivalent of Jellyfish's shared-version-file recommendation to follow here.

## Known Limitations

### Supervisor child changes

When a supervisor module changes, the plugin always emits the generic `{update, Module, supervisor}` instruction.
This instruction lets the release handler pick up changes to an existing child's spec, such as its start function or restart type, but only once that child restarts for some other reason - a running child keeps its old spec until then.
Per the [Erlang appup cookbook](https://www.erlang.org/doc/system/appup_cookbook.html), a new child specification is added automatically, but the matching child process is not started, and a removed child's process is not stopped.
So if a release adds or removes a supervisor's child, the generated appup alone will not start or stop that process.
The upgrade will look successful while quietly leaving a new worker un-started, or a removed one still running.
Use `EDIT_APPUP=true rebar3 tar` to add the missing `{apply, {supervisor, start_child, [...]}}`, `{apply, {supervisor, terminate_child, [...]}}`, or `{apply, {supervisor, delete_child, [...]}}` instructions by hand whenever a release changes a supervisor's children, not just its properties.

### NIFs and non-OTP processes

The instructions this plugin generates use the short appup forms, such as `{load_module, Module}` and `{update, Module, {advanced, Extra}}`.
Per the [appup file format reference](https://www.erlang.org/doc/apps/sasl/appup.html), these short forms default to `brutal_purge` for both the pre-purge and post-purge steps.
`brutal_purge` kills any process still executing old code at purge time instead of waiting for it to finish.
That's safe for a `gen_server`, `gen_statem`, or supervisor, since the standard upgrade protocol suspends and resumes those processes around the code swap, so none of them are still running old code by the time the purge happens.
It's not safe for a process that doesn't go through that suspend/resume protocol, such as a plain `spawn_link` loop or a process blocked inside a NIF call, since that process can still be executing old code when the purge runs and gets killed outright.
If a release touches a NIF-loaded module or a hand-rolled, non-OTP process, review whether `brutal_purge` is appropriate before shipping the upgrade, and use `EDIT_APPUP=true rebar3 tar` to switch the relevant instruction to `soft_purge` if it isn't.

## Development

`make help` lists the available developer targets (compiling, the unit test suite, xref, the integration test, and a `check` target that runs all of them - see the [Makefile](Makefile)).

### Releasing

Published to [Hex](https://hex.pm/packages/rebar3_jellyfish_plugin) via [rebar3_hex](https://github.com/erlef/rebar3_hex).
`make release` runs `make check` and then `rebar3 hex cut`, which bumps the version, commits, tags, pushes, and publishes the package (and its docs) interactively - review its prompts and the file manifest it shows before confirming.
Publishing requires a Hex account authenticated once per machine via `rebar3 hex user auth`.

> [!IMPORTANT]
> `rebar3_hex` >= 7.3.0 requires **rebar3 >= 3.27.1** - it added native Hex auth support that calls into a module only that rebar3 version and later provide. An older rebar3 fails with `{undef, [{rebar_hex_auth, client_id, [], []}, ...]}` when running `rebar3 hex user auth`/`cut`/`publish`. Check with `rebar3 --version` and upgrade (`asdf install rebar <version>` or equivalent) if needed.

## Copyright and License

Copyright (c) 2026, Thiago Esteves.

`rebar3_jellyfish_plugin` source code is licensed under the [MIT License](LICENSE.md).
