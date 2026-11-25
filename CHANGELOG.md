# CHANGELOG (v0.1.x)

## 0.1.6 🚀 (2026-11-25)

### Backwards incompatible changes for 0.1.5
 * None

### Bug fixes
 * [`PULL-16`](https://github.com/deployex/rebar3_jellyfish_plugin/pull/16) Remove what earlier builds left before generating the appups
 * [`PULL-17`](https://github.com/deployex/rebar3_jellyfish_plugin/pull/17) Upgrade a dependency from the version the previous release shipped

## 0.1.5 🚀 (2026-11-24)

### Backwards incompatible changes for 0.1.4
 * None

### Enhancements
 * [`PULL-14`](https://github.com/deployex/rebar3_jellyfish_plugin/pull/14) Use an appup written by hand, kept in `rel/appup_overrides`, in place of the generated one

## 0.1.4 🚀 (2026-11-24)

### Backwards incompatible changes for 0.1.3
 * None

### Bug fixes
 * [`PULL-12`](https://github.com/deployex/rebar3_jellyfish_plugin/pull/12) Leave modules whose code did not change out of the appup, and generate it from a release that strips its beams

## 0.1.3 🚀 (2026-11-24)

### Backwards incompatible changes for 0.1.2
 * None

### Bug fixes
 * [`PULL-10`](https://github.com/deployex/rebar3_jellyfish_plugin/pull/10) Pick the previous version in the same order as Jellyfish

### Enhancements
 * [`PULL-9`](https://github.com/deployex/rebar3_jellyfish_plugin/pull/9) Cover a transitive dependency in the integration test

## 0.1.2 🚀 (2026-11-22)

### Backwards incompatible changes for 0.1.1
 * None

### Bug fixes
 * [`PULL-8`](https://github.com/deployex/rebar3_jellyfish_plugin/pull/8) Generate soft updates for OTP behaviours without code_change

## 0.1.1 🚀 (2026-11-21)

### Backwards incompatible changes for 0.1.0
 * None

### Bug fixes
 * [`PULL-6`](https://github.com/deployex/rebar3_jellyfish_plugin/pull/6) Check the new beam's exports for the code_change decision

### Enhancements
 * [`PULL-5`](https://github.com/deployex/rebar3_jellyfish_plugin/pull/5) Document supervisor child start/stop and NIF/brutal_purge limitations in the README's new "Known Limitations" section

# 🚀 Previous Releases
 * [0.1.0 🚀 (2026-11-19)](https://github.com/deployex/rebar3_jellyfish_plugin/blob/v0.1.0/CHANGELOG.md)
