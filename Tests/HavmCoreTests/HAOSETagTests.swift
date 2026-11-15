import Foundation
import Testing
@testable import HavmCore

/// The value sent back in `If-None-Match`.
///
/// GitHub sends `W/"<hex>"` and answers 304 to `W/"…"` and `"…"` alike — but
/// 200 to the bare hex, which is what stripping both the weak marker and the
/// quotes used to produce. The cache then never hit and every setup spent a
/// request against the rate limit it was meant to save.
@Suite struct HAOSETagTests {

    private static let hex = "763232245d80a5e4e75a3d9f31716119d894604cb76580687d48fca70df95f60"

    @Test func dropsTheWeakMarkerAndKeepsTheQuotes() {
        #expect(HAOSETag.ifNoneMatch(fromHeader: #"W/"\#(Self.hex)""#) == #""\#(Self.hex)""#)
    }

    @Test func acceptsAStrongTag() {
        #expect(HAOSETag.ifNoneMatch(fromHeader: #""\#(Self.hex)""#) == #""\#(Self.hex)""#)
    }

    @Test func trimsSurroundingWhitespace() {
        #expect(HAOSETag.ifNoneMatch(fromHeader: "  " + #"W/"\#(Self.hex)""# + " ") == #""\#(Self.hex)""#)
    }

    /// An unquoted tag is not an entity-tag, and sending it earns a 200 — so
    /// there is nothing to gain by passing it through.
    @Test(arguments: [
        Self.hex,
        "W/" + Self.hex,
        #"W/"#,
        #"""#,
        "",
        "   ",
        nil,
    ])
    func rejectsAnythingThatIsNotAnEntityTag(header: String?) {
        #expect(HAOSETag.ifNoneMatch(fromHeader: header) == nil)
    }
}
