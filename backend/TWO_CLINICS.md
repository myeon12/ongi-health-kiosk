# Two clinic operation

Student tablets use /?room=1 and /?room=2. Teacher login uses mw1 or mw2; the authenticated account determines its clinic even when opened from the other clinic URL. Existing records belong to clinic 1. Sessions, settings, counts, active records, history, edits, deletes and CSV exports are scoped by clinic on the server. No student room selector is shown.

For an existing deployment, apply setup-two-clinics.sql before kiosk_api.sql, then deploy kiosk-api/index.ts and public/index.html. setup-retention.sql preserves per-clinic periods and schedules daily deletion at 02:00 Asia/Seoul. Provision passwords separately; setup copies the legacy account hash for new accounts only. Passwords must never be committed.

The application budget is shared across both clinics per UTC calendar month: 150,000 accepted RPC requests and 512 MiB estimated response traffic, with a 1 MiB reservation per response. At 80%, automatic requests stop. At the hard threshold, operations return a direct-contact message; a browser stores only the pause deadline to avoid repeated requests. Server estimates response JSON bytes plus 2 KiB per accepted request. Requests over 1 MiB require narrower filters.

Automatic polling runs on visible pages only, Monday–Friday 07:00–18:00 Asia/Seoul: students 60 seconds, active teacher lists 15 seconds. Unchanged active lists return only a revision acknowledgement. Teachers lock after 15 minutes without input. Completed/cancelled records retain the configured period (initially 30 days).

These are application limits, not provider billing controls. Invalid/blocked Edge Function invocations, request traffic, provider overhead, static site transfers, other projects and abuse are not fully counted. They cannot guarantee free-plan compliance. No paid upgrade is enabled by this implementation.

Verified: rollback integration tests cover same-student concurrent reception in both clinics, client clinic spoofing, cross-clinic edit/delete/status rejection, revision changes, and soft/hard budget responses. Live service-role and Edge Function login/list/revision checks pass for both accounts. DOM tests cover room-specific entry screens, generic URL guidance and two-field teacher login.
