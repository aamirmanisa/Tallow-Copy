# Documentation index

Four documents behind the tool. The README states what `tallowx` does; these say why, and what it
found out the hard way.

| Page | What it answers |
|---|---|
| [`DESIGN.md`](DESIGN.md) | The shape: one program, a three-line launcher, no state. Decisions and the alternatives that were rejected. |
| [`ENGINE-FINDINGS.md`](ENGINE-FINDINGS.md) | Nine engine defects and gaps found while building this against 1.5.2 — each with the command that reproduces it. Most are now fixed; the file is the record of what "compiles" did not mean. |
| [`OPTIMIZATION-REPORT.md`](OPTIMIZATION-REPORT.md) | Measured analysis of both the tool and the engine, in priority order, with the gates that decide whether a change helped. |
| [`PRIOR-ART.md`](PRIOR-ART.md) | What `cp`, `rsync`, `rclone`, `bbcp`, `tar`+pipe and the content-addressed tools are each good at, and what was deliberately not researched. |

## Reading order

Start with `DESIGN.md` if you are changing the tool. Read `ENGINE-FINDINGS.md` before blaming the
program for a compiler error — the failure modes there look like tool bugs and were not.
`OPTIMIZATION-REPORT.md` is the evidence behind every performance claim in the README; if a number
there and a number in the README disagree, the report is the older measurement and the README
should be corrected.

## Numbers

Every figure in these documents is labelled with the engine it was measured on. The engine moved
from 1.5.2 to 1.5.7 while the tool was being built, and the native plane did not exist for the
earliest measurements — a fact that matters when reading anything about throughput.
