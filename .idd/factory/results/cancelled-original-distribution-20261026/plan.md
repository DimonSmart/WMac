# Task

Prepare reproducible release distribution for the existing universal Xcode application. Add documented automation for Release build, Developer ID Application signing with Hardened Runtime, verification of both architectures and stable bundle metadata, DMG creation with an Applications drag-install destination, notarization, stapling and final signature/Gatekeeper checks. Require explicit supplied signing identity and existing notarization credentials; detect missing prerequisites clearly and never represent an ad-hoc build or unsigned package as a distributable release. Do not register identities, accept terms, alter trust/security settings, expose credentials or upload artifacts without the necessary external authority.

Keep local development builds usable. Validate packaging mechanics with the available local tools and artifacts; execute genuine Developer ID/notarization stages only when authorized resources exist. Update README, architecture, limitations and manual-test documentation to describe the actual build/install pipeline, remaining signing and quarantine acceptance checks, and the supported application/platform matrix. Record unavailable certificates, external access and hardware as concrete unverified acceptance items while completing independent release preparation.

# ExecutionProfile

standard

# TaskRelatedIntent

IDD-0001
IDD-0008

# TaskRelatedEngineering

ENG-0004
