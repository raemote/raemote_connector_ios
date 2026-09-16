import Testing
import Foundation
@testable import Raemote_Connector

@MainActor
struct WebViewStateTests {
    @Test func downloadBannerTracksTheFileBeingSaved() {
        let state = WebViewState()
        #expect(state.downloadingFileName == nil)

        state.downloadStarted(named: "video.mp4")
        #expect(state.downloadingFileName == "video.mp4")

        state.downloadFinished()
        #expect(state.downloadingFileName == nil)
    }

    @Test func overlappingDownloadsKeepTheBannerUp() {
        let state = WebViewState()
        state.downloadStarted(named: "first.zip")
        state.downloadStarted(named: "second.zip")
        #expect(state.downloadingFileName == "second.zip")

        // The first one finishing must not hide that another is still running.
        state.downloadFinished()
        #expect(state.downloadingFileName == "second.zip")

        state.downloadFinished()
        #expect(state.downloadingFileName == nil)
    }

    @Test func theCountNeverGoesNegative() {
        let state = WebViewState()
        state.downloadFinished()
        #expect(state.downloadingFileName == nil)
        state.downloadStarted(named: "a")
        state.downloadFinished()
        state.downloadFinished()
        #expect(state.downloadingFileName == nil)
    }
}
