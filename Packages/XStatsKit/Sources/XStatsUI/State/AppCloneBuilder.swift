// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

enum AppCloneBuilder {
  private static let signer = "/usr/bin/codesign"
  private static let libraryName = "libXStatsClone.dylib"
  private static let codeBundles: Set<String> = ["app", "appex", "framework", "xpc"]

  static func build(
    _ clone: AppClone, source: URL, candidate: URL, profile: URL, stage: URL
  ) async throws {
    let files = FileManager.default
    try Task.checkCancellation()
    try await AppCloneStore.run(
      "/usr/bin/ditto", ["--norsrc", "--noextattr", source.path, candidate.path], stage: stage)
    let contents = candidate.appending(path: "Contents")
    let info = contents.appending(path: "Info.plist")
    try rejectSymlinks([contents, info])
    var metadata = try readPlist(info)
    guard let sourceIdentifier = metadata["CFBundleIdentifier"] as? String,
      clone.application.sourceIdentifiers.contains(sourceIdentifier),
      let executableName = metadata["CFBundleExecutable"] as? String,
      !executableName.isEmpty, executableName != ".", executableName != "..",
      !executableName.contains("/")
    else { throw AppCloneStore.Failure.invalidSource }
    try AppCloneSourceSignature.validate(
      candidate, identifier: sourceIdentifier, application: clone.application)

    let macOS = contents.appending(path: "MacOS")
    let executable = macOS.appending(path: executableName)
    try rejectSymlinks([macOS, executable])
    guard files.isExecutableFile(atPath: executable.path) else {
      throw AppCloneStore.Failure.invalidSource
    }
    let frameworks = contents.appending(path: "Frameworks")
    try files.createDirectory(at: frameworks, withIntermediateDirectories: true)
    try rejectSymlinks([frameworks])
    let library = frameworks.appending(path: libraryName)
    guard !files.fileExists(atPath: library.path) else { throw AppCloneStore.Failure.invalidSource }
    let configuration = stage.appending(path: "profile.h")
    let header = """
      #define CLONE_HOME \(cString(profile.appending(path: "Home").path))
      #define CLONE_TMP \(cString(profile.appending(path: "Tmp").path))
      #define CLONE_PROFILE \(cString(profile.path))
      #define CLONE_NAME \(cString(clone.engineName))
      #define CLONE_LIBRARY "\(libraryName)"
      """
    try Data(header.utf8).write(to: configuration)
    let runtime = stage.appending(path: "CloneRuntime.m")
    try Data(runtimeSource.utf8).write(to: runtime)
    let compiler = [
      "--sdk", "macosx", "clang", "-arch", "arm64", "-O2", "-include", configuration.path,
    ]
    try await AppCloneStore.run(
      "/usr/bin/xcrun",
      compiler + ["-dynamiclib", "-framework", "Foundation", runtime.path, "-o", library.path],
      stage: stage)

    let originalEntitlements = try await entitlements(of: source, stage: stage)
    let mainProgram = macOS.appending(path: clone.engineName)
    try files.moveItem(at: executable, to: mainProgram)
    let attached =
      if clone.application == .lark { false } else {
        try MachOCloneLoadCommand.attach(libraryName, to: mainProgram)
      }
    let loaderDirectory = frameworks.appending(path: "ld")
    if clone.application == .weChat,
      (try? loaderDirectory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]))
        .map({ $0.isDirectory == true && $0.isSymbolicLink != true }) == true
    {
      try files.createSymbolicLink(
        atPath: loaderDirectory.appending(path: libraryName).path,
        withDestinationPath: "../\(libraryName)")
    }
    if attached {
      metadata["CFBundleExecutable"] = clone.engineName
    } else {
      let launcher = macOS.appending(path: "\(clone.engineName)-Launcher")
      let launcherSourceURL = stage.appending(path: "CloneLauncher.c")
      try Data(launcherSource.utf8).write(to: launcherSourceURL)
      try await AppCloneStore.run(
        "/usr/bin/xcrun", compiler + [launcherSourceURL.path, "-o", launcher.path],
        stage: stage)
      try await sign(mainProgram, entitlements: originalEntitlements, stage: stage)
      metadata["CFBundleExecutable"] = launcher.lastPathComponent
    }
    try files.createSymbolicLink(
      atPath: executable.path, withDestinationPath: mainProgram.lastPathComponent)
    metadata["CFBundleIdentifier"] = clone.bundleID
    metadata["CFBundleName"] = clone.name
    metadata["CFBundleDisplayName"] = clone.name
    metadata.removeValue(forKey: "CFBundleURLTypes")
    metadata.removeValue(forKey: "CFBundleDocumentTypes")
    metadata.removeValue(forKey: "LSHasLocalizedDisplayName")
    metadata.removeValue(forKey: "TeamIdentifier")
    let resources = contents.appending(path: "Resources")
    if files.fileExists(atPath: resources.path) {
      try rejectSymlinks([resources])
      for localization in try files.contentsOfDirectory(
        at: resources, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
      ) where localization.pathExtension == "lproj" {
        let values = try localization.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
        let strings = localization.appending(path: "InfoPlist.strings")
        guard files.fileExists(atPath: strings.path) else { continue }
        try rejectSymlinks([strings])
        var localized = try readPlist(strings)
        localized["CFBundleName"] = clone.name
        localized["CFBundleDisplayName"] = clone.name
        try writePlist(localized, to: strings)
        metadata["LSHasLocalizedDisplayName"] = true
      }
    }
    try writePlist(metadata, to: info)

    let (nested, code) = try prepareNestedCode(
      in: contents, mainProgram: mainProgram, sourceIdentifier: sourceIdentifier,
      cloneIdentifier: clone.bundleID)
    for binary in code {
      try Task.checkCancellation()
      try await sign(binary, entitlements: nil, stage: stage)
    }
    for bundle in nested.sorted(by: { $0.pathComponents.count > $1.pathComponents.count }) {
      try Task.checkCancellation()
      let candidatePath = candidate.resolvingSymlinksInPath().pathComponents
      let bundlePath = bundle.resolvingSymlinksInPath().pathComponents
      guard bundlePath.starts(with: candidatePath) else {
        throw AppCloneStore.Failure.invalidSource
      }
      let relativePath = bundlePath.dropFirst(candidatePath.count).joined(separator: "/")
      let original = source.appending(path: relativePath)
      let entitlementFile = try await entitlements(of: original, stage: stage)
      try await sign(bundle, entitlements: entitlementFile, stage: stage)
    }
    try await sign(candidate, entitlements: attached ? originalEntitlements : nil, stage: stage)
    try await AppCloneStore.run(
      signer, ["--verify", "--deep", "--strict", candidate.path], stage: stage)
  }

  private static func prepareNestedCode(
    in contents: URL, mainProgram: URL, sourceIdentifier: String, cloneIdentifier: String
  ) throws -> ([URL], [URL]) {
    // 保留 Helper 的文件名和相对路径，Chromium 通过这些路径查找子进程。
    let files = FileManager.default
    var nested: [URL] = []
    var code: [URL] = []
    var enumerationFailure: Error?
    let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
    guard
      let entries = files.enumerator(
        at: contents, includingPropertiesForKeys: Array(keys),
        errorHandler: { _, error in
          enumerationFailure = error
          return false
        })
    else { throw AppCloneStore.Failure.invalidSource }
    for case let entry as URL in entries {
      try Task.checkCancellation()
      let values = try entry.resourceValues(forKeys: keys)
      guard values.isSymbolicLink != true else { continue }
      if values.isDirectory == true, codeBundles.contains(entry.pathExtension) {
        nested.append(entry)
      } else if entries.level > 1, values.isRegularFile == true,
        entry.lastPathComponent == "Info.plist",
        var child = try? readPlist(entry), let identifier = child["CFBundleIdentifier"] as? String,
        identifier.hasPrefix(sourceIdentifier + ".")
      {
        child["CFBundleIdentifier"] =
          cloneIdentifier + identifier.dropFirst(sourceIdentifier.count)
        child.removeValue(forKey: "TeamIdentifier")
        try writePlist(child, to: entry)
      } else if values.isRegularFile == true, entry != mainProgram,
        entry.pathExtension == "dylib" || entry.pathExtension == "so"
          || entry.pathExtension == "node"
          || files.isExecutableFile(atPath: entry.path),
        MachOCloneLoadCommand.isMachO(entry)
      {
        code.append(entry)
      }
    }
    if let enumerationFailure { throw enumerationFailure }

    return (nested, code)
  }

  private static func entitlements(of bundle: URL, stage: URL) async throws -> URL? {
    let output = stage.appending(path: "\(UUID().uuidString).plist")
    try await AppCloneStore.run(
      signer, ["-d", "--entitlements", output.path, "--xml", bundle.path], stage: stage)
    guard FileManager.default.fileExists(atPath: output.path) else { return nil }
    let entitlements = try readPlist(output).filter { entitlement, _ in
      [
        "com.apple.security.cs.allow-jit", "com.apple.security.cs.allow-unsigned-executable-memory",
        "com.apple.security.cs.disable-library-validation",
        "com.apple.security.cs.allow-dyld-environment-variables",
      ].contains(entitlement)
    }
    guard !entitlements.isEmpty else { return nil }
    try writePlist(entitlements, to: output)
    return output
  }

  private static func sign(_ url: URL, entitlements: URL?, stage: URL) async throws {
    var arguments = ["--force", "--sign", "-"]
    if let entitlements { arguments += ["--entitlements", entitlements.path] }
    try await AppCloneStore.run(signer, arguments + [url.path], stage: stage)
  }

  private static func readPlist(_ url: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: url)
    guard
      let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any]
    else { throw AppCloneStore.Failure.invalidSource }
    return plist
  }

  private static func rejectSymlinks(_ urls: [URL]) throws {
    for url in urls
    where try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != false {
      throw AppCloneStore.Failure.invalidSource
    }
  }

  private static func writePlist(_ plist: [String: Any], to url: URL) throws {
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try data.write(to: url, options: .atomic)
  }

  private static func cString(_ value: String) -> String {
    "\"" + value.utf8.map { String(format: "\\%03o", $0) }.joined() + "\""
  }

  private static let runtimeSource = #"""
    #import <Foundation/Foundation.h>
    #include <pwd.h>
    #include <unistd.h>
    #include <stdlib.h>
    #include <string.h>

    __attribute__((constructor)) static void configure_profile(void) {
        setenv("HOME", CLONE_HOME, 1);
        setenv("CFFIXED_USER_HOME", CLONE_HOME, 1);
        setenv("TMPDIR", CLONE_TMP, 1);
        unsetenv("DYLD_INSERT_LIBRARIES");
    }

    static NSString *clone_home(void) { return @CLONE_HOME; }
    static NSString *clone_tmp(void) { return @CLONE_TMP; }
    static NSString *clone_user_home(NSString *user) {
        if (user == nil || [user isEqualToString:NSUserName()]) return @CLONE_HOME;
        return NSHomeDirectoryForUser(user);
    }
    static NSArray<NSString *> *clone_search_paths(NSSearchPathDirectory directory,
                                                   NSSearchPathDomainMask domains, BOOL expand) {
        NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(directory, domains, expand);
        if (!(domains & NSUserDomainMask) || !expand) return paths;
        const struct passwd *record = getpwuid(getuid());
        if (record == NULL || record->pw_dir == NULL) return paths;
        NSString *prefix = [[NSString stringWithUTF8String:record->pw_dir] stringByAppendingString:@"/"];
        NSMutableArray<NSString *> *rewritten = [NSMutableArray arrayWithCapacity:paths.count];
        for (NSString *path in paths) {
            [rewritten addObject:[path hasPrefix:prefix]
                ? [@CLONE_HOME stringByAppendingPathComponent:[path substringFromIndex:prefix.length]]
                : path];
        }
        return rewritten;
    }
    static struct passwd *clone_passwd(uid_t uid) {
        struct passwd *record = getpwuid(uid);
        if (record == NULL || uid != getuid()) return record;
        static _Thread_local struct passwd isolated;
        isolated = *record;
        isolated.pw_dir = CLONE_HOME;
        return &isolated;
    }
    static int clone_passwd_r(uid_t uid, struct passwd *record, char *buffer,
                              size_t capacity, struct passwd **result) {
        int status = getpwuid_r(uid, record, buffer, capacity, result);
        if (status == 0 && *result != NULL && uid == getuid()) record->pw_dir = CLONE_HOME;
        return status;
    }
    static size_t clone_confstr(int selector, char *buffer, size_t capacity) {
        const char *path = selector == _CS_DARWIN_USER_TEMP_DIR ? CLONE_TMP "/" :
            selector == _CS_DARWIN_USER_CACHE_DIR ? CLONE_HOME "/Library/Caches/" : NULL;
        if (path == NULL) return confstr(selector, buffer, capacity);
        if (buffer != NULL && capacity > 0) strlcpy(buffer, path, capacity);
        return strlen(path) + 1;
    }
    #define INTERPOSE(replacement, original) \
      __attribute__((used, section("__DATA,__interpose"))) \
      static const struct { const void *new_function; const void *old_function; } \
      replacement##_entry = { (const void *)&replacement, (const void *)&original };
    INTERPOSE(clone_home, NSHomeDirectory)
    INTERPOSE(clone_tmp, NSTemporaryDirectory)
    INTERPOSE(clone_user_home, NSHomeDirectoryForUser)
    INTERPOSE(clone_search_paths, NSSearchPathForDirectoriesInDomains)
    INTERPOSE(clone_passwd, getpwuid)
    INTERPOSE(clone_passwd_r, getpwuid_r)
    INTERPOSE(clone_confstr, confstr)
    """#

  private static let launcherSource = #"""
    #include <libgen.h>
    #include <limits.h>
    #include <mach-o/dyld.h>
    #include <stdio.h>
    #include <stdlib.h>
    #include <unistd.h>

    int main(int argc, char **argv) {
        char path[PATH_MAX], program[PATH_MAX], library[PATH_MAX];
        uint32_t size = sizeof(path);
        if (_NSGetExecutablePath(path, &size) != 0) return 1;
        const char *directory = dirname(path);
        if (snprintf(program, sizeof(program), "%s/%s", directory, CLONE_NAME) >= sizeof(program) ||
            snprintf(library, sizeof(library), "%s/../Frameworks/%s", directory, CLONE_LIBRARY) >= sizeof(library)) return 1;
        setenv("HOME", CLONE_HOME, 1);
        setenv("CFFIXED_USER_HOME", CLONE_HOME, 1);
        setenv("TMPDIR", CLONE_TMP, 1);
        setenv("DYLD_INSERT_LIBRARIES", library, 1);
        argv[0] = program;
        execv(program, argv);
        perror("execv");
        return 1;
    }
    """#
}
