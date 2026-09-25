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
}
