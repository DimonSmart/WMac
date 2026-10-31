# Experiment: strict geometry fallback

The proposed fallback was tested in a separate locally signed diagnostic bundle using the existing WMac Debug identity. The running taskbar and production sources were not modified. No permission was requested. AX and ScreenCapture authorization both passed in the diagnostic app. Images were captured in memory only; no frames or window titles were saved.

## Live results

| App/window | Original matcher | Prototype | Capture |
| --- | --- | --- | --- |
| Edge AX 0, CG/SC 60 | unmatched | matched(60) | 440 x 253, succeeded |
| Edge AX 1, CG/SC 51 | unmatched | matched(51) | 440 x 276, succeeded |
| CSharpFar AX 0, CG/SC 5628 | matched(5628) | matched(5628) | 440 x 299, succeeded |

Edge AX and CG geometry was identical in both cases. SC titles were nonempty but differed from AX titles: lengths 39 vs 67 and 59 vs 85. Removing the application suffix from AX made the first title equal; the second still differed after Unicode compatibility normalization and removal of format scalars. Exact title contents were deliberately not recorded.

## Adversarial model cases

Seven of nine cases behaved as expected: unique geometry with decorated or missing title, competing SC windows, competing AX windows, minimized target, missing geometry, and a 2 pt offset.

Two cases disproved the fallback's safety:

1. An AX snapshot lists distinct windows A and B at left and right. A newer SC snapshot has the same windows at exchanged positions. The original matcher rejects both. The fallback incorrectly maps A to B and B to A.
2. An AX snapshot contains a closed document. A newer SC snapshot contains a different document at exactly the same frame. The original matcher rejects the candidate. The fallback incorrectly accepts the replacement.

These are modeled snapshot races, not movements or closures performed on the user's actual browser windows. The failure is independent of the 1 pt threshold: all mistaken frames coincide exactly.

## Decision

Do not ship the proposed geometry-only fallback. It improves the happy path but violates IDD-0010 requirements to reject contradictory identity evidence and stale associations. Title compatibility should be retained as independent evidence, and association must be revalidated around capture. A title-normalization alternative requires its own verification; this experiment does not establish that it is safe or solves both Edge windows.

Reproduction source: main.swift. Full sanitized observations: results.json. First run: first-results.json.
