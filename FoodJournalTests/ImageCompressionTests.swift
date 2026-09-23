import XCTest
import UIKit
@testable import FoodJournal

final class ImageCompressionTests: XCTestCase {
    /// 构造纯色图片
    private func makeImage(width: CGFloat, height: CGFloat, scale: CGFloat = 1) -> UIImage {
        let size = CGSize(width: width, height: height)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    private func pixelSize(of image: UIImage) -> CGSize {
        CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
    }

    func testCompressLargeImageDownscalesTo1024() throws {
        let image = makeImage(width: 3000, height: 2000)
        let data = try XCTUnwrap(ImageCompression.compress(image))
        // JPEG 格式（魔数 FF D8）
        XCTAssertEqual([UInt8](data.prefix(2)), [0xFF, 0xD8])
        let decoded = try XCTUnwrap(UIImage(data: data))
        let size = pixelSize(of: decoded)
        XCTAssertEqual(max(size.width, size.height), 1024)
    }

    func testCompressSmallImageKeepsSize() throws {
        let image = makeImage(width: 500, height: 300)
        let data = try XCTUnwrap(ImageCompression.compress(image))
        let decoded = try XCTUnwrap(UIImage(data: data))
        let size = pixelSize(of: decoded)
        XCTAssertEqual(size.width, 500)
        XCTAssertEqual(size.height, 300)
    }

    func testBase64DataURIFormat() throws {
        let image = makeImage(width: 100, height: 100)
        let data = try XCTUnwrap(ImageCompression.compress(image))
        let uri = ImageCompression.dataURI(from: data)
        XCTAssertTrue(uri.hasPrefix("data:image/jpeg;base64,"))
        // 解码 base64 应与原始数据一致
        let prefix = "data:image/jpeg;base64,"
        let encoded = String(uri.dropFirst(prefix.count))
        XCTAssertEqual(Data(base64Encoded: encoded), data)
    }
}
