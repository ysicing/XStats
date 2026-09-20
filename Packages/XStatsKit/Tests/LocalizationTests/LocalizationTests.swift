import Testing
@testable import Localization

// 不切换全局语言：其他测试套件并行运行，依赖中文原文
@Suite struct LocalizationTests {
    @Test func translatesExactAndTemplates() {
        let table = Translations.shared
        #expect(table.translate("内存") == "Memory")
        #expect(table.translate("12 个进程") == "12 processes")
        #expect(table.translate("1 个进程") == "1 process")
        #expect(table.translate("不存在的文案") == nil)
    }

    @Test func translatesCapturedChinese() {
        // 插进来的中文也会再翻一次
        #expect(Translations.shared.translate("设置 · 关于") == "Settings · About")
    }

    @Test func defaultsToChinese() {
        #expect(tr("内存") == "内存")
        #expect(AppLanguage.english.resolved == .english)
    }

    @Test func translatesWebDAVControlsAndErrors() {
        #expect(Translations.shared.translate("设置同步") == "Settings Sync")
        #expect(Translations.shared.translate("下载并应用") == "Download and Apply")
        #expect(Translations.shared.translate("WebDAV 返回错误：503") == "WebDAV returned an error: 503")
    }
}
