import XCTest
import Foundation
@testable import Vivid

final class DetailVersionSelectionTests: XCTestCase {

    func testSourceColorRangeIsNotAppliedToTranscodedOutput() {
        XCTAssertTrue(PlaybackDeliveryStrategy.direct.preservesSourceVideoMetadata)
        XCTAssertTrue(PlaybackDeliveryStrategy.remux.preservesSourceVideoMetadata)
        XCTAssertFalse(PlaybackDeliveryStrategy.transcode.preservesSourceVideoMetadata)
    }

    private func decodedVersions(_ json: String) -> [FileVersion] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try! decoder.decode([FileVersion].self, from: Data(json.utf8))
    }

    func testFileVersionDecodesServerEditionFields() {
        let versions = decodedVersions("""
        [
          {
            "file_id": 10,
            "edition_raw": "Final Cut",
            "edition_key": "final_cut",
            "edition": "Legacy Cut",
            "resolution": "4K"
          }
        ]
        """)

        let version = versions[0]

        XCTAssertTrue(version.editionRaw == "Final Cut")
        XCTAssertTrue(version.editionKey == "final_cut")
        XCTAssertTrue(version.edition == "Legacy Cut")
        XCTAssertTrue(version.editionDisplayLabel == "Final Cut")
    }

    func testFileVersionDecodesIntroAndCreditsMarkers() {
        let json = """
        {
          "file_id": 42,
          "file_name": "Episode.mkv",
          "intro": { "start": 12.5, "end": 74.25 },
          "credits": { "start": 1440.0, "end": 1500.0 }
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let version = try! decoder.decode(FileVersion.self, from: Data(json.utf8))

        XCTAssertTrue(version.fileId == 42)
        XCTAssertTrue(version.intro?.start == 12.5)
        XCTAssertTrue(version.intro?.end == 74.25)
        XCTAssertTrue(version.credits?.start == 1440.0)
        XCTAssertTrue(version.credits?.end == 1500.0)
    }

    func testLibrariesResponseDecodesBareArray() {
        let json = """
        [
          { "id": 1, "name": "Movies", "type": "movies" },
          { "id": 10, "name": "Series", "type": "series" }
        ]
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let response = try! decoder.decode(LibrariesResponse.self, from: Data(json.utf8))

        XCTAssertTrue(response.libraries.count == 2)
        XCTAssertTrue(response.libraries[1].isSeriesLibrary)
    }
}
