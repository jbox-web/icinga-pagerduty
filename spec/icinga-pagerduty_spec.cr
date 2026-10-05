require "./spec_helper"

# These specs cover the build provenance and the baked licenses. They are
# written against the *shape* of the provenance rather than its values, because
# every value here is captured at compile time and differs between a checkout,
# a tarball and a release build — a spec asserting a literal commit would fail
# on the machine next door.
Spectator.describe IcingaPagerduty do
  describe "NAME" do
    it "is the shard name" do
      expect(IcingaPagerduty::NAME).to eq("icinga-pagerduty")
    end
  end

  describe "TARGET" do
    it "is the platform the binary was compiled for" do
      expect(IcingaPagerduty::TARGET).to match(%r{\A(linux|darwin|windows|unknown)/(amd64|arm64|unknown)\z})
    end
  end

  describe "BUILT_AT" do
    it "is a UTC ISO 8601 timestamp" do
      expect(IcingaPagerduty::BUILT_AT).to match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/)
    end
  end

  describe ".commit" do
    # The -dirty suffix is the one field whose absence makes the version false
    # rather than merely incomplete, so the shape is asserted explicitly.
    it "is a short ref, optionally suffixed -dirty, or unknown" do
      expect(IcingaPagerduty.commit).to match(/\A(unknown|[0-9a-f]{8}(-dirty)?)\z/)
    end

    it "reports unknown rather than an empty string outside a checkout" do
      expect(IcingaPagerduty.commit).not_to be_empty
    end
  end

  describe ".git_tag" do
    it "never degenerates to an empty string" do
      expect(IcingaPagerduty.git_tag).not_to be_empty
    end
  end

  # Shapes written out by hand: rebuilding the expected string from VERSION,
  # commit and TARGET would only prove the method equal to itself.
  describe ".version" do
    it "carries version, commit and platform, without the program name" do
      expect(IcingaPagerduty.version).to match(%r{\A\d+\.\d+\.\d+ \((unknown|[0-9a-f]{8}(-dirty)?), [a-z]+/[a-z0-9]+\)\z})
    end
  end

  describe ".version_line" do
    it "names itself, so the line survives being pasted alone" do
      expect(IcingaPagerduty.version_line).to match(%r{\Aicinga-pagerduty \d+\.\d+\.\d+ \((unknown|[0-9a-f]{8}(-dirty)?), [a-z]+/[a-z0-9]+\)\z})
    end
  end

  describe IcingaPagerduty::Licenses do
    # Proves the harvest chain actually ran before compilation: an empty baked
    # folder is exactly the failure the licenses machinery exists to prevent.
    it "embeds the project's own license" do
      expect(IcingaPagerduty::Licenses.files.map(&.path)).to contain("/#{IcingaPagerduty::NAME}.txt")
    end

    it "embeds the grouped notices of the statically linked C libraries" do
      expect(IcingaPagerduty::Licenses.files.map(&.path).select(&.includes?("clib-"))).not_to be_empty
    end
  end
end
