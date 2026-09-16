import Testing
import Foundation
import UIKit
@testable import Raemote_Connector

struct QRCodeImageTests {
    @Test func rendersAPairingLink() {
        let image = QRCodeImage.make(from: "raemote://bind?node=abc&token=def&exp=1")
        #expect(image != nil)
        #expect((image?.size.width ?? 0) > 0)
        #expect((image?.size.height ?? 0) > 0)
    }

    @Test func scaleChangesTheSize() {
        let small = QRCodeImage.make(from: "hello", scale: 2)
        let large = QRCodeImage.make(from: "hello", scale: 8)
        #expect((large?.size.width ?? 0) > (small?.size.width ?? 0))
    }
}
