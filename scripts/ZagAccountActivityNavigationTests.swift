import Foundation

@main struct AccountActivityTests {
    static func main() {
        var count = 0
        func check(_ value: Bool, _ label: String) {
            precondition(value, label)
            count += 1
            print("PASS: \(label)")
        }
        var handoff = ZagAccountActivityHandoff()
        var host = ActivityHost()
        check(handoff.takeAfterDismissal() == nil && ZagStoreRouter.pendingRoute == nil, "closing Account alone does not navigate")
        handoff.request()
        check(ZagStoreRouter.pendingRoute == nil, "Activity request does not navigate under the presented popup")
        handoff.request()
        let route = handoff.takeAfterDismissal()
        check(route == .activity && handoff.takeAfterDismissal() == nil, "dismissal yields Activity exactly once, including multiple taps")
        _ = ZagStoreRouter.open(route!.url)
        host.route(route!)
        check(host.selectedTab.wrappedValue == .activity && host.linkedTab == nil && host.creations == 0, "avatar Activity reuses the dock Activity page")
        check(ZagStoreRouter.pendingRoute == nil, "dock consumes Activity route")
        for _ in 0..<3 {
            handoff.request()
            let route = handoff.takeAfterDismissal()!
            _ = ZagStoreRouter.open(route.url)
            host.route(route)
        }
        check(host.selectedTab.wrappedValue == .activity && host.creations == 0, "repeated avatar Activity while already selected creates no duplicate page")
        check(handoff.takeAfterDismissal() == nil, "ordinary dismissal after navigation cannot replay a stale request")

        ZagDockConfiguration.tabs = [.discover, .sources, .library, .games, .settings]
        host = ActivityHost()
        handoff.request()
        let hidden = handoff.takeAfterDismissal()!
        _ = ZagStoreRouter.open(hidden.url)
        host.route(hidden)
        check(host.linkedTab == .activity && host.selectedTab.wrappedValue == .library && host.creations == 1, "Activity absent from five-tab dock opens existing hidden destination without changing selection")
        // The root sheet's existing onAppear consumes a newly presented tab root.
        ZagStoreRouter.consume(hidden)
        handoff.request()
        let repeated = handoff.takeAfterDismissal()!
        _ = ZagStoreRouter.open(repeated.url)
        host.route(repeated)
        check(host.creations == 1 && host.linkedTab == .activity, "repeated hidden Activity reuses existing destination")
        check(ZagStoreRouter.pendingRoute == nil, "already-visible hidden Activity consumes route without another onAppear")
        check(ZagDockConfiguration.tabs == [.discover, .sources, .library, .games, .settings], "customized dock remains unchanged")

        ZagDockConfiguration.tabs = [.discover, .sources, .library, .games, .activity]
        host = ActivityHost()
        _ = ZagStoreRouter.open(ZagStoreRoute.activity.url)
        host.route(.activity)
        check(host.selectedTab.wrappedValue == .activity && host.linkedTab == nil, "normal dock Activity route still works independently of Account")
        print("SUCCESS: \(count) account Activity navigation checks passed")
    }
}
