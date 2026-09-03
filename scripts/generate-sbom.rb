#!/usr/bin/env ruby
require "json"

resolved = JSON.parse(File.read(ARGV.fetch(0)))
packages = resolved.fetch("pins").map do |pin|
  state = pin.fetch("state")
  version = state["version"] || state["revision"] || state["branch"] || "unknown"
  {
    "SPDXID" => "SPDXRef-Package-#{pin.fetch("identity").gsub(/[^A-Za-z0-9.-]/, "-")}",
    "name" => pin.fetch("identity"),
    "versionInfo" => version,
    "downloadLocation" => pin.fetch("location"),
    "filesAnalyzed" => false,
    "licenseConcluded" => "NOASSERTION",
    "licenseDeclared" => "NOASSERTION"
  }
end

document = {
  "spdxVersion" => "SPDX-2.3",
  "dataLicense" => "CC0-1.0",
  "SPDXID" => "SPDXRef-DOCUMENT",
  "name" => "VaultBridge-dependencies",
  "documentNamespace" => "https://github.com/haivri/VaultBridge/sbom/#{ENV.fetch("GITHUB_SHA", "local")}",
  "creationInfo" => {
    "created" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
    "creators" => ["Tool: VaultBridge-generate-sbom"]
  },
  "packages" => packages
}
puts JSON.pretty_generate(document)
