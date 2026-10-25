import Foundation
import Testing
@testable import RestorationStation

@Suite struct ReleaseUpdaterTests {
    @Test func normalizesAndComparesSemanticVersions() {
        #expect(ReleaseUpdater.normalizeVersion(" v1.2.3 \n") == "1.2.3")
        #expect(ReleaseUpdater.normalizeVersion("V2.0.0") == "2.0.0")
        #expect(ReleaseUpdater.normalizeVersion("") == "0.0.0")

        #expect(ReleaseUpdater.isVersion("1.2.0", newerThan: "1.1.9"))
        #expect(ReleaseUpdater.isVersion("v1.10.0", newerThan: "1.2.0"))
        #expect(!ReleaseUpdater.isVersion("1.2.0", newerThan: "1.2.0"))
        #expect(!ReleaseUpdater.isVersion("1.2", newerThan: "1.2.0"))
        #expect(ReleaseUpdater.isVersion("1.0.0", newerThan: "0.0.0"))
        #expect(ReleaseUpdater.isVersion("1.0.0", newerThan: "1.0.0-beta.1"))
        #expect(!ReleaseUpdater.isVersion("1.0.0-beta.1", newerThan: "1.0.0"))
    }

    @Test func decodesGitHubReleaseAndPrefersATCStudioDMG() throws {
        let json = """
        {
          "tag_name": "v1.4.2",
          "name": "ATC Studio 1.4.2",
          "body": "### Fixed\\n- Improved sanctuary acoustic cleanup",
          "html_url": "https://github.com/michaelrubi/atcStudio/releases/tag/v1.4.2",
          "published_at": "2026-10-25T18:30:00Z",
          "assets": [
            {
              "name": "checksums.txt",
              "browser_download_url": "https://github.com/michaelrubi/atcStudio/releases/download/v1.4.2/checksums.txt",
              "size": 128
            },
            {
              "name": "ATC-Studio-1.4.2.dmg",
              "browser_download_url": "https://github.com/michaelrubi/atcStudio/releases/download/v1.4.2/ATC-Studio-1.4.2.dmg",
              "size": 48234496
            }
          ]
        }
        """
        let release = try ReleaseUpdater.decodeRelease(from: Data(json.utf8))
        #expect(release.tagName == "v1.4.2")
        #expect(release.version == "1.4.2")
        #expect(release.title == "ATC Studio 1.4.2")
        #expect(release.notes.contains("Improved sanctuary acoustic cleanup"))
        #expect(release.publishedAt != nil)
        #expect(release.dmgAsset?.name == "ATC-Studio-1.4.2.dmg")
        #expect(release.dmgAsset?.size == 48_234_496)
    }

    @Test func parsesHdiutilMountPointFromPlist() throws {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>system-entities</key>
            <array>
                <dict>
                    <key>content-hint</key>
                    <string>Apple_partition_scheme</string>
                    <key>dev-entry</key>
                    <string>/dev/disk4</string>
                </dict>
                <dict>
                    <key>content-hint</key>
                    <string>Apple_HFS</string>
                    <key>dev-entry</key>
                    <string>/dev/disk4s1</string>
                    <key>mount-point</key>
                    <string>/Volumes/ATC Studio</string>
                </dict>
            </array>
        </dict>
        </plist>
        """
        let mount = try ReleaseUpdater.parseMountPoint(fromPlistData: Data(plist.utf8))
        #expect(mount.path == "/Volumes/ATC Studio")
    }
}
