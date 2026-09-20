import HelperShared
import Testing

@Suite struct DNSConfigurationTests {
    @Test func acceptsNumericAddressesOnly() {
        #expect(DNSConfiguration.isValidAddress("1.1.1.1"))
        #expect(DNSConfiguration.isValidAddress("2606:4700:4700::1111"))
        #expect(!DNSConfiguration.isValidAddress("dns.google"))
        #expect(!DNSConfiguration.isValidAddress("1.1.1.1; rm -rf /"))
        #expect(!DNSConfiguration.isValidAddress("999.1.1.1"))
    }

    @Test func parsesUserInput() {
        #expect(DNSConfiguration.parse("1.1.1.1, 8.8.8.8") == ["1.1.1.1", "8.8.8.8"])
        #expect(DNSConfiguration.parse("223.5.5.5，223.6.6.6\n2400:3200::1") == ["223.5.5.5", "223.6.6.6", "2400:3200::1"])
        #expect(DNSConfiguration.parse("1.1.1.1 example.com") == nil)
        #expect(DNSConfiguration.parse(Array(repeating: "1.1.1.1", count: 7).joined(separator: " ")) == nil)
    }

    @Test func matchesPresets() {
        #expect(DNSPreset.matching([]) == .automatic)
        #expect(DNSPreset.matching(["1.1.1.1", "1.0.0.1"]) == .cloudflare)
        #expect(DNSPreset.matching(["1.0.0.1", "1.1.1.1"]) == nil)
    }

    @Test func buildsArgumentsWithoutShell() {
        #expect(DNSConfiguration.networksetupArguments(service: "Wi-Fi", servers: []) == ["-setdnsservers", "Wi-Fi", "Empty"])
        #expect(DNSConfiguration.networksetupArguments(service: "USB LAN", servers: ["8.8.8.8"]) == ["-setdnsservers", "USB LAN", "8.8.8.8"])
    }

    @Test func quotesServiceNameForShell() {
        #expect(DNSConfiguration.shellCommand(service: "Bob's LAN", servers: ["1.1.1.1"])
            == "/usr/sbin/networksetup -setdnsservers 'Bob'\\''s LAN' 1.1.1.1")
        #expect(!DNSConfiguration.isValidServiceName("Wi-Fi\nrm"))
    }
}
