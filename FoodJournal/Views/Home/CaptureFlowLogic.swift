import Foundation

/// 拍摄流程状态机：相机 dismiss 后的落点判定。
/// 核心不变式：确认页内补拍的相机，无论取消还是成功，都回落到照片确认页；
/// 只有用户在确认页主动取消/完成时才离开确认流程。
enum CaptureFlowLogic {
    /// 相机的进入路径
    enum CameraEntryPoint {
        /// 主界面拍摄入口（Menu → 拍照）
        case entry
        /// 确认页「再拍一张」补拍
        case retake
    }

    /// 相机 dismiss 后应落到的界面
    enum PostCameraDestination {
        case confirmSheet
        case main
    }

    /// 入口相机：拍到照片进确认页，取消回主界面；
    /// 补拍相机：永远回落确认页（sheet 保持呈现，已拍照片全部保留）。
    static func destinationAfterCameraDismiss(
        entryPoint: CameraEntryPoint,
        didCaptureImage: Bool
    ) -> PostCameraDestination {
        switch entryPoint {
        case .retake:
            return .confirmSheet
        case .entry:
            return didCaptureImage ? .confirmSheet : .main
        }
    }

    /// 确认页应显示的照片列表：新照片追加到已有列表，超过上限时截断，已满则原样返回。
    static func appendedPhotos(current: [Data], new: [Data], limit: Int) -> [Data] {
        let space = limit - current.count
        guard space > 0 else { return current }
        return current + new.prefix(space)
    }
}
