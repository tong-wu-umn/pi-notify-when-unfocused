import Foundation

/// Minimal dependency-free test harness.
///
/// Why not XCTest: this project is built with Command Line Tools only, and CLT ships no
/// XCTest or Testing module, so `swift test` cannot link here. The harness keeps the
/// familiar shape (`expectEqual`, `unwrap`, one case per behaviour) inside a normal
/// executable so `make test` works on any Mac with CLT. If Xcode is installed later, the
/// bodies port to XCTest mechanically.
public enum TestFailure: Error, CustomStringConvertible {
    case failed(String)

    public var description: String {
        switch self {
        case let .failed(message): return message
        }
    }
}

/// Records assertion failures for the test currently running. Tests run serially, so a
/// single sink is enough; the lock keeps it honest if that ever changes.
enum TestContext {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var sink: ((String) -> Void)?

    static func install(_ newSink: ((String) -> Void)?) {
        lock.lock()
        defer { lock.unlock() }
        sink = newSink
    }

    static func fail(_ message: String) {
        lock.lock()
        let current = sink
        lock.unlock()
        current?(message)
    }
}

public func fail(_ message: String = "", file: String = #filePath, line: Int = #line) {
    TestContext.fail("\(shortPath(file)):\(line): \(message.isEmpty ? "failed" : message)")
}

public func expect(
    _ condition: Bool,
    _ message: @autoclosure () -> String = "",
    file: String = #filePath,
    line: Int = #line
) {
    if !condition {
        fail(message().isEmpty ? "expected condition to be true" : message(), file: file, line: line)
    }
}

public func expectTrue(
    _ condition: Bool,
    _ message: @autoclosure () -> String = "",
    file: String = #filePath,
    line: Int = #line
) {
    expect(condition, message().isEmpty ? "expected true" : message(), file: file, line: line)
}

public func expectFalse(
    _ condition: Bool,
    _ message: @autoclosure () -> String = "",
    file: String = #filePath,
    line: Int = #line
) {
    expect(!condition, message().isEmpty ? "expected false" : message(), file: file, line: line)
}

public func expectEqual<T: Equatable>(
    _ lhs: T,
    _ rhs: T,
    _ message: @autoclosure () -> String = "",
    file: String = #filePath,
    line: Int = #line
) {
    guard lhs == rhs else {
        let detail = message().isEmpty ? "" : " — \(message())"
        fail("expected \(lhs) == \(rhs)\(detail)", file: file, line: line)
        return
    }
}

public func expectNotEqual<T: Equatable>(
    _ lhs: T,
    _ rhs: T,
    _ message: @autoclosure () -> String = "",
    file: String = #filePath,
    line: Int = #line
) {
    guard lhs != rhs else {
        let detail = message().isEmpty ? "" : " — \(message())"
        fail("expected \(lhs) != \(rhs)\(detail)", file: file, line: line)
        return
    }
}

public func expectNil<T>(
    _ value: T?,
    _ message: @autoclosure () -> String = "",
    file: String = #filePath,
    line: Int = #line
) {
    if let value {
        let detail = message().isEmpty ? "" : " — \(message())"
        fail("expected nil, got \(value)\(detail)", file: file, line: line)
    }
}

public func expectNotNil<T>(
    _ value: T?,
    _ message: @autoclosure () -> String = "",
    file: String = #filePath,
    line: Int = #line
) {
    if value == nil {
        let detail = message().isEmpty ? "" : " — \(message())"
        fail("expected a value, got nil\(detail)", file: file, line: line)
    }
}

public func expectGreaterThanOrEqual<T: Comparable>(
    _ lhs: T,
    _ rhs: T,
    _ message: @autoclosure () -> String = "",
    file: String = #filePath,
    line: Int = #line
) {
    guard lhs >= rhs else {
        let detail = message().isEmpty ? "" : " — \(message())"
        fail("expected \(lhs) >= \(rhs)\(detail)", file: file, line: line)
        return
    }
}

/// Fails unless `body` throws; optionally inspects the error.
public func expectThrows<T>(
    _ body: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "",
    file: String = #filePath,
    line: Int = #line,
    _ check: ((Error) -> Void)? = nil
) {
    do {
        let value = try body()
        let detail = message().isEmpty ? "" : " — \(message())"
        fail("expected an error, got \(value)\(detail)", file: file, line: line)
    } catch {
        check?(error)
    }
}

/// Unwraps or throws, so a missing value stops the current test instead of crashing.
public func unwrap<T>(
    _ value: T?,
    _ message: @autoclosure () -> String = "",
    file: String = #filePath,
    line: Int = #line
) throws -> T {
    guard let value else {
        let detail = message().isEmpty ? "" : " — \(message())"
        throw TestFailure.failed("\(shortPath(file)):\(line): failed to unwrap\(detail)")
    }
    return value
}

private func shortPath(_ file: String) -> String {
    (file as NSString).lastPathComponent
}

/// Collects and runs tests, printing a compact report.
public final class TestRunner {
    public struct CaseResult {
        public let name: String
        public let failures: [String]
        public let duration: TimeInterval
    }

    private var cases: [(name: String, body: () throws -> Void)] = []
    private var results: [CaseResult] = []

    public init() {}

    public func test(_ name: String, _ body: @escaping () throws -> Void) {
        cases.append((name, body))
    }

    public var count: Int { cases.count }

    /// Runs every registered test. Returns a process exit code (0 = all green).
    @discardableResult
    public func run() -> Int {
        let started = Date()
        for testCase in cases {
            // Print before running so a hard crash still names the offending test.
            print("→ \(testCase.name)")
            fflush(stdout)
            var failures: [String] = []
            TestContext.install { failures.append($0) }
            let caseStarted = Date()
            do {
                try testCase.body()
            } catch {
                failures.append("threw: \(error)")
            }
            TestContext.install(nil)
            results.append(CaseResult(
                name: testCase.name,
                failures: failures,
                duration: Date().timeIntervalSince(caseStarted)
            ))
        }

        let failed = results.filter { !$0.failures.isEmpty }
        for result in results where !result.failures.isEmpty {
            print("✗ \(result.name)")
            for failure in result.failures {
                print("    \(failure)")
            }
        }
        for result in results where result.failures.isEmpty {
            print("✓ \(result.name)")
        }
        let elapsed = String(format: "%.2fs", Date().timeIntervalSince(started))
        print("")
        print("\(results.count - failed.count)/\(results.count) passed in \(elapsed)")
        if !failed.isEmpty {
            print("\(failed.count) failing: \(failed.map(\.name).joined(separator: ", "))")
        }
        return failed.isEmpty ? 0 : 1
    }
}

