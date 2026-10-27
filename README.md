# AvailKit Swift public client 0.1.1

SDK **0.1.1**. Standalone build and synthetic test instructions are in
[DEVELOPMENT.md](DEVELOPMENT.md). [Versioned release notes](https://github.com/availkit/sdk-swift/releases)
record dated verification and available distribution channels. Source availability
does not imply registry publication or mobile/service acceptance.
Install examples name this SDK version; check the release notes for artifact availability.

A typed Swift 6 public-booking package: page, offerings, availability, create, read,
reschedule and cancel. This is the supported native mobile path. It accepts published
page IDs and private per-booking capabilities. There is no workspace credential,
account/passkey/session/recovery API and no native login claim. Keep workspace
credentials on a trusted backend; use the hosted browser dashboard for account work.

The package declares iOS 15+/macOS 12+ Foundation support and requires Swift 6.4 tools in Swift 6 language mode.
The release verification target is Swift 6.4.x on Linux x86_64, including actual
URLSession HTTP fixtures. Apple-platform source compatibility is declared, while
device/Keychain/UI integration must be verified in the integrating app. Keep the
current Swift 6.4 patch for builds; runtime/compiler policy changes require a minor
SDK release, compatible contract/security fixes a patch. No external dependencies.

## Install from the hosted SPM source archive

The hosted ZIP has a flat `Package.swift` root. It is a conventional Swift package,
not a claim of a public Git repository, Swift Package Index entry or registry:

<!-- docs:install:start -->
```sh
curl --fail --proto '=https' -O https://availkit.dev/downloads/availkit-swift-0.1.1.zip
curl --fail --proto '=https' -O https://availkit.dev/downloads/SHA256SUMS
sha256sum --check --ignore-missing SHA256SUMS
mkdir -p Vendor/AvailKit
unzip -q availkit-swift-0.1.1.zip -d Vendor/AvailKit
```
<!-- docs:install:end -->

Add `.package(path: "Vendor/AvailKit")` to your app's `Package.swift` dependencies and
`.product(name: "AvailKit", package: "AvailKit")` to its target dependencies. In
Xcode use Add Local Package for that extracted directory. No private app repository
is needed. Future public SDK-only Git tags/ownership are covered by the publication
plan; the private application repository is never the package dependency.

```swift
import AvailKit
let client = try PublicBookingClient(pageID: "11111111111111111111111111111111")
let page = try await client.getPage()
let catalog = try await client.listOfferings(limit: 25)
// Follow nextAfter explicitly with a finite caller-controlled page budget.
```

`Sources/FirstBooking/FirstBooking.swift` is a runnable, opt-in test create/read/move/cancel
lifecycle. Create an existing 0700 private intent directory and a 0600 JSON config:

```json
{"pageID":"YOUR_PUBLISHED_TEST_PAGE_ID","offeringID":"YOUR_TEST_OFFERING_ID","from":"2026-11-02T09:00:00Z","to":"2026-11-02T17:00:00Z","displayName":"Your test contact","email":null,"phone":null,"intentDirectory":"/absolute/private/intents"}
```

<!-- docs:run:start -->
```sh
AVAILKIT_CONFIG_FILE=/absolute/private/config.json swift run --package-path Vendor/AvailKit -j 1 availkit-first-booking
```
<!-- docs:run:end -->

The executable requires a test page, chooses two available times, moves the booking and cancels
only the booking it creates. It stores the exact original intent before each write.
Every directory allows exactly one deliberate lifecycle. A permanent durable `lifecycle-started.json` latch and fixed `create.json`/`move.json`/`cancel.json` originals refuse every rerun, including after loss or successful completion. Keep them and inspect/reconcile manually; never delete a latch to invent a replacement for unknown work. It prints no customer values,
capabilities or IDs. Reads require only published page access; reading/changing an
individual booking requires its private capability. Create also needs the retained
contact-reuse proof. These authorities are distinct and never interchangeable.

## Durable intents and unknown outcomes

```swift
let bookingToken = AvailKitSecrets.newBookingToken()
let contactToken = AvailKitSecrets.newBookingToken()
let intent = try client.prepareBook(
    PublicBookingInput(offeringId: offering.id, start: slot.start,
        contact: CustomerInput(displayName: "Test contact")),
    idempotencyKey: AvailKitSecrets.newIdempotencyKey(),
    bookingToken: bookingToken, contactToken: contactToken)
let privateBytes = try intent.exportPrivate()
// Persist privateBytes in your durable encrypted app-private store BEFORE execute.
let booking = try await client.execute(intent)
```

`BookingIntent` retains exact encoded body, key, origin, page, both capabilities and
creation time. Its description is redacted. Import/export never sends. Store it in
a durable app-private encrypted store with Keychain/file protection appropriate to
your app. Never UserDefaults, logs, analytics, URLs, public backups or source control.
`savePrivate(to:)` exclusively creates and fsyncs a 0600 file in an owned 0700 directory; `loadPrivate(from:)` checks permissions/type/size and rejects symlinks. iOS files receive complete file protection. The command-line example uses these helpers; mobile
apps own secure-storage integration and should retain on every outcome.

The client sends once. `AvailKitError` contains finite kind/code/status and
`mutationOutcomeUnknown`. Transport failure, cancellation, invalid acknowledgment
or server 5xx can mean the write committed. Keep the original and freeze follow-on
mutations until deliberately reconciled. A read does not settle an unknown
acknowledgment. A create whose ID is unknown cannot be discovered from a capability;
obtain an authoritative booking ID through your support/backend process. Do not
invent a new intent/key. Only an explicit `execute(original)` can use the server's
24h original booking replay contract. Local age/scope checks cannot prove receipt
retention after privacy pruning or authority changes. No other mutation replay is
invented. Tokens must be generated before admission and retained together.

Every call has a bounded total deadline (default 10 seconds; max 120), incremental
response-size cap, cancellation through Swift Task, strict typed/schema JSON and
safe redacted errors. It uses a fresh ephemeral URLSession per request, no SDK retry
loop, no cookie/credential/cache storage or proxy configuration, rejects redirects
and HTTP authentication/body-stream renewal, and uses normal platform TLS trust.
HTTP is accepted only for loopback tests. URLSession owns platform transport-level
behavior; the package does not implement HTTP protocol retries. Cancellation never
claims that a mutation failed to commit.

## Verify/build

```sh
swift test -j 1
swift build -j 1
```

The tests need Python 3 solely for bundled loopback HTTP fixtures. They cover all 7
operations, lost-response send count and exact explicit replay, deadline/cancellation,
scope/expiry/input guards, redaction, redirects, bounded bodies and duplicate keys.
Tests perform no live account/API writes. Production authenticated acceptance and
fresh archived consumer verification are recorded separately at release.

The stream/replacement behavior follows Apple's [httpBodyStream contract](https://developer.apple.com/documentation/foundation/urlrequest/httpbodystream) and [needNewBodyStream delegate contract](https://developer.apple.com/documentation/foundation/urlsessiontaskdelegate/urlsession(_:task:neednewbodystream:)). The original stream is supplied to a data task; every replacement request receives nil. Actual wire verification is recorded for the tested Linux runtime; this is not an Apple-device test claim.


See [CHANGELOG.md](CHANGELOG.md), [SUPPORT.md](SUPPORT.md) and
[SECURITY.md](SECURITY.md) for release policy and private reporting prerequisites.
`contract-projection.json` pins only this SDK's supported wire operations;
additive unrelated API routes do not imply this SDK implements them.

The separate optional business export endpoint and current versioned browser
recovery protocol are not methods of this SDK. Use their documented browser/
TypeScript integration where appropriate; this package preserves its declared
workspace/public booking surface rather than inventing account/native APIs.
