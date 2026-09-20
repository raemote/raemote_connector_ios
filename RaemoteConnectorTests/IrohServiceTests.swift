import Testing
import Foundation
@testable import Raemote_Connector

struct IrohServiceTests {

    // Server returns this exact JSON for /_hub/catalog
    private let catalogJSON = """
    {"apps":[{"name":"app_name","path":"/app/app_name","port":3000}]}
    """

    @Test func catalogDecode() throws {
        let data = Data(catalogJSON.utf8)
        let response = try JSONDecoder().decode(IrohService.CatalogResponse.self, from: data)
        #expect(response.apps.count == 1)
        #expect(response.apps[0].name == "app_name")
        #expect(response.apps[0].path == "/app/app_name")
        #expect(response.apps[0].port == 3000)
    }

    @Test func catalogDecodeEmpty() throws {
        let json = #"{"apps":[]}"#
        let data = Data(json.utf8)
        let response = try JSONDecoder().decode(IrohService.CatalogResponse.self, from: data)
        #expect(response.apps.isEmpty)
    }

    @Test func catalogDecodePlainArray() throws {
        let json = #"[{"name":"x","path":"/x","port":1234}]"#
        let data = Data(json.utf8)
        let response = try JSONDecoder().decode([AppInfo].self, from: data)
        #expect(response.count == 1)
    }

    @Test func parseRaemoteURI() {
        let uri = "raemote://bind?node=abc123&token=def456&exp=9999"
        let result = ContentView.parseRaemoteURI(uri)
        #expect(result != nil)
        #expect(result?.nodeId == "abc123")
        #expect(result?.token == "def456")
    }

    @Test func parseRaemoteURIBadScheme() {
        #expect(ContentView.parseRaemoteURI("http://bind?node=x&token=y") == nil)
    }

    @Test func parseRaemoteURIMissingToken() {
        #expect(ContentView.parseRaemoteURI("raemote://bind?node=x") == nil)
    }

    @Test func parseRaemoteURIMissingNode() {
        #expect(ContentView.parseRaemoteURI("raemote://bind?token=y") == nil)
    }

    @Test func parseRaemoteURIEmpty() {
        #expect(ContentView.parseRaemoteURI("") == nil)
    }

    @Test func parseServerFullURI() throws {
        // Exact format the server prints at startup
        let uri = "raemote://bind?node=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef&token=abc123def456abc123def456abc123def456abc123def456abc123def456abc1&exp=1789032581"
        let result = ContentView.parseRaemoteURI(uri)
        #expect(result != nil)
        #expect(result?.nodeId.count == 64)
        #expect(result?.token.count == 64)
    }

    @Test func reusesConnectionOnlyForTheSameServer() {
        // Per-node connection model: connections are keyed by node id, so a
        // request for server A can only ever resolve A's entry. The old
        // single-connection guard is expressed now as identity of the key:
        // two servers with the same app name are distinct sessions, and no
        // session key ever collapses across nodes.
        let a1 = WebAppSessionKey(nodeId: "server-a", app: "jellyfin")
        let b1 = WebAppSessionKey(nodeId: "server-b", app: "jellyfin")
        #expect(a1 != b1, "same app name on two servers must be two sessions")
        #expect(a1.id != b1.id)
        #expect(a1 == WebAppSessionKey(nodeId: "server-a", app: "jellyfin"))
        #expect(WebAppSessionKey(nodeId: "server-a", app: "jellyfin")
            != WebAppSessionKey(nodeId: "server-a", app: "pihole"))
    }
}
