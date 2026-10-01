import XCTest
@testable import FoodJournal

/// 拍摄流程状态机：相机 dismiss 后落点判定。
/// 重点回归真机 bug：确认页补拍的相机取消后必须回落确认页，已拍照片保留。
final class CaptureFlowLogicTests: XCTestCase {
    func testRetakeCameraAlwaysFallsBackToConfirmSheet() {
        // 补拍路径：取消（X）与拍摄成功都必须回到确认页，sheet 不得被收起
        for didCapture in [false, true] {
            let destination = CaptureFlowLogic.destinationAfterCameraDismiss(
                entryPoint: .retake, didCaptureImage: didCapture
            )
            XCTAssertEqual(destination, .confirmSheet)
        }
    }

    func testEntryCameraDestinationDependsOnCapture() {
        // 入口路径：拍到照片进确认页；取消回主界面
        let captured = CaptureFlowLogic.destinationAfterCameraDismiss(
            entryPoint: .entry, didCaptureImage: true
        )
        XCTAssertEqual(captured, .confirmSheet)

        let cancelled = CaptureFlowLogic.destinationAfterCameraDismiss(
            entryPoint: .entry, didCaptureImage: false
        )
        XCTAssertEqual(cancelled, .main)
    }

    // MARK: 确认页应显示的照片列表（回归：首拍后确认页 0/5 不显示图）

    func testAppendedPhotosAppendsWithinLimit() {
        // 未达上限：新照片全部追加，首拍后确认页立即应显示 1 张
        let result = CaptureFlowLogic.appendedPhotos(
            current: [], new: [Data([1]), Data([2])], limit: 5
        )
        XCTAssertEqual(result.count, 2)
    }

    func testAppendedPhotosTruncatesAndStopsAtLimit() {
        // 已有 4 张再追加 2 张 → 截断到 5 张；已满 5 张 → 不再追加
        let current = [Data](repeating: Data([0]), count: 4)
        let truncated = CaptureFlowLogic.appendedPhotos(
            current: current, new: [Data([1]), Data([2])], limit: 5
        )
        XCTAssertEqual(truncated.count, 5)

        let full = [Data](repeating: Data([0]), count: 5)
        let unchanged = CaptureFlowLogic.appendedPhotos(
            current: full, new: [Data([1])], limit: 5
        )
        XCTAssertEqual(unchanged, full)
    }
}
