import PalConnect
import Testing

@Suite("Connect app status")
struct ConnectAppStatusTests {
    @Test(arguments: [
        (ConnectAppState.connected, ConnectAppStatus.connected, "Connected"),
        (.needsAuthorization, .needsSignIn, "Needs sign-in"),
        (.disconnected, .notConnected, "Not connected"),
    ])
    func eachAppStateReadsAsOneStatus(state: ConnectAppState, status: ConnectAppStatus, title: String) {
        #expect(ConnectAppStatus(state) == status)
        #expect(ConnectAppStatus(state).title == title)
    }
}
