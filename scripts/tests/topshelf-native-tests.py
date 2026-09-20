#!/usr/bin/env python3
"""Exercise the production native Top Shelf clients without an Apple TV or account."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
swift = r'''
import Foundation

final class Stub: URLProtocol {
    static var handler: ((URLRequest) -> (Int, [String:Any]))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, object) = Self.handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: object))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
final class Requests: @unchecked Sendable {
    let lock = NSLock()
    private var paths: [String] = []
    func add(_ path: String) { lock.lock(); defer { lock.unlock() }; paths.append(path) }
    func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return paths }
}
@main struct Check {
    static func main() async throws {
        let account: [String: Any] = ["id":"saved", "serverID":"server", "requiresLogin":false]
        func allowed(_ rows: [[String:Any]], active: String = "saved", server: String = "server", pin: Bool = false) throws -> Bool {
            TopShelfProfilePolicy.allowsSavedAccountContent(accountsData:try JSONSerialization.data(withJSONObject:rows),
                activeAccountID:active, serverID:server, hasStoredPIN:{_ in pin})
        }
        let policyResults = try [allowed([account]), !allowed([]), !allowed([account,account]),
            !allowed([account],active:"other"), !allowed([account],server:"other"), !allowed([account],pin:true),
            !allowed([account.merging(["pinEnabled":true]) {_,v in v}]),
            !allowed([account.merging(["requiresLogin":true]) {_,v in v}])]
        assert(policyResults.allSatisfy { $0 })
        assert(!TopShelfProfilePolicy.allowsSavedAccountContent(accountsData:nil,activeAccountID:"saved",serverID:"server",hasStoredPIN:{_ in false}))
        assert(!TopShelfProfilePolicy.allowsSavedAccountContent(accountsData:Data("invalid".utf8),activeAccountID:"saved",serverID:"server",hasStoredPIN:{_ in false}))
        for count in 0...5 { assert(AccountLimitCheck(accounts:Array(repeating:0,count:count)).canAddAccount == (count < 4)) }
        print("PASS saved-account isolation, single/multiple profiles, PINs, corrupt data and four-profile capacity")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Stub.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let episode: [String:Any] = ["Id":"episode-version", "Type":"Episode", "Name":"Episode",
            "SeriesId":"series", "SeriesName":"Show", "ParentIndexNumber":2, "IndexNumber":3,
            "RunTimeTicks":20_000_000_000, "UserData":["PlaybackPositionTicks":5_000_000_000],
            "ImageTags":["Primary":"still"], "SeriesPrimaryImageTag":"poster"]
        for provider in [TopShelfNativeClient.Provider.emby, .jellyfin] {
            let client = TopShelfNativeClient(provider:provider, serverURL:"https://media.example.test/base",
                userID:"user-one", token:"test-token", session:session)
            let requests = Requests()
            Stub.handler = { request in
                let url = request.url!
                requests.add(url.path)
                let q = URLComponents(url:url, resolvingAgainstBaseURL:false)!.queryItems!
                assert(q.first { $0.name == "UserId" }?.value == "user-one")
                assert(q.first { $0.name == "EnableUserData" }?.value == "true")
                assert(q.first { $0.name == "Limit" }?.value == "12")
                assert(!url.absoluteString.contains("test-token"))
                assert(request.value(forHTTPHeaderField:"X-Profile-Token") == nil)
                if provider == .emby {
                    assert(url.path.hasPrefix("/base/emby/"))
                    assert(request.value(forHTTPHeaderField:"X-Emby-Token") == "test-token")
                    assert(request.value(forHTTPHeaderField:"Authorization") == nil)
                    if url.path.hasSuffix("/NextUp") { assert(q.first { $0.name == "LegacyNextUp" }?.value == "true") }
                    else { assert(q.first { $0.name == "IncludeNextUp" }?.value == "false") }
                } else {
                    assert(!url.path.contains("/emby/"))
                    assert(request.value(forHTTPHeaderField:"Authorization")?.hasPrefix("MediaBrowser ") == true)
                    assert(request.value(forHTTPHeaderField:"X-Emby-Token") == nil)
                    if url.path.hasSuffix("/NextUp") { assert(q.first { $0.name == "EnableResumable" }?.value == "false") }
                }
                return (200,["Items":[episode]])
            }
            let result = try await client.fetchHomeSections()
            assert(result.sections.map(\.sectionType) == ["continue_watching", "next_up"])
            assert(requests.snapshot().count == 2)
            let item = result.sections[0].items[0]
            assert(item.contentId == "episode-version" && item.seasonNumber == 2 && item.episodeNumber == 3)
            assert(item.positionSeconds == 500 && item.playbackProgress == 0.25)
            let artwork = URLComponents(string:item.posterUrl!)!
            assert(artwork.path.hasSuffix("/Items/series/Images/Primary"))
            assert(artwork.queryItems!.first { $0.name == "tag" }?.value == "poster")
            assert(!item.posterUrl!.contains("test-token"))
            do { _ = try client.item(["Id":"../invalid", "Name":"Bad"]); fatalError("Invalid ID accepted") }
            catch TopShelfNativeClient.Failure.invalidItem {}
            print("PASS", provider, "native routes, auth, both sections, exact episode, progress and main series poster")
        }
        let jellyfin = TopShelfNativeClient(provider:.jellyfin,serverURL:"https://media.example.test/base",userID:"user-one",token:"test-token",session:session)
        let legacyRequests = Requests()
        Stub.handler = { request in
            legacyRequests.add(request.url!.path)
            if request.url!.path == "/base/UserItems/Resume" { return (404,[:]) }
            return (200,["Items":[]])
        }
        let legacy = try await jellyfin.fetchHomeSections()
        assert(legacy.sections.allSatisfy { $0.items.isEmpty })
        assert(legacyRequests.snapshot().contains("/base/Users/user-one/Items/Resume"))
        let failedRequests = Requests()
        Stub.handler = { request in failedRequests.add(request.url!.path); return (401,[:]) }
        do { _ = try await jellyfin.fetchHomeSections(); fatalError("Unauthorised response accepted") }
        catch TopShelfNativeClient.Failure.status(let code) { assert(code == 401) }
        assert(!failedRequests.snapshot().contains { $0.contains("/Users/") })
        let emby = TopShelfNativeClient(provider:.emby,serverURL:"https://media.example.test/base/emby/",userID:"one",token:"secret")
        let embyURL = try emby.url("/Shows/NextUp",query:[:])
        assert(embyURL.path == "/base/emby/Shows/NextUp")
        print("PASS Jellyfin legacy fallback, empty sections, no auth fallback, Emby base path")
    }
}
'''
# Keep generated compilation products scoped and automatically disposable.
with tempfile.TemporaryDirectory(prefix='vivid-topshelf-') as tmp:
    tmp = Path(tmp)
    test = tmp / 'Check.swift'
    test.write_text(swift)
    policy = tmp / 'Policy.swift'
    policy.write_text((root/'iosApp/iosApp/Shared/TopShelfProfilePolicy.swift').read_text().split('    static func allowsPersonalizedContent')[0] + '}')
    capacity = tmp / 'Capacity.swift'
    account_source = (root/'iosApp/iosApp/tvOS/Profiles/TVSavedAccountStore.swift').read_text()
    capacity_method = account_source.split('    var canAddAccount: Bool {',1)[1].split('    }',1)[0]
    capacity.write_text('struct AccountLimitCheck { let accounts: [Int]\n var canAddAccount: Bool {' + capacity_method + '}\n}')
    binary = tmp / 'check'
    subprocess.run(['swiftc', '-parse-as-library', str(root/'iosApp/TopShelf/TopShelfModels.swift'),
                    str(root/'iosApp/TopShelf/TopShelfNativeClient.swift'), str(policy), str(capacity), str(test), '-o',str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
