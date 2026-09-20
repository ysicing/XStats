import Foundation

// libIOReport 没有公开头文件，按 powermetrics / macmon 使用的签名声明。只读取统计，不需要 root。

typealias IOReportSubscriptionRef = OpaquePointer

@_silgen_name("IOReportCopyChannelsInGroup")
func IOReportCopyChannelsInGroup(_ group: CFString?, _ subgroup: CFString?, _ a: UInt64, _ b: UInt64, _ c: UInt64) -> Unmanaged<CFMutableDictionary>?

@_silgen_name("IOReportMergeChannels")
func IOReportMergeChannels(_ into: CFMutableDictionary, _ from: CFDictionary, _ unused: CFTypeRef?)

@_silgen_name("IOReportCreateSubscription")
func IOReportCreateSubscription(_ allocator: UnsafeRawPointer?, _ channels: CFMutableDictionary,
                                _ subscribed: UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>,
                                _ channelID: UInt64, _ options: CFTypeRef?) -> IOReportSubscriptionRef?

@_silgen_name("IOReportCreateSamples")
func IOReportCreateSamples(_ subscription: IOReportSubscriptionRef, _ channels: CFMutableDictionary, _ options: CFTypeRef?) -> Unmanaged<CFDictionary>?

@_silgen_name("IOReportCreateSamplesDelta")
func IOReportCreateSamplesDelta(_ previous: CFDictionary, _ current: CFDictionary, _ options: CFTypeRef?) -> Unmanaged<CFDictionary>?

@_silgen_name("IOReportChannelGetGroup")
func IOReportChannelGetGroup(_ channel: CFDictionary) -> Unmanaged<CFString>?

@_silgen_name("IOReportChannelGetSubGroup")
func IOReportChannelGetSubGroup(_ channel: CFDictionary) -> Unmanaged<CFString>?

@_silgen_name("IOReportChannelGetChannelName")
func IOReportChannelGetChannelName(_ channel: CFDictionary) -> Unmanaged<CFString>?

@_silgen_name("IOReportChannelGetUnitLabel")
func IOReportChannelGetUnitLabel(_ channel: CFDictionary) -> Unmanaged<CFString>?

@_silgen_name("IOReportSimpleGetIntegerValue")
func IOReportSimpleGetIntegerValue(_ channel: CFDictionary, _ unused: Int32) -> Int64

@_silgen_name("IOReportStateGetCount")
func IOReportStateGetCount(_ channel: CFDictionary) -> Int32

@_silgen_name("IOReportStateGetNameForIndex")
func IOReportStateGetNameForIndex(_ channel: CFDictionary, _ index: Int32) -> Unmanaged<CFString>?

@_silgen_name("IOReportStateGetResidency")
func IOReportStateGetResidency(_ channel: CFDictionary, _ index: Int32) -> Int64
