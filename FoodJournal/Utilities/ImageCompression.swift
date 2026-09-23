import UIKit

/// 图片压缩工具：拍照识图前把 UIImage 压成适合上传的 JPEG Data。
enum ImageCompression {
    /// 最长边上限（像素）
    static let maxDimension: CGFloat = 1024
    /// JPEG 压缩质量
    static let jpegQuality: CGFloat = 0.6

    /// 压缩：最长边超过 1024px 时按比例缩小（小于则不动），输出 JPEG Data。
    static func compress(_ image: UIImage) -> Data? {
        downscale(image).jpegData(compressionQuality: jpegQuality)
    }

    /// 压缩并转 base64 data URI（"data:image/jpeg;base64,..."），供 OpenAI 兼容 image_url 使用。
    static func base64DataURI(for image: UIImage) -> String? {
        guard let data = compress(image) else { return nil }
        return dataURI(from: data)
    }

    /// 把 JPEG Data 转成 data URI 字符串。
    static func dataURI(from data: Data) -> String {
        "data:image/jpeg;base64," + data.base64EncodedString()
    }

    /// 最长边缩到 maxDimension（保持比例）；已小于等于上限则原样返回。
    private static func downscale(_ image: UIImage) -> UIImage {
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        let longestPixel = max(pixelWidth, pixelHeight)
        guard longestPixel > maxDimension, longestPixel > 0 else { return image }

        let ratio = maxDimension / longestPixel
        let targetSize = CGSize(width: pixelWidth * ratio, height: pixelHeight * ratio)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1 // 渲染上下文以像素为单位，确保输出尺寸精确
        return UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }
}
