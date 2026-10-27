import ImageIO
import UniformTypeIdentifiers
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
        XCTAssertEqual(CreateImageModel.Size.allCases.count, 5)
        XCTAssertEqual(CreateImageModel.Size.square.width, 1024)
        XCTAssertEqual(CreateImageModel.Size.square.height, 1024)
        XCTAssertEqual(CreateImageModel.Size.wide.width, 1344)
        XCTAssertEqual(CreateImageModel.Size.wide.height, 768)
        XCTAssertEqual(CreateImageModel.Size.tall.width, 768)
        XCTAssertEqual(CreateImageModel.Size.tall.height, 1344)
    }

    func testSquareStaysTheDefaultAndOldRawValuesStillLoad() {
        XCTAssertEqual(CreateImageModel.Size(rawValue: "square"), .square)
        XCTAssertEqual(CreateImageModel.Size(rawValue: "wide"), .wide)
        XCTAssertEqual(CreateImageModel.Size(rawValue: "tall"), .tall)
        XCTAssertNil(CreateImageModel.Size(rawValue: "something-else"))
        // A remembered value from before Instagram sizes existed must load.
        XCTAssertEqual(CreateImageModel.Size(rawValue: "tall") ?? .square, .tall)
        XCTAssertEqual(CreateImageModel.Size(rawValue: "nonsense") ?? .square, .square)
    }

    func testInstagramPresetsDrawAtMultiplesOfSixteenAndTrimToFinalSize() {
        let post = CreateImageModel.Size.instagramPost
        XCTAssertEqual(post.drawSize.width, 1088)
        XCTAssertEqual(post.drawSize.height, 1360)
        XCTAssertEqual(post.finalSize?.width, 1080)
        XCTAssertEqual(post.finalSize?.height, 1350)

        let story = CreateImageModel.Size.instagramStory
        XCTAssertEqual(story.drawSize.width, 1088)
        XCTAssertEqual(story.drawSize.height, 1920)
        XCTAssertEqual(story.finalSize?.width, 1080)
        XCTAssertEqual(story.finalSize?.height, 1920)

        for plain in [CreateImageModel.Size.square, .wide, .tall] {
            XCTAssertNil(plain.finalSize)
            XCTAssertEqual(plain.drawSize.width % 16, 0)
            XCTAssertEqual(plain.drawSize.height % 16, 0)
        }
    }

    func testInstagramCropRectsAreCentred() {
        XCTAssertEqual(
            CreateImageModel.cropRect(
                drawn: CreateImageModel.PixelSize(width: 1088, height: 1360),
                final: CreateImageModel.PixelSize(width: 1080, height: 1350)
            ),
            CGRect(x: 4, y: 5, width: 1080, height: 1350)
        )
        XCTAssertEqual(
            CreateImageModel.cropRect(
                drawn: CreateImageModel.PixelSize(width: 1088, height: 1920),
                final: CreateImageModel.PixelSize(width: 1080, height: 1920)
            ),
            CGRect(x: 4, y: 0, width: 1080, height: 1920)
        )
    }

    func testNoCropWhenTheDrawnSizeIsAlreadyFinalOrTooSmall() {
        XCTAssertNil(CreateImageModel.cropRect(
            drawn: CreateImageModel.PixelSize(width: 1024, height: 1024),
            final: CreateImageModel.PixelSize(width: 1024, height: 1024)
        ))
        XCTAssertNil(CreateImageModel.cropRect(
            drawn: CreateImageModel.PixelSize(width: 20, height: 20),
            final: CreateImageModel.PixelSize(width: 24, height: 30)
        ))
    }

    func testCropPNGTrimsTheFileInPlace() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("CreateImageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let url = folder.appendingPathComponent("drawn.png")
        let image = try XCTUnwrap(Self.makeTestImage(width: 32, height: 32))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        XCTAssertTrue(CreateImageModel.cropPNG(
            at: url, to: CGRect(x: 4, y: 1, width: 24, height: 30)
        ))

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let cropped = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(cropped.width, 24)
        XCTAssertEqual(cropped.height, 30)
    }

    private static func makeTestImage(width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 0.85, green: 0.4, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
