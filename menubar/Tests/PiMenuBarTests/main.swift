import Foundation

// Entry point for `make test` / `swift run PiMenuBarTests`.
//
// Test targets need XCTest, which Command Line Tools does not ship, so the suite runs as
// a plain executable instead. Every group must be registered here.
let runner = TestRunner()
registerNdjsonFramerTests(runner)
registerUnixSocketTests(runner)
registerHerdrSocketDiscoveryTests(runner)
registerHerdrProtocolTests(runner)
registerRegistryReaderTests(runner)
registerAttentionRulesTests(runner)
registerAcknowledgementStoreTests(runner)
registerSessionMergerTests(runner)
registerTitleFormatterTests(runner)
registerConfigTests(runner)
registerNotificationPolicyTests(runner)
registerNotificationContentTests(runner)
registerNotificationRouteStoreTests(runner)
registerFocusPolicyTests(runner)
exit(Int32(runner.run()))
