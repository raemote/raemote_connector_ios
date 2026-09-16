import Testing
import Foundation
@testable import Raemote_Connector

struct WebNavigationErrorTests {
    private func error(_ domain: String, _ code: Int) -> NSError {
        NSError(domain: domain, code: code, userInfo: nil)
    }

    @Test func aDownloadedFileIsNotALoadFailure() {
        // Handing a link to WKDownload interrupts the frame load on purpose.
        #expect(WebNavigationError.isBenign(error("WebKitErrorDomain", 102)))
        #expect(WebNavigationError.isBenign(error("WKErrorDomain", 102)))
    }

    @Test func cancellationsAreBenign() {
        #expect(WebNavigationError.isBenign(error(NSURLErrorDomain, NSURLErrorCancelled)))
    }

    @Test func realFailuresStillSurface() {
        #expect(!WebNavigationError.isBenign(error(NSURLErrorDomain, NSURLErrorCannotFindHost)))
        #expect(!WebNavigationError.isBenign(error(NSURLErrorDomain, NSURLErrorTimedOut)))
        #expect(!WebNavigationError.isBenign(error("WebKitErrorDomain", 101)))
        #expect(!WebNavigationError.isBenign(error("WKErrorDomain", 1)))
    }
}
