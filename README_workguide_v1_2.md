# WorkGuide v1.2 — draft editing and accurate training statuses

## Files
- `index.html` — updated responsive English/Spanish prototype.
- `workguide_schema.sql` — original Supabase schema supplied with the previous build.
- `workguide_v1_1_personalization.sql` — personalization/group assignment migration supplied with the previous build.

## Updates in this revision
- Training & Sign-Off records open when clicked and include a clear Edit action; edits update the existing record.
- Skills Matrix status cells open a readable employee/skill detail panel with current status and training history. Each history item can open its training record, and a new training record can be started for that employee and skill.
- Procedure steps can be reordered by dragging the step card; step numbers update automatically after moving or removing a step.

## Fixes in v1.2
- Saved procedures can now be reopened and edited. Existing title, category, status, and steps are loaded into the editor; saving updates the existing record rather than creating a duplicate.
- Training records now display their actual selected outcome instead of always displaying “Qualified”.
- The Skills Matrix maps the selected outcome to the corresponding qualification status. Only `qualified` displays as qualified; `inTraining`, `pending`, `notTrained`, and `due` remain distinct.
- Training history labels show the actual recorded outcome.
- Added Spanish labels for editing and pending approval.

## Run
1. Extract the ZIP.
2. Open `index.html` in a modern browser.
3. Demo login: company `JJ-DEMO`, username `admin`, password `demo1234`.
4. Existing local browser demo data is stored in localStorage. The updated app uses the same `workguide_demo` key, so it should preserve data in the same browser profile.

## Important limitations
This remains a local demo prototype. It does not provide secure authentication, shared multi-device data, production role-based access, real group assignment workflows, or cloud media storage. The SQL files are a design foundation and must be reviewed and tested before production use. Do not enter confidential company information.
