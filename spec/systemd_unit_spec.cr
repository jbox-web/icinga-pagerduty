require "./spec_helper"

# The unit is compiled into the binary so that a deployment installs the unit
# matching the binary it starts. Each line asserted here is a contract the
# deployment (spool permissions, user) relies on.
Spectator.describe "IcingaPagerduty::SYSTEMD_UNIT" do
  subject { IcingaPagerduty::SYSTEMD_UNIT.lines(chomp: true) }

  it "starts the daemon on the default spool" do
    expect(subject).to contain("ExecStart=/usr/local/bin/icinga-pagerduty daemon --spool /var/spool/icinga-pagerduty")
  end

  it "runs as the dedicated user, with Icinga's group to read the queued events" do
    expect(subject).to contain("User=icinga-pagerduty")
    expect(subject).to contain("Group=nagios")
  end

  it "only lets the daemon write to the spool" do
    expect(subject).to contain("ProtectSystem=strict")
    expect(subject).to contain("ReadWritePaths=/var/spool/icinga-pagerduty")
  end

  it "restarts the daemon whenever it exits" do
    expect(subject).to contain("Restart=always")
  end

  it "is enabled for the default target" do
    expect(subject).to contain("WantedBy=multi-user.target")
  end
end
