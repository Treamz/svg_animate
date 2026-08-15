# Contributing

## Working on the package

```sh
flutter pub get
flutter test
flutter analyze --fatal-infos
dart format .
```

CI runs exactly those, plus a publish dry run, the pub.dev score, and a build of
the example, on every push and pull request. The example is worth building even
for a change that seems internal: it is the only check that exercises the
package from the outside, as a dependency of an app, rather than from its own
tests.

Tests live alongside what they cover. `test/animation/` holds the parsing and
sampling, which is where most of the behaviour is and where a bug is cheapest to
pin down; `test/animated_svg_test.dart` drives the widget.

## Releasing

Releases are driven by a git tag, so that whatever reaches pub.dev is a commit
that exists in the history under a name. Nothing is published from a laptop, and
no pub.dev credentials live in this repository.

### Cutting a release

1. Decide the version. The package follows [semantic
   versioning](https://dart.dev/tools/pub/versioning): a breaking change to
   anything exported from `lib/svg_animate.dart` needs a major bump, or a minor
   one while the package is below `1.0.0`.

2. Bump `version:` in `pubspec.yaml` and add the matching section to
   `CHANGELOG.md`. The heading has to read exactly `## 0.3.1` — the release
   refuses to run otherwise, because a version that reaches pub.dev with nothing
   written about it cannot be fixed afterwards.

3. Commit and push to `main`, and let CI go green.

4. Tag that commit and push the tag:

   ```sh
   git tag v0.3.1
   git push origin v0.3.1
   ```

   The tag must be `v` followed by the version, which is the pattern pub.dev is
   configured to trust.

Pushing the tag starts the `Publish` workflow. It re-runs formatting, analysis
and the tests against the tagged commit, checks that the tag agrees with the
pubspec and that the CHANGELOG has a section for the version, and only then
publishes.

### When a release fails

| what happened | what to do |
|---|---|
| `verify` failed | Nothing was published. Fix it on `main`, then `git tag -d v0.3.1 && git push origin :v0.3.1` and tag again. |
| Publishing failed after `verify` passed | Run the `Publish` workflow again from the Actions tab, picking the tag in the ref dropdown. The tag does not need to be moved or reissued. |
| The version is on pub.dev and is wrong | It cannot be removed. It can be **retracted** within seven days, from **Admin → Retract package version** on the package page, which stops new dependants resolving to it without breaking those that already did. Then release a fixed version. |

A version number is spent the moment it is published, even if the publish is a
mistake, so the checks above exist to make the mistakes that are cheap to make
also cheap to catch.

### How publishing is allowed to happen

pub.dev is configured, under **Admin → Automated publishing** on the package
page, to trust tags matching `v{{version}}` pushed to `Treamz/svg_animate`. The
workflow asks GitHub for a short-lived OIDC token for that run and exchanges it
for the right to publish, so there is no long-lived credential to store, leak or
rotate.

The publishing job names a `pub.dev` GitHub environment. Adding a required
reviewer to that environment, under **Settings → Environments**, makes every
release wait for a second pair of eyes; pub.dev can be told to insist on the
environment too.
