import Foundation

enum EventMark {
    /// 自己合成的键盘事件带上这个标记，监听端直接忽略，避免输入文字再次触发录音。
    static let userData: Int64 = 0x5159_4B45_5900_0001
}
