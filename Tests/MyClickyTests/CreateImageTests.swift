import XCTest
@testable import MyClicky

@MainActor
final class CreateImageTests: XCTestCase {
    // MARK: Slugs and file names

    func testSlugFoldsQuotesAndPunctuation() {
        XCTAssertEqual(CreateImageModel.slug(from: "A “quoted” picture!"), "a-quoted-picture")
        XCTAssertEqual(CreateImageModel.slug(from: "  Hello,   WORLD!!  "), "hello-world")
        XCTAssertEqual(CreateImageModel.slug(from: "cat's toy"), "cat-s-toy")
    }

    func testSlugDropsEmoji() {
        XCTAssertEqual(CreateImageModel.slug(from: "a 🌈 cat 🐈"), "a-cat")
        XCTAssertEqual(CreateImageModel.slug(from: "🌅🌅"), "image")
    }

    func testSlugUsesOnlyTheFirstSixWords() {
        let description = "one two three four five six seven eight nine ten"
        XCTAssertEqual(CreateImageModel.slug(from: description), "one-two-three-four-five-six")
    }

    func testSlugIsAtMostFortyCharacters() {
        let longWord = String(repeating: "a", count: 60)
        let slug = CreateImageModel.slug(from: longWord)
        XCTAssertEqual(slug.count, 40)
        XCTAssertEqual(slug, String(repeating: "a", count: 40))

        let longSentence = String(repeating: "wordy ", count: 20)
        XCTAssertLessThanOrEqual(CreateImageModel.slug(from: longSentence).count, 40)
    }

    func testEmptyDescriptionBecomesImage() {
        XCTAssertEqual(CreateImageModel.slug(from: ""), "image")
        XCTAssertEqual(CreateImageModel.slug(from: "   \n\t "), "image")
        XCTAssertEqual(CreateImageModel.slug(from: "!!! ??? ..."), "image")
    }

    func testSlugHasNoIllegalCharacters() {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        for description in ["A “quoted” picture!", "a 🌈 cat 🐈", "  ", "cat's toy"] {
            let slug = CreateImageModel.slug(from: description)
            XCTAssertTrue(slug.unicodeScalars.allSatisfy { allowed.contains($0) },
                          "\(slug) contains an unexpected character")
        }
    }

    func testFileNameIsTimestampThenSlug() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let name = CreateImageModel.fileBaseName(for: "A “quoted” picture!", at: date)
        XCTAssertTrue(name.hasSuffix(" a-quoted-picture"))
        let stamp = String(name.dropLast(" a-quoted-picture".count))
        XCTAssertNotNil(stamp.range(of: #"^\d{4}-\d{2}-\d{2} \d{2}\.\d{2}\.\d{2}$"#,
                                   options: .regularExpression),
                        "\(stamp) isn't a yyyy-MM-dd HH.mm.ss stamp")
    }

    func testEmptyDescriptionStillGetsAFileName() {
        let name = CreateImageModel.fileBaseName(for: "   ", at: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(name.hasSuffix(" image"))
    }

    // MARK: Progress

    func testProgressTakesTheLastStepInAChunk() {
        let chunk = " 22%|██▏       | 2/9 [00:01<00:04,  1.80it/s]\r"
            + " 44%|████▍     | 4/9 [00:03<00:04,  1.10it/s]\r"
        let progress = CreateImageModel.parseProgress(chunk)
        XCTAssertEqual(progress?.step, 4)
        XCTAssertEqual(progress?.total, 9)
        XCTAssertEqual(progress?.downloading, false)
    }

    func testFetchingLinesHaveNoProgressButCountAsDownloading() {
        XCTAssertNil(CreateImageModel.parseProgress("Fetching 17 files"))
        XCTAssertTrue(CreateImageModel.isDownloading("Fetching 17 files"))
        XCTAssertTrue(CreateImageModel.isDownloading("Downloading model.safetensors"))
        XCTAssertFalse(CreateImageModel.isDownloading(" 44%|████▍     | 4/9 [00:03<00:04,  1.10it/s]"))
    }

    func testProgressInADownloadChunkIsFlagged() {
        let chunk = "Fetching 17 files: 100%|██████| 17/17\r"
            + " 44%|████▍     | 4/9 [00:03<00:04,  1.10it/s]\r"
        let progress = CreateImageModel.parseProgress(chunk)
        XCTAssertEqual(progress?.step, 4)
        XCTAssertEqual(progress?.total, 9)
        XCTAssertEqual(progress?.downloading, true)
    }

    func testProgressRejectsLinesWithoutAFraction() {
        XCTAssertNil(CreateImageModel.parseProgress(""))
        XCTAssertNil(CreateImageModel.parseProgress("Loading model…"))
        XCTAssertNil(CreateImageModel.parseProgress(" 44%|████▍     | [00:03<00:04,  1.10it/s]"))
    }

    // MARK: Sizes

    func testSizePresets() {
        XCTAssertEqual(CreateImageModel.Size.allCases.count, 3)
        XCTAssertEqual(CreateImageModel.Size.square.width, 1024)
        XCTAssertEqual(CreateImageModel.Size.square.height, 1024)
        XCTAssertEqual(CreateImageModel.Size.wide.width, 1344)
        XCTAssertEqual(CreateImageModel.Size.wide.height, 768)
        XCTAssertEqual(CreateImageModel.Size.tall.width, 768)
        XCTAssertEqual(CreateImageModel.Size.tall.height, 1344)
    }
}
