# Changelog

## 2.10.0 — Portfolio release

- Added read-only Windows network-stack, adapter-binding, route, DoH, offload, and NCSI evidence.
- Added bounded probes, compact redacted export, and repeated-run comparison support.
- Changed the public default invocation to the local `doctor` self-test.
- Changed Pktmon collection to require the explicit `-EnablePktmon` switch.
- Removed the execution-policy-bypass launcher from the public release.
- Added public documentation, privacy guidance, static safety tests, and CI.
- Removed private support-workflow terminology, implicit clipboard writes, and raw-export packaging.
- Fixed private IPv4 redaction and added IPv6, path, SSID, MAC, host, and user regression fixtures.
- Made Pktmon filter ownership explicit and added function-level plus outer capture cleanup.

The diagnostic algorithms retain the 2.10.0 implementation lineage; public-release changes harden defaults and presentation.
