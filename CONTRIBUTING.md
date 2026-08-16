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

A pull request that touches `lib/` also has to say so in `CHANGELOG.md`, under a
`## Unreleased` heading at the top of the file — see [Releasing](#releasing) for
why the heading rather than a version number. Work with nothing in it for a user
to read, such as a refactor or a test, gets past that check with the `skip
changelog` label.

Tests live alongside what they cover. `test/animation/` holds the parsing and
sampling, which is where most of the behaviour is and where a bug is cheapest to
pin down; `test/animated_svg_test.dart` drives the widget.

## Releasing

Releases are driven by a git tag, so that whatever reaches pub.dev is a commit
that exists in the history under a name. Nothing is published from a laptop, and
no pub.dev credentials live in this repository.

### Why a pull request never names a version

Nothing outside a release touches `version:` in `pubspec.yaml`. A pull request
writes what it did under `## Unreleased` at the top of `CHANGELOG.md`, and the
release gives those notes their number once it knows what it is.

This is not tidiness. A branch that picks its version when it opens is picking
one it cannot know is still free when it lands: release something else from
`main` in the meantime and the branch's number is quietly spent, while every
check keeps passing, because the pubspec and the CHANGELOG go on agreeing with
each other. The entry then reaches pub.dev filed under a version that does not
contain it, and a published section cannot be edited afterwards. Leaving the
number to the release removes the guess rather than checking it.

### Cutting a release

1. Run the **Release** workflow from the Actions tab, choosing `patch`, `minor`
   or `major`. The package follows [semantic
   versioning](https://dart.dev/tools/pub/versioning), under which a breaking
   change to anything exported from `lib/svg_animate.dart` takes `major` — or
   `minor` while the package is below `1.0.0`, where that is what a breaking
   change is spelled.

   It works out the next version, renames `## Unreleased` to it, bumps the
   pubspec and opens a pull request with those two edits and nothing else. It
   refuses to run if there is no `## Unreleased` section, or if the version it
   arrived at is somehow already on pub.dev.

2. Read the new section as someone who will only ever see this version through
   it, then merge. There is nothing else in the pull request to review, and no
   CI on it: a run opened with the workflow's own token cannot start another
   workflow, and the `Publish` run below covers the same ground against the same
   commit.

3. Tag the merge commit and push the tag:

   ```sh
   git switch main && git pull
   git tag v0.3.3
   git push origin v0.3.3
   ```

   The tag must be `v` followed by the version, which is the pattern pub.dev is
   configured to trust. This step is deliberately left to a person: it is the
   one action in the process that cannot be taken back.

Pushing the tag starts the `Publish` workflow. It re-runs formatting, analysis
and the tests against the tagged commit, checks that the tag agrees with the
pubspec, that the CHANGELOG has a section for the version, and that the version
is still free on pub.dev, and only then publishes.

### When a release fails

| what happened | what to do |
|---|---|
| `Release` said there was nothing to release | No pull request since the last release wrote under `## Unreleased`. If something should have, add the section and say what changed. |
| `verify` failed | Nothing was published. Fix it on `main`, then `git tag -d v0.3.3 && git push origin :v0.3.3` and tag again. |
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
