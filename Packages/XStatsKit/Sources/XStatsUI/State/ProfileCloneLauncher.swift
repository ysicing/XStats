// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Security

enum ProfileCloneLauncher {
  static func build(
    _ clone: AppClone, source: URL, candidate: URL, arguments: [String], stage: URL
  ) async throws {
    let identifier = clone.application.rawValue
    var code: SecStaticCode?
    var requirement: SecRequirement?
    let flags = SecCSFlags(rawValue: kSecCSDoNotValidateResources | kSecCSCheckAllArchitectures)
    let rule = AppCloneSourceSignature.profileRequirement(for: clone.application)
    guard SecStaticCodeCreateWithPath(source as CFURL, [], &code) == errSecSuccess,
      SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess,
      let code, let requirement,
      SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    else { throw AppCloneStore.Failure.untrustedSource }

    let contents = candidate.appending(path: "Contents")
    let executables = contents.appending(path: "MacOS")
    let files = FileManager.default
    try files.createDirectory(at: executables, withIntermediateDirectories: true)
    let executable = executables.appending(path: clone.engineName)
    var metadata: [String: Any] = [
      "CFBundleIdentifier": clone.bundleID,
      "CFBundleExecutable": clone.engineName,
      "CFBundleName": clone.name,
      "CFBundleDisplayName": clone.name,
      "CFBundlePackageType": "APPL",
      "LSUIElement": true,
      "XStatsSourceIdentifier": identifier,
      "XStatsSourceRequirement": rule,
      "XStatsProfileArguments": arguments,
      "XStatsChromiumProxyArgument": clone.application.usesChromiumProxyArgument,
    ]
    metadata.merge(BrowserCloneProxy.bundleMetadata) { _, value in value }
    switch clone.application {
    case .visualStudioCode, .cursor:
      metadata["XStatsShortUserDataPath"] = true
    default:
      break
    }
    if let icon = Bundle(url: source)?.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
      !icon.isEmpty, icon == URL(fileURLWithPath: icon).lastPathComponent, icon != ".", icon != ".."
    {
      let filename = icon.hasSuffix(".icns") ? icon : icon + ".icns"
      let original = source.appending(path: "Contents/Resources").appending(path: filename)
      if let values = try? original.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
        values.isRegularFile == true, let size = values.fileSize, size <= 8 * 1024 * 1024
      {
        let resources = contents.appending(path: "Resources")
        try files.createDirectory(at: resources, withIntermediateDirectories: false)
        let iconData = try Data(contentsOf: original)
        try iconData.write(to: resources.appending(path: filename))
        metadata["CFBundleIconFile"] = filename
      }
    }
    let info = try PropertyListSerialization.data(
      fromPropertyList: metadata, format: .xml, options: 0)
    try info.write(to: contents.appending(path: "Info.plist"))
    let launcher = stage.appending(path: "ProfileLauncher.m")
    try Data((BrowserCloneProxy.launcherHeader + "\n" + launcherSource).utf8).write(to: launcher)
    try await AppCloneStore.run(
      "/usr/bin/xcrun",
      [
        "--sdk", "macosx", "clang", "-arch", "arm64", "-mmacosx-version-min=14.0", "-fobjc-arc",
        "-framework", "AppKit", "-framework", "Security", launcher.path, "-o", executable.path,
      ], stage: stage)
    try await AppCloneStore.run(
      "/usr/bin/codesign", ["--force", "--sign", "-", candidate.path], stage: stage)
    try await AppCloneStore.run(
      "/usr/bin/codesign", ["--verify", "--strict", candidate.path], stage: stage)
  }

  private static let launcherSource = #"""
    #import <AppKit/AppKit.h>
    #import <Security/Security.h>

    static BOOL matchesSource(NSURL *url, NSString *rule) {
        if (!url || !rule) return NO;
        SecStaticCodeRef code = NULL;
        SecRequirementRef requirement = NULL;
        BOOL valid = SecStaticCodeCreateWithPath((__bridge CFURLRef)url, 0, &code) == errSecSuccess
            && SecRequirementCreateWithString((__bridge CFStringRef)rule, 0, &requirement) == errSecSuccess
            && SecStaticCodeCheckValidity(code, kSecCSDoNotValidateResources | kSecCSCheckAllArchitectures,
                requirement) == errSecSuccess;
        if (requirement) CFRelease(requirement);
        if (code) CFRelease(code);
        return valid;
    }

    @interface ProfileLauncher : NSObject <NSApplicationDelegate>
    @property (strong) NSRunningApplication *sourceApplication;
    @property (strong) NSURL *shortProfileDirectory;
    @property BOOL launchingSource;
    @end

