# Local coverage archive

Coverage recording is opt-in through a session. Constructing the store does not create files, request location, contact a router or enable networking. Relaunching the app never resumes recording implicitly. The older rolling history remains a separate legacy source; it is not the durable Coverage archive and is not silently imported.

## Durable events

Each session has a stable UUID directory under the app's `T-Mobile/Coverage` Application Support folder. Each successful mutation creates one schema-version-1 JSON event, capped at 256 KiB. A session start, observation, correction, timed speed result, gap, tested-stop attempt or session end is an individual event. Writes use an owner-only temporary file, synchronize its contents, and atomically create a new event destination without overwriting an existing file. Archive and session directories use mode 0700; event files use 0600.

Published state advances only after the event is committed. A failed write surfaces an error and does not claim an unsaved reading. No retention timer removes old sessions. Explicit session deletion removes that session's files; it requires recording to stop first. Local observations remain retained regardless of future upload status.

Replaying the journal validates schema, sequence, session identity, bounded record size, normalized gateway values, times, coordinates and finite accuracy/test measurements. A corrupt event leaves the original files intact. A valid prefix may be displayed, with an error; the damaged session cannot receive mutations or be exported as a complete archive. No attempt is made to rewrite away corrupt data. An unfinished session from a crash remains unfinished; the archive does not invent an end time or an unobserved gap duration.

## Position and missing data

An observation stores the original location source, coordinate, fix time and reported horizontal accuracy. Manual corrections append separate revisions. They never overwrite the original fix. A synthetic effective fix for a manual pin uses the manual source; its zero accuracy is a marker convention, never a claim of measured GPS accuracy. Presentation should say “Manual correction,” not “±0 m.”

A stored fix can be valid yet unusable for route rendering: the shared usability helper permits at most 60 seconds of age, five seconds in the future and 200 m accuracy. Automatic parked detection can apply stricter limits. Missing locations, radio metrics and speed tests stay optional. A missing measurement is never converted to zero. Explicit gaps retain start/end times and reason; open gaps have an unknown end.

Speed results retain their own start/end times and fixes, download, optional upload/latency, provider and eligibility. A speed test is paired with an observation UUID, not carried along subsequent route samples. An ineligible result can remain visible as a measurement while being excluded from the combined score. A tested-stop event records an automatic attempt before any network request, allowing the recorder to avoid repeated tests after relaunch or failure.

## Custom balanced score

`balanced-v1` is a custom equal-weight starting formula, not an industry standard. RSRP is normalized over −120…−80 dBm, SINR over −5…25 dB and tested download over 0…150 Mbps. Each normalized component is clamped to 0…100; the three components are averaged. Raw upload and latency remain available separately and do not contribute to this formula version.

A full score needs all three components, a recognized registered radio, a score-eligible speed result and original/start/end fixes with at most 100 m accuracy and 30 seconds of age. The test must be within five minutes of the radio observation, its endpoints within 100 m of each other and within 150 m of the observation. A manual correction farther than 150 m from the test invalidates the combined score. A result missing any requirement returns no complete score. Later formula changes must use another version rather than silently reinterpret an old version.

## Future sync capability

`pendingSyncEnvelope(for:afterSequence:limit:)` is serialization only. It returns up to 500 immutable events with stable event IDs, sequence cursor and schema version. `syncEnabled` is always false. There is no endpoint field, credentials, network client or uploader. A future client-owned tailnet-only connector must acknowledge immutable IDs, resume after confirmed sequences and preserve corrections as revisions. Acknowledgment must never automatically delete this Mac's archive.

`exportSession(_:)` creates a local JSON export with original observations, corrections, gaps, attempts and journal lineage. The app should save it to a user-selected local path. Exports contain precise location history and should remain on the local filesystem or a client-owned tailnet service.

## Validation

Run `zsh Tests/TMobileCoverageStoreTests.sh`. The harness uses temporary folders and synthetic readings only. It exercises opt-in recording, bounded immutable writes, permissions, replay, missing/stale/moving/ineligible speed, correction preservation, gap closure, durable stop attempts, long-lived sessions, explicit deletion, resumed export batches, corruption and write failures. It makes no location/router/network requests and reads no real preferences or credentials.
