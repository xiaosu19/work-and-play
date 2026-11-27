import Darwin
import Foundation

private var failures = 0

func expect(_ value: @autoclosure () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) {
    do {
        guard try value() else {
            failures += 1
            print("FAIL \(file):\(line)")
            return
        }
    } catch {
        failures += 1
        print("FAIL \(file):\(line) \(error)")
    }
}

@main
struct RunVerification {
    static func main() {
        let engine = TimeEngineTests()
        let store = SQLiteStoreTests()
        let bridge = BridgeTests()
        let workReport = WorkReportTests()
        let cases: [(String, () throws -> Void)] = [
            ("阅读 90 + 120 秒与重复上报", engine.testReadingExampleAndDuplicate),
            ("午休 10 + 10 分钟与休息隐私", engine.testLunchExampleAndRestPrivacy),
            ("切标签与后台播放", engine.testForegroundVideoAndNoCreditAfterSwitch),
            ("闲置恢复、应用切换与视频暂停", engine.testIdleResumesOnlyOnNewInputAndPauseStopsVideo),
            ("设备空闲按阈值开始、真实输入截止", engine.testOptionalDeviceIdleStartsAtThresholdAndEndsAtInput),
            ("设备空闲避开休息、暂停及停采间隙", engine.testDeviceIdleRespectsRestMidnightSuspensionAndCoverage),
            ("有效阅读和播放优先于设备空闲", engine.testDeviceIdleDoesNotOverlapReadingOrPlayingVideo),
            ("锁屏和睡眠分开记入普通时段的空闲", engine.testKnownLockAndSleepCountAsIdleWithoutOverlap),
            ("本地午夜、日期覆盖与边界续计", engine.testMidnightOverrideAndBoundaryDoesNotRenew),
            ("当前休息时段、多个时段与空日期覆盖", engine.testEffectiveRestPlanAndEmptyDateOverride),
            ("按上下班设置全周、午休和边界", engine.testWorkdaySetupWithLunchAndDailyBoundaries),
            ("上下班时间输入与顺序校验", engine.testWorkdayClockEntryAndValidation),
            ("锁屏、睡眠、重启和旧信号", engine.testLockSleepRestartAndOldSignals),
            ("Chrome 失联截止与规则优先级", engine.testBrowserLeaseAndSpecificRule),
            ("工作视频与纯音频不延长计时", engine.testVideoCannotExtendWorkAndAudioDoesNotRenewReading),
            ("原生 App、系统类别与动态网页自动分类", engine.testAutomaticClassificationUsesAppMetadataAndLiveContext),
            ("网站通配、域名边界与分类优先级", engine.testWildcardWebsiteMatchingAndPrecedence),
            ("夏令时切换的 23 与 25 小时日界", engine.testDaylightSavingUsesElapsedHours),
            ("SQLite 隐私、总数、修正与重开", store.testPrivacyTotalsCorrectionAndRestart),
            ("日报列出十分钟空档，排除午休且不生成片段", store.testDailyReportShowsUnrecordedTimeWithoutCountingIt),
            ("工作网站与客户会话按明确授权匹配", workReport.activityAuthorizationRequiresSpecificWorkContext),
            ("日报周报仅使用工作，独立摸鱼接口、加班与撤销", workReport.workAndLeisureReportsStaySeparateAndCountOvertime),
            ("自动 JSON 分流、重启重试及修正后更新", workReport.automaticOperationJSONKeepsChannelsAndCorrectionsSeparate),
            ("设备空闲旧配置兼容、入库与报表", store.testDeviceIdleSettingAndReportAreBackwardCompatible),
            ("SQLite 连续片段合并与重复写入", store.testCheckpointsMergeOnlyContiguousSpans),
            ("网页未识别单列、应用统计汇总与历史修正", store.testHistoricalAutomaticClassificationPreservesOverrides),
            ("排班保存重开与修改仅作用于新片段", store.testSavedScheduleDoesNotRecategorizeExistingTime),
            ("跨日期报表、分类分页与来源汇总", store.testReportRangeTotalsPagingAndSources),
            ("同一网站按工作和摸鱼汇总", store.testMixedSiteShowsWorkEntertainmentAndReview),
            ("网站访问跨浏览器汇总、跨午夜去重及旧库迁移", store.testWebsiteVisitsAcrossBrowsersAndLegacyMigration),
            ("Chrome 桥接拒绝原始 URL 与无效数据", bridge.testRejectsPrivateURLAndUnsupportedFrames),
            ("Chrome 桥接新鲜度与重复数据", bridge.testLeaseAndReplay),
            ("Chrome 后台配置与断连", bridge.testBackgroundProfileCannotReplaceActiveProfile),
            ("浏览器来源与旧 Chrome 连接器兼容", bridge.testHostBrowserIdentificationAndLegacyCompatibility),
            ("Chrome 本机消息封包", bridge.testNativeFramesRoundTrip)
        ]
        for (name, run) in cases {
            let prior = failures
            do {
                try run()
            } catch {
                failures += 1
                print("FAIL \(name) \(error)")
            }
            if prior == failures { print("PASS \(name)") }
        }
        print("\(cases.count) cases, \(failures) failures")
        exit(failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE)
    }
}