    @implementation ProfileLauncher
    - (void)applicationDidFinishLaunching:(NSNotification *)notification {
        NSBundle *bundle = NSBundle.mainBundle;
        NSDictionary *info = bundle.infoDictionary;
        NSArray<NSString *> *arguments = info[@"XStatsProfileArguments"];
        NSString *endpoint = cloneProxyEndpoint(bundle);
        if (!endpoint) {
            [self showError:[NSError errorWithDomain:NSCocoaErrorDomain
                code:NSFileReadCorruptFileError userInfo:nil]];
            return;
        }
        if (endpoint.length && [info[@"XStatsChromiumProxyArgument"] boolValue]) {
            arguments = [arguments arrayByAddingObject:[@"--proxy-server=" stringByAppendingString:endpoint]];
        }
        NSString *identifier = info[@"XStatsSourceIdentifier"];
        NSWorkspace *workspace = NSWorkspace.sharedWorkspace;
        NSURL *url = identifier ? [workspace URLForApplicationWithBundleIdentifier:identifier] : nil;
        if (!matchesSource(url, info[@"XStatsSourceRequirement"])) {
            [self showError:[NSError errorWithDomain:NSCocoaErrorDomain
                code:NSExecutableLoadError userInfo:nil]];
            return;
        }
        if ([info[@"XStatsShortUserDataPath"] boolValue]) {
            NSUInteger option = [arguments indexOfObject:@"--user-data-dir"];
            if (option == NSNotFound || option + 1 >= arguments.count) {
                [self showError:[NSError errorWithDomain:NSCocoaErrorDomain
                    code:NSFileReadCorruptFileError userInfo:nil]];
                return;
            }
            char path[] = "/tmp/xstats-editor.XXXXXXXX";
            if (!mkdtemp(path)) {
                [self showError:[NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil]];
                return;
            }
            self.shortProfileDirectory = [NSURL fileURLWithFileSystemRepresentation:path
                isDirectory:YES relativeToURL:nil];
            NSURL *alias = [self.shortProfileDirectory URLByAppendingPathComponent:@"profile"];
            NSURL *data = [NSURL fileURLWithPath:arguments[option + 1] isDirectory:YES];
            NSError *error = nil;
            if (![NSFileManager.defaultManager createDirectoryAtURL:data
                    withIntermediateDirectories:YES attributes:nil error:&error] ||
                ![NSFileManager.defaultManager createSymbolicLinkAtURL:alias
                    withDestinationURL:data error:&error]) {
                [self showError:error];
                return;
            }
            NSMutableArray<NSString *> *shortArguments = [arguments mutableCopy];
            shortArguments[option + 1] = alias.path;
            arguments = shortArguments;
        }
        [workspace.notificationCenter addObserver:self selector:@selector(sourceTerminated:)
            name:NSWorkspaceDidTerminateApplicationNotification object:nil];
        NSWorkspaceOpenConfiguration *configuration = [NSWorkspaceOpenConfiguration configuration];
        configuration.createsNewApplicationInstance = YES;
        configuration.arguments = arguments;
        if (endpoint.length) configuration.environment = cloneProxyEnvironment(endpoint);
        self.launchingSource = YES;
        [workspace openApplicationAtURL:url configuration:configuration completionHandler:
            ^(NSRunningApplication *sourceApplication, NSError *error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.launchingSource = NO;
                    if (error) {
                        [self showError:error];
                        return;
                    }
                    self.sourceApplication = sourceApplication;
                    if (!sourceApplication || sourceApplication.terminated) [NSApp terminate:nil];
                });
            }];
    }

    - (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)visible {
        [self.sourceApplication activateWithOptions:0];
        return NO;
    }

    - (void)applicationWillTerminate:(NSNotification *)notification {
        if (self.shortProfileDirectory && !self.launchingSource &&
            (!self.sourceApplication || self.sourceApplication.terminated)) {
            NSURL *alias = [self.shortProfileDirectory URLByAppendingPathComponent:@"profile"];
            unlink(alias.fileSystemRepresentation);
            rmdir(self.shortProfileDirectory.fileSystemRepresentation);
        }
    }

    - (void)sourceTerminated:(NSNotification *)notification {
        NSRunningApplication *application = notification.userInfo[NSWorkspaceApplicationKey];
        if (self.sourceApplication && application.processIdentifier == self.sourceApplication.processIdentifier)
            [NSApp terminate:nil];
    }

    - (void)showError:(NSError *)error {
        [NSApp activate];
        [[NSAlert alertWithError:error] runModal];
        [NSApp terminate:nil];
    }
    @end

    int main(void) {
        @autoreleasepool {
            NSApplication *application = NSApplication.sharedApplication;
            __attribute__((objc_precise_lifetime)) ProfileLauncher *launcher = [ProfileLauncher new];
            application.delegate = launcher;
            [application run];
            application.delegate = nil;
        }
        return 0;
    }
    """#
}
