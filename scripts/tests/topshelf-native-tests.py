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
        let other: [String: Any] = ["id":"other", "serverID":"elsewhere", "requiresLogin":true, "pinEnabled":true]
        func saved(_ rows: [[String:Any]], active: String? = "saved", server: String = "server", pin: Bool = false) -> TopShelfAccess.Refusal? {
            TopShelfAccess.savedProfileRefusal(accountsData:try! JSONSerialization.data(withJSONObject:rows),
                activeAccountID:active, serverID:server, hasStoredPIN:{_ in pin})
        }
        assert(saved([account]) == nil)
        // Other saved profiles don't matter, whatever state they're in.
        assert(saved([other, account, account.merging(["id":"third"]) {_,v in v}]) == nil)
        assert(saved([account.merging(["name":"ignored", "extra":["nested":1]]) {_,v in v}]) == nil)
        assert(saved([]) == .savedProfileMissing)
        assert(saved([account], active:"missing") == .savedProfileMissing)
        assert(saved([account], active:nil) == .savedProfileMissing)
        assert(saved([account], server:"other") == .savedProfileMissing)
        assert(saved([account.merging(["requiresLogin":true]) {_,v in v}]) == .savedProfileSignedOut)
        assert(saved([account], pin:true) == .savedProfileLocked)
        assert(saved([account.merging(["pinEnabled":true]) {_,v in v}]) == .savedProfileLocked)
        assert(saved([account.merging(["pinEnabled":false]) {_,v in v}]) == nil)
        for data in [nil, Data("invalid".utf8)] {
            assert(TopShelfAccess.savedProfileRefusal(accountsData:data, activeAccountID:"saved", serverID:"server",
                hasStoredPIN:{_ in false}) == .savedProfileMissing)
        }

        let records = try JSONSerialization.data(withJSONObject:["server":
            ["accountEpoch":"epoch", "profileIDs":["one","two","three"], "lockedProfileIDs":["two"]]])
        func viewing(_ data: Data?, server: String = "server", profile: String = "one", epoch: String? = "epoch") -> TopShelfAccess.Refusal? {
            TopShelfAccess.viewingProfileRefusal(recordsData:data, serverID:server, profileID:profile, accountEpoch:epoch)
        }
        // Any number of viewing profiles is fine, as long as this one has no PIN.
        assert(viewing(records) == nil && viewing(records, profile:"three") == nil)
        assert(viewing(records, profile:"two") == .viewingProfileLocked)
        assert(viewing(records, profile:"unknown") == .viewingProfilesUnknown)
        assert(viewing(records, server:"other") == .viewingProfilesUnknown)
        assert(viewing(records, epoch:"newer") == .viewingProfilesUnknown)
        assert(viewing(records, epoch:nil) == .viewingProfilesUnknown)
        assert(viewing(nil) == .viewingProfilesUnknown)
        assert(viewing(Data("invalid".utf8)) == .viewingProfilesUnknown)
        // Emby and Jellyfin have no Silo viewing profiles to check.
        assert(TopShelfAccess.isNativeServer("emby:one") && TopShelfAccess.isNativeServer("jellyfin:one"))
        assert(!TopShelfAccess.isNativeServer("server"))
        assert(viewing(nil, server:"emby:one", epoch:nil) == nil && viewing(nil, server:"jellyfin:one", epoch:nil) == nil)
        for count in 0...9 { assert(AccountLimitCheck(accounts:Array(repeating:0,count:count)).canAddAccount == (count < 8)) }
        print("PASS saved profiles (several allowed, missing, other server, signed out, PINs, corrupt data), viewing profiles and eight-profile capacity")
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
            let feed = try await client.fetchHomeSections()
            assert(feed.resume.count == 1 && feed.upNext.count == 1)
            assert(requests.snapshot().count == 2)
            let entry = feed.resume[0]
            assert(entry.id == "episode-version" && entry.kind == .episode && entry.title == "Episode")
            assert(entry.seriesID == "series" && entry.seriesTitle == "Show" && entry.season == 2 && entry.episode == 3)
            assert(entry.progress == 0.25)
            assert(feed.upNext[0] == entry)
            let artwork = URLComponents(url:entry.poster!, resolvingAgainstBaseURL:false)!
            assert(artwork.path.hasSuffix("/Items/series/Images/Primary"))
            assert(artwork.queryItems!.first { $0.name == "tag" }?.value == "poster")
            assert(!entry.poster!.absoluteString.contains("test-token"))
            do { _ = try client.item(["Id":"../invalid", "Name":"Bad"]); fatalError("Invalid ID accepted") }
            catch TopShelfNativeClient.Failure.invalidItem {}
            print("PASS", provider, "native routes, auth, both rows, exact episode, progress and main series poster")
        }
        let jellyfin = TopShelfNativeClient(provider:.jellyfin,serverURL:"https://media.example.test/base",userID:"user-one",token:"test-token",session:session)
        let legacyRequests = Requests()
        Stub.handler = { request in
            legacyRequests.add(request.url!.path)
            if request.url!.path == "/base/UserItems/Resume" { return (404,[:]) }
            return (200,["Items":[]])
        }
        let legacy = try await jellyfin.fetchHomeSections()
        assert(legacy.isEmpty)
        assert(legacyRequests.snapshot().contains("/base/Users/user-one/Items/Resume"))
        let failedRequests = Requests()
        Stub.handler = { request in failedRequests.add(request.url!.path); return (401,[:]) }
        do { _ = try await jellyfin.fetchHomeSections(); fatalError("Unauthorised response accepted") }
        catch TopShelfNativeClient.Failure.status(let code) { assert(code == 401) }
        assert(!failedRequests.snapshot().contains { $0.contains("/Users/") })
        // A film keeps its own poster, and rows keep the server's order, including entries never played.
        func film(_ id: String, watched: String?) -> [String:Any] {
            var data: [String:Any] = ["PlaybackPositionTicks":30_000_000_000]
            if let watched { data["LastPlayedDate"] = watched }
            return ["Id":id, "Type":"Movie", "Name":id, "RunTimeTicks":20_000_000_000, "UserData":data, "ImageTags":["Primary":"own"]]
        }
        Stub.handler = { _ in (200,["Items":[film("never",watched:nil), film("older",watched:"2026-01-01T00:00:00Z"),
            film("newer",watched:"2026-02-01T00:00:00Z"), film("never-too",watched:nil), ["Id":"trailer", "Type":"Trailer", "Name":"Trailer"]]]) }
        let films = try await jellyfin.fetchHomeSections().resume
        assert(films.map(\.id) == ["never", "older", "newer", "never-too", "trailer"])
        assert(films[2].kind == .movie && films[2].progress == 1 && films[4].kind == .other && films[4].progress == nil)
        assert(films[2].poster!.path.hasSuffix("/Items/newer/Images/Primary") && films[2].poster!.query!.contains("tag=own"))
        assert(ShelfEntry.progress(positionSeconds:10, durationSeconds:0) == nil && ShelfEntry.progress(positionSeconds:nil, durationSeconds:10) == nil)
        let emby = TopShelfNativeClient(provider:.emby,serverURL:"https://media.example.test/base/emby/",userID:"one",token:"secret")
        let embyURL = try emby.url("/Shows/NextUp",query:[:])
        assert(embyURL.path == "/base/emby/Shows/NextUp")
        print("PASS Jellyfin legacy fallback, empty rows, no auth fallback, server order, Emby base path")
    }
}
'''
# Keep generated compilation products scoped and automatically disposable.
with tempfile.TemporaryDirectory(prefix='vivid-topshelf-') as tmp:
    tmp = Path(tmp)
    test = tmp / 'Check.swift'
    test.write_text(swift)
    capacity = tmp / 'Capacity.swift'
    account_source = (root/'iosApp/iosApp/tvOS/Profiles/TVSavedAccountStore.swift').read_text()
    capacity_method = account_source.split('    var canAddAccount: Bool {',1)[1].split('    }',1)[0]
    capacity_limit = account_source.split('    static let maximumAccounts = ',1)[1].split('\n',1)[0]
    capacity.write_text('struct AccountLimitCheck { let accounts: [Int]\n static let maximumAccounts = ' + capacity_limit
                        + '\n var canAddAccount: Bool {' + capacity_method + '}\n}')
    binary = tmp / 'check'
    subprocess.run(['swiftc', '-parse-as-library', str(root/'iosApp/TopShelf/ShelfFeed.swift'),
                    str(root/'iosApp/TopShelf/TopShelfNativeClient.swift'),
                    str(root/'iosApp/iosApp/Shared/TopShelfAccess.swift'), str(capacity), str(test), '-o',str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
